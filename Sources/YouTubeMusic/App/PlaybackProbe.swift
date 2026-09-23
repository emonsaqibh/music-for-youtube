import Foundation

/// Determines, empirically, how to make the hidden page actually start audio.
///
/// Three candidate strategies, tried in order, each logged in detail:
///   A — `loadVideoById` on whatever page is loaded, then nudge with `playVideo()`
///   B — a full navigation to `/watch?v=…`
///   C — `loadVideoById` again *after* B, i.e. once the app is in watch context
@MainActor
enum PlaybackProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe") }

    private static var engine: WebEngine { .shared }

    static func run() async {
        Log.reset()
        Log.write("=== playback probe ===")
        PlayerController.shared.attach()

        guard await engine.waitUntilReady(timeout: .seconds(40)) else {
            return finish("engine never bound")
        }

        var ids: [Track] = []
        do {
            ids = try await Catalog.search("Daft Punk Get Lucky", filter: .songs).flatMap(\.tracks)
        } catch {
            return finish("search failed: \(error.localizedDescription)")
        }
        guard ids.count >= 2 else { return finish("search gave < 2 tracks") }
        let first = ids[0], second = ids[1]
        Log.write("A/B track: \(first.id) \(first.title)")
        Log.write("C track:   \(second.id) \(second.title)")

        // ---- Strategy A ----
        Log.write("--- A: loadVideoById + playVideo nudges ---")
        await engine.command("load", first.id)
        var aWorked = false
        for tick in 1...10 {
            try? await Task.sleep(for: .seconds(1))
            await engine.command("play")
            let s = await engine.snapshot()
            Log.write("A t+\(tick) state=\(s.state) id=\(s.videoId) time=\(fmt(s.time)) dur=\(fmt(s.duration))")
            if s.isPlaying && s.time > 1 { aWorked = true; break }
        }
        await logPlayability("A")
        Log.write("A result: \(aWorked ? "WORKS" : "fails")")

        // ---- Strategy B ----
        Log.write("--- B: navigate to /watch ---")
        engine.navigateToWatch(videoId: first.id)
        _ = await engine.waitUntilReady(timeout: .seconds(30))
        var bWorked = false
        for tick in 1...15 {
            try? await Task.sleep(for: .seconds(1))
            let s = await engine.snapshot()
            Log.write("B t+\(tick) state=\(s.state) id=\(s.videoId) time=\(fmt(s.time)) dur=\(fmt(s.duration))")
            if s.isPlaying && s.time > 1 { bWorked = true; break }
            if tick == 4 { await engine.command("play") }
        }
        await logPlayability("B")
        Log.write("B result: \(bWorked ? "WORKS" : "fails")")

        // ---- Strategy C ----
        Log.write("--- C: loadVideoById while in watch context ---")
        await engine.command("load", second.id)
        var cWorked = false
        for tick in 1...10 {
            try? await Task.sleep(for: .seconds(1))
            let s = await engine.snapshot()
            Log.write("C t+\(tick) state=\(s.state) id=\(s.videoId) time=\(fmt(s.time)) dur=\(fmt(s.duration))")
            if s.isPlaying && s.videoId == second.id && s.time > 1 { cWorked = true; break }
            if tick == 3 { await engine.command("play") }
        }
        await logPlayability("C")
        Log.write("C result: \(cWorked ? "WORKS" : "fails")")

        finish("A=\(aWorked) B=\(bWorked) C=\(cWorked)")
    }

    private static func logPlayability(_ label: String) async {
        let p = await engine.playability()
        Log.write("\(label) playability: " + p.keys.sorted().map { "\($0)=\(p[$0] ?? "")" }.joined(separator: " "))
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }

    private static func finish(_ summary: String) {
        Log.write("=== probe done: \(summary) ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
    }
}
