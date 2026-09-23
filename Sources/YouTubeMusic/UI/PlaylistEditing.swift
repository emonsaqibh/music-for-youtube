import SwiftUI

extension Notification.Name {
    /// The library changed from inside the app — a playlist created, saved or unsaved — so
    /// the sidebar's playlists are out of date.
    static let libraryDidChange = Notification.Name("ytm.libraryDidChange")
}

/// Playlist and library edits, shared by every menu and page that offers them, plus the
/// New Playlist sheet and the short confirmation each edit ends with.
@MainActor
@Observable
final class LibraryEditor {
    static let shared = LibraryEditor()

    struct NewPlaylistRequest: Identifiable {
        let id = UUID()
        /// Songs the playlist starts with; empty for one made with ⌘N or the sidebar's +.
        var tracks: [Track] = []
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError = false
        /// A button in the notice ("Add Anyway").
        var actionTitle: String?
        var action: (() -> Void)?

        static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
    }

    /// The account's own playlists, for "Add to Playlist", most recently edited first.
    private(set) var playlists: [PlaylistOption] = []
    /// A New Playlist sheet waiting to show.
    var creating: NewPlaylistRequest?
    private(set) var notice: Notice?

    /// Edits need the account, signed in — not the guest profile, not a signed-out page.
    var canEdit: Bool { Session.shared.profile == .account && Session.shared.isSignedIn }

    private init() {
        NotificationCenter.default.addObserver(forName: WebEngine.sessionDidChange, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                LibraryEditor.shared.playlists = []
                LibraryEditor.shared.playlistsFetched = nil
            }
        }
    }

    private var playlistsFetched: Date?
    private var fetchingPlaylists = false

    /// Keeps the "Add to Playlist" list ready for when a menu opens. YouTube only lists it
    /// for a song (the answer is the same whichever song), so this runs when the pointer
    /// rests on one — at most every few minutes, and never while signed out.
    func preparePlaylists(for videoId: String) {
        guard canEdit, !fetchingPlaylists else { return }
        if let fetched = playlistsFetched, Date().timeIntervalSince(fetched) < 300 { return }
        fetchingPlaylists = true
        Task {
            defer { fetchingPlaylists = false }
            if let fresh = try? await Catalog.addablePlaylists(for: videoId) {
                playlists = fresh
                playlistsFetched = Date()
            }
        }
    }

    func add(_ tracks: [Track], to playlist: PlaylistOption, allowingDuplicates: Bool = false) {
        guard !tracks.isEmpty else { return }
        Task {
            do {
                let added = try await Catalog.add(videoIds: tracks.map(\.id), to: playlist.id,
                                                  allowingDuplicates: allowingDuplicates)
                guard added else {
                    show("Already in “\(playlist.title)”", actionTitle: "Add Anyway") { [weak self] in
                        self?.add(tracks, to: playlist, allowingDuplicates: true)
                    }
                    return
                }
                forgetPlaylist(playlist.id)
                playlists.removeAll { $0.id == playlist.id }
                playlists.insert(playlist, at: 0)
                show("Added to “\(playlist.title)”")
            } catch {
                show("Couldn’t add to “\(playlist.title)”", isError: true)
            }
        }
    }

    func startNewPlaylist(with tracks: [Track] = []) {
        creating = NewPlaylistRequest(tracks: tracks)
    }

    /// Creates the playlist; nil (with a notice) when YouTube refused.
    func create(title: String, description: String, privacy: PlaylistPrivacy, tracks: [Track]) async -> String? {
        do {
            let id = try await Catalog.createPlaylist(title: title, description: description,
                                                      privacy: privacy, videoIds: tracks.map(\.id))
            playlists.insert(PlaylistOption(id: id, title: title), at: 0)
            libraryChanged()
            show("Created “\(title)”")
            return id
        } catch {
            show("Couldn’t create the playlist", isError: true)
            return nil
        }
    }

    /// Removes one row from one of the account's playlists.
    func remove(_ track: Track, from playlistId: String) async throws {
        try await Catalog.remove([track], from: playlistId)
        forgetPlaylist(playlistId)
    }

    /// Saves a playlist or album to the library, or takes it out.
    func setSaved(_ saved: Bool, targetId: String, title: String) async throws {
        try await Catalog.setSaved(saved, playlistId: targetId)
        libraryChanged()
        show(saved ? "Saved “\(title)” to your library" : "Removed “\(title)” from your library")
    }

    func show(_ text: String, isError: Bool = false,
              actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let notice = Notice(text: text, isError: isError, actionTitle: actionTitle, action: action)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.notice = notice }
        Task {
            // Long enough to read — and, with a button, to reach it.
            try? await Task.sleep(for: .seconds(action != nil ? 5 : isError ? 3.5 : 2.2))
            guard self.notice == notice else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.notice = nil }
        }
    }

    func dismissNotice() {
        withAnimation(.easeOut(duration: 0.2)) { notice = nil }
    }

    /// A playlist's remembered page is stale once it has been edited.
    private func forgetPlaylist(_ playlistId: String) {
        let bare = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        Catalog.collections.remove { $0.hasPrefix("playlist|\(bare)|") }
    }

    private func libraryChanged() {
        Catalog.libraries.remove { $0.contains(Guide.likedPlaylistsId) || $0.contains("FEmusic_liked_albums") }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}

