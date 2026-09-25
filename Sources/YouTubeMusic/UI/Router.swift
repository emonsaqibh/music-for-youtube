import Foundation
import Observation
import SwiftUI

enum Route: Hashable {
    case album(String)      // browseId
    case playlist(String)   // playlistId
    case artist(String)     // channel browseId
    case seeAll(browseId: String, params: String?, title: String)
}

/// What the sidebar can select. Everything except Search and the user's playlists comes
/// from YouTube Music's own navigation, and is identified by its browseId — never by its
/// (localised) title.
enum SidebarItem: Hashable {
    case search
    /// A top-level guide destination (Home, Explore, …), shown as a page of shelves.
    case feed(NavItem)
    /// A library section, shown as a grid or song list.
    case library(NavItem)
    case playlist(id: String, title: String)

    /// Identity for selection — survives the guide being re-fetched with new titles.
    var key: String {
        switch self {
        case .search: "search"
        case .feed(let item): "feed:" + item.id
        case .library(let item): "library:" + item.id
        case .playlist(let id, _): "playlist:" + id
        }
    }
}

/// The panel on the right of the window. Music.app shares one panel between the queue
/// and the lyrics, and so do we.
enum SidePanel: Hashable {
    case queue, lyrics
}

@MainActor
@Observable
final class Router {
    var selection: SidebarItem
    var path: [Route] = []
    var searchText = ""
    /// Bumped to put the cursor in the sidebar's search field (⌘K).
    var searchFocusRequest = 0
    /// Bumped when Return is pressed in the search field: search now, not after the pause.
    var searchSubmitted = 0

    /// ⌘K: show Search and put the cursor in the sidebar field.
    func focusSearch() {
        if selection.key != SidebarItem.search.key { select(.search) }
        searchFocusRequest += 1
    }
    var panel: SidePanel? = DemoMode.opensLyrics ? .lyrics : DemoMode.opensQueue ? .queue : nil
    var showFullScreenPlayer = DemoMode.opensFullScreen
    /// The detail column on screen (window coordinates). The pill always sits at its
    /// bottom centre, so this is where the full-screen player grows from and shrinks back
    /// to. Not observed: it's only read when the player opens or closes.
    @ObservationIgnored var detailFrame: CGRect = .zero
    /// The full-screen overlay's origin in the same coordinates. Not observed either: a
    /// geometry write that re-renders the root view mid-layout crashes the window.
    @ObservationIgnored var overlayOrigin: CGPoint = .zero

    /// YouTube Music's navigation. Starts from the last fetched copy so the sidebar is
    /// complete on the first frame, then refreshes in the background.
    private(set) var guide: Guide

    /// The account's saved playlists, with artwork, listed in the sidebar as Music.app does.
    private(set) var playlists: [Card] = []

    init() {
        let initial = Guide.cached ?? .fallback
        guide = initial
        selection = initial.primary.first.map(SidebarItem.feed) ?? .search
    }

    /// The sidebar's top section: YouTube's own destinations, plus Charts straight after
    /// Explore — the web app buries it a click deep, but it is a place people go directly.
    var primaryItems: [NavItem] {
        // History is listed with the library instead.
        var items = guide.primary.filter { $0.browseId != Guide.historyId }
        guard !items.contains(where: { $0.browseId == Guide.charts.browseId }) else { return items }
        let explore = items.firstIndex { $0.browseId == "FEmusic_explore" }
        items.insert(Guide.charts, at: explore.map { $0 + 1 } ?? items.endIndex)
        return items
    }

    /// The library's sections, ending with History — YouTube's own entry if the guide or
    /// the library has one, else ours. The sidebar only lists them for an account.
    var librarySections: [NavItem] {
        var items = guide.librarySections
        if !items.contains(where: { $0.browseId == Guide.historyId }) {
            items.append(guide.primary.first { $0.browseId == Guide.historyId } ?? Guide.history)
        }
        return items
    }

    var isPanelPresented: Bool {
        get { panel != nil }
        set { if !newValue { panel = nil } }
    }

    func toggle(_ newPanel: SidePanel) {
        panel = panel == newPanel ? nil : newPanel
    }

    func open(_ route: Route) { path.append(route) }

    func select(_ item: SidebarItem) {
        selection = item
        path.removeAll()
    }

    /// The profile changed underneath us: drop everything that belonged to the old one
    /// before the new navigation arrives, so nothing from the other identity lingers.
    func resetForNewSession() {
        path.removeAll()
        playlists = []
        guide = Guide.cached ?? .fallback
        reconcileSelection()
    }

