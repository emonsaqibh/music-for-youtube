import Foundation

/// Songs YouTube suggests under one of the account's own playlists, and the token that
/// swaps them for a fresh set (its Refresh button).
struct PlaylistSuggestions: Sendable {
    var tracks: [Track]
    var refreshToken: String?
}

/// One of the account's own playlists, as YouTube's "Save to playlist" picker lists them.
struct PlaylistOption: Identifiable, Hashable, Sendable {
    var id: String          // playlistId, without "VL"
    var title: String
    var artwork: URL?
}

enum PlaylistPrivacy: String, CaseIterable, Identifiable, Sendable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .private: "Private"
        case .unlisted: "Unlisted"
        case .public: "Public"
        }
    }
}

enum PlaylistEditError: LocalizedError {
    /// YouTube answered, but not with success. Carries its own message when it gave one.
    case rejected(String?)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): message ?? "YouTube Music didn’t accept the change."
        }
    }
}

/// Library edits. Each is the request YouTube Music's own web app sends for the same click,
/// from the signed-in page — never through the anonymous Android client, and only ever in
/// answer to a click (see HANDOFF's account-safety notes).
extension Catalog {
    /// The playlists a song can be added to, most recently edited first.
    static func addablePlaylists(for videoId: String) async throws -> [PlaylistOption] {
        let json = try await engine.innertube("playlist/get_add_to_playlist", ["videoIds": [videoId]])
        return json.all("playlistAddToOptionRenderer").compactMap { option in
            guard let id = option["playlistId"].stringValue,
                  let title = option["title"].text, !title.isEmpty else { return nil }
            return PlaylistOption(id: id, title: title, artwork: Parse.artwork(option, size: 120))
        }
    }

    /// The Suggestions shelf, from `Collection.suggestionsToken` or a Refresh token.
    static func playlistSuggestions(_ token: String) async throws -> PlaylistSuggestions {
        let json = try await engine.innertube("browse", ["continuation": token])
        return PlaylistSuggestions(
            tracks: json.all("musicResponsiveListItemRenderer").compactMap(Parse.track),
            refreshToken: json.first("reloadContinuationData")?["continuation"].stringValue)
    }

    /// Creates a playlist, optionally starting with some songs. Returns its id.
    static func createPlaylist(title: String, description: String = "",
                               privacy: PlaylistPrivacy = .private,
                               videoIds: [String] = []) async throws -> String {
        var body: [String: Any] = ["title": title, "description": description,
                                   "privacyStatus": privacy.rawValue]
        if !videoIds.isEmpty { body["videoIds"] = videoIds }
        let json = try await engine.innertube("playlist/create", body, changesAccount: true)
        guard let id = json["playlistId"].stringValue else { throw PlaylistEditError.rejected(nil) }
        return id
    }

    /// Adds songs to one of the account's playlists. As on the web, YouTube first refuses a
    /// song that is already there (false); `allowingDuplicates` is its "Add anyway".
    static func add(videoIds: [String], to playlistId: String, allowingDuplicates: Bool = false) async throws -> Bool {
        try await addRows(videoIds: videoIds, to: playlistId, allowingDuplicates: allowingDuplicates) != nil
    }

    /// Adds one song and returns its new row's `setVideoId` (so it can be removed without a
    /// reload) — "" if YouTube didn't say — or nil when it was already there.
    static func addReturningRow(_ videoId: String, to playlistId: String) async throws -> String? {
        try await addRows(videoIds: [videoId], to: playlistId).map { $0.first ?? "" }
    }

    private static func addRows(videoIds: [String], to playlistId: String,
                                allowingDuplicates: Bool = false) async throws -> [String]? {
        // "SKIP" skips the duplicate check; "CHECK" makes YouTube refuse duplicates.
        let dedupe = allowingDuplicates ? "DEDUPE_OPTION_SKIP" : "DEDUPE_OPTION_CHECK"
        let actions: [[String: Any]] = videoIds.map {
            ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0, "dedupeOption": dedupe]
        }
        let json = try await edit(playlistId, actions, checked: false)
        if json["status"].stringValue == "STATUS_SUCCEEDED" {
            return json.all("playlistEditVideoAddedResultData").compactMap { $0["setVideoId"].stringValue }
        }
        // The refusal carries a toast offering to add it anyway — the same edit, unchecked.
        if json.first("playlistEditEndpoint") != nil { return nil }
        throw PlaylistEditError.rejected(json.first("responseText")?.text)
    }

    /// Removes rows from one of the account's playlists. Rows are named by their
    /// `setVideoId`, so a song that appears twice loses only the chosen copy.
    static func remove(_ tracks: [Track], from playlistId: String) async throws {
        let actions: [[String: Any]] = tracks.compactMap { track in
            guard let setVideoId = track.setVideoId else { return nil }
            return ["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId, "removedVideoId": track.id]
        }
        guard !actions.isEmpty else { throw PlaylistEditError.rejected("That song can’t be removed here.") }
        _ = try await edit(playlistId, actions)
    }

    /// Saves someone else's playlist (or an album) to the library, or takes it out again —
    /// the bookmark on YouTube Music's playlist page.
    static func setSaved(_ saved: Bool, playlistId: String) async throws {
        _ = try await engine.innertube(saved ? "like/like" : "like/removelike",
                                       ["target": ["playlistId": bare(playlistId)]],
                                       changesAccount: true)
    }

    /// Likes a song (it joins Liked Music) or takes the like back — the thumbs-up in
    /// YouTube Music's player bar.
    static func setLiked(_ liked: Bool, videoId: String) async throws {
        _ = try await engine.innertube(liked ? "like/like" : "like/removelike",
                                       ["target": ["videoId": videoId]],
                                       changesAccount: true)
    }

    /// Whether the account likes a song, from `next`: the request YouTube Music's web app
    /// makes for every song it plays. Nil when the answer doesn't say (signed out).
    static func isLiked(videoId: String) async throws -> Bool? {
        Parse.isLiked(videoId: videoId,
                      in: try await engine.innertube("next", ["videoId": videoId, "isAudioOnly": true]))
    }

    static func deletePlaylist(_ playlistId: String) async throws {
        _ = try await engine.innertube("playlist/delete", ["playlistId": bare(playlistId)],
                                       changesAccount: true)
    }

    private static func edit(_ playlistId: String, _ actions: [[String: Any]],
                             checked: Bool = true) async throws -> JSON {
        let json = try await engine.innertube("browse/edit_playlist",
                                              ["playlistId": bare(playlistId), "actions": actions],
                                              changesAccount: true)
        guard !checked || json["status"].stringValue == "STATUS_SUCCEEDED" else {
            throw PlaylistEditError.rejected(json.first("responseText")?.text)
        }
        return json
    }

    /// Edits take the playlist id itself, not its "VL" browse id.
    private static func bare(_ playlistId: String) -> String {
        playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
    }
}
