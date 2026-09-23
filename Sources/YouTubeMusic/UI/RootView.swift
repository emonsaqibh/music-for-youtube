import AppKit
import SwiftUI

struct RootView: View {
    @State private var router = Router()
    private var player: PlayerController { .shared }

    var body: some View {
        @Bindable var router = router

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: Theme.sidebarWidth, max: 300)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $router.path) {
                ContentRoot()
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            // The player floats over the content column only — it stays centred on the
            // page even when the side panel is open, exactly as Music.app does.
            .overlay(alignment: .bottom) { PlayerPill() }
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
            if router.showFullScreenPlayer {
                FullScreenPlayer()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: router.showFullScreenPlayer)
        .environment(router)
        .environment(player)
        .task {
            player.attach()
            await WebEngine.shared.waitUntilReady()
            await router.loadNavigation()
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

// MARK: - Sidebar

/// Music.app's sidebar design, filled with YouTube Music's own navigation: the guide's
/// top-level entries, then its library sections, then the account's playlists.
struct SidebarView: View {
    @Environment(Router.self) private var router

    var body: some View {
        List {
            Section {
                SidebarRow(item: .search, title: "Search", symbol: "magnifyingglass")
                ForEach(router.guide.primary) { item in
                    SidebarRow(item: .feed(item), title: item.title, symbol: item.symbol)
                }
            }

            if !router.guide.librarySections.isEmpty {
                Section(router.guide.library?.title ?? "Library") {
                    ForEach(router.guide.librarySections) { item in
                        SidebarRow(item: .library(item), title: item.title, symbol: item.symbol)
                    }
                }
            }

            if !AppSettings.shared.showsPlaylistsInSidebar {
                EmptyView()
            } else if !router.playlists.isEmpty {
                Section(playlistsHeader) {
                    ForEach(router.playlists) { card in
                        SidebarRow(item: .playlist(id: card.playlistRouteId, title: card.title),
                                   title: card.title,
                                   artwork: card.artwork)
                    }
                }
            } else if !router.guide.playlists.isEmpty {
                // Saved playlists did not load, but the guide lists some — use those.
                Section(playlistsHeader) {
                    ForEach(router.guide.playlists) { item in
                        SidebarRow(item: .playlist(id: String(item.browseId.dropFirst(2)), title: item.title),
                                   title: item.title, symbol: item.symbol)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 0)
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 22) }
        .safeAreaInset(edge: .bottom) { AccountRow() }
        .animation(.easeInOut(duration: 0.2), value: router.guide)
        .animation(.easeInOut(duration: 0.2), value: router.playlists)
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

/// Music.app marks the selected sidebar row with a neutral grey capsule and leaves the
/// icon tinted, so the rows draw their own background rather than using the List's
/// selection, which would paint the whole row in the system accent colour.
private struct SidebarRow: View {
    let item: SidebarItem
    let title: String
    var symbol: String?
    var artwork: URL?

    @Environment(Router.self) private var router
    @State private var hovering = false

    private var isSelected: Bool { router.selection.key == item.key }

    var body: some View {
        HStack(spacing: 9) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 19, alignment: .center)
            } else {
                Artwork(url: artwork, cornerRadius: 3, symbol: "music.note.list")
                    .frame(width: 19, height: 19)
            }

            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.13)
                      : hovering ? Color.primary.opacity(0.055) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { router.select(item) }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowSeparator(.hidden)
    }
}

// MARK: - Content routing

struct ContentRoot: View {
    @Environment(Router.self) private var router

    var body: some View {
        // Keyed on the session so every page reloads when the profile or sign-in changes,
        // rather than showing the previous identity's recommendations.
        page.id(Session.shared.generation)
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
