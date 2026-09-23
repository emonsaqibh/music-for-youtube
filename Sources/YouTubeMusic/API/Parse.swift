import Foundation

/// Turns InnerTube "renderer" trees into our models.
///
/// Every extractor is written to fail soft: YouTube reshuffles these structures without
/// warning, so we look for the pieces we need wherever they happen to be rather than
/// walking one fixed path. A shelf we cannot read is dropped, never fatal.
enum Parse {

    // MARK: - Artwork

    /// Picks the largest thumbnail and asks Google for it at `size` points.
    static func artwork(_ node: JSON, size: Int = 544) -> URL? {
        let candidates = node["thumbnailRenderer"].first("thumbnails")
            ?? node["thumbnail"].first("thumbnails")
            ?? node.first("thumbnails")
        guard let list = candidates?.arrayValue, !list.isEmpty else { return nil }

        let best = list.max { ($0["width"].intValue ?? 0) < ($1["width"].intValue ?? 0) }
        guard let raw = best?["url"].stringValue, let url = URL(string: raw) else { return nil }
        return upscaled(url, to: size)
    }

    /// Google's image CDN encodes the requested size in the path, so we can simply ask
    /// for a bigger one instead of shipping blurry 60pt thumbnails into a 220pt tile.
    static func upscaled(_ url: URL, to size: Int) -> URL {
        let s = url.absoluteString
        guard s.contains("googleusercontent.com") || s.contains("ggpht.com") else { return url }
        let bumped = s.replacingOccurrences(of: #"w\d+-h\d+"#,
                                            with: "w\(size)-h\(size)",
                                            options: .regularExpression)
        return URL(string: bumped) ?? url
    }

    // MARK: - Endpoints

    static func pageKind(_ endpoint: JSON) -> CardKind? {
        let type = endpoint[path: "browseEndpointContextSupportedConfigs"
                            + ".browseEndpointContextMusicConfig.pageType"].stringValue
        switch type {
        case "MUSIC_PAGE_TYPE_ALBUM": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL": return .artist
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW": return .podcast
        default: return nil
        }
    }

    static func kind(fromSubtitle text: String) -> CardKind? {
        switch text.lowercased() {
        case "album": return .album
        case "single": return .single
        case "ep": return .ep
        case "playlist": return .playlist
        case "artist": return .artist
        case "song": return .song
        case "video": return .video
        case "podcast", "podcast show": return .podcast
        default: return nil
        }
    }

    /// Finds the playlist a tile should start playing, checking every endpoint flavour
    /// YouTube uses for play buttons.
    static func playlistId(in node: JSON) -> String? {
        node.first("watchPlaylistEndpoint")?["playlistId"].stringValue
            ?? node.first("watchEndpoint")?["playlistId"].stringValue
            ?? node.first("playlistId")?.stringValue
    }

    static func videoId(in node: JSON) -> String? {
        node.first("watchEndpoint")?["videoId"].stringValue
            ?? node.first("videoId")?.stringValue
    }

    static func isExplicit(_ node: JSON) -> Bool {
        node.all("iconType").contains { $0.stringValue == "MUSIC_EXPLICIT_BADGE" }
    }

    // MARK: - Tracks

    private static func flexText(_ renderer: JSON, _ index: Int) -> JSON {
        renderer["flexColumns"][index]["musicResponsiveListItemFlexColumnRenderer"]["text"]
    }

    private static let labelWords: Set<String> = [
        "song", "video", "album", "single", "ep", "playlist", "artist", "podcast", "episode",
    ]

