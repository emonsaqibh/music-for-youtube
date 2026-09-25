import Foundation

enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all, songs, videos, albums, artists, playlists

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .videos: "Videos"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }

    /// Opaque protobuf filters YouTube Music's own web client sends.
    var params: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        case .videos: "EgWKAQIQAWoKEAkQBRAKEAMQBA=="
        case .albums: "EgWKAQIYAWoKEAkQBRAKEAMQBA=="
        case .artists: "EgWKAQIgAWoKEAkQBRAKEAMQBA=="
        case .playlists: "EgWKAQIoAWoKEAkQBRAKEAMQBA=="
        }
    }
}

/// High-level access to YouTube Music's catalogue, all of it routed through the
/// authenticated page so the user's own library and recommendations come back.
///
/// Deliberately not main-actor: only the request itself hops to the engine, and turning
/// the (often megabyte-sized) renderer tree into models happens off the main thread, so
/// the UI keeps scrolling while a page loads.
enum Catalog {
    @MainActor static var engine: WebEngine { .shared }

    // MARK: Page memory

    /// Home, Explore, Charts, chips and See All pages. The plain Home page is also kept on
    /// disk so it can show at launch before the engine is up.
    @MainActor static let feeds = PageCache<FeedPage>(
        limit: 40,
        directory: URL.cachesDirectory.appending(path: (Bundle.main.bundleIdentifier ?? "ytm") + "/pages",
                                                 directoryHint: .isDirectory),
        persists: { $0.hasPrefix("feed|FEmusic_home||") })
    @MainActor static let collections = PageCache<Collection>(limit: 30)
    @MainActor static let artists = PageCache<ArtistPage>(limit: 20)
    @MainActor static let libraries = PageCache<LibraryPage>(limit: 20)

    /// Everything that makes a feed page distinct — and the profile, so the account's and
    /// the guest's pages never mix.
    @MainActor static func feedKey(_ browseId: String, params: String?, filterValue: String?) -> String {
        "feed|\(browseId)|\(params ?? "")|\(filterValue ?? "")|\(Session.shared.profile.rawValue)"
    }

    // MARK: Feeds

    static func home() async throws -> [Shelf] {
        Parse.shelves(in: try await engine.innertube("browse", ["browseId": "FEmusic_home"]))
    }

    static func explore() async throws -> [Shelf] {
        Parse.shelves(in: try await engine.innertube("browse", ["browseId": "FEmusic_explore"]))
    }

    static func charts() async throws -> [Shelf] {
        Parse.shelves(in: try await engine.innertube("browse", ["browseId": "FEmusic_charts"]))
    }

    /// Any browse destination — a guide entry, a library section, a "See All" page.
    static func browse(_ browseId: String, params: String? = nil) async throws -> [Shelf] {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return Parse.shelves(in: try await engine.innertube("browse", body))
    }

    /// A library section, plus YouTube's own message for when it is empty.
    /// The first page of a feed. Later pages come from `feed(continuation:)`.
    /// `filterValue` is a `FeedFilter` choice — a country, for Charts.
    /// Fetches a feed page (sharing a fetch already under way) and remembers it; views show
    /// `feeds.cached(feedKey(…))` first.
    @MainActor
    static func feed(_ browseId: String, params: String? = nil, filterValue: String? = nil) async throws -> FeedPage {
        try await feeds.load(feedKey(browseId, params: params, filterValue: filterValue)) {
            try await fetchFeed(browseId, params: params, filterValue: filterValue)
        }
    }

    /// Warms the page memory — used when the pointer rests on a chip.
    @MainActor
    static func prefetchFeed(_ browseId: String, params: String?, filterValue: String?) {
        feeds.prefetch(feedKey(browseId, params: params, filterValue: filterValue)) {
            try await fetchFeed(browseId, params: params, filterValue: filterValue)
        }
    }

