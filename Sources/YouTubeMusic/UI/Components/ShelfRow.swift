import SwiftUI

enum LoadState: Equatable {
    case loading
    case ready
    case empty(String)
    case failed(String)
}

/// Shared loading / empty / error presentation so every page behaves the same.
struct StateOverlay: View {
    let state: LoadState
    var retry: (() -> Void)?

    var body: some View {
        switch state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty(let text):
            notice(symbol: "music.note.list", title: "Nothing here yet", detail: text)

        case .failed(let text):
            notice(symbol: "exclamationmark.triangle", title: "Couldn’t load", detail: text)

        case .ready:
            EmptyView()
        }
    }

    private func notice(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.glass)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// One horizontal shelf: a header plus a paging row of tiles, or a grid of songs.
struct ShelfRow: View {
    let shelf: Shelf
    /// The narrowest a tile may get; the real width fills the page evenly.
    var tileWidth: CGFloat = Theme.tileWidth

    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !shelf.title.isEmpty {
                SectionHeader(title: shelf.title, strapline: shelf.strapline, onSeeAll: seeAll)
                    .pageInsets()
            }

            if !shelf.buttons.isEmpty {
                ButtonShelf(shelf: shelf)
            }

            if !shelf.cards.isEmpty {
                // Music videos keep their 16:9 frame, in wider tiles, as on YouTube Music.
                let wide = shelf.cards.filter(\.isWide).count * 2 > shelf.cards.count
                let minWidth = wide ? tileWidth * 1.55 : tileWidth
                if shelf.cards.allSatisfy({ $0.rank != nil }) {
                    RankedShelfGrid(shelf: shelf)
                } else if shelf.isGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: minWidth * 1.5),
                                                 spacing: 20, alignment: .top)],
                              alignment: .leading, spacing: 26) {
                        ForEach(shelf.cards) { CardTile(card: $0, wide: wide) }
                    }
                    .pageInsets()
                } else {
                    PagedShelf(items: shelf.cards, minItemWidth: minWidth) { card in
                        CardTile(card: card, wide: wide)
                    }
                }
            }

            if !shelf.tracks.isEmpty {
                TrackShelfGrid(shelf: shelf)
            }
        }
    }

    private var seeAll: (() -> Void)? {
        guard let browseId = shelf.moreBrowseId else { return nil }
        return { router.open(.seeAll(browseId: browseId, params: shelf.moreParams, title: shelf.title)) }
    }
}

/// A page made of shelves — Home, Explore, and any "See All" destination.
///
/// Shows everything YouTube sends for the page, not just its first batch: the feed is
/// paged, so reaching the end fetches the next page, as music.youtube.com does. Home's
/// mood chips sit under the title and re-filter the whole feed.
struct FeedView: View {
    let title: String
    let browseId: String
    var params: String?

    @State private var shelves: [Shelf] = []
    @State private var chips: [FeedChip] = []
    @State private var continuation: String?
    @State private var state: LoadState = .loading
    /// Params of the chip currently applied, if any.
    @State private var chipParams: String?
    @State private var loadingMore = false
    @State private var pageCount = 0
    /// Charts' country menu, and the choice sent with the request.
    @State private var filter: FeedFilter?
    @State private var filterValue: String?
    /// The page on screen, and the one asked for. They differ while a chip's or country's
    /// page is on its way: the old one stays up, dimmed, instead of blanking to a spinner.
    @State private var shownKey: String?
    @State private var wantedKey: String?
    @State private var hoveredChip: String?

    private var isSwitching: Bool { wantedKey != nil && wantedKey != shownKey && shownKey != nil }

