import SwiftUI

struct SearchView: View {
    @Environment(Router.self) private var router
    @Environment(PlayerController.self) private var player

    @State private var filter: SearchFilter = .all
    @State private var shelves: [Shelf] = []
    @State private var state: LoadState = .empty("Search for songs, albums, artists and playlists.")
    @State private var task: Task<Void, Never>?

    var body: some View {
        @Bindable var router = router

        // The query is typed in the sidebar's search field (⌘K); this page shows the
        // filters and the results.
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Search")
            filters
                .padding(.top, 8)
            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.shelfGap) {
                    ForEach(shelves) { shelf in
                        if shelf.tracks.isEmpty {
                            ShelfRow(shelf: shelf, tileWidth: 150)
                        } else {
                            trackShelf(shelf)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .padding(.bottom, Theme.playerClearance)
            }
            .overlay { StateOverlay(state: state) }
        }
        .onAppear {
            if !router.searchText.isEmpty && shelves.isEmpty { schedule(immediate: true) }
            router.searchFocusRequest += 1
        }
        .onChange(of: router.searchText) { _, _ in schedule() }
        .onChange(of: router.searchSubmitted) { _, _ in schedule(immediate: true) }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            ForEach(SearchFilter.allCases) { option in
                Button(option.label) {
                    filter = option
                    schedule(immediate: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(filter == option ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(filter == option ? Theme.accent : Color.primary.opacity(0.08))
                }
            }
            Spacer(minLength: 0)
        }
        .pageInsets()
        .padding(.bottom, 12)
    }

    private func trackShelf(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !shelf.title.isEmpty {
                SectionHeader(title: shelf.title).pageInsets()
            }
            TrackList(tracks: shelf.tracks) { offset in
                player.play(shelf.tracks, startingAt: offset, source: "Search")
            }

            if !shelf.cards.isEmpty {
                PagedShelf(items: shelf.cards, minItemWidth: 150) { CardTile(card: $0) }
            }
        }
    }

    /// Debounced so typing does not fire a request per keystroke.
    private func schedule(immediate: Bool = false) {
        task?.cancel()
        let query = router.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            shelves = []
            state = .empty("Search for songs, albums, artists and playlists.")
            return
        }
        task = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
            }
            state = .loading
            do {
                let result = try await Catalog.search(query, filter: filter)
                guard !Task.isCancelled else { return }
                shelves = result
                state = result.isEmpty ? .empty("No results for “\(query)”.") : .ready
            } catch {
                guard !Task.isCancelled else { return }
                shelves = []
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// A library section — a grid of collections, or a song list with Play and Shuffle.
struct LibraryView: View {
    let item: NavItem

    @Environment(PlayerController.self) private var player
    @State private var shelves: [Shelf] = []
    @State private var state: LoadState = .loading

    private var cards: [Card] { shelves.flatMap(\.cards) }
    private var tracks: [Track] { shelves.flatMap(\.tracks) }

    private let columns = [GridItem(.adaptive(minimum: Theme.tileWidth, maximum: 240), spacing: 20, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(text: item.title)

                if !tracks.isEmpty {
                    HStack(spacing: 10) {
                        PillButton(title: "Play", symbol: "play.fill") {
                            player.play(tracks, startingAt: 0, source: item.title)
                        }
                        PillButton(title: "Shuffle", symbol: "shuffle") {
                            player.shufflePlay(tracks, source: item.title)
                        }
                    }
                    .pageInsets()

                    TrackList(tracks: tracks, showArtwork: true) { offset in
                        player.play(tracks, startingAt: offset, source: item.title)
                    }
                }

                if !cards.isEmpty || isPlaylists {
                    LazyVGrid(columns: columns, spacing: 26) {
                        if isPlaylists, LibraryEditor.shared.canEdit { NewPlaylistTile() }
                        ForEach(cards) { CardTile(card: $0) }
                    }
                    .pageInsets()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.playerClearance)
        }
        .overlay { StateOverlay(state: state, retry: { Task { await refresh() } }) }
        .task(id: item.id) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await refresh() }
        }
    }

    /// The library's Playlists section, which starts with a New Playlist tile.
    private var isPlaylists: Bool { item.browseId == Guide.likedPlaylistsId }

    /// Remembered sections show at once; fetched again only when older than a minute.
    private func refresh() async {
        if let cached = Catalog.libraries.cached(Catalog.libraryKey(item)) {
            show(cached.value)
            if cached.age < PageCache<LibraryPage>.freshFor { return }
        } else {
            state = .loading
        }
        do {
            show(try await Catalog.library(item))
        } catch {
            guard shelves.isEmpty else { return }       // keep what's on screen
            state = .failed(error.localizedDescription)
        }
    }

    private func show(_ result: LibraryPage) {
        shelves = result.shelves
        state = result.shelves.allSatisfy(\.isEmpty) && !(isPlaylists && LibraryEditor.shared.canEdit)
            ? .empty(result.emptyMessage
                     ?? (Session.shared.isSignedIn
                         ? "Nothing in \(item.title) yet."
                         : "Sign in to YouTube Music to see your \(item.title.lowercased())."))
            : .ready
    }
}

/// The first tile on the Playlists page, as on YouTube Music: makes a new playlist.
private struct NewPlaylistTile: View {
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.12 : 0.07))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
            Text("New Playlist")
                .font(.system(size: 13, weight: .medium))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onTapGesture { LibraryEditor.shared.startNewPlaylist() }
        .help("New Playlist")
    }
}
