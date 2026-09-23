import Foundation

struct ArtistRef: Hashable, Sendable, Identifiable {
    var id: String?
    var name: String
    var identity: String { id ?? name }
}

struct AlbumRef: Hashable, Sendable {
    var id: String?
    var name: String
}

/// A playable song.
struct Track: Identifiable, Hashable, Sendable {
    var id: String                  // videoId
    var title: String
    var artists: [ArtistRef] = []
    var album: AlbumRef?
    var artwork: URL?
    var seconds: Int?
    var isExplicit = false
    /// Identifies this row *within a playlist*, required to remove or reorder it.
    var setVideoId: String?
    /// Position in a chart.
    var rank: ChartRank?

    var artistLine: String {
        artists.isEmpty ? "" : artists.map(\.name).joined(separator: ", ")
    }

    var durationText: String { Format.duration(seconds) }
}

enum CardKind: String, Hashable, Sendable {
    case album, single, ep, playlist, artist, song, video, podcast, other

    var isCircular: Bool { self == .artist }
}

/// One tile in a shelf — an album, playlist, artist or song.
struct Card: Identifiable, Hashable, Sendable {
    var id: String
    var kind: CardKind = .other
    var title: String
    var subtitle: String = ""
    var artwork: URL?
    /// Present for anything with a detail page.
    var browseId: String?
    /// Present for anything directly playable.
    var videoId: String?
    var playlistId: String?
    /// Music videos arrive as 16:9 thumbnails; squaring them crops the picture.
    var isWide = false
    /// Position in a chart (Top artists, Weekly top podcast shows).
    var rank: ChartRank?
}

/// A chart position and which way it moved since the last chart.
struct ChartRank: Hashable, Sendable {
    enum Trend: Hashable, Sendable { case up, down, same }
    var position: String
    var trend: Trend?
}

/// A button that opens another browse page: Explore's New releases / Charts / Moods &
/// genres, and every mood and genre tile.
struct NavButton: Identifiable, Hashable, Sendable {
    var title: String
    var browseId: String
    var params: String?
    /// Set on Explore's top buttons.
    var iconType: String?
    /// The mood or genre's colour, from YouTube's `leftStripeColor` (ARGB).
    var color: UInt32?

    var id: String { browseId + (params ?? "") + title }
}

struct Shelf: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var strapline: String?
    var cards: [Card] = []
    /// Rows rather than tiles — search results and track listings use this.
    var tracks: [Track] = []
    /// Buttons to other pages — Explore's top row, and mood and genre tiles.
    var buttons: [NavButton] = []
    var moreBrowseId: String?
    var moreParams: String?
    /// YouTube sent a grid rather than a carousel: lay it out as rows that wrap, not a
    /// row that pages.
    var isGrid = false

    var isEmpty: Bool { cards.isEmpty && tracks.isEmpty && buttons.isEmpty }
}

/// An album or playlist detail page.
struct Collection: Identifiable, Hashable, Sendable {
    var id: String
    var kind: CardKind = .album
    var title: String
    var subtitle: String = ""
    var secondSubtitle: String = ""
    var description: String?
    var artwork: URL?
    var tracks: [Track] = []
    var playlistId: String?
    var shelves: [Shelf] = []

    var totalSeconds: Int { tracks.compactMap(\.seconds).reduce(0, +) }
}

/// An artist detail page.
struct ArtistPage: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var artwork: URL?
    var description: String?
    var subscribers: String?
    var shufflePlaylistId: String?
    var radioPlaylistId: String?
    var shelves: [Shelf] = []
}

// MARK: - Formatting

enum Format {
    static func duration(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "--:--" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// A playback position — unlike `duration`, zero is a real time and reads "0:00".
    static func time(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds)) : 0
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "1 hour, 12 minutes" — the phrasing Apple Music uses under a track list.
    static func longDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        if parts.isEmpty { return "\(seconds) seconds" }
        return parts.joined(separator: ", ")
    }

    /// Parses "3:45" or "1:02:03" into seconds.
    static func parseDuration(_ text: String?) -> Int? {
        guard let text, text.contains(":") else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

// MARK: - Navigation

/// One destination in YouTube Music's own navigation — a guide entry or a library chip.
///
/// Titles arrive localised to the account's language, so nothing may branch on them:
/// routing and icons key off `browseId` and `iconType` only.
struct NavItem: Identifiable, Hashable, Sendable, Codable {
    var title: String
    var browseId: String
    var params: String?
    var iconType: String?

    var id: String { browseId + (params ?? "") }
}

/// The sidebar as YouTube Music defines it.
struct Guide: Hashable, Sendable, Codable {
    /// Top-level destinations (Home, Explore, …), in YouTube's order.
    var primary: [NavItem] = []
    /// The Library entry itself — its title heads the library section.
    var library: NavItem?
    /// Library sub-sections (Playlists, Songs, Albums, …).
    var librarySections: [NavItem] = []
    /// Playlists YouTube lists in its own guide (signed in only).
    var playlists: [NavItem] = []
}

// MARK: - Lyrics

struct LyricLine: Identifiable, Hashable, Sendable {
    var id: Int
    var text: String
    var start: Double       // seconds
    var end: Double

    /// YouTube marks instrumental stretches with a lone "♪".
    var isInstrumental: Bool { text.trimmingCharacters(in: .whitespaces) == "♪" || text.isEmpty }
}

struct Lyrics: Hashable, Sendable {
    /// Time-synced lines, when YouTube has them.
    var lines: [LyricLine] = []
    /// Unsynced text, the fallback.
    var plain: String?
    /// "Source: LyricFind" — the licence note YouTube asks to be shown.
    var source: String?

    var isSynced: Bool { !lines.isEmpty }
    var isEmpty: Bool { lines.isEmpty && (plain?.isEmpty ?? true) }

    /// The line playing at `time`, or nil before the first line starts.
    func lineIndex(at time: Double) -> Int? {
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

// MARK: - Feeds

/// One page of a browse feed (Home, Explore, "See All"). YouTube sends a few shelves at a
/// time plus a token for the next batch, which the web app fetches as you scroll.
struct FeedPage: Sendable {
    var shelves: [Shelf] = []
    var continuation: String?
    /// The mood chips across the top of Home ("Workout", "Relax", …).
    var chips: [FeedChip] = []
    /// A page-wide option menu — Charts' country picker.
    var filter: FeedFilter?
}

/// A menu that re-requests the whole page with the chosen value (sent as the browse
/// request's `formData`). Charts uses it to pick a country.
struct FeedFilter: Hashable, Sendable {
    struct Option: Identifiable, Hashable, Sendable {
        var title: String
        /// What the page is re-requested with — a country code for Charts.
        var value: String
        var isSelected: Bool
        /// YouTube puts a divider before this option (Global stands apart from countries).
        var startsGroup = false
        var id: String { value }
    }

    /// The menu's heading ("Select a country").
    var title: String?
    var options: [Option]

    var selected: Option? { options.first(where: \.isSelected) }
}

/// A filter chip. Selecting one reloads the same feed with its params; deselecting uses
/// the chip's own "deselect" endpoint rather than assuming the default page.
struct FeedChip: Identifiable, Hashable, Sendable {
    var title: String
    var browseId: String
    var params: String?
    var deselectParams: String?
    var isSelected: Bool

    var id: String { title }
}