    /// Fetches the guide and the saved playlists. Called at launch and whenever the
    /// session changes (sign-in, sign-out).
    func loadNavigation() async {
        let session = Session.shared
        if session.profile == .account, session.isSignedIn, let info = await Catalog.accountInfo() {
            session.remember(info)
        }

        if var fresh = try? await Catalog.guide() {
            // Signed out, YouTube offers no library sections at all; keep the usual set so
            // the sidebar still reads as a music library and explains itself when opened.
            if fresh.library == nil { fresh.library = Guide.fallback.library }
            if fresh.librarySections.isEmpty { fresh.librarySections = Guide.fallback.librarySections }
            guide = fresh
            fresh.save()
            reconcileSelection()
        } else {
            Log.write("guide: fetch failed, keeping \(Guide.cached == nil ? "fallback" : "cached") navigation")
        }
        playlists = (try? await Catalog.savedPlaylists()) ?? []
    }

    /// A playlist was created, saved or unsaved in the app: list the library's playlists again.
    func reloadPlaylists() async {
        if let fresh = try? await Catalog.savedPlaylists() { playlists = fresh }
    }

    /// Titles can change between fetches (a language switch); keep the same destination
    /// selected, with its new title.
    private func reconcileSelection() {
        switch selection {
        case .feed(let item):
            if let match = primaryItems.first(where: { $0.id == item.id }) { selection = .feed(match) }
            else if let first = primaryItems.first { selection = .feed(first) }
        case .library(let item):
            if let match = librarySections.first(where: { $0.id == item.id }) { selection = .library(match) }
        default:
            break
        }
    }
}

// MARK: - Guide defaults and persistence

extension Guide {
    static let libraryId = "FEmusic_library_landing"
    static let charts = NavItem(title: "Charts", browseId: "FEmusic_charts")
    static let likedPlaylistsId = "FEmusic_liked_playlists"
    static let historyId = "FEmusic_history"
    static let history = NavItem(title: "History", browseId: historyId, iconType: "TAB_HISTORY")

    /// Used before the first successful fetch, or if `guide` fails.
    static let fallback = Guide(
        primary: [
            NavItem(title: "Home", browseId: "FEmusic_home", iconType: "TAB_HOME"),
            NavItem(title: "Explore", browseId: "FEmusic_explore", iconType: "TAB_EXPLORE"),
        ],
        library: NavItem(title: "Library", browseId: libraryId, iconType: "TAB_BOOKMARK"),
        librarySections: [
            NavItem(title: "Playlists", browseId: likedPlaylistsId),
            NavItem(title: "Songs", browseId: "FEmusic_liked_videos"),
            NavItem(title: "Albums", browseId: "FEmusic_liked_albums"),
            NavItem(title: "Artists", browseId: "FEmusic_library_corpus_track_artists"),
        ])

    /// One cached guide per profile — the guest's navigation is not the account's.
    @MainActor private static var defaultsKey: String {
        "navigation.guide.v1." + Session.shared.profile.rawValue
    }

    @MainActor static var cached: Guide? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let guide = try? JSONDecoder().decode(Guide.self, from: data),
              !guide.primary.isEmpty else { return nil }
        return guide
    }

    @MainActor func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

extension NavItem {
    /// YouTube's icon types (and, for library chips, which carry none, the browseId)
    /// mapped onto SF Symbols — outlined, as Music.app's sidebar draws them. Anything
    /// unknown degrades to a generic music symbol.
    var symbol: String {
        switch iconType {
        case "TAB_HOME": return "house"
        case "TAB_EXPLORE", "EXPLORE": return "safari"
        case "TAB_BOOKMARK", "LIBRARY_MUSIC": return "square.stack"
        case "TAB_SAMPLES": return "play.square.stack"
        case "TAB_HISTORY", "WATCH_HISTORY": return "clock"
        case "LIKES_PLAYLIST", "LIKE": return "hand.thumbsup"
        default: break
        }
        switch browseId {
        case "FEmusic_liked_playlists": return "music.note.list"
        case "FEmusic_liked_videos": return "music.note"
        case "FEmusic_liked_albums": return "square.stack"
        case "FEmusic_library_corpus_track_artists", "FEmusic_library_corpus_artists": return "music.mic"
        case "FEmusic_library_non_music_audio_list", "FEmusic_library_podcasts": return "mic"
        case "FEmusic_history": return "clock"
        case "FEmusic_library_user_profile_channels_list": return "person.2"
        case "FEmusic_library_privately_owned_landing": return "icloud.and.arrow.up"
        case "FEmusic_charts": return "chart.line.uptrend.xyaxis"
        case "FEmusic_new_releases": return "sparkles"
        case "FEmusic_moods_and_genres": return "face.smiling"
        case "VLLM": return "hand.thumbsup"
        default: return browseId.hasPrefix("VL") ? "music.note.list" : "music.note.house"
        }
    }
}
