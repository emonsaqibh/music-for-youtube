import SwiftUI

/// A chart of artists or shows (Charts' Top artists): numbered rows with the week's
/// movement, in columns of five that page sideways, as Music.app lays out its charts.
struct RankedShelfGrid: View {
    let shelf: Shelf
    var rows: Int = 5

    private struct Column: Identifiable {
        let cards: [Card]
        var id: String { cards.first?.id ?? "" }
    }

    private var columns: [Column] {
        stride(from: 0, to: shelf.cards.count, by: rows).map { start in
            Column(cards: Array(shelf.cards[start..<min(start + rows, shelf.cards.count)]))
        }
    }

    var body: some View {
        // Rows carry their own 8pt hover inset; the margin gives it back so the numbers
        // line up with the shelf title.
        PagedShelf(items: columns, minItemWidth: 300, spacing: 16, margin: Theme.pageInset - 8) { column in
            VStack(spacing: 0) {
                ForEach(Array(column.cards.enumerated()), id: \.element.id) { index, card in
                    RankedRow(card: card)
                    if index < column.cards.count - 1 {
                        Divider().padding(.leading, 8 + 34 + 12 + 56 + 12)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct RankedRow: View {
    let card: Card

    @Environment(Router.self) private var router
    @Environment(PlayerController.self) private var player
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let rank = card.rank { RankMark(rank: rank) }

            Artwork(url: card.artwork, cornerRadius: 6, circular: card.kind.isCircular,
                    symbol: card.kind == .artist ? "music.mic" : "mic")
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if card.playlistId != nil {
                Button { play() } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .opacity(hovering ? 1 : 0)
                .help("Play")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 72)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.055) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let route = card.route { router.open(route) } }
        .help(card.title)
    }

    /// An artist's shuffle — the playlist YouTube attaches to the row.
    private func play() {
        guard let playlistId = card.playlistId else { return }
        Task {
            guard let tracks = try? await Catalog.tracks(inPlaylist: playlistId), !tracks.isEmpty else { return }
            player.play(tracks, source: card.title)
        }
    }
}

/// A chart position over the arrow for how it moved: green up, red down, a dash if not.
struct RankMark: View {
    let rank: ChartRank

    var body: some View {
        VStack(spacing: 3) {
            Text(rank.position)
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            trend
        }
        .frame(width: 34)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trend: some View {
        switch rank.trend {
        case .up:
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 7))
                .foregroundStyle(.green)
        case .down:
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
        case .same:
            Capsule().fill(.tertiary).frame(width: 7, height: 2).frame(height: 7)
        case nil:
            Color.clear.frame(height: 7)
        }
    }
}
