import Observation
import SwiftUI

/// Lyrics for whatever is playing. Shared by the side panel and the full-screen player,
/// so switching between them never refetches.
@MainActor
@Observable
final class LyricsStore {
    static let shared = LyricsStore()

    enum State: Equatable {
        case idle
        case loading
        case loaded(Lyrics)
        case unavailable
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var videoId: String?

    private init() {}

    func load(for track: Track?, force: Bool = false) async {
        guard let track else {
            videoId = nil
            state = .idle
            return
        }
        if !force, track.id == videoId, state != .idle { return }
        if case .failed = state, track.id == videoId, !force { return }

        videoId = track.id
        state = .loading

        // The lookup is a second `next` call; issuing it on the same beat as the player's
        // own media request is what makes InnerTube fetches fail, so let playback go first.
        // Carried on even if the view that asked goes away: another view may be waiting on
        // the same result, and it is cached for next time either way.
        try? await Task.sleep(for: .milliseconds(500))
        guard videoId == track.id else { return }

        do {
            let lyrics = try await Catalog.lyrics(videoId: track.id)
            guard videoId == track.id else { return }
            state = lyrics.isEmpty ? .unavailable : .loaded(lyrics)
        } catch {
            guard videoId == track.id else { return }
            Log.write("lyrics: \(track.id) failed — \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }
}

/// Lyrics presentation. `immersive` is the full-screen player's large type over the
/// artwork; `panel` is the side panel next to the library.
struct LyricsView: View {
    enum Style {
        case immersive, panel

        @MainActor var fontSize: CGFloat { (self == .immersive ? 30 : 21) * AppSettings.shared.lyricsSize.scale }
        @MainActor var lineSpacing: CGFloat { (self == .immersive ? 22 : 14) * AppSettings.shared.lyricsSize.scale }
    }

    var style: Style

    @Environment(PlayerController.self) private var player
    private var store: LyricsStore { .shared }

    var body: some View {
        Group {
            switch store.state {
            case .loaded(let lyrics):
                if lyrics.isSynced {
                    SyncedLyricsView(lyrics: lyrics, style: style)
                } else {
                    PlainLyricsView(lyrics: lyrics, style: style)
                }
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                notice("Lyrics aren’t available for this song.")
            case .failed:
                notice("Lyrics couldn’t be loaded.", retry: true)
            case .idle:
                notice(player.hasTrack ? "" : "Play a song to see its lyrics here.")
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: store.state)
        .task(id: player.current?.id) { await store.load(for: player.current) }
    }

    private func notice(_ text: String, retry: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: style == .immersive ? 16 : 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("Try Again") { Task { await store.load(for: player.current, force: true) } }
                    .buttonStyle(.glass)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Synced

/// Time-synced lyrics: the current line is lit and held a third of the way down, the rest
/// dimmed, the way Music.app does it. Clicking a line seeks to it. Scrolling by hand
/// suspends the follow for a few seconds so the user can read ahead.
private struct SyncedLyricsView: View {
    let lyrics: Lyrics
    let style: LyricsView.Style

    @Environment(PlayerController.self) private var player
    @State private var active: Int?
    @State private var manualScrollUntil: Date = .distantPast
    @State private var viewportHeight: CGFloat = 600

    /// Lines light up a touch early — reading lags hearing, and a line that appears
    /// exactly on its first syllable already feels late.
    private let lead: Double = 0.2

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: style.lineSpacing) {
                    ForEach(lyrics.lines) { line in
                        LyricLineView(line: line, style: style,
                                      isActive: line.id == active,
                                      isPast: (active ?? -1) > line.id)
                            .id(line.id)
                            .onTapGesture {
                                manualScrollUntil = .distantPast
                                player.seek(to: line.start)
                            }
                    }
                    if let source = lyrics.source {
                        Text(source)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, style == .immersive ? 8 : 20)
                // Room above the first and below the last line so either can sit at the
                // reading position.
                .padding(.top, viewportHeight * 0.3)
                .padding(.bottom, viewportHeight * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    manualScrollUntil = .now.addingTimeInterval(3.5)
                }
            }
            .mask(fadeMask)
            .onChange(of: active) { _, index in
                guard let index, Date.now > manualScrollUntil else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.88)) {
                    proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
            .onAppear {
                active = lyrics.lineIndex(at: player.livePosition() + lead)
                if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
        }
        .task(id: lyrics) {
            // Poll on our own clock: the bridge only reports every 500ms.
            while !Task.isCancelled {
                let index = lyrics.lineIndex(at: player.livePosition() + lead)
                if index != active { active = index }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// Lines fade out towards the top and bottom edges rather than being cut off.
    private var fadeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.86),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    let style: LyricsView.Style
    let isActive: Bool
    let isPast: Bool

    @State private var hovering = false

    var body: some View {
        Group {
            if line.isInstrumental {
                InstrumentalDots(isActive: isActive, size: style.fontSize * 0.34)
                    .frame(height: style.fontSize * 1.1, alignment: .leading)
            } else {
                Text(line.text)
                    .font(.system(size: style.fontSize, weight: .bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color.primary.opacity(opacity))
        .scaleEffect(isActive ? 1 : 0.96, anchor: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering && !isActive ? 0.07 : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.3), value: isActive)
        .help(Format.time(line.start))
    }

    private var opacity: Double {
        if isActive { return 1 }
        if hovering { return 0.6 }
        return isPast ? 0.26 : 0.32
    }
}

/// The three breathing dots Music.app shows through instrumental passages.
private struct InstrumentalDots: View {
    let isActive: Bool
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.7) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = isActive ? (sin(t * 3 - Double(i) * 0.7) + 1) / 2 : 0
                    Circle()
                        .frame(width: size, height: size)
                        .scaleEffect(0.75 + 0.35 * phase)
                        .opacity(isActive ? 0.55 + 0.45 * phase : 1)
                }
            }
        }
    }
}

// MARK: - Plain

private struct PlainLyricsView: View {
    let lyrics: Lyrics
    let style: LyricsView.Style

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(lyrics.plain ?? "")
                    .font(.system(size: (style == .immersive ? 22 : 16) * AppSettings.shared.lyricsSize.scale,
                                  weight: .semibold))
                    .lineSpacing(style == .immersive ? 8 : 5)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = lyrics.source {
                    Text(source)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, style == .immersive ? 18 : 30)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Side panel

/// The lyrics side panel, opened from the player pill.
struct LyricsPanel: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Artwork(url: player.current?.artwork, cornerRadius: 5)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? "Lyrics")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(player.current?.artistLine ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)

            LyricsView(style: .panel)
                .padding(.bottom, Theme.playerClearance - 40)
        }
    }
}
