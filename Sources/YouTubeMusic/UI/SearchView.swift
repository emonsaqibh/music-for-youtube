import SwiftUI

struct SearchView: View {
    @Environment(Router.self) private var router
    @Environment(PlayerController.self) private var player

    @State private var filter: SearchFilter = .all
    @State private var shelves: [Shelf] = []
    @State private var state: LoadState = .empty("Search for songs, albums, artists and playlists.")
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var router = router

        VStack(spacing: 0) {
            field(text: $router.searchText)
            filters
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
        .onAppear { focused = true }
    }

    private func field(text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search YouTube Music", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { schedule(immediate: true) }
                .onChange(of: text.wrappedValue) { _, _ in schedule() }
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                    shelves = []
                    state = .empty("Search for songs, albums, artists and playlists.")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary.opacity(0.55))
        }
        .padding(.horizontal, Theme.pageInset)
        .padding(.top, 14)
        .padding(.bottom, 10)
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

                if !cards.isEmpty {
                    LazyVGrid(columns: columns, spacing: 26) {
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
    }

    private func refresh() async {
        state = .loading
        do {
            let result = try await Catalog.library(item)
            shelves = result.shelves
            state = result.shelves.allSatisfy(\.isEmpty)
                ? .empty(result.emptyMessage
                         ?? (Session.shared.isSignedIn
                             ? "Nothing in \(item.title) yet."
                             : "Sign in to YouTube Music to see your \(item.title.lowercased())."))
                : .ready
        } catch {
            shelves = []
            state = .failed(error.localizedDescription)
        }
    }
}
