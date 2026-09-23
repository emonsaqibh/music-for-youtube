import Foundation

/// `--probe-playlists` dumps the signed-in responses playlist editing is built on — the
/// "add to playlist" picker, one of the account's own playlists and one community
/// playlist — into the log folder. Read-only unless `--write` is added (see `writeRound`).
@MainActor
enum PlaylistProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe-playlists") }

    private static var engine: WebEngine { .shared }

    static func run() async {
        Log.reset()
        Log.write("=== playlist probe ===")
        guard await engine.waitUntilReady(timeout: .seconds(40)) else { return finish("engine never bound") }

        guard let song = try? await Catalog.search("Daft Punk Get Lucky", filter: .songs)
            .flatMap(\.tracks).first else { return finish("search failed") }
        Log.write("song: \(song.id) \(song.title)")

        // Which identity the requests act as — a Google account with several channels can
        // answer as a different one until the page has finished loading.
        for pass in 0..<2 {
            let who = await Catalog.accountInfo()
            let titles = (try? await Catalog.addablePlaylists(for: song.id))?.map(\.title) ?? []
            Log.write("identity[\(pass)]: \(who?.name ?? "?") \(who?.handle ?? "") addable=\(titles)")
            if pass == 0 { try? await Task.sleep(for: .seconds(8)) }
        }

        if let picker = await raw("playlist/get_add_to_playlist", ["videoIds": [song.id]]) {
            dump(picker, to: "add_to_playlist.json")
            let json = try? JSON(parsing: picker)
            let ids = json?.all("playlistAddToOptionRenderer").compactMap { $0["playlistId"].stringValue } ?? []
            Log.write("add_to_playlist: options=\(ids)")
            if let own = ids.first(where: { $0 != "LM" && $0 != "SE" }) ?? ids.first,
               let page = await raw("browse", ["browseId": "VL" + own]) {
                dump(page, to: "playlist_owned.json")
                Log.write("owned \(own): bytes=\(page.count)")
            }
        }

        if let playlist = try? await Catalog.search("lofi hip hop", filter: .playlists)
            .flatMap(\.cards).first(where: { $0.kind == .playlist }),
           let browseId = playlist.browseId ?? playlist.playlistId.map({ "VL" + $0 }),
           let page = await raw("browse", ["browseId": browseId]) {
            dump(page, to: "playlist_community.json")
            Log.write("community \(browseId) \(playlist.title): bytes=\(page.count)")
        }

        if CommandLine.arguments.contains("--write") { await writeRound(song: song) }
        if CommandLine.arguments.contains("--cleanup") {
            // Playlists left by a by-hand test in the app, named to be found here.
            for leftover in (try? await Catalog.addablePlaylists(for: song.id)) ?? []
            where leftover.title.hasPrefix("ytm probe") {
                do { try await Catalog.deletePlaylist(leftover.id); Log.write("cleanup: deleted \(leftover.title)") }
                catch { Log.write("cleanup FAILED \(leftover.id): \(error.localizedDescription)") }
            }
        }
        finish("dumps in \(Log.fileURL.deletingLastPathComponent().path)")
    }

    /// `--probe-playlists --write`: every edit once, through the same `Catalog` calls the
    /// app uses, on a private throwaway playlist that is deleted at the end — and a
    /// community playlist saved and unsaved again. Leaves the library as it found it.
    private static func writeRound(song: Track) async {
        var created: String?
        do {
            let id = try await Catalog.createPlaylist(title: "ytm probe — safe to delete",
                                                      privacy: .private, videoIds: [song.id])
            created = id
            Log.write("create: \(id)")

            if let other = try await Catalog.search("Daft Punk One More Time", filter: .songs)
                .flatMap(\.tracks).first(where: { $0.id != song.id }) {
                Log.write("add new: \(try await Catalog.add(videoIds: [other.id], to: id))")
            }
            Log.write("add duplicate: \(try await Catalog.add(videoIds: [song.id], to: id))")
            Log.write("add anyway: \(try await Catalog.add(videoIds: [song.id], to: id, allowingDuplicates: true))")

            if let rawPage = await raw("browse", ["browseId": "VL" + id]) {
                dump(rawPage, to: "playlist_created.json")
                // The suggestions under an own playlist come from the section list's continuation.
                if let token = (try? JSON(parsing: rawPage))?.first("secondaryContents")?
                    .first("nextContinuationData")?["continuation"].stringValue,
                   let more = await raw("browse", ["continuation": token]) {
                    dump(more, to: "playlist_suggestions.json")
                }
            }
            let (page, _) = try await Catalog.playlistFirstPage(playlistId: id)
            Log.write("page: owned=\(page.isOwned) saved=\(String(describing: page.isSaved)) "
                      + "tracks=\(page.tracks.map { "\($0.id)/\($0.setVideoId ?? "-")" })")
            if let token = page.suggestionsToken {
                let found = try await Catalog.playlistSuggestions(token)
                Log.write("suggestions: \(found.tracks.count) refresh=\(found.refreshToken != nil)")
                if let pick = found.tracks.first {
                    Log.write("add suggestion row: \(String(describing: try await Catalog.addReturningRow(pick.id, to: id)))")
                }
            } else {
                Log.write("suggestions: no token")
            }
            if let first = page.tracks.first {
                try await Catalog.remove([first], from: id)
                // Reads can lag a write by a moment; check at once and after a pause.
                let (now, _) = try await Catalog.playlistFirstPage(playlistId: id)
                try? await Task.sleep(for: .seconds(3))
                let (later, _) = try await Catalog.playlistFirstPage(playlistId: id)
                Log.write("remove \(first.setVideoId ?? "-"): \(page.tracks.count) -> \(now.tracks.count) at once, "
                          + "\(later.tracks.count) after 3s: \(later.tracks.map { "\($0.id)/\($0.setVideoId ?? "-")" })")
            }
            let options = try await Catalog.addablePlaylists(for: song.id)
            Log.write("addable: \(options.count) first=\(options.first.map { "\($0.id) \($0.title)" } ?? "-")")
        } catch {
            Log.write("write round FAILED: \(error.localizedDescription)")
        }
        if let created {
            do { try await Catalog.deletePlaylist(created); Log.write("delete: ok") }
            catch { Log.write("delete FAILED (\(created)): \(error.localizedDescription)") }
        }

        guard let community = try? await Catalog.search("lofi hip hop", filter: .playlists)
            .flatMap(\.cards).first(where: { $0.kind == .playlist }),
              let playlistId = community.playlistId ?? community.browseId else { return }
        do {
            let (page, _) = try await Catalog.playlistFirstPage(playlistId: playlistId)
            Log.write("community: owned=\(page.isOwned) saved=\(String(describing: page.isSaved)) "
                      + "target=\(page.saveTargetId ?? "-")")
            guard page.isSaved == false, let target = page.saveTargetId else { return }
            try await Catalog.setSaved(true, playlistId: target)
            let (saved, _) = try await Catalog.playlistFirstPage(playlistId: playlistId)
            Log.write("after save: saved=\(String(describing: saved.isSaved))")
            try await Catalog.setSaved(false, playlistId: target)
            let (unsaved, _) = try await Catalog.playlistFirstPage(playlistId: playlistId)
            Log.write("after unsave: saved=\(String(describing: unsaved.isSaved))")
        } catch {
            Log.write("save round FAILED: \(error.localizedDescription)")
        }
    }

    private static func raw(_ endpoint: String, _ body: [String: Any]) async -> String? {
        do {
            return try await engine.call("return await window.__ytm.innertube(endpoint, body);",
                                         ["endpoint": endpoint, "body": body]) as? String
        } catch {
            Log.write("\(endpoint) FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    private static func dump(_ text: String, to name: String) {
        try? text.write(to: Log.fileURL.deletingLastPathComponent().appending(path: name),
                        atomically: true, encoding: .utf8)
    }

    private static func finish(_ summary: String) {
        Log.write("=== playlist probe done: \(summary) ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
    }
}
