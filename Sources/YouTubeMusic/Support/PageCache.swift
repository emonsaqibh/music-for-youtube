import Foundation

/// Recently loaded pages, so going back to one — Home after a chip, Explore after an album —
/// is instant instead of another trip to YouTube, and so simultaneous requests for the same
/// page share one fetch.
///
/// Views show a cached page at once and refetch only when it's older than `freshFor`, so
/// this also cuts traffic. Entries can be persisted to disk (Home), which lets the app show
/// the last Home immediately at launch while the web engine is still loading. Everything is
/// dropped when the session changes — a different account or profile must never see these.
@MainActor
final class PageCache<Value: Codable & Sendable> {
    struct Entry {
        let value: Value
        let date: Date
        var age: TimeInterval { Date().timeIntervalSince(date) }
    }

    /// How long a page counts as current. Older ones still show instantly, then refresh.
    static var freshFor: TimeInterval { 60 }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var inflight: [String: Task<Value, Error>] = [:]
    private let limit: Int
    /// Where persisted entries live — wiped whole when the session changes.
    private let directory: URL?
    private let persists: (String) -> Bool

    init(limit: Int = 40, directory: URL? = nil, persists: @escaping (String) -> Bool = { _ in false }) {
        self.limit = limit
        self.directory = directory
        self.persists = persists
        NotificationCenter.default.addObserver(forName: WebEngine.sessionDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    func cached(_ key: String) -> Entry? {
        if let entry = entries[key] { return entry }
        guard let url = diskURL(key),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Value.self, from: data) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let entry = Entry(value: value, date: date)
        store(entry, for: key, persist: false)
        return entry
    }

    /// Fetches the page — joining a fetch already under way for the same key — and keeps it.
    func load(_ key: String, _ fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let running = inflight[key] { return try await running.value }
        let task = Task { try await fetch() }
        inflight[key] = task
        defer { inflight[key] = nil }
        let value = try await task.value
        store(Entry(value: value, date: Date()), for: key, persist: true)
        return value
    }

    /// Keeps a page assembled elsewhere (a playlist once all its tracks are in).
    func put(_ value: Value, for key: String) {
        store(Entry(value: value, date: Date()), for: key, persist: true)
    }

    /// Forgets pages that have changed (a playlist just edited), so they're fetched afresh.
    func remove(where changed: (String) -> Bool) {
        for key in order where changed(key) {
            entries[key] = nil
            if let url = diskURL(key) { try? FileManager.default.removeItem(at: url) }
        }
        order.removeAll(where: changed)
    }

    /// Like `load`, for when nobody is waiting: failures are dropped.
    func prefetch(_ key: String, _ fetch: @escaping @Sendable () async throws -> Value) {
        guard entries[key] == nil, inflight[key] == nil else { return }
        Task { _ = try? await load(key, fetch) }
    }

    private func store(_ entry: Entry, for key: String, persist: Bool) {
        entries[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit { entries[order.removeFirst()] = nil }
        guard persist, let url = diskURL(key) else { return }
        let value = entry.value
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func diskURL(_ key: String) -> URL? {
        guard let directory, persists(key) else { return nil }
        let name = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appending(path: name + ".json")
    }

    private func removeAll() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        entries = [:]
        order = []
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
    }
}