    /// `musicResponsiveListItemRenderer` — the row used by track lists and search results.
    static func track(_ r: JSON) -> Track? {
        let title = flexText(r, 0).text ?? ""
        guard !title.isEmpty else { return nil }

        let id = r[path: "playlistItemData.videoId"].stringValue
            ?? r["overlay"].first("watchEndpoint")?["videoId"].stringValue
            ?? flexText(r, 0)["runs"][0].first("watchEndpoint")?["videoId"].stringValue
            ?? ""
        guard !id.isEmpty else { return nil }

        var track = Track(id: id, title: title)
        track.setVideoId = r[path: "playlistItemData.playlistSetVideoId"].stringValue
        track.isRemovable = r["menu"].all("playlistEditEndpoint")
            .contains { $0["actions"].arrayValue.contains { $0["action"].stringValue == "ACTION_REMOVE_VIDEO" } }
        track.artwork = artwork(r, size: 240)
        track.isExplicit = isExplicit(r["badges"])
        track.rank = rank(r)

        // Artists, album and duration all live in the secondary flex columns, told apart
        // by the endpoint attached to each run.
        for column in 1..<4 {
            for run in flexText(r, column)["runs"].arrayValue {
                guard let text = run["text"].stringValue, text != " • " else { continue }
                let browse = run[path: "navigationEndpoint.browseEndpoint"]
                if browse.exists, let browseId = browse["browseId"].stringValue {
                    switch pageKind(browse) {
                    case .artist: track.artists.append(ArtistRef(id: browseId, name: text))
                    case .album, .single, .ep: track.album = AlbumRef(id: browseId, name: text)
                    default: break
                    }
                } else if let seconds = Format.parseDuration(text) {
                    track.seconds = seconds
                }
            }
        }

        if let fixed = r[path: "fixedColumns.0.musicResponsiveListItemFixedColumnRenderer.text"].text,
           let seconds = Format.parseDuration(fixed) {
            track.seconds = seconds
        }

        // Unlinked artist names (common on library rows) — take the plain text runs that
        // are not one of YouTube's type labels, a duration, or a play count.
        if track.artists.isEmpty {
            let names = flexText(r, 1)["runs"].arrayValue
                .compactMap { $0["text"].stringValue }
                .filter { $0 != " • " }
                .filter { !labelWords.contains($0.lowercased()) }
                .filter { Format.parseDuration($0) == nil }
                .filter { !$0.lowercased().contains("views") && !$0.lowercased().contains("plays") }
            if let first = names.first, !first.isEmpty {
                track.artists = [ArtistRef(id: nil, name: first)]
            }
        }

        return track
    }

    /// `playlistPanelVideoRenderer` — the rows of the watch/radio queue from `next`.
    static func queueTrack(_ r: JSON) -> Track? {
        guard let id = r["videoId"].stringValue,
              let title = r["title"].text, !title.isEmpty else { return nil }
        var track = Track(id: id, title: title)
        track.artwork = artwork(r, size: 240)
        track.seconds = Format.parseDuration(r["lengthText"].text)
        track.setVideoId = r["playlistSetVideoId"].stringValue

        let byline = r["longBylineText"].exists ? r["longBylineText"] : r["shortBylineText"]
        for run in byline["runs"].arrayValue {
            guard let text = run["text"].stringValue, text != " • " else { continue }
            let browse = run[path: "navigationEndpoint.browseEndpoint"]
            switch pageKind(browse) {
            case .artist: track.artists.append(ArtistRef(id: browse["browseId"].stringValue, name: text))
            case .album, .single, .ep: track.album = AlbumRef(id: browse["browseId"].stringValue, name: text)
            default: break
            }
        }
        if track.artists.isEmpty, let first = byline["runs"][0]["text"].stringValue {
            track.artists = [ArtistRef(id: nil, name: first)]
        }
        return track
    }

    // MARK: - Cards

    /// `musicTwoRowItemRenderer` — the square/circular tiles that fill carousels and grids.
    static func card(_ r: JSON) -> Card? {
        guard let title = r["title"].text, !title.isEmpty else { return nil }
        let nav = r["navigationEndpoint"]
        let browse = nav["browseEndpoint"]
        let browseId = browse["browseId"].stringValue
        let video = nav.first("watchEndpoint")?["videoId"].stringValue

        guard let id = browseId ?? video else { return nil }

        let subtitleRuns = r["subtitle"]["runs"].arrayValue.compactMap { $0["text"].stringValue }
        let kind = pageKind(browse)
            ?? subtitleRuns.first.flatMap(kind(fromSubtitle:))
            ?? (video != nil ? .song : .other)

        return Card(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitleRuns.joined().replacingOccurrences(of: " • ", with: " · "),
            artwork: artwork(r, size: kind == .artist ? 400 : 544),
            browseId: browseId,
            videoId: video,
            playlistId: playlistId(in: r["thumbnailOverlay"]) ?? playlistId(in: nav),
            // YouTube says so outright ("…_RECTANGLE_16_9"); the pixel size is a fallback.
            isWide: r["aspectRatio"].stringValue?.contains("16_9") ?? (thumbnailAspect(r) > 1.3))
    }