// MARK: - Menus

/// "Add to Playlist ▸" — New Playlist…, then the account's playlists. Shown only when the
/// account can edit.
struct AddToPlaylistMenu: View {
    let tracks: [Track]

    private var editor: LibraryEditor { .shared }

    var body: some View {
        if editor.canEdit, !tracks.isEmpty {
            Menu("Add to Playlist", systemImage: "text.badge.plus") {
                Button("New Playlist…", systemImage: "plus") { editor.startNewPlaylist(with: tracks) }
                if !editor.playlists.isEmpty { Divider() }
                ForEach(editor.playlists) { playlist in
                    Button(playlist.title) { editor.add(tracks, to: playlist) }
                }
            }
        }
    }
}

// MARK: - New Playlist sheet

struct NewPlaylistSheet: View {
    let request: LibraryEditor.NewPlaylistRequest
    /// Called with the new playlist's id once it exists.
    let onCreated: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var privacy: PlaylistPrivacy = .private
    @State private var working = false
    @FocusState private var titleFocused: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New Playlist")
                    .font(.system(size: 17, weight: .bold))
                if let first = request.tracks.first {
                    Text(request.tracks.count == 1 ? "With “\(first.title)”" : "With \(request.tracks.count) songs")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Form {
                TextField("Title", text: $title, prompt: Text("Playlist name"))
                    .focused($titleFocused)
                TextField("Description", text: $description, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
                Picker("Visibility", selection: $privacy) {
                    ForEach(PlaylistPrivacy.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.columns)

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { titleFocused = true }
    }

    private func create() {
        working = true
        Task {
            let id = await LibraryEditor.shared.create(title: trimmedTitle, description: description,
                                                       privacy: privacy, tracks: request.tracks)
            working = false
            if let id {
                dismiss()
                onCreated(id, trimmedTitle)
            }
        }
    }
}

// MARK: - Notice

/// The short confirmation an edit ends with ("Added to …"), floating above the player.
struct LibraryNoticeView: View {
    private var editor: LibraryEditor { .shared }

    var body: some View {
        if let notice = editor.notice {
            HStack(spacing: 12) {
                Label(notice.text, systemImage: notice.isError || notice.action != nil
                      ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let title = notice.actionTitle, let action = notice.action {
                    Button(title) {
                        editor.dismissNotice()
                        action()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .glassEffect(.regular.interactive(notice.action != nil), in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(notice.id)
            .allowsHitTesting(notice.action != nil)
        }
    }
}
