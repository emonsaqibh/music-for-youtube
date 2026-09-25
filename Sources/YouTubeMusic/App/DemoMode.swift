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
        if CommandLine.arguments.contains("--demo-playlist") {
            // A long public playlist, open on screen and playing — the page and queue a
            // signed-in user has when they play one of their own.
            if let card = try? await Catalog.search("hindi hits playlist", filter: .playlists)
                .flatMap(\.cards).first(where: { $0.kind == .playlist }),
               let id = card.playlistId ?? card.browseId,
               let (page, _) = try? await Catalog.playlistFirstPage(playlistId: id), !page.tracks.isEmpty {
                NotificationCenter.default.post(name: .demoOpenPlaylist, object: nil,
                                                userInfo: ["id": id, "title": card.title])
                PlayerController.shared.play(page.tracks, source: card.title)
                return
            }
        }
        if CommandLine.arguments.contains("--demo-long-queue") {
            // A queue as long as a big playlist's, songs repeating, to exercise the panel.
            var pool = [track]
            for query in ["Daft Punk", "The Weeknd", "Coldplay", "Dua Lipa", "Arijit Singh"] {
                pool += (try? await Catalog.search(query, filter: .songs).flatMap(\.tracks)) ?? []
            }
            let long = (0..<2000).map { pool[$0 % pool.count] }
            PlayerController.shared.play(long, source: "Long Queue")
            return
        }
        PlayerController.shared.play(track, source: "Discover Mix")
    }
}

extension Notification.Name {
    /// `--demo-playlist`: show this playlist's page (userInfo "id", "title").
    static let demoOpenPlaylist = Notification.Name("demoOpenPlaylist")
}
