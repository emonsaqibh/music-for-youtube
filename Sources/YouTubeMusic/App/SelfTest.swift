import Foundation
import MediaPlayer

/// Scripted end-to-end check of the playback path, run with `--selftest`.
///
/// Playback is the one part of this app that cannot be verified by compiling: it depends
/// on whether YouTube's player object accepts `loadVideoById` inside the hidden page.
/// This drives a real track through the whole stack and writes what happened to the log.
@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    static func run() async {
        Log.reset()
        Log.write("=== selftest start ===")

        let engine = WebEngine.shared
        let player = PlayerController.shared
        player.attach()

        let clock = ContinuousClock()
        let started = clock.now
        let ready = await engine.waitUntilReady(timeout: .seconds(40))
        Log.write("engine ready=\(ready) after \(started.duration(to: clock.now))")
        guard ready else { return finish(false, "engine never bound to #movie_player") }

        let diagnostics = await engine.diagnostics()
        Log.write("page: \(diagnostics.keys.sorted().map { "\($0)=\(diagnostics[$0] ?? "")" }.joined(separator: " "))")

        // 1. Search resolves a real videoId.
        var track: Track?
        do {
            let shelves = try await Catalog.search("Daft Punk Get Lucky", filter: .songs)
            track = shelves.flatMap(\.tracks).first
            Log.write("search shelves=\(shelves.count) tracks=\(shelves.flatMap(\.tracks).count)")
        } catch {
            Log.write("search FAILED: \(error.localizedDescription)")
        }
        guard let track else { return finish(false, "search returned no playable track") }
        Log.write("track: \(track.id) \(track.title) — \(track.artistLine) (\(track.durationText))")

        // 2. Playback starts.
        player.play(track, source: "selftest")
        var startedPlaying = false
        for tick in 1...20 {
            try? await Task.sleep(for: .seconds(1))
            let s = await engine.snapshot()
            Log.write("t+\(tick)s state=\(s.state) id=\(s.videoId) time=\(String(format: "%.1f", s.time)) dur=\(String(format: "%.1f", s.duration)) ad=\(s.ad)")
            if s.isPlaying && s.time > 1.5 { startedPlaying = true; break }
        }
        guard startedPlaying else { return finish(false, "player never reached a playing state") }

        // 3. Seek lands.
        player.seek(to: 60)
        try? await Task.sleep(for: .seconds(2))
        let afterSeek = await engine.snapshot()
        Log.write("after seek -> time=\(String(format: "%.1f", afterSeek.time))")
        let seekWorked = afterSeek.time > 55

        // 4. Pause takes effect.
        player.pause()
        try? await Task.sleep(for: .milliseconds(900))
        let afterPause = await engine.snapshot()
        Log.write("after pause -> state=\(afterPause.state)")
        let pauseWorked = !afterPause.isPlaying

        // 5. Radio queue filled in behind the track.
        try? await Task.sleep(for: .seconds(2))
        Log.write("queue=\(player.queue.count) upNext=\(player.upNext.count) source=\(player.queueSource ?? "-")")

        let radioFilled = player.queue.count > 1

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let nowPlayingOK = (info[MPMediaItemPropertyTitle] as? String)?.isEmpty == false
        Log.write("nowPlaying title=\(info[MPMediaItemPropertyTitle] as? String ?? "-") "
                  + "artist=\(info[MPMediaItemPropertyArtist] as? String ?? "-") "
                  + "duration=\(info[MPMediaItemPropertyPlaybackDuration] as? Double ?? -1) "
                  + "artwork=\(info[MPMediaItemPropertyArtwork] != nil) "
                  + "state=\(MPNowPlayingInfoCenter.default().playbackState.rawValue)")

        finish(seekWorked && pauseWorked && radioFilled && nowPlayingOK,
               "play=ok seek=\(seekWorked ? "ok" : "FAIL") pause=\(pauseWorked ? "ok" : "FAIL") "
               + "radio=\(radioFilled ? "ok" : "FAIL") nowPlaying=\(nowPlayingOK ? "ok" : "FAIL") queue=\(player.queue.count)")
    }

    private static func finish(_ passed: Bool, _ summary: String) {
        Log.write("=== selftest \(passed ? "PASS" : "FAIL"): \(summary) ===")
        // Give the log queue a moment to flush before tearing the process down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(passed ? 0 : 1) }
    }
}
