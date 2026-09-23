import SwiftUI

enum CollectionSource: Hashable {
    case album(String)      // browseId
    case playlist(String)   // playlistId
}

/// Album and playlist detail: hero artwork, metadata, Play / Shuffle, track listing.
struct CollectionView: View {
    let source: CollectionSource
    var fallbackTitle: String = ""

    @Environment(PlayerController.self) private var player
    @Environment(Router.self) private var router

    @State private var collection: Collection?
    @State private var state: LoadState = .loading

    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let collection {
                    hero(collection)
                    trackList(collection)
                    footer(collection)
                    ForEach(collection.shelves) { ShelfRow(shelf: $0, tileWidth: 150) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, Theme.playerClearance)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay { StateOverlay(state: state, retry: { Task { await refresh() } }) }
        .task(id: source) { await refresh() }
    }

    // MARK: Hero

    /// Artwork beside the metadata, as Music.app lays it out — until the column gets too
    /// narrow for both, when the metadata moves underneath.
    private var stacked: Bool { width < 560 }
    private var artSize: CGFloat { stacked ? min(260, width - Theme.pageInset * 2) : min(270, max(170, width * 0.26)) }

    @ViewBuilder
    private func hero(_ c: Collection) -> some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 26))
        layout {
            Artwork(url: c.artwork, cornerRadius: 12,
                    symbol: c.kind == .playlist ? "music.note.list" : "square.stack")
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(c.title)
                    .font(.system(size: width < 700 ? 26 : 32, weight: .bold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !c.subtitle.isEmpty {
                    Text(c.subtitle)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(2)
                }
                if !c.secondSubtitle.isEmpty {
                    Text(c.secondSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if let description = c.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .help(description)
                }

                HStack(spacing: 10) {
                    PillButton(title: "Play", symbol: "play.fill") {
                        player.play(c.tracks, startingAt: 0, source: c.title)
                    }
                    PillButton(title: "Shuffle", symbol: "shuffle") {
                        player.shufflePlay(c.tracks, source: c.title)
                    }
                }
                .padding(.top, 10)
                .disabled(c.tracks.isEmpty)
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageInsets()
    }

    // MARK: Tracks

    private func trackList(_ c: Collection) -> some View {
        // Albums number their rows; playlists show artwork because the artists vary.
        let numbered = c.kind != .playlist
        return TrackList(tracks: c.tracks, numbered: numbered,
                         showArtwork: !numbered, showAlbum: !numbered) { offset in
            player.play(c.tracks, startingAt: offset, source: c.title)
        }
    }

    private func footer(_ c: Collection) -> some View {
        Text("\(c.tracks.count) song\(c.tracks.count == 1 ? "" : "s") · \(Format.longDuration(c.totalSeconds))")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .pageInsets()
    }

    // MARK: Loading

    /// A remembered album or playlist shows at once (refetched behind it when older than a
    /// minute). A playlist shows its first 100 tracks as soon as they arrive; the rest
    /// fill in underneath.
    private func refresh() async {
        let started = ContinuousClock.now
        defer { if WebEngine.tracesPerf { Log.write("perf page collection shown in \(WebEngine.ms(ContinuousClock.now - started))") } }

        let key: String
        switch source {
        case .album(let browseId): key = Catalog.collectionKey(album: browseId)
        case .playlist(let playlistId): key = Catalog.collectionKey(playlist: playlistId)
        }
        if let cached = Catalog.collections.cached(key) {
            show(cached.value)
            if cached.age < PageCache<Collection>.freshFor { return }
        } else {
            state = .loading
        }

        do {
            switch source {
            case .album(let browseId):
                show(try await Catalog.album(browseId: browseId))
            case .playlist(let playlistId):
                var (result, token) = try await Catalog.playlistFirstPage(playlistId: playlistId)
                if collection == nil || token == nil { show(result) }
                var pages = 0
                while let next = token, pages < 12, !Task.isCancelled {
                    let (more, following) = try await Catalog.playlistMore(next)
                    if more.isEmpty { break }
                    result.tracks.append(contentsOf: more)
                    if collection?.tracks.count ?? 0 < result.tracks.count { show(result) }
                    token = following
                    pages += 1
                }
                show(result)
                Catalog.remember(result, playlistId: playlistId)
            }
        } catch {
            guard collection == nil else { return }     // keep what's on screen
            state = .failed(error.localizedDescription)
        }
    }

    private func show(_ result: Collection) {
        collection = result
        state = result.tracks.isEmpty && result.title.isEmpty
            ? .empty("This collection came back empty.")
            : .ready
    }
}

/// Artist page: full-bleed hero, then the artist's shelves.
struct ArtistView: View {
    let browseId: String

    @Environment(PlayerController.self) private var player
    @State private var artist: ArtistPage?
    @State private var state: LoadState = .loading

    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.shelfGap) {
                if let artist {
                    hero(artist)
                    ForEach(artist.shelves) { ShelfRow(shelf: $0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.playerClearance)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay { StateOverlay(state: state, retry: { Task { await refresh() } }) }
        .task(id: browseId) { await refresh() }
    }

    private func hero(_ a: ArtistPage) -> some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: a.artwork, cornerRadius: 0, symbol: "music.mic")
                .frame(height: min(460, max(260, width * 0.42)))
                .clipped()
                .overlay {
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.3), .black.opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom)
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(a.name)
                    .font(.system(size: width < 700 ? 34 : 44, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.3), radius: 12)

                if let subscribers = a.subscribers {
                    Text(subscribers)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }

                HStack(spacing: 10) {
                    PillButton(title: "Play", symbol: "play.fill") {
                        Task { await playTop(a, shuffled: false) }
                    }
                    PillButton(title: "Shuffle", symbol: "shuffle") {
                        Task { await playTop(a, shuffled: true) }
                    }
                }
            }
            .padding(.horizontal, Theme.pageInset)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playTop(_ a: ArtistPage, shuffled: Bool) async {
        // Prefer the artist's own top-songs shelf; fall back to the shuffle playlist.
        if let songs = a.shelves.first(where: { !$0.tracks.isEmpty })?.tracks, !songs.isEmpty {
            shuffled ? player.shufflePlay(songs, source: a.name)
                     : player.play(songs, startingAt: 0, source: a.name)
            return
        }
        guard let playlistId = shuffled ? (a.shufflePlaylistId ?? a.radioPlaylistId)
                                        : (a.radioPlaylistId ?? a.shufflePlaylistId),
              let tracks = try? await Catalog.tracks(inPlaylist: playlistId), !tracks.isEmpty
        else { return }
        player.play(tracks, startingAt: 0, source: a.name)
    }

    private func refresh() async {
        let started = ContinuousClock.now
        defer { if WebEngine.tracesPerf { Log.write("perf page artist shown in \(WebEngine.ms(ContinuousClock.now - started))") } }
        // A remembered artist shows at once; refetched behind it when older than a minute.
        if let cached = Catalog.artists.cached(Catalog.artistKey(browseId)) {
            artist = cached.value
            state = .ready
            if cached.age < PageCache<ArtistPage>.freshFor { return }
        } else {
            state = .loading
        }
        do {
            let result = try await Catalog.artist(browseId: browseId)
            artist = result
            state = result.shelves.isEmpty && result.name.isEmpty ? .empty("No artist page found.") : .ready
        } catch {
            guard artist == nil else { return }         // keep what's on screen
            state = .failed(error.localizedDescription)
        }
    }
}
