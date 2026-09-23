import SwiftUI

/// A single song row. Doubles as the album listing (numbered, no artwork) and the
/// playlist / search listing (artwork, album column).
struct TrackRow: View {
    let track: Track
    var number: Int?
    var showArtwork = true
    var showAlbum = false
    var albumWidth: CGFloat = 190
    /// Alternate rows get a faint band, as in Music.app's song lists.
    var striped = false
    let onPlay: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(Router.self) private var router
    @State private var hovering = false

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.system(size: 13))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    if track.isExplicit { ExplicitBadge() }
                }
                if !track.artistLine.isEmpty {
                    Text(track.artistLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if showAlbum, let album = track.album?.name, !album.isEmpty {
                Text(album)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: albumWidth, alignment: .leading)
            }

            // Home-feed rows often arrive without a duration; leave the column blank
            // rather than printing a placeholder.
            Text(track.seconds == nil ? "" : track.durationText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(track) }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(track) }
                Divider()
                if let artist = track.artists.first, let id = artist.id {
                    Button("Go to Artist", systemImage: "music.mic") { router.open(.artist(id)) }
                }
                if let album = track.album, let id = album.id {
                    Button("Go to Album", systemImage: "square.stack") { router.open(.album(id)) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.075)
                      : striped ? Color.primary.opacity(0.035) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: onPlay)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(track) }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(track) }
        }
    }

    @ViewBuilder
    private var leading: some View {
        ZStack {
            if showArtwork {
                Artwork(url: track.artwork, cornerRadius: 4)
                    .frame(width: 40, height: 40)
                    .opacity(hovering ? 0.45 : 1)
            } else {
                Group {
                    if isCurrent && player.isPlaying {
                        PlayingIndicator()
                    } else if !hovering {
                        Text(number.map(String.init) ?? "")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(isCurrent ? Theme.accent : .secondary)
                    }
                }
                .frame(width: 26)
            }

            if hovering {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: showArtwork ? 14 : 11, weight: .semibold))
                        .foregroundStyle(showArtwork ? .white : Color.primary)
                        .frame(width: showArtwork ? 40 : 26, height: showArtwork ? 40 : 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: showArtwork ? 40 : 26)
    }

}

/// A song listing that adapts to its width: the album column only appears when there is
/// room for it, and grows with the window rather than staying a fixed 190pt.
struct TrackList: View {
    let tracks: [Track]
    var numbered = false
    var showArtwork = true
    var showAlbum = true
    let onPlay: (Int) -> Void

    @State private var width: CGFloat = 800

    var body: some View {
        let albumColumn = showAlbum && width > 620
        LazyVStack(spacing: 0) {
            // Offsets, not video ids: the same song can legitimately appear twice.
            ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                TrackRow(track: track,
                         number: numbered ? offset + 1 : nil,
                         showArtwork: showArtwork,
                         showAlbum: albumColumn,
                         albumWidth: min(260, max(150, width * 0.26)),
                         striped: offset.isMultiple(of: 2)) {
                    onPlay(offset)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.horizontal, Theme.pageInset - 10)
    }
}

/// The small "E" marker YouTube attaches to explicit tracks.
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 12)
            .background(Color.primary.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
    }
}

/// The three dancing bars Apple Music shows beside the playing track.
struct PlayingIndicator: View {
    var color: Color = Theme.accent
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: height(for: i))
            }
        }
        .frame(width: 14, height: 13, alignment: .bottom)
        .task {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func height(for index: Int) -> CGFloat {
        let base: [CGFloat] = [11, 5, 8]
        let peak: [CGFloat] = [4, 13, 6]
        return base[index] + (peak[index] - base[index]) * phase
    }
}
