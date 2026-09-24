import AppKit
import SwiftUI

struct RootView: View {
    @State private var router = Router()
    /// The overlay's origin on screen, to turn the pill's frame into the player's coordinates.
    @State private var overlayOrigin: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var player: PlayerController { .shared }

    var body: some View {
        @Bindable var router = router
        @Bindable var editor = LibraryEditor.shared

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Theme.sidebarMinWidth, ideal: Theme.sidebarWidth, max: 300)
                .background(SidebarDefaultWidth())
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $router.path) {
                ContentRoot()
                    .withPlayerPill()
                    .navigationDestination(for: Route.self) {
                        RouteView(route: $0)
                            .withPlayerPill()
                            .hidesBackButtonUnderFullScreenPlayer()
                    }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { router.detailFrame = $0 }
        }
        .inspector(isPresented: $router.isPanelPresented) {
            Group {
                switch router.panel {
                case .lyrics: LyricsPanel()
                default: QueueView()
                }
            }
            .inspectorColumnWidth(min: 270, ideal: 320, max: 440)
        }
        .overlay {
            // The animation is scoped to the overlay: an animated transaction reaching the
            // split view makes AppKit resize its columns mid-layout, which can loop.
            ZStack {
                Color.clear.allowsHitTesting(false)
                if router.showFullScreenPlayer {
                    // The pill itself stretches into the player, and back.
                    FullScreenPlayer()
                        .transition(reduceMotion ? .opacity : .pillMorph(
                            detail: router.detailFrame.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y),
                            topInset: overlayOrigin.y))
                }
            }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { overlayOrigin = $0 }
            .animation(Motion.expand, value: router.showFullScreenPlayer)
        }
        .overlay(alignment: .bottom) {
            LibraryNoticeView()
                .padding(.bottom, Theme.playerClearance - 8)
        }
        .sheet(item: $editor.creating) { request in
            NewPlaylistSheet(request: request) { id, title in
                // Made from the menu, not for a song: go to it, as Music.app does.
                if request.tracks.isEmpty {
                    router.showFullScreenPlayer = false
                    router.select(.playlist(id: id, title: title))
                }
            }
        }
        .environment(router)
        .environment(player)
        .task {
            player.attach()
            await WebEngine.shared.waitUntilReady()
            await router.loadNavigation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            router.showFullScreenPlayer = false
            router.focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await router.reloadPlaylists() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFullScreenPlayer)) { _ in
            if player.hasTrack { router.showFullScreenPlayer = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: WebEngine.sessionDidChange)) { _ in
            router.resetForNewSession()
            Task {
                await WebEngine.shared.waitUntilReady()
                await router.loadNavigation()
            }
        }
    }
}

private extension View {
    /// The player floats over the content column only — it stays centred on the page even
    /// when the side panel is open, exactly as Music.app does.
    ///
    /// It is attached to every page rather than once to the navigation stack: on macOS a
    /// pushed page is hosted in its own AppKit view, which draws above an overlay on the
    /// stack and would hide the player on every album, artist or playlist.
    func withPlayerPill() -> some View {
        overlay(alignment: .bottom) { PlayerPill() }
    }
}

// MARK: - Sidebar

/// Music.app's sidebar, filled with YouTube Music's own navigation: the guide's top-level
/// entries (plus Charts), the library when there is one, then the account's playlists.
///
/// Laid out by hand rather than as a `List` so its measurements can match Music.app's:
/// 32pt rows, 15pt titles, outlined accent icons, a filled accent capsule for the
/// selection, and headers set in from the rows.
struct SidebarView: View {
    @Environment(Router.self) private var router
    @Namespace private var selectionSpace
    /// The playlists section can be folded away; remembered across launches.
    @AppStorage("sidebar.playlistsCollapsed") private var playlistsCollapsed = false

    private var session: Session { .shared }

    /// A remembered account counts until an explicit sign-out, so the library doesn't
    /// blink out while the page is still reporting its state.
    private var hasLibrary: Bool {
        !session.isGuest && (session.isSignedIn || session.hasAccount)
    }

    var body: some View {
        // The list scrolls on its own; the update card and account row sit in their own
        // container underneath it, so rows never slide beneath the account.
        VStack(spacing: 0) {
            list
            VStack(spacing: 0) {
                UpdateCard()
                AccountRow()
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.25), value: Updater.shared.offersUpdate)
        }
        .animation(.easeInOut(duration: 0.2), value: router.guide)
        .animation(.easeInOut(duration: 0.2), value: router.playlists)
        .animation(.easeInOut(duration: 0.2), value: hasLibrary)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SidebarSearchField()
                    .padding(.bottom, 6)
                ForEach(router.primaryItems) { item in
                    SidebarRow(item: .feed(item), title: item.title, symbol: item.symbol)
                }

