import Foundation

/// `--probe-nav` dumps the raw InnerTube responses behind two things we have not built
/// yet — YouTube Music's own navigation, and lyrics — into
/// ~/Library/Logs/MusicForYouTube/ so their shape can be read offline.
@MainActor
enum NavProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-nav") }

    private static var engine: WebEngine { .shared }

    private static var dumpDirectory: URL {
        Log.fileURL.deletingLastPathComponent()
    }

    static func run() async {
        Log.reset()
        Log.write("=== nav probe ===")
        guard await engine.waitUntilReady(timeout: .seconds(40)) else {
            return finish("engine never bound")
        }

        // --- 1. The navigation YouTube Music builds its own sidebar from ---
        for endpoint in ["guide", "account/account_menu"] {
            if let raw = await raw(endpoint, [:]) {
                dump(raw, to: endpoint.replacingOccurrences(of: "/", with: "_") + ".json")
                let json = try? JSON(parsing: raw)
                Log.write("\(endpoint): bytes=\(raw.count) "
                          + "guideEntry=\(json?.all("guideEntryRenderer").count ?? 0) "
                          + "pivotBarItem=\(json?.all("pivotBarItemRenderer").count ?? 0)")
            }
        }

        // The library landing page lists the real library sections and their browseIds.
        if let raw = await raw("browse", ["browseId": "FEmusic_library_landing"]) {
            dump(raw, to: "library_landing.json")
            Log.write("library_landing: bytes=\(raw.count)")
        }

        // The library sections themselves, to check what shape each one comes back in.
        for browseId in ["FEmusic_liked_playlists", "FEmusic_liked_videos", "FEmusic_liked_albums"] {
            if let raw = await raw("browse", ["browseId": browseId]) {
                dump(raw, to: browseId + ".json")
                let json = try? JSON(parsing: raw)
                Log.write("\(browseId): bytes=\(raw.count) shelves=\(json.map(Parse.shelves)?.count ?? -1) "
                          + "cards=\(json.map(Parse.shelves)?.flatMap(\.cards).count ?? -1) "
                          + "tracks=\(json.map(Parse.shelves)?.flatMap(\.tracks).count ?? -1)")
            }
        }

        // --- 1b. Home, every page of it ---
        // YouTube pages the home feed: the first response carries a handful of shelves
        // and a continuation token; the web app fetches the rest as you scroll.
        if let first = await raw("browse", ["browseId": "FEmusic_home"]) {
            dump(first, to: "home_0.json")
            var json = try? JSON(parsing: first)
            logSections(json, page: 0)
            var page = 1
            while page <= 12, let token = json.flatMap(homeContinuation) {
                guard let more = await raw("browse", ["continuation": token]) else { break }
                dump(more, to: "home_\(page).json")
                json = try? JSON(parsing: more)
                logSections(json, page: page)
                page += 1
            }
        }

        // --- 1c. Explore, and the pages its buttons lead to ---
        for browseId in ["FEmusic_explore", "FEmusic_new_releases", "FEmusic_charts", "FEmusic_moods_and_genres"] {
            if let body = await raw("browse", ["browseId": browseId]) {
                dump(body, to: browseId + ".json")
                logSections(try? JSON(parsing: body), page: 0, label: browseId)
                if browseId == "FEmusic_explore", let json = try? JSON(parsing: body) {
                    let shelves = Parse.shelves(in: json)
                    Log.write("explore parsed: " + shelves.map { "\"\($0.title)\" buttons=\($0.buttons.count) cards=\($0.cards.count)" }
                        .joined(separator: " | "))
                    // Where a mood tile leads.
                    if let mood = shelves.flatMap(\.buttons).first(where: { $0.color != nil }),
                       let page = await raw("browse", ["browseId": mood.browseId, "params": mood.params ?? ""]) {
                        dump(page, to: "mood_category.json")
                        logSections(try? JSON(parsing: page), page: 0, label: "mood:" + mood.title)
                    }
                }
            }
        }

        // Charts for one country, chosen the way the web app's country menu does it.
        for country in ["US", "BD"] {
            if let body = await raw("browse", ["browseId": "FEmusic_charts",
                                               "formData": ["selectedValues": [country]]]) {
                dump(body, to: "FEmusic_charts_\(country).json")
                logSections(try? JSON(parsing: body), page: 0, label: "charts:" + country)
            }
        }

        // --- 2. Lyrics ---
        guard let track = try? await Catalog.search("Daft Punk Get Lucky", filter: .songs)
            .flatMap(\.tracks).first else { return finish("search failed") }
        Log.write("lyrics probe track: \(track.id) \(track.title)")

        guard let nextRaw = await raw("next", ["videoId": track.id,
                                              "playlistId": "RDAMVM" + track.id,
                                              "isAudioOnly": true]) else {
            return finish("next failed")
        }
        dump(nextRaw, to: "next.json")

        let next = try? JSON(parsing: nextRaw)
        let tabs = next?.all("tabRenderer") ?? []
        Log.write("next tabs: " + tabs.map { $0[path: "title"].stringValue ?? $0["title"].text ?? "?" }
            .joined(separator: " | "))

        // The lyrics tab carries a browseId that must be fetched separately.
        let lyricsBrowseId = tabs
            .first { ($0["title"].text ?? $0["title"].stringValue ?? "").lowercased().contains("lyric") }?
            .first("browseId")?.stringValue
        Log.write("lyrics browseId = \(lyricsBrowseId ?? "NOT FOUND")")

        if let id = lyricsBrowseId {
            if let raw = await raw("browse", ["browseId": id]) {
                dump(raw, to: "lyrics_web.json")
                let json = try? JSON(parsing: raw)
                let text = json?.first("musicDescriptionShelfRenderer")?["description"].text
                Log.write("lyrics(web) bytes=\(raw.count) chars=\(text?.count ?? 0) "
                          + "preview=\(String((text ?? "").prefix(70)).replacingOccurrences(of: "\n", with: " / "))")
            }
            // Timed lyrics are only served to the Android music client, so ask as one.
            if let raw = await rawAsAndroid("browse", ["browseId": id]) {
                dump(raw, to: "lyrics_android.json")
                let json = try? JSON(parsing: raw)
                Log.write("lyrics(android) bytes=\(raw.count) "
                          + "timedLyricsData=\(json?.all("timedLyricsData").count ?? 0) "
                          + "cueRange=\(json?.all("cueRange").count ?? 0) "
                          + "lyricLine=\(json?.all("lyricLine").count ?? 0)")
            }
        }

        finish("dumps in \(dumpDirectory.path)")
    }

    // MARK: Helpers

    private static func homeContinuation(_ json: JSON) -> String? {
        json.first("nextContinuationData")?["continuation"].stringValue
            ?? json.first("continuationCommand")?["token"].stringValue
    }

    /// One line per page: which renderer each section is, and whether we parse it.
    private static func logSections(_ json: JSON?, page: Int, label: String = "home") {
        guard let json else { return Log.write("\(label)[\(page)]: unparseable") }
        var sections: [JSON] = []
        for list in json.all("sectionListRenderer") { sections += list["contents"].arrayValue }
        for cont in json.all("sectionListContinuation") { sections += cont["contents"].arrayValue }
        let kinds = sections.map { section -> String in
            let key = section.objectValue.keys.sorted().first ?? "?"
            let items = section[key]["contents"].arrayValue.first?.objectValue.keys.sorted().first ?? "-"
            let title = section[key][path: "header.musicCarouselShelfBasicHeaderRenderer.title"].text ?? ""
            return "\(key)<\(items)>\"\(title)\""
        }
        let chips = json.all("chipCloudChipRenderer").compactMap { $0["text"].text }
        Log.write("\(label)[\(page)]: sections=\(sections.count) parsed=\(Parse.shelves(in: json).count) "
                  + (chips.isEmpty ? "" : "chips=\(chips) ") + kinds.joined(separator: " | "))
    }

    private static func raw(_ endpoint: String, _ body: [String: Any]) async -> String? {
        do {
            let result = try await engine.call(
                "return await window.__ytm.innertube(endpoint, body);",
                ["endpoint": endpoint, "body": body])
            return result as? String
        } catch {
            Log.write("\(endpoint) FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    /// Same call, but presenting as the Android YouTube Music client.
    private static func rawAsAndroid(_ endpoint: String, _ body: [String: Any]) async -> String? {
        let js = """
        const ctx = { client: { clientName: 'ANDROID_MUSIC', clientVersion: '7.21.50',
                                androidSdkVersion: 34, hl: 'en', gl: 'US' } };
        const res = await fetch('https://music.youtube.com/youtubei/v1/' + endpoint + '?prettyPrint=false', {
          method: 'POST', credentials: 'omit',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(Object.assign({ context: ctx }, body))
        });
        return await res.text();
        """
        do {
            return try await engine.call(js, ["endpoint": endpoint, "body": body]) as? String
        } catch {
            Log.write("\(endpoint) (android) FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    private static func dump(_ text: String, to name: String) {
        try? text.write(to: dumpDirectory.appending(path: name), atomically: true, encoding: .utf8)
    }

    private static func finish(_ summary: String) {
        Log.write("=== nav probe done: \(summary) ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
    }
}
