import SwiftUI

/// Which songs the account likes, and liking them.
///
/// A song's like is known from the row it was played from (album, playlist and radio rows
/// carry it), from the `next` answers the radio and lyrics fetch anyway, and only when none
/// of those said, from one `next` request of its own.
@MainActor
@Observable
final class LikeStore {
    static let shared = LikeStore()

    /// Likes learned or changed this session. They win over what a remembered row says.
    private var known: [String: Bool] = [:]
    /// Songs with a like or unlike on its way, so a double click can't race itself.
    @ObservationIgnored private var sending: Set<String> = []
    @ObservationIgnored private var asking: Set<String> = []

    private init() {
        NotificationCenter.default.addObserver(forName: WebEngine.sessionDidChange, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { LikeStore.shared.known = [:] }
        }
    }

    /// Liking needs the account, signed in: not the guest profile, not a signed-out page.
    var canLike: Bool { LibraryEditor.shared.canEdit }

    /// Nil until something has said.
    func isLiked(_ track: Track) -> Bool? { known[track.id] ?? track.isLiked }

    /// A like read from a response. The first answer this session stands; after that only
    /// the user's own clicks change it.
    func learn(_ liked: Bool, for videoId: String) {
        if known[videoId] == nil { known[videoId] = liked }
    }

    /// Asks YouTube about a song nothing has said anything about yet.
    func resolve(_ track: Track) async {
        guard canLike, isLiked(track) == nil else { return }
        // The radio and lyrics fetch `next` for a new song anyway; give them time to answer
        // first. It also keeps clear of the player's own media request.
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled, canLike, isLiked(track) == nil, !asking.contains(track.id),
              PlayerController.shared.current?.id == track.id else { return }
        asking.insert(track.id)
        defer { asking.remove(track.id) }
        if let liked = try? await Catalog.isLiked(videoId: track.id) { learn(liked, for: track.id) }
    }

    /// Likes the song or takes the like back. The button changes at once; if YouTube
    /// refuses, it changes back and a notice says so.
    func toggle(_ track: Track) {
        guard canLike, !sending.contains(track.id) else { return }
        let liked = !(isLiked(track) ?? false)
        known[track.id] = liked
        sending.insert(track.id)
        Task {
            defer { self.sending.remove(track.id) }
            do {
                try await Catalog.setLiked(liked, videoId: track.id)
                // Liked Music's remembered pages no longer match.
                Catalog.collections.remove { $0.hasPrefix("playlist|LM|") || $0.hasPrefix("playlist|VLLM|") }
                Catalog.libraries.remove { $0.contains("FEmusic_liked_videos") }
            } catch {
                Log.write("like: \(liked ? "like" : "removelike") \(track.id) failed — \(error.localizedDescription)")
                self.known[track.id] = !liked
                LibraryEditor.shared.show(liked ? "Couldn’t like “\(track.title)”"
                                                : "Couldn’t remove the like from “\(track.title)”",
                                          isError: true)
            }
        }
    }
}

/// A thumbs-up for the song that's playing, filled in the accent colour when it's liked.
/// Draws nothing without a song, or when the account can't like (guest, signed out).
struct LikeButton: View {
    var size: CGFloat = 13

    private var player: PlayerController { .shared }
    private var likes: LikeStore { .shared }

    var body: some View {
        if let track = player.current, likes.canLike {
            let liked = likes.isLiked(track) == true
            TransportButton(symbol: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                            size: size, isActive: liked) { likes.toggle(track) }
                .contentTransition(.symbolEffect(.replace))
                .help(liked ? "Unlike" : "Like")
                .task(id: track.id) { await likes.resolve(track) }
        }
    }
}