    private static func fetchFeed(_ browseId: String, params: String?, filterValue: String?) async throws -> FeedPage {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        if let filterValue { body["formData"] = ["selectedValues": [filterValue]] }
        return Parse.feedPage(try await engine.innertube("browse", body))
    }

    static func feed(continuation token: String) async throws -> FeedPage {
        Parse.feedPage(try await engine.innertube("browse", ["continuation": token]))
    }

    @MainActor static func libraryKey(_ item: NavItem) -> String {
        "library|\(item.id)|\(Session.shared.profile.rawValue)"
    }

    @MainActor
    static func library(_ item: NavItem) async throws -> LibraryPage {
        try await libraries.load(libraryKey(item)) {
            var body: [String: Any] = ["browseId": item.browseId]
            if let params = item.params { body["params"] = params }
            let json = try await engine.innertube("browse", body)
            return LibraryPage(shelves: Parse.shelves(in: json), emptyMessage: Parse.emptyMessage(in: json))
        }
    }

    /// The user's saved playlists, with artwork — what the sidebar lists.
    static func savedPlaylists() async throws -> [Card] {
        try await browse(Guide.likedPlaylistsId).flatMap(\.cards).filter { $0.kind == .playlist }
    }

    static func history() async throws -> [Shelf] {
        Parse.shelves(in: try await engine.innertube("browse", ["browseId": "FEmusic_history"]))
    }

    // MARK: Search

    static func search(_ query: String, filter: SearchFilter = .all) async throws -> [Shelf] {
        var body: [String: Any] = ["query": query]
        if let params = filter.params { body["params"] = params }
        return Parse.searchResults(in: try await engine.innertube("search", body))
    }

    static func suggestions(_ query: String) async throws -> [String] {
        let json = try await engine.innertube("music/get_search_suggestions", ["input": query])
        return json.all("suggestion").compactMap { $0.text }
    }

    // MARK: Detail pages

    @MainActor static func collectionKey(album browseId: String) -> String {
        "album|\(browseId)|\(Session.shared.profile.rawValue)"
    }

    @MainActor static func collectionKey(playlist playlistId: String) -> String {
        "playlist|\(playlistId)|\(Session.shared.profile.rawValue)"
    }

    @MainActor
    static func album(browseId: String) async throws -> Collection {
        try await collections.load(collectionKey(album: browseId)) {
            let json = try await engine.innertube("browse", ["browseId": browseId])
            return collection(from: json, id: browseId, defaultKind: .album)
        }
    }

    /// A playlist's first page (up to 100 tracks) and the token for the rest — so the page
    /// can show at once and fill in, instead of waiting for every page first.
    static func playlistFirstPage(playlistId: String) async throws -> (Collection, String?) {
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        let json = try await engine.innertube("browse", ["browseId": browseId])
        var result = collection(from: json, id: browseId, defaultKind: .playlist)
        result.playlistId = result.playlistId ?? playlistId
        return (result, trackContinuation(in: json))
    }

    static func playlistMore(_ token: String) async throws -> ([Track], String?) {
        let json = try await engine.innertube("browse", ["continuation": token])
        return (json.all("musicResponsiveListItemRenderer").compactMap(Parse.track), continuation(in: json))
    }

    /// Remembers a playlist once all of it has loaded.
    @MainActor static func remember(_ collection: Collection, playlistId: String) {
        collections.put(collection, for: collectionKey(playlist: playlistId))
    }

    static func playlist(playlistId: String) async throws -> Collection {
        // Playlist browse ids are the playlist id with a "VL" prefix.
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        var json = try await engine.innertube("browse", ["browseId": browseId])
        var result = collection(from: json, id: browseId, defaultKind: .playlist)
        result.playlistId = result.playlistId ?? playlistId

        // Long playlists page at 100 tracks; pull the rest before showing the list.
        var token = trackContinuation(in: json)
        var pages = 0
        while let t = token, pages < 12 {
            json = try await engine.innertube("browse", ["continuation": t])
            let more = json.all("musicResponsiveListItemRenderer").compactMap(Parse.track)
            if more.isEmpty { break }
            result.tracks.append(contentsOf: more)
            token = continuation(in: json)
            pages += 1
        }
        return result
    }

