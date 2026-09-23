import Foundation
import Observation

enum RepeatMode: String, Sendable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var isActive: Bool { self != .off }
}

/// Owns the play queue and mirrors the web player's state.
///
/// The queue is ours, not YouTube's: we hand the hidden player one video at a time and
/// advance it when a track ends. That is what lets the native UI reorder, shuffle and
/// show Up Next the way Apple Music does, while YouTube still resolves the actual audio.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    // MARK: Observable state

    private(set) var queue: [Track] = []
    private(set) var index = -1
    private(set) var queueSource: String?

    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isAd = false
    private(set) var position: Double = 0 {
        didSet { positionStamp = .now }
    }
    private(set) var duration: Double = 0

    var repeatMode: RepeatMode = .off
    private(set) var isShuffling = false

    /// Non-nil while the user is dragging the scrubber.
    ///
    /// A drag whose end SwiftUI never delivers — released outside the window, or
    /// interrupted — would otherwise pin the position display forever, so the value
    /// expires on its own.
    var scrubTarget: Double? {
        didSet { armScrubExpiry() }
    }

    var volume: Double = 1 {
        didSet {
            guard abs(volume - oldValue) > 0.0001 else { return }
            isMuted = false
            Task { await engine.command("volume", volume * 100) }
        }
    }

    private(set) var isMuted = false

    // MARK: Derived

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var hasTrack: Bool { current != nil }
    var displayPosition: Double { scrubTarget ?? position }
    var progress: Double { duration > 0 ? min(1, displayPosition / duration) : 0 }

    /// The position right now, extrapolated from the last poll.
    ///
    /// The bridge only reports every 500ms, which is too coarse for synced lyrics — a line
    /// would light up as much as half a second late. Views that need it poll this on
    /// their own clock rather than making `position` itself tick faster.
    func livePosition(at date: Date = .now) -> Double {
        guard scrubTarget == nil, isPlaying, !isBuffering else { return displayPosition }
        let elapsed = min(max(0, date.timeIntervalSince(positionStamp)), 1.5)
        let live = position + elapsed
        return duration > 0 ? min(duration, live) : live
    }
    var upNext: [Track] { index >= 0 && index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }
    var canGoPrevious: Bool { index > 0 || position > 3 }
    var canGoNext: Bool { index + 1 < queue.count || repeatMode == .all }

    // MARK: Internals

    private var engine: WebEngine { .shared }
    private var unshuffled: [Track]?
    private var handledEndFor: String?
    private var loadWatchdog: Task<Void, Never>?
    private var didApplyInitialVolume = false
    private var scrubExpiry: Task<Void, Never>?
    @ObservationIgnored private var positionStamp = Date.now

    private init() {}

    func attach() {
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.start()
        NowPlaying.shared.install()
        GlobalHotkeys.install()
    }

    private func armScrubExpiry() {
        scrubExpiry?.cancel()
        guard scrubTarget != nil else { return }
        scrubExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.scrubTarget != nil else { return }
            self.scrubTarget = nil
        }
    }

    // MARK: Transport

    func toggle() {
        Task { await engine.command(isPlaying ? "pause" : "play") }
    }

    func play() { Task { await engine.command("play") } }
    func pause() { Task { await engine.command("pause") } }

    func seek(to seconds: Double) {
        position = max(0, seconds)
        Task { await engine.command("seek", max(0, seconds)) }
    }

    func skipForward(_ delta: Double = 15) { seek(to: min(duration, position + delta)) }
    func skipBackward(_ delta: Double = 15) { seek(to: max(0, position - delta)) }

    func toggleMute() {
        isMuted.toggle()
        Task { await engine.command("mute", isMuted) }
    }

    func next() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one, let track = current {
            seek(to: 0)
            Task { await load(track) }
            return
        }
        if index + 1 < queue.count {
            go(to: index + 1)
        } else if repeatMode == .all {
            go(to: 0)
        } else {
            Task { await engine.command("pause") }
        }
    }

    func previous() {
        // Matches every other music player: the first press restarts the track.
        if position > 3 || index <= 0 {
            seek(to: 0)
        } else {
            go(to: index - 1)
        }
    }

    func go(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        position = 0
        duration = Double(queue[newIndex].seconds ?? 0)
        Task { await load(queue[newIndex]) }
    }

    // MARK: Starting playback

    /// Plays one track and lets YouTube's radio fill in what comes next — the behaviour
    /// you get when you tap a song on the web player.
    func play(_ track: Track, source: String? = nil) {
        queue = [track]
        unshuffled = nil
        index = 0
        queueSource = source
        position = 0
        duration = Double(track.seconds ?? 0)
        Task { await load(track) }
        if AppSettings.shared.autoplayRadio { Task { await fillRadio(after: track) } }
    }

    /// Plays a whole album or playlist starting at `start`.
    func play(_ tracks: [Track], startingAt start: Int = 0, source: String? = nil) {
        guard tracks.indices.contains(start) else { return }
        queue = tracks
        unshuffled = nil
        isShuffling = false
        queueSource = source
        go(to: start)
    }

    func shufflePlay(_ tracks: [Track], source: String? = nil) {
        guard !tracks.isEmpty else { return }
        queue = tracks.shuffled()
        unshuffled = tracks
        isShuffling = true
        queueSource = source
        go(to: 0)
    }

    func playNext(_ track: Track) {
        guard index >= 0 else { return play(track) }
        queue.insert(track, at: min(index + 1, queue.count))
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty { play(track) } else { queue.append(track) }
    }

    func removeFromQueue(at offsets: IndexSet) {
        let removable = offsets.filter { $0 != index }
        guard !removable.isEmpty else { return }
        let before = removable.filter { $0 < index }.count
        queue.remove(atOffsets: IndexSet(removable))
        index -= before
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let currentId = current?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentId, let moved = queue.firstIndex(where: { $0.id == currentId }) {
            index = moved
        }
    }

    func clearQueue() {
        guard let track = current else { return queue.removeAll() }
        queue = [track]
        index = 0
    }

    // MARK: Modes

    func toggleShuffle() {
        isShuffling.toggle()
        guard let track = current else { return }

        if isShuffling {
            unshuffled = queue
            var rest = queue
            rest.remove(at: index)
            queue = [track] + rest.shuffled()
            index = 0
        } else if let original = unshuffled {
            queue = original
            index = original.firstIndex(where: { $0.id == track.id }) ?? 0
            unshuffled = nil
        }
    }

    func cycleRepeat() { repeatMode = repeatMode.next }

    /// Appends YouTube's autoplay radio behind a single track, so "play this song"
    /// keeps going the way it does on the web.
    private func fillRadio(after track: Track) async {
        // Let the player get its own media request away first; competing with it is what
        // makes this fetch fail.
        try? await Task.sleep(for: .milliseconds(1200))
        guard queue.count == 1, queue.first?.id == track.id else { return }
        do {
            let radio = try await Catalog.upNext(videoId: track.id)
            let rest = radio.filter { $0.id != track.id }
            guard !rest.isEmpty else {
                Log.write("radio: nothing returned for \(track.id)")
                return
            }
            // Only extend if the user has not started something else meanwhile.
            guard queue.count == 1, queue.first?.id == track.id else {
                Log.write("radio: queue moved on, discarding \(rest.count)")
                return
            }
            queue.append(contentsOf: rest)
            Log.write("radio: appended \(rest.count) tracks")
        } catch {
            Log.write("radio: failed — \(error.localizedDescription)")
        }
    }

    // MARK: Profiles

    /// Where to pick up once the engine has been rebuilt for another profile.
    private var resumePoint: (position: Double, playing: Bool)?

    /// Moves the engine to the other profile (account ⇄ guest), keeping the queue and
    /// the place in the current song.
    func switchProfile(to profile: Session.Profile) {
        if hasTrack { resumePoint = (position, isPlaying) }
        Log.write("profile: → \(profile.rawValue), resume at \(Int(position))s playing=\(isPlaying)")
        engine.switchProfile(to: profile)
    }

    private func restore(_ point: (position: Double, playing: Bool), on track: Track) async {
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(400))
            guard current?.id == track.id else { return }
            let snap = await engine.snapshot()
            guard snap.videoId == track.id, snap.isPlaying else { continue }
            if point.position > 3 { seek(to: point.position) }
            if !point.playing { await engine.command("pause") }
            Log.write("profile: resumed \(track.id) at \(Int(point.position))s")
            return
        }
        Log.write("profile: \(track.id) never started after the switch")
    }

    // MARK: Engine plumbing

    /// Set while a watch-page reload we started is in flight, so the page's `ready` knows
    /// to start the track rather than trust autoplay.
    private var watchReloadFor: String?
    /// One watch-page retry per track: if the reloaded page refuses it too, retrying
    /// again would only loop.
    private var lastWatchReload: (id: String, at: Date)?

    private func reloadViaWatchPage(_ track: Track) {
        if let last = lastWatchReload, last.id == track.id, Date.now.timeIntervalSince(last.at) < 30 {
            Log.write("load: \(track.id) failed again after a watch-page reload; giving up")
            return
        }
        lastWatchReload = (track.id, .now)
        watchReloadFor = track.id
        engine.navigateToWatch(videoId: track.id)
    }

    private func load(_ track: Track) async {
        handledEndFor = nil
        loadWatchdog?.cancel()

        let accepted = await engine.command("load", track.id)
        if !accepted {
            Log.write("load: \(track.id) refused by the page; reloading via watch page")
            reloadViaWatchPage(track)
            return
        }

        // `loadVideoById` resolves the track but WebKit's autoplay policy leaves it
        // merely cued, so it needs an explicit nudge. A few retries also cover the case
        // where YouTube Music's own app resets the player right after we hand it a video.
        loadWatchdog = Task { [weak self] in
            guard let self else { return }
            // Startup is occasionally slow — YouTube can sit unstarted for ten seconds
            // before it takes the nudge — so keep prodding for a while before falling
            // back to the (slower but always reliable) watch-page load.
            var unstarted = 0
            for attempt in 0..<22 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 220 : 700))
                guard !Task.isCancelled, self.current?.id == track.id else { return }

                let snap = await self.engine.snapshot()
                // Playing, or deliberately paused by the user — nothing to do.
                if snap.videoId == track.id, snap.isPlaying || snap.state == 2 { return }

                // Buffering can legitimately take a while, but a player that keeps
                // ignoring the nudge and sits *unstarted* is stuck; waiting out the full
                // loop just leaves the user in silence for fifteen seconds.
                unstarted = snap.videoId == track.id && snap.isUnstarted ? unstarted + 1 : 0
                if unstarted >= 8 {
                    Log.write("player unstarted on \(track.id) after nudges; reloading via watch page")
                    self.reloadViaWatchPage(track)
                    return
                }

                if snap.videoId == track.id {
                    await self.engine.command("play")
                } else if attempt >= 8 {
                    self.reloadViaWatchPage(track)
                    return
                }
            }
            guard !Task.isCancelled, self.current?.id == track.id else { return }
            Log.write("player stalled on \(track.id); reloading via watch page")
            self.reloadViaWatchPage(track)
        }
    }

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .ready(_, let snapshot):
            apply(snapshot)
            // A reload dropped the audio; resume whatever we were on.
            // …or we sent the page to the watch URL ourselves, and the track it loaded
            // still needs starting: autoplay there is no more reliable than loadVideoById.
            if let track = current, snapshot.videoId != track.id || watchReloadFor == track.id {
                watchReloadFor = nil
                let resume = resumePoint
                resumePoint = nil
                Task {
                    await load(track)
                    if let resume { await restore(resume, on: track) }
                }
            }

        case .snapshot(let snapshot):
            apply(snapshot)

        case .remote(let action, let time):
            switch action {
            case "play": play()
            case "pause": pause()
            case "next": next()
            case "previous": previous()
            case "stop": pause()
            case "seek": if let time { seek(to: time) }
            default: break
            }

        case .playerError:
            // Unplayable (region-locked, taken down) — don't strand the queue on it.
            next()

        case .log(let text):
            // The bridge's own account of a failed command — the only place a JavaScript
            // exception inside the web player surfaces.
            Log.write("bridge: \(text)")

        case .injected:
            break
        }
    }

    private func apply(_ snapshot: PlayerSnapshot) {
        guard snapshot.ok else { return }

        isPlaying = snapshot.isPlaying
        isBuffering = snapshot.isBuffering
        isAd = snapshot.ad
        isMuted = snapshot.muted

        if !didApplyInitialVolume {
            didApplyInitialVolume = true
            volume = snapshot.volume / 100
        }

        // Ignore state that belongs to a track we already moved on from.
        guard let track = current, snapshot.videoId.isEmpty || snapshot.videoId == track.id else { return }

        if scrubTarget == nil { position = snapshot.time }
        if snapshot.duration > 0 { duration = snapshot.duration }

        if snapshot.hasEnded, handledEndFor != track.id {
            handledEndFor = track.id
            next()
        }

        NowPlaying.shared.update(from: self)
    }
}