    /// Width over height of the largest thumbnail offered.
    static func thumbnailAspect(_ node: JSON) -> Double {
        let list = (node["thumbnailRenderer"].first("thumbnails") ?? node.first("thumbnails"))?.arrayValue ?? []
        guard let best = list.max(by: { ($0["width"].intValue ?? 0) < ($1["width"].intValue ?? 0) }),
              let w = best["width"].doubleValue, let h = best["height"].doubleValue, h > 0 else { return 1 }
        return w / h
    }

    /// A `musicResponsiveListItemRenderer` that stands for a collection rather than a song
    /// (albums and artists in search results arrive this way).
    static func cardFromRow(_ r: JSON) -> Card? {
        let title = flexText(r, 0).text ?? ""
        guard !title.isEmpty else { return nil }
        let browse = r[path: "navigationEndpoint.browseEndpoint"]
        guard let browseId = browse["browseId"].stringValue else { return nil }

        let subtitle = flexText(r, 1)["runs"].arrayValue
            .compactMap { $0["text"].stringValue }
            .joined()
            .replacingOccurrences(of: " • ", with: " · ")

        return Card(
            id: browseId,
            kind: pageKind(browse) ?? .other,
            title: title,
            subtitle: subtitle,
            artwork: artwork(r, size: 400),
            browseId: browseId,
            videoId: nil,
            playlistId: playlistId(in: r["overlay"]),
            rank: rank(r))
    }

    /// The chart position column of a ranked row: "1" and an up / down / unchanged arrow.
    static func rank(_ r: JSON) -> ChartRank? {
        let column = r[path: "customIndexColumn.musicCustomIndexColumnRenderer"]
        guard let position = column["text"].text, !position.isEmpty else { return nil }
        let trend: ChartRank.Trend? = switch column[path: "icon.iconType"].stringValue {
        case "ARROW_DROP_UP": .up
        case "ARROW_DROP_DOWN": .down
        case "ARROW_CHART_NEUTRAL": .same
        default: nil
        }
        return ChartRank(position: position, trend: trend)
    }

    // MARK: - Navigation buttons

    /// `musicNavigationButtonRenderer` — Explore's top buttons and the mood and genre tiles.
    static func navButton(_ r: JSON) -> NavButton? {
        guard let title = r["buttonText"].text, !title.isEmpty,
              let browse = r["clickCommand"].first("browseEndpoint"),
              let browseId = browse["browseId"].stringValue else { return nil }
        return NavButton(title: title,
                         browseId: browseId,
                         params: browse["params"].stringValue,
                         iconType: r[path: "iconStyle.icon.iconType"].stringValue,
                         color: r[path: "solid.leftStripeColor"].doubleValue.map { UInt32(truncatingIfNeeded: Int64($0)) })
    }

    // MARK: - Shelves

    /// Maps one `sectionListRenderer` child onto a shelf, if we recognise it.
    static func shelf(_ section: JSON, index: Int) -> Shelf? {
        if section["musicCarouselShelfRenderer"].exists {
            return carousel(section["musicCarouselShelfRenderer"], index: index)
        }
        if section["musicShelfRenderer"].exists {
            return list(section["musicShelfRenderer"], index: index)
        }
        if section["gridRenderer"].exists {
            return grid(section["gridRenderer"], index: index)
        }
        if section["musicPlaylistShelfRenderer"].exists {
            return list(section["musicPlaylistShelfRenderer"], index: index)
        }
        if section["musicCardShelfRenderer"].exists {
            return topResult(section["musicCardShelfRenderer"], index: index)
        }
        return nil
    }

