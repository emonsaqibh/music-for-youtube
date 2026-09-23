import SwiftUI

/// One tile in a shelf or grid: artwork, title, subtitle, and a play button on hover.
///
/// The tile fills whatever width it is given — shelves and grids size it so a whole
/// number of tiles fit the window. Pass `width` only where a fixed size is wanted.
struct CardTile: View {
    let card: Card
    var width: CGFloat?
    /// 16:9 artwork, for shelves of music videos.
    var wide = false

    @Environment(Router.self) private var router
    @Environment(PlayerController.self) private var player
    @State private var hovering = false

    private var circular: Bool { card.kind.isCircular }

    var body: some View {
        VStack(alignment: circular ? .center : .leading, spacing: 8) {
            Artwork(url: card.artwork,
                    cornerRadius: Theme.tileCorner,
                    circular: circular,
                    symbol: symbol)
                .aspectRatio(wide && !circular ? 16 / 9 : 1, contentMode: .fit)
                .shadow(color: .black.opacity(circular ? 0 : hovering ? 0.3 : 0.18),
                        radius: hovering ? 10 : 6, y: hovering ? 5 : 3)
                .overlay(alignment: .bottomTrailing) {
                    HoverPlayButton(isVisible: hovering && isPlayable) { playNow() }
                        .padding(9)
                }

            VStack(alignment: circular ? .center : .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(circular ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: circular ? .center : .leading)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onTapGesture { open() }
        .contextMenu { menuItems }
        .help(card.title)
    }

    @ViewBuilder
    private var menuItems: some View {
        if isPlayable { Button("Play", systemImage: "play.fill") { playNow() } }
        if card.browseId != nil {
            Button("Go to \(card.kind.rawValue.capitalized)", systemImage: "arrow.forward") { open() }
        }
    }

    private var symbol: String {
        switch card.kind {
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        case .podcast: "mic"
        case .video: "play.rectangle"
        default: "music.note"
        }
    }

    private var isPlayable: Bool { card.videoId != nil || card.playlistId != nil }

    private func open() {
        if let route = card.route { router.open(route) }
        else if isPlayable { playNow() }
    }

    private func playNow() {
        if let videoId = card.videoId {
            player.play(Track(id: videoId, title: card.title,
                              artists: [ArtistRef(id: nil, name: card.subtitle)],
                              artwork: card.artwork),
                        source: card.subtitle)
        } else if let playlistId = card.playlistId {
            Task {
                guard let tracks = try? await Catalog.tracks(inPlaylist: playlistId), !tracks.isEmpty else { return }
                player.play(tracks, source: card.title)
            }
        }
    }
}

extension Card {
    var route: Route? {
        guard let browseId else { return nil }
        switch kind {
        case .artist: return .artist(browseId)
        case .playlist: return .playlist(browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId)
        case .album, .single, .ep, .podcast: return .album(browseId)
        default: return browseId.hasPrefix("MPRE") ? .album(browseId) : nil
        }
    }
}