    /// The last choice is remembered per page, so Charts reopens on the same country.
    private var filterKey: String { "feed.filter." + browseId }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.shelfGap) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 0) {
                        PageTitle(text: title,
                                  badge: BuildFlavor.isDev && browseId == "FEmusic_home" ? "DEV" : nil)
                        if isSwitching {
                            ProgressView().controlSize(.small).padding(.top, Theme.contentTop)
                        }
                    }
                    if let filter {
                        FilterMenu(filter: filter) { choose($0) }
                            .pageInsets()
                    }
                    if !chips.isEmpty {
                        ChipBar(chips: chips, onSelect: select, onHover: hover)
                    }
                }
                .padding(.bottom, chips.isEmpty && filter == nil ? 0 : -8)

                ForEach(Array(shelves.enumerated()), id: \.element.id) { order, shelf in
                    ShelfRow(shelf: shelf).appearIn(order: order)
                }
                    .opacity(isSwitching ? 0.45 : 1)
                    .animation(.easeOut(duration: 0.15), value: isSwitching)

                if let continuation {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        // A fresh identity per token, so reaching the end again after a
                        // page lands asks for the next one.
                        .id(continuation)
                        .onAppear { Task { await loadMore() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.playerClearance)
        }
        .overlay { StateOverlay(state: state, retry: { Task { await load() } }) }
        .task(id: browseId + (params ?? "")) {
            chipParams = nil
            filterValue = UserDefaults.standard.string(forKey: filterKey)
            await load()
        }
    }

    /// Marks the chip at once — the page follows, instantly if it was loaded before.
    private func select(_ chip: FeedChip) {
        chipParams = chip.isSelected ? chip.deselectParams : chip.params
        // The chip bar animates its own capsule; the page swap stays out of the transaction.
        chips = chips.map { other in
            var other = other
            other.isSelected = !chip.isSelected && other.id == chip.id
            return other
        }
        Task { await load(keepingChips: true) }
    }

    /// A pointer resting on a chip loads its page ahead of the click.
    private func hover(_ chip: FeedChip, _ inside: Bool) {
        hoveredChip = inside ? chip.id : (hoveredChip == chip.id ? nil : hoveredChip)
        guard inside else { return }
        let target = chip.isSelected ? chip.deselectParams : chip.params
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard hoveredChip == chip.id else { return }
            Catalog.prefetchFeed(browseId, params: target, filterValue: filterValue)
        }
    }

    private func choose(_ option: FeedFilter.Option) {
        filterValue = option.value
        UserDefaults.standard.set(option.value, forKey: filterKey)
        Task { await load(keepingChips: true) }
    }

    /// Shows the remembered page at once when there is one; fetches only when there isn't,
    /// or when it's older than `PageCache.freshFor` (then quietly, behind it).
    private func load(keepingChips: Bool = false) async {
        let request = (params: chipParams ?? params, filter: filterValue)
        let key = Catalog.feedKey(browseId, params: request.params, filterValue: request.filter)
        wantedKey = key
        let started = ContinuousClock.now
        defer {
            if WebEngine.tracesPerf {
                Log.write("perf page \(browseId) shown in \(WebEngine.ms(ContinuousClock.now - started)) (shelves \(shelves.count))")
            }
        }

        if let cached = Catalog.feeds.cached(key) {
            show(cached.value, key: key, keepingChips: keepingChips)
            if WebEngine.tracesPerf { Log.write("perf page \(browseId) from memory, \(Int(cached.age))s old") }
            if cached.age < PageCache<FeedPage>.freshFor { return }
        } else if shelves.isEmpty {
            state = .loading
        }

        do {
            let page = try await Catalog.feed(browseId, params: request.params, filterValue: request.filter)
            guard wantedKey == key else { return }      // another chip was picked meanwhile
            show(page, key: key, keepingChips: keepingChips)
        } catch {
            guard wantedKey == key else { return }
            if shownKey == nil {
                shelves = []
                continuation = nil
                state = .failed(error.localizedDescription)
            } else {
                // Keep what's on screen; just stop waiting for the page that failed.
                Log.write("feed: \(browseId) failed — \(error.localizedDescription)")
                wantedKey = shownKey
            }
        }
    }

    private func show(_ page: FeedPage, key: String, keepingChips: Bool) {
        // Continuation pages prefix their shelf ids "p1-", "p2-"…; carry on from there.
        let continued = page.shelves.compactMap { Int($0.id.dropFirst().prefix { $0.isNumber }) }
        pageCount = 1 + (continued.max() ?? 0)
        shelves = page.shelves
        // The chip row comes with the first page; a filtered page re-sends it with the new
        // selection marked.
        if !page.chips.isEmpty || !keepingChips { chips = page.chips }
        filter = page.filter
        continuation = page.continuation
        shownKey = key
        state = page.shelves.isEmpty && page.continuation == nil
            ? .empty(Session.shared.isGuest || !Session.shared.isSignedIn
                     ? "Sign in to YouTube Music to see your recommendations."
                     : "Nothing here right now.")
            : .ready
        // Some first pages are almost empty; fetch on until there is something to show.
        if page.shelves.count < 2, page.continuation != nil { Task { await loadMore() } }
    }

    private func loadMore() async {
        guard let token = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await Catalog.feed(continuation: token)
            guard token == continuation else { return }     // a chip changed the feed meanwhile
            // Shelf ids restart on every page; prefix them so they stay unique.
            let prefix = "p\(pageCount)-"
            pageCount += 1
            let fresh = page.shelves.map { shelf -> Shelf in
                var shelf = shelf
                shelf.id = prefix + shelf.id
                return shelf
            }
            // Not animated: these land below the fold while the user is scrolling, where an
            // insertion animation only costs frames.
            shelves.append(contentsOf: fresh)
            continuation = page.continuation
            if state != .ready, !shelves.isEmpty { state = .ready }
            // Remember the page as it now stands, so coming back shows everything scrolled
            // in so far instead of fetching the extra shelves again.
            if let shownKey, shownKey == wantedKey, let original = Catalog.feeds.cached(shownKey)?.value {
                var grown = original
                grown.shelves = shelves
                grown.continuation = continuation
                Catalog.feeds.put(grown, for: shownKey)
            }
        } catch {
            // Leave what we have; the end of the page simply stops growing.
            Log.write("feed: continuation failed — \(error.localizedDescription)")
            continuation = nil
        }
    }
}