    private static func carousel(_ r: JSON, index: Int) -> Shelf? {
        let header = r[path: "header.musicCarouselShelfBasicHeaderRenderer"]
        let more = header[path: "moreContentButton.buttonRenderer.navigationEndpoint.browseEndpoint"]
        var shelf = Shelf(
            id: "carousel-\(index)",
            title: header["title"].text ?? "",
            strapline: header["strapline"].text,
            moreBrowseId: more["browseId"].stringValue,
            moreParams: more["params"].stringValue)

        for item in r["contents"].arrayValue {
            if item["musicTwoRowItemRenderer"].exists {
                if let c = card(item["musicTwoRowItemRenderer"]) { shelf.cards.append(c) }
            } else if item["musicNavigationButtonRenderer"].exists {
                if let b = navButton(item["musicNavigationButtonRenderer"]) { shelf.buttons.append(b) }
            } else if item["musicResponsiveListItemRenderer"].exists {
                let row = item["musicResponsiveListItemRenderer"]
                if let t = track(row) { shelf.tracks.append(t) }
                else if let c = cardFromRow(row) { shelf.cards.append(c) }
            }
        }
        return shelf.isEmpty ? nil : shelf
    }

    private static func list(_ r: JSON, index: Int) -> Shelf? {
        var shelf = Shelf(id: "list-\(index)", title: r["title"].text ?? "")
        for item in r["contents"].arrayValue {
            let row = item["musicResponsiveListItemRenderer"]
            guard row.exists else { continue }
            if let t = track(row) { shelf.tracks.append(t) }
            else if let c = cardFromRow(row) { shelf.cards.append(c) }
        }
        return shelf.isEmpty ? nil : shelf
    }

    private static func grid(_ r: JSON, index: Int) -> Shelf? {
        var shelf = Shelf(id: "grid-\(index)",
                          title: r[path: "header.gridHeaderRenderer.title"].text ?? "",
                          isGrid: true)
        for item in r["items"].arrayValue {
            if let c = card(item["musicTwoRowItemRenderer"]) { shelf.cards.append(c) }
            else if let b = navButton(item["musicNavigationButtonRenderer"]) { shelf.buttons.append(b) }
        }
        return shelf.isEmpty ? nil : shelf
    }

    /// Search's "Top result" hero card.
    private static func topResult(_ r: JSON, index: Int) -> Shelf? {
        var shelf = Shelf(id: "top-\(index)", title: r[path: "header.musicCardShelfHeaderBasicRenderer.title"].text ?? "Top result")
        guard let title = r["title"].text else { return nil }
        let browse = r["title"].first("browseEndpoint") ?? r.first("browseEndpoint") ?? .null
        let video = videoId(in: r["title"]) ?? videoId(in: r["buttons"])
        let subtitle = r["subtitle"]["runs"].arrayValue
            .compactMap { $0["text"].stringValue }.joined()
            .replacingOccurrences(of: " • ", with: " · ")

        shelf.cards.append(Card(
            id: browse["browseId"].stringValue ?? video ?? title,
            kind: pageKind(browse) ?? (video != nil ? .song : .other),
            title: title,
            subtitle: subtitle,
            artwork: artwork(r, size: 544),
            browseId: browse["browseId"].stringValue,
            videoId: video,
            playlistId: playlistId(in: r)))

        for item in r["contents"].arrayValue {
            if let t = track(item["musicResponsiveListItemRenderer"]) { shelf.tracks.append(t) }
        }
        return shelf
    }