                if hasLibrary {
                    if !router.guide.librarySections.isEmpty {
                        SidebarHeader(title: router.guide.library?.title ?? "Library")
                        ForEach(router.guide.librarySections) { item in
                            SidebarRow(item: .library(item), title: item.title, symbol: item.symbol)
                        }
                    }
                    playlists
                } else if !session.isGuest {
                    // Signed out there is no library to list — say what signing in brings
                    // instead of offering rows that can only say "sign in".
                    SidebarHeader(title: router.guide.library?.title ?? "Library")
                    LibrarySignInPrompt()
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .environment(\.sidebarSelectionSpace, selectionSpace)
            // Animates the capsule sliding between rows — here only, never the page swap.
            .animation(Motion.snappy, value: router.selection.key)
        }
        .scrollIndicators(.never)
        // A short fade where the list meets the account container, so rows ease out
        // rather than being cut off.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
            }
        }
    }

    @ViewBuilder
    private var playlists: some View {
        if !AppSettings.shared.showsPlaylistsInSidebar {
            EmptyView()
        } else if !router.playlists.isEmpty {
            SidebarHeader(title: playlistsHeader, isCollapsed: $playlistsCollapsed)
            if !playlistsCollapsed {
                NewPlaylistRow()
                ForEach(router.playlists) { card in
                    SidebarRow(item: .playlist(id: card.playlistRouteId, title: card.title),
                               title: card.title,
                               artwork: card.artwork)
                }
            }
        } else if !router.guide.playlists.isEmpty {
            // Saved playlists did not load, but the guide lists some — use those.
            SidebarHeader(title: playlistsHeader, isCollapsed: $playlistsCollapsed)
            if !playlistsCollapsed {
                NewPlaylistRow()
                ForEach(router.guide.playlists) { item in
                    SidebarRow(item: .playlist(id: String(item.browseId.dropFirst(2)), title: item.title),
                               title: item.title, symbol: item.symbol)
                }
            }
        } else if LibraryEditor.shared.canEdit {
            // No playlists yet: the section is still where a first one gets made.
            SidebarHeader(title: playlistsHeader, isCollapsed: $playlistsCollapsed)
            if !playlistsCollapsed { NewPlaylistRow() }
        }
    }

    /// YouTube's own (localised) name for the playlists section, if it gave us one.
    private var playlistsHeader: String {
        router.guide.librarySections.first { $0.browseId == Guide.likedPlaylistsId }?.title ?? "Playlists"
    }
}

private extension Card {
    /// Library playlist cards carry the "VL"-prefixed browseId; routes want the bare id.
    var playlistRouteId: String {
        let id = browseId ?? playlistId ?? self.id
        return id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }
}

/// A section title: small, bold and grey, set in a little from the rows' icons.
/// Search, typed straight into the sidebar as in Music.app: focusing or typing opens the
/// Search page, which updates as you type (Return searches at once). ⌘K lands here.
private struct SidebarSearchField: View {
    @Environment(Router.self) private var router
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var router = router

        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(focused ? Theme.accent : .secondary)
            TextField("Search", text: $router.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit {
                    router.focusSearch()
                    router.searchSubmitted += 1
                }
            if !router.searchText.isEmpty {
                Button {
                    router.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            } else if !focused {
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.1 : 0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.accent.opacity(focused ? 0.55 : 0), lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: focused) { _, isFocused in
            if isFocused, router.selection.key != SidebarItem.search.key { router.select(.search) }
        }
        .onChange(of: router.searchText) { _, text in
            if !text.isEmpty, router.selection.key != SidebarItem.search.key { router.select(.search) }
        }
        .onChange(of: router.searchFocusRequest) { _, _ in focused = true }
        // Picking another page lets go of the field, so its focus ring doesn't linger.
        .onChange(of: router.selection.key) { _, key in
            if key != SidebarItem.search.key { focused = false }
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// "New Playlist" at the top of the sidebar's playlists — shown when the account can edit.
private struct NewPlaylistRow: View {
    @State private var hovering = false

    var body: some View {
        if LibraryEditor.shared.canEdit {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: 24)
                Text("New Playlist")
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { LibraryEditor.shared.startNewPlaylist() }
        }
    }
}

/// A section title: small, bold and grey, set in a little from the rows' icons. Given a
/// binding, the whole header folds its section away, with a chevron showing which way.
private struct SidebarHeader: View {
    let title: String
    var isCollapsed: Binding<Bool>?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let isCollapsed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed.wrappedValue ? 0 : 90))
                    .opacity(hovering || isCollapsed.wrappedValue ? 1 : 0.45)
                    .padding(.trailing, 8)
            }
        }
        .padding(.leading, 6)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let isCollapsed else { return }
            withAnimation(.easeInOut(duration: 0.22)) { isCollapsed.wrappedValue.toggle() }
        }
        .help(isCollapsed.map { $0.wrappedValue ? "Show \(title)" : "Hide \(title)" } ?? "")
    }
}

