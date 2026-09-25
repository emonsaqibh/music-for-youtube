import SwiftUI

/// Listening history: the songs played recently, grouped under YouTube's own headings
/// (Today, Yesterday, …). Fetched afresh on every visit, since it changes with each song.
struct HistoryView: View {
    let title: String

    @Environment(PlayerController.self) private var player
    @State private var shelves: [Shelf] = []
    @State private var state: LoadState = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(text: title)

                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                        VStack(alignment: .leading, spacing: 10) {
                            if !shelf.title.isEmpty {
                                SectionHeader(title: shelf.title).pageInsets()
                            }
                            // A row plays the history onward from there, into older sections.
                            let before = shelves[..<index].reduce(0) { $0 + $1.tracks.count }
                            TrackList(tracks: shelf.tracks) { offset in
                                player.play(shelves.flatMap(\.tracks), startingAt: before + offset, source: title)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.playerClearance)
        }
        .overlay { StateOverlay(state: state, retry: { Task { await load() } }) }
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let page = try await Catalog.history()
            shelves = page.shelves
            state = shelves.isEmpty
                ? .empty(page.emptyMessage ?? "Songs you play will show up here.")
                : .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