    @MainActor static func artistKey(_ browseId: String) -> String {
        "artist|\(browseId)|\(Session.shared.profile.rawValue)"
    }

    @MainActor
    static func artist(browseId: String) async throws -> ArtistPage {
        try await artists.load(artistKey(browseId)) { try await fetchArtist(browseId: browseId) }
    }

    private static func fetchArtist(browseId: String) async throws -> ArtistPage {
        let json = try await engine.innertube("browse", ["browseId": browseId])
        let header = json.first("musicImmersiveHeaderRenderer")
            ?? json.first("musicVisualHeaderRenderer")
            ?? json.first("musicResponsiveHeaderRenderer")
            ?? .null

        var page = ArtistPage(id: browseId, name: header["title"].text ?? "Artist")
        page.artwork = Parse.artwork(header, size: 1000)
        page.description = header[path: "description.runs"].arrayValue
            .compactMap { $0["text"].stringValue }.joined()
        if page.description?.isEmpty == true { page.description = nil }
        page.subscribers = header.first("subscriberCountText")?.text
        page.shufflePlaylistId = Parse.playlistId(in: header["playButton"])
        page.radioPlaylistId = Parse.playlistId(in: header["startRadioButton"])
        page.shelves = Parse.shelves(in: json)
        return page
    }

    // MARK: Navigation

    /// YouTube Music's own navigation: the `guide` endpoint for the top-level entries and
    /// playlists, and the library landing page's chips for the library sections.
    static func guide() async throws -> Guide {
        let json = try await engine.innertube("guide", [:])
        var guide = Guide()
        var seen = Set<String>()

        for entry in json.all("guideEntryRenderer") {
            let browse = entry[path: "navigationEndpoint.browseEndpoint"]
            guard let browseId = browse["browseId"].stringValue,
                  let title = entry["formattedTitle"].text ?? entry["title"].text, !title.isEmpty
            else { continue }   // "New playlist" and similar actions carry no destination
            let item = NavItem(title: title, browseId: browseId,
                               params: browse["params"].stringValue,
                               iconType: entry["icon"]["iconType"].stringValue)
            guard seen.insert(item.id).inserted else { continue }

            if browseId == Guide.libraryId {
                guide.library = item
            } else if browseId.hasPrefix("VL") || Parse.pageKind(browse) == .playlist {
                guide.playlists.append(item)
            } else if browseId.hasPrefix("FE") {
                guide.primary.append(item)
            }
            // Anything else ("SPunlimited" upsell, channel pages) has no native page.
        }
        guard !guide.primary.isEmpty else { throw EngineError.badResponse }

        if let library = guide.library {
            guide.librarySections = (try? await librarySections(library)) ?? []
        }
        return guide
    }

    /// The chips across the top of YouTube Music's library page — its library sections.
    private static func librarySections(_ library: NavItem) async throws -> [NavItem] {
        let json = try await engine.innertube("browse", ["browseId": library.browseId])
        var items: [NavItem] = []
        for chip in json.all("chipCloudChipRenderer") {
            // A chip carries two commands: go to its section, and (on deselect) back to the
            // landing page. Take the one that goes somewhere.
            guard let title = chip["text"].text, !title.isEmpty,
                  let browse = chip.all("browseEndpoint").first(where: {
                      $0["browseId"].stringValue.map { $0 != library.browseId } ?? false
                  }),
                  let browseId = browse["browseId"].stringValue else { continue }
            let item = NavItem(title: title, browseId: browseId,
                               params: browse["params"].stringValue,
                               iconType: chip["icon"]["iconType"].stringValue)
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
        }
        return items
    }

    // MARK: Account

