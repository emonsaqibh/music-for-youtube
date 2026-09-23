import Foundation

/// `--demo` starts the app with a real track playing and the queue panel open.
///
/// Playing state is where most of the UI actually lives — the player display, the queue,
/// the full-screen player — and none of it can be inspected from a cold launch. This
/// puts the app into that state without anyone having to click through to it.
@MainActor
enum DemoMode {
    static var isRequested: Bool { CommandLine.arguments.contains("--demo") }
    static var opensQueue: Bool { isRequested && !CommandLine.arguments.contains("--no-queue") }
    static var opensLyrics: Bool { CommandLine.arguments.contains("--demo-lyrics") }
    static var opensFullScreen: Bool { CommandLine.arguments.contains("--demo-fullscreen") }

    static func start() async {
        guard await WebEngine.shared.waitUntilReady(timeout: .seconds(40)) else { return }
        guard let track = try? await Catalog.search("Daft Punk Get Lucky", filter: .songs)
            .flatMap(\.tracks).first else { return }
        PlayerController.shared.play(track, source: "Discover Mix")
    }
}