    /// The "nothing here" notice YouTube sends in place of an empty page — already
    /// localised, and more specific than anything generic we could say.
    static func emptyMessage(in response: JSON) -> String? {
        guard let message = response.first("messageRenderer") else { return nil }
        let parts = [message["text"].text, message.first("messageSubtextRenderer")?["text"].text]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Every shelf in a browse/search response, in page order.
    static func shelves(in response: JSON) -> [Shelf] {
        var sections: [JSON] = []
        for list in response.all("sectionListRenderer") {
            sections.append(contentsOf: list["contents"].arrayValue)
        }
        // Later pages of a feed arrive as a continuation of the section list.
        for list in response.all("sectionListContinuation") {
            sections.append(contentsOf: list["contents"].arrayValue)
        }
        if sections.isEmpty {
            // Some library tabs return a bare grid with no section list wrapper.
            sections = response.all("gridRenderer").map { JSON.object(["gridRenderer": $0]) }
        }
        return sections.enumerated().compactMap { shelf($0.element, index: $0.offset) }
    }

    // MARK: - Feeds

    /// A feed page: its shelves, the token for the next page, and its filter chips.
    static func feedPage(_ response: JSON) -> FeedPage {
        FeedPage(shelves: shelves(in: response),
                 continuation: feedContinuation(response),
                 chips: chips(in: response),
                 filter: feedFilter(response))
    }

    /// Charts' country menu (`musicSortFilterButtonRenderer` → `musicMultiSelectMenuRenderer`).
    static func feedFilter(_ response: JSON) -> FeedFilter? {
        guard let button = response.first("musicSortFilterButtonRenderer"),
              let menu = button.first("musicMultiSelectMenuRenderer") else { return nil }
        let current = button["title"].text
        var options: [FeedFilter.Option] = []
        var afterDivider = false
        for item in menu["options"].arrayValue {
            if item["musicMenuItemDividerRenderer"].exists { afterDivider = true; continue }
            let r = item["musicMultiSelectMenuItemRenderer"]
            guard let title = r["title"].text,
                  let value = formValue(r["formItemEntityKey"].stringValue) else { continue }
            // The button is titled with the option in effect; failing that, it is the one
            // with nothing to do when chosen.
            let selected = current.map { $0 == title } ?? !r["selectedCommand"].exists
            options.append(.init(title: title, value: value, isSelected: selected, startsGroup: afterDivider))
            afterDivider = false
        }
        guard !options.isEmpty else { return nil }
        return FeedFilter(title: menu[path: "title.musicMenuTitleRenderer.primaryText"].text, options: options)
    }

    private static let formValuePattern = try! Regex(#"_menu_\d+([A-Z]{2})"#)

    /// A menu option's value lives inside its entity key: base64 protobuf whose field 2 is
    /// a string naming the form and the value — "explore_charts_country_menu_316766567AR",
    /// sometimes with the referring page after it ("…567ARFEmusic_explore"). The value is
    /// the two-letter country code straight after the digits (ZZ is Global).
    static func formValue(_ key: String?) -> String? {
        guard let key = key?.removingPercentEncoding,
              let data = Data(base64Encoded: key), data.count > 2,
              data[data.startIndex] == 0x12 else { return nil }
        let length = Int(data[data.startIndex + 1])
        let start = data.startIndex + 2
        guard length < 0x80, start + length <= data.endIndex,
              let name = String(data: data[start..<start + length], encoding: .utf8),
              let match = name.firstMatch(of: formValuePattern),
              let value = match.output[1].substring else { return nil }
        return String(value)
    }

    /// The next-page token of the feed's section list — looked for on the section list
    /// itself, so a stray continuation elsewhere on the page (a carousel's) isn't taken.
    static func feedContinuation(_ response: JSON) -> String? {
        let lists = response.all("sectionListRenderer") + response.all("sectionListContinuation")
        for list in lists {
            if let token = list["continuations"].first("nextContinuationData")?["continuation"].stringValue {
                return token
            }
            // Newer responses end the section list with a continuation item instead.
            if let item = list["contents"].arrayValue.last?["continuationItemRenderer"],
               let token = item.first("continuationCommand")?["token"].stringValue {
                return token
            }
        }
        return nil
    }

    static func chips(in response: JSON) -> [FeedChip] {
        response.all("chipCloudChipRenderer").compactMap { chip in
            guard let title = chip["text"].text, !title.isEmpty,
                  let browse = chip[path: "navigationEndpoint.browseEndpoint"].exists
                      ? chip[path: "navigationEndpoint.browseEndpoint"] : nil,
                  let browseId = browse["browseId"].stringValue else { return nil }
            return FeedChip(title: title,
                            browseId: browseId,
                            params: browse["params"].stringValue,
                            deselectParams: chip["onDeselectedCommand"].first("browseEndpoint")?["params"].stringValue,
                            isSelected: chip["isSelected"].boolValue ?? false)
        }
    }
}