    /// Who is signed in, from the account menu's header. Nil when signed out, or if the
    /// header is not where it is expected — callers treat that as "unknown", not an error.
    static func accountInfo() async -> AccountInfo? {
        guard let json = try? await engine.innertube("account/account_menu", [:]),
              let header = json.first("activeAccountHeaderRenderer"),
              let name = header["accountName"].text, !name.isEmpty else { return nil }
        return AccountInfo(name: name,
                           handle: header["channelHandle"].text,
                           photo: Parse.artwork(header["accountPhoto"], size: 176))
    }

    // MARK: Lyrics

    @MainActor private static var lyricsCache: [String: Lyrics] = [:]
    @MainActor private static var lyricsInflight: [String: Task<Lyrics, Error>] = [:]

    /// Lyrics for a track: time-synced when YouTube has them, plain text otherwise.
    /// Empty (not an error) when the track has none.
    @MainActor
    static func lyrics(videoId: String) async throws -> Lyrics {
        if let hit = lyricsCache[videoId] { return hit }
        if let running = lyricsInflight[videoId] { return try await running.value }

        let task = Task<Lyrics, Error> { try await fetchLyrics(videoId: videoId) }
        lyricsInflight[videoId] = task
        defer { lyricsInflight[videoId] = nil }
        let result = try await task.value
        lyricsCache[videoId] = result
        return result
    }

    private static func fetchLyrics(videoId: String) async throws -> Lyrics {
        // Lyrics are not on the track: they are a tab of the watch page, whose browseId
        // has to be looked up first. The tab title is localised, so match the page type.
        let next = try await engine.innertube("next", ["videoId": videoId, "isAudioOnly": true])
        // The same answer says whether the song is liked, so the Like button needn't ask.
        if let liked = Parse.isLiked(videoId: videoId, in: next) {
            await LikeStore.shared.learn(liked, for: videoId)
        }
        let endpoint = next.all("tabRenderer")
            .compactMap { $0[path: "endpoint.browseEndpoint"].exists ? $0[path: "endpoint.browseEndpoint"] : nil }
            .first {
                $0[path: "browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType"]
                    .stringValue == "MUSIC_PAGE_TYPE_TRACK_LYRICS"
                    || ($0["browseId"].stringValue ?? "").hasPrefix("MPLY")
            }
        guard let browseId = endpoint?["browseId"].stringValue else { return Lyrics() }

        // Timed lyrics are only served to the Android client.
        if let timed = try? await engine.innertube("browse", ["browseId": browseId],
                                                   client: InnerTubeClient.androidMusic) {
            let lines = timed.all("timedLyricsData").first?.arrayValue ?? []
            let parsed: [LyricLine] = lines.enumerated().compactMap { offset, node in
                guard let text = node["lyricLine"].stringValue,
                      let start = node[path: "cueRange.startTimeMilliseconds"].doubleValue else { return nil }
                let end = node[path: "cueRange.endTimeMilliseconds"].doubleValue ?? start
                return LyricLine(id: offset, text: text, start: start / 1000, end: end / 1000)
            }
            if !parsed.isEmpty {
                return Lyrics(lines: parsed, source: timed.first("sourceMessage")?.text)
            }
        }

        let plain = try await engine.innertube("browse", ["browseId": browseId])
        let shelf = plain.first("musicDescriptionShelfRenderer") ?? .null
        return Lyrics(plain: shelf["description"].text?
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      source: shelf["footer"].text)
    }

    // MARK: Queue / radio

    /// Asks YouTube for the queue that would follow this track — the real autoplay and
    /// radio sequence, which is what makes "play a song" behave like it does on the web.
    static func upNext(videoId: String, playlistId: String? = nil) async throws -> [Track] {
        // A bare `next` call answers with the track itself and nothing else. Seeding it
        // with YouTube Music's radio playlist for the video ("RDAMVM" + id) is what
        // produces the ~50-track autoplay queue the web player uses.
        let list = playlistId ?? "RDAMVM" + videoId
        let body: [String: Any] = ["videoId": videoId, "playlistId": list, "isAudioOnly": true]
        let json = try await engine.innertube("next", body)
        return json.all("playlistPanelVideoRenderer").compactMap(Parse.queueTrack)
    }

