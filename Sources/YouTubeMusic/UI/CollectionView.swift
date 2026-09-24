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
    @State private var saving = false
    @State private var suggestions: [Track] = []
    @State private var suggestionsRefresh: String?
    /// Search for songs to add, on an own playlist. Kept apart from the track list so
    /// typing never redraws it.
    @State private var addQuery = ""
    @State private var addResults: [Track] = []
    @State private var addSearching = false
    @State private var addSearchTask: Task<Void, Never>?
    @State private var addedIds: Set<String> = []

    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let collection {
                    hero(collection)
                    trackList(collection)
                    footer(collection)
                    if collection.isOwned {
                        suggestionsSection
                    }
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
                    .disabled(c.tracks.isEmpty)
                    PillButton(title: "Shuffle", symbol: "shuffle") {
                        player.shufflePlay(c.tracks, source: c.title)
                    }
                    .disabled(c.tracks.isEmpty)
                    if let saved = c.isSaved, !c.isOwned, c.saveTargetId != nil, LibraryEditor.shared.canEdit {
                        SaveButton(isSaved: saved, isWorking: saving) { toggleSaved() }
                    }
                }
                .padding(.top, 10)
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
                         showArtwork: !numbered, showAlbum: !numbered,
                         onRemove: c.kind == .playlist ? { remove(at: $0) } : nil) { offset in
            player.play(c.tracks, startingAt: offset, source: c.title)
        }
    }

    // MARK: Editing

    /// Takes the row out at once and puts it back if YouTube refuses.
    private func remove(at offset: Int) {
        guard case .playlist(let playlistId) = source, var c = collection, c.tracks.indices.contains(offset)
        else { return }
        let track = c.tracks.remove(at: offset)
        collection = c
        Task {
            do {
                try await LibraryEditor.shared.remove(track, from: playlistId)
                if let current = collection { Catalog.remember(current, playlistId: playlistId) }
            } catch {
                if var current = collection {
                    current.tracks.insert(track, at: min(offset, current.tracks.count))
                    collection = current
                }
                LibraryEditor.shared.show("Couldn’t remove “\(track.title)”", isError: true)
            }
        }
    }

    private func toggleSaved() {
        guard let c = collection, let saved = c.isSaved, let target = c.saveTargetId, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await LibraryEditor.shared.setSaved(!saved, targetId: target, title: c.title)
                collection?.isSaved = !saved
                Catalog.collections.remove { $0.hasPrefix(cacheKeyPrefix) }
            } catch {
                LibraryEditor.shared.show(saved ? "Couldn’t remove it from your library"
                                                : "Couldn’t save it to your library", isError: true)
            }
        }
    }

    // MARK: Suggestions

    private var isSearchingToAdd: Bool {
        addQuery.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// Under an own playlist: a search for any song to add, and YouTube Music's
    /// "Suggestions" while the search is empty — each with one-click add.
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isSearchingToAdd ? "Add Songs" : "Suggestions")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                if !isSearchingToAdd, let token = suggestionsRefresh {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await loadSuggestions(token) }
                    }
                    .buttonStyle(.glass)
                }
            }
            .pageInsets()

            addSearchField.pageInsets()

            let rows = isSearchingToAdd ? addResults : suggestions
            VStack(spacing: 0) {
                ForEach(rows) { track in
                    SuggestionRow(track: track, isAdded: isInPlaylist(track)) { add(track) }
                }
            }
            .padding(.horizontal, Theme.pageInset - 10)

            if isSearchingToAdd, !addSearching, addResults.isEmpty {
                Text("No songs found for “\(addQuery.trimmingCharacters(in: .whitespaces))”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .pageInsets()
            }
        }
    }

    private var addSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search for songs to add", text: $addQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { searchToAdd(immediately: true) }
            if addSearching {
                ProgressView().controlSize(.small)
            } else if !addQuery.isEmpty {
                Button { addQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        .onChange(of: addQuery) { _, _ in searchToAdd() }
    }

    /// Searches songs once typing pauses; a newer query cancels an older one.
    private func searchToAdd(immediately: Bool = false) {
        addSearchTask?.cancel()
        let query = addQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            addResults = []
            addSearching = false
            return
        }
        addSearchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            addSearching = true
            let found = (try? await Catalog.search(query, filter: .songs))?.flatMap(\.tracks) ?? []
            guard !Task.isCancelled else { return }
            addResults = Array(found.prefix(20))
            addSearching = false
        }
    }

    private func isInPlaylist(_ track: Track) -> Bool {
        addedIds.contains(track.id) || (collection?.tracks.contains { $0.id == track.id } ?? false)
    }

    private func loadSuggestions(_ token: String) async {
        guard let result = try? await Catalog.playlistSuggestions(token) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            suggestions = result.tracks
            suggestionsRefresh = result.refreshToken
        }
    }

    /// Adds a suggestion to the end of the playlist.
    private func add(_ track: Track) {
        guard case .playlist(let playlistId) = source else { return }
        addedIds.insert(track.id)
        withAnimation(.easeInOut(duration: 0.2)) { suggestions.removeAll { $0.id == track.id } }
        Task {
            do {
                if let setVideoId = try await Catalog.addReturningRow(track.id, to: playlistId) {
                    var added = track
                    added.setVideoId = setVideoId.isEmpty ? nil : setVideoId
                    added.isRemovable = !setVideoId.isEmpty
                    collection?.tracks.append(added)
                    if let current = collection { Catalog.remember(current, playlistId: playlistId) }
                } else {
                    LibraryEditor.shared.show("“\(track.title)” is already in this playlist")
                }
            } catch {
                addedIds.remove(track.id)
                withAnimation { suggestions.insert(track, at: 0) }
                LibraryEditor.shared.show("Couldn’t add “\(track.title)”", isError: true)
            }
        }
    }

    /// The remembered copy of this page, which a save makes stale.
    private var cacheKeyPrefix: String {
        switch source {
        case .album(let browseId): "album|\(browseId)|"
        case .playlist(let playlistId): "playlist|\(playlistId)|"
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
        if suggestions.isEmpty, suggestionsRefresh == nil, let token = result.suggestionsToken {
            suggestionsRefresh = token      // marks it as asked for
            Task { await loadSuggestions(token) }
        }
        collection = result
        state = result.tracks.isEmpty && result.title.isEmpty
            ? .empty("This collection came back empty.")
            : .ready
    }
}

/// One suggested song: artwork, title and artist, and a + that adds it.
private struct SuggestionRow: View {
    let track: Track
    /// Already in the playlist (or just added): a tick instead of the add button.
    var isAdded = false
    let onAdd: () -> Void

    @Environment(PlayerController.self) private var player
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.artwork, cornerRadius: 4)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 13)).lineLimit(1)
                Text(track.artistLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(track.seconds == nil ? "" : track.durationText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isAdded ? Color.secondary : Theme.accent)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
            .help(isAdded ? "In this playlist" : "Add to this playlist")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(hovering ? Color.primary.opacity(0.075) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { player.play(track, source: "Suggestions") }
    }
}

/// Save / Saved — the bookmark YouTube Music shows on playlists and albums that aren't
/// the account's own.
private struct SaveButton: View {
    let isSaved: Bool
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "checkmark" : "plus")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 84)
                .frame(height: 30)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .disabled(isWorking)
        .help(isSaved ? "Remove from your library" : "Save to your library")
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