/// Charts' country picker: a glass pull-down naming the current choice.
private struct FilterMenu: View {
    let filter: FeedFilter
    let onChoose: (FeedFilter.Option) -> Void

    /// Options split where YouTube puts a divider (Global | the countries).
    private var groups: [[FeedFilter.Option]] {
        filter.options.reduce(into: [[FeedFilter.Option]]()) { groups, option in
            if option.startsGroup || groups.isEmpty { groups.append([option]) }
            else { groups[groups.count - 1].append(option) }
        }
    }

    var body: some View {
        Menu {
            if let title = filter.title { Text(title) }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group) { option in
                    Toggle(option.title, isOn: Binding(
                        get: { option.isSelected },
                        set: { _ in if !option.isSelected { onChoose(option) } }))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(filter.selected?.title ?? filter.title ?? "")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: Capsule())
        .fixedSize()
    }
}

/// Home's mood chips — a scrolling row of capsules, the selected one filled.
private struct ChipBar: View {
    let chips: [FeedChip]
    let onSelect: (FeedChip) -> Void
    var onHover: (FeedChip, Bool) -> Void = { _, _ in }
    @Namespace private var selectionSpace

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button { onSelect(chip) } label: {
                        Text(chip.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(chip.isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background {
                                ZStack {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    if chip.isSelected {
                                        // Slides between chips as the selection moves.
                                        Capsule().fill(Theme.accent)
                                            .matchedGeometryEffect(id: "chip", in: selectionSpace)
                                    }
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pressable(scale: 0.93))
                    .onHover { onHover(chip, $0) }
                }
            }
            .padding(.horizontal, Theme.pageInset)
        }
        .scrollIndicators(.never)
        .animation(Motion.snappy, value: chips)
    }
}

/// Songs in a shelf are laid out as a horizontally-paging grid of four rows, which is
/// how Music.app fills the home page — a single tall column reads as a list and loses
/// the browsable feel. Columns are sized so a whole number fit the window.
struct TrackShelfGrid: View {
    let shelf: Shelf
    var rows: Int = 4

    @Environment(PlayerController.self) private var player

    private struct Column: Identifiable {
        let id: Int
        let entries: [(offset: Int, track: Track)]
    }

    private var columns: [Column] {
        let all = Array(shelf.tracks.enumerated()).map { (offset: $0.offset, track: $0.element) }
        return stride(from: 0, to: all.count, by: rows).map { start in
            Column(id: start, entries: Array(all[start..<min(start + rows, all.count)]))
        }
    }

    var body: some View {
        // Rows carry their own 8pt hover inset, so the margin gives that back to keep the
        // text in line with the shelf title.
        PagedShelf(items: columns, minItemWidth: 270, spacing: 12, margin: Theme.pageInset - 8) { column in
            VStack(spacing: 2) {
                ForEach(column.entries, id: \.track.id) { entry in
                    ShelfTrackCell(track: entry.track) {
                        player.play(shelf.tracks, startingAt: entry.offset, source: shelf.title)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ShelfTrackCell: View {
    let track: Track
    let onPlay: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(Router.self) private var router
    @State private var hovering = false

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 10) {
            if let rank = track.rank { RankMark(rank: rank) }
            ZStack {
                Artwork(url: track.artwork, cornerRadius: 4)
                    .frame(width: 44, height: 44)
                    .opacity(hovering ? 0.45 : 1)
                if isCurrent && player.isPlaying && !hovering {
                    PlayingIndicator(color: .white).shadow(radius: 3)
                } else if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.system(size: 13))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    if track.isExplicit { ExplicitBadge() }
                }
                Text(track.artistLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(track) }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(track) }
                if let id = track.artists.first?.id {
                    Divider()
                    Button("Go to Artist", systemImage: "music.mic") { router.open(.artist(id)) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.055) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
    }
}