/// One destination. The selected row is a capsule of the accent colour with white text,
/// as in Music.app on macOS 26.
/// The sidebar's selection capsule is one shape that moves between rows.
private struct SidebarSelectionSpaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private extension EnvironmentValues {
    var sidebarSelectionSpace: Namespace.ID? {
        get { self[SidebarSelectionSpaceKey.self] }
        set { self[SidebarSelectionSpaceKey.self] = newValue }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let title: String
    var symbol: String?
    var artwork: URL?

    @Environment(Router.self) private var router
    @Environment(\.sidebarSelectionSpace) private var selectionSpace
    @State private var hovering = false

    private var isSelected: Bool { router.selection.key == item.key }

    var body: some View {
        Button { router.select(item) } label: { row }
            .buttonStyle(.pressable(scale: 0.98))
            .onHover { hovering = $0 }
            .help(title)
    }

    private var row: some View {
        HStack(spacing: 8) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? Color.white : Theme.accent)
                } else {
                    Artwork(url: artwork, cornerRadius: 4, symbol: "music.note.list")
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 24)

            Text(title)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            ZStack {
                if hovering && !isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                }
                if isSelected {
                    // Slides from the previous row to this one rather than blinking over.
                    let capsule = RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent)
                    if let selectionSpace {
                        capsule.matchedGeometryEffect(id: "selection", in: selectionSpace)
                    } else {
                        capsule
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Stands in for the library while signed out.
private struct LibrarySignInPrompt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to see the songs, albums, artists and playlists you’ve saved on YouTube Music.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign In") { SignIn.start() }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Content routing

struct ContentRoot: View {
    @Environment(Router.self) private var router

    var body: some View {
        // Keyed on the session so every page reloads when the profile or sign-in changes,
        // rather than showing the previous identity's recommendations.
        page.id(Session.shared.generation)
            // Each page rises in as it appears. Only its opacity and offset animate: the
            // swap itself stays instant, since animating the navigation stack's root inside
            // the split view makes AppKit relayout in a loop and abort.
            .modifier(PageArrival())
            .id(router.selection.key)
    }

    @ViewBuilder
    private var page: some View {
        switch router.selection {
        case .search:
            SearchView()
        case .feed(let item):
            FeedView(title: item.title, browseId: item.browseId, params: item.params)
        case .library(let item):
            LibraryView(item: item)
        case .playlist(let id, let title):
            CollectionView(source: .playlist(id), fallbackTitle: title)
        }
    }
}

private struct PageArrival: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear { withAnimation(Motion.gentle) { shown = true } }
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let browseId):
            CollectionView(source: .album(browseId), fallbackTitle: "Album")
        case .playlist(let playlistId):
            CollectionView(source: .playlist(playlistId), fallbackTitle: "Playlist")
        case .artist(let browseId):
            ArtistView(browseId: browseId)
        case .seeAll(let browseId, let params, let title):
            FeedView(title: title, browseId: browseId, params: params)
        }
    }
}

/// With no saved layout (a first launch), `NavigationSplitView` ignores the column's ideal
/// and minimum widths and opens the sidebar at ~144pt. Once per launch, a sidebar found
/// narrower than its minimum is moved out to the default; a width the user dragged to is
/// always at least the minimum, so it's left alone.
private struct SidebarDefaultWidth: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var applied = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !applied else { return }
            DispatchQueue.main.async { [weak self] in self?.widen() }
        }

        private func widen() {
            var ancestor = superview
            while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
            guard let split = ancestor as? NSSplitView, let sidebar = split.arrangedSubviews.first
            else { return }
            applied = true
            if sidebar.frame.width < Theme.sidebarMinWidth {
                split.setPosition(Theme.sidebarWidth, ofDividerAt: 0)
            }
        }
    }
}