    /// The tracks of a playlist, in order, without building a full detail page.
    static func tracks(inPlaylist playlistId: String) async throws -> [Track] {
        try await playlist(playlistId: playlistId).tracks
    }

    // MARK: Helpers

    /// The next page of a playlist's own tracks. Scoped to the track shelf: an own
    /// playlist's page also carries a continuation for its Suggestions, which must not be
    /// read as more tracks.
    private static func trackContinuation(in json: JSON) -> String? {
        continuation(in: json.first("musicPlaylistShelfRenderer") ?? json)
    }

    private static func continuation(in json: JSON) -> String? {
        json.first("continuationCommand")?["token"].stringValue
            ?? json.first("nextContinuationData")?["continuation"].stringValue
    }

    private static func collection(from json: JSON, id: String, defaultKind: CardKind) -> Collection {
        let header = json.first("musicResponsiveHeaderRenderer")
            ?? json.first("musicDetailHeaderRenderer")
            ?? json.first("musicEditablePlaylistDetailHeaderRenderer")
            ?? .null

        var result = Collection(id: id, kind: defaultKind, title: header["title"].text ?? "")
        result.artwork = Parse.artwork(header, size: 720)
        result.subtitle = header["subtitle"]["runs"].arrayValue
            .compactMap { $0["text"].stringValue }.joined()
            .replacingOccurrences(of: " • ", with: " · ")
        result.secondSubtitle = header["secondSubtitle"]["runs"].arrayValue
            .compactMap { $0["text"].stringValue }.joined()
            .replacingOccurrences(of: " • ", with: " · ")

        if result.subtitle.isEmpty, let strapline = header["straplineTextOne"].text {
            result.subtitle = strapline
        }
        let description = header.first("description")?.text
            ?? json.first("musicDescriptionShelfRenderer")?["description"].text
        result.description = (description?.isEmpty == false) ? description : nil

        result.playlistId = Parse.playlistId(in: header)
            ?? json.first("musicPlayButtonRenderer").flatMap { Parse.playlistId(in: $0) }

        // Only the account's own playlists come with the editable header — and with
        // YouTube's song suggestions, loaded separately.
        result.isOwned = json.first("musicEditablePlaylistDetailHeaderRenderer") != nil
        if result.isOwned {
            result.suggestionsToken = json.first("secondaryContents")?
                .first("nextContinuationData")?["continuation"].stringValue
        }
        // Everything else can be saved to the library: a bookmark toggle, which only
        // carries a like endpoint when signed in (signed out it opens a sign-in prompt).
        if let toggle = header["buttons"].arrayValue.map({ $0["toggleButtonRenderer"] })
            .first(where: { $0[path: "defaultServiceEndpoint.likeEndpoint"].exists }) {
            result.isSaved = toggle["isToggled"].boolValue ?? false
            result.saveTargetId = toggle[path: "defaultServiceEndpoint.likeEndpoint.target.playlistId"].stringValue
        }

        // Take tracks from the dedicated track shelf so "related albums" carousels below
        // the listing do not leak into the track list.
        let shelf = json.first("musicPlaylistShelfRenderer") ?? json.first("musicShelfRenderer")
        if let shelf {
            result.tracks = shelf["contents"].arrayValue
                .compactMap { Parse.track($0["musicResponsiveListItemRenderer"]) }
        }
        if result.tracks.isEmpty {
            result.tracks = json.all("musicResponsiveListItemRenderer").compactMap(Parse.track)
        }

        result.shelves = Parse.shelves(in: json).filter { $0.tracks.isEmpty && !$0.cards.isEmpty }
        return result
    }
}
