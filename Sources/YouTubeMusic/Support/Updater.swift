import AppKit
import Foundation
import Observation

/// Keeps the installed beta up to date from the app's GitHub releases.
///
/// Why the app updates itself: releases are ad-hoc signed, not notarized, so a copy
/// downloaded in a browser is quarantined and Gatekeeper refuses to open it. A file the app
/// downloads with URLSession is not quarantined (the app doesn't opt in with
/// `LSFileQuarantineEnabled`), so once someone has the app, every later version installs
/// without Gatekeeper getting involved.
///
/// The dev build never updates — it is replaced by `./build.sh`, and must not be swapped
/// for a release while being worked on.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// The app's own (public) repository; each GitHub release carries the app as a zip.
    static let repo = "emonsaqibh/music-for-youtube"

    struct Release: Equatable {
        var version: String
        var notes: String
        var zip: URL
        var page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading
        case installing
        case failed(String)
    }

    private(set) var available: Release?
    private(set) var state: State = .idle
    /// The user dismissed the offer for this version; don't raise it again this launch.
    private(set) var dismissedVersion: String?

    var isEnabled: Bool { !BuildFlavor.isDev }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Shown in the sidebar while a newer version is waiting.
    var offersUpdate: Bool {
        guard let available else { return false }
        return available.version != dismissedVersion
    }

    private var timer: Task<Void, Never>?

    /// Checks shortly after launch, then once a day.
    func startBackgroundChecks() {
        guard isEnabled, timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func dismiss() { dismissedVersion = available?.version }

    // MARK: Checking

    /// Asks GitHub for the newest release. Returns true when one newer than this build
    /// exists.
    @discardableResult
    func check() async -> Bool {
        guard isEnabled, state != .downloading, state != .installing else { return false }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            if Version(release.version) > Version(currentVersion) {
                available = release
                state = .idle
                Log.write("update: \(release.version) available (running \(currentVersion))")
                return true
            }
            available = nil
            state = .upToDate
            return false
        } catch {
            state = .failed(error.localizedDescription)
            Log.write("update: check failed — \(error.localizedDescription)")
            return false
        }
    }

    /// The newest release by version. Betas are GitHub pre-releases, which the API's
    /// `releases/latest` skips, so this reads the list and picks the highest itself.
    private static func fetchLatest() async throws -> Release {
        guard let list = try await getJSON("https://api.github.com/repos/\(repo)/releases?per_page=30")
                as? [[String: Any]] else { throw UpdateError.noRelease }

        let published = list.filter { $0["draft"] as? Bool != true && $0["tag_name"] is String }
        guard let newest = published.max(by: {
                  Version($0["tag_name"] as! String) < Version($1["tag_name"] as! String) }),
              let tag = newest["tag_name"] as? String,
              let page = (newest["html_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.noRelease }

        // GitHub sometimes lags filling in a release's embedded asset list; its own assets
        // endpoint is up to date, so ask that when the list comes back without the zip.
        var assets = newest["assets"] as? [[String: Any]] ?? []
        if zipURL(in: assets) == nil, let id = newest["id"] as? Int {
            assets = try await getJSON("https://api.github.com/repos/\(repo)/releases/\(id)/assets")
                as? [[String: Any]] ?? []
        }
        guard let zip = zipURL(in: assets) else { throw UpdateError.noRelease }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: newest["body"] as? String ?? "", zip: zip, page: page)
    }

    private static func zipURL(in assets: [[String: Any]]) -> URL? {
        (assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String)
            .flatMap(URL.init(string:))
    }

    private static func getJSON(_ url: String) async throws -> Any {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noRelease }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Installing

    /// Downloads the new version, checks it is really this app, then hands over to a small
    /// script that swaps the bundle once we have quit and opens the new one.
    func install() async {
        guard isEnabled, let release = available else { return }
        do {
            state = .downloading
            let work = FileManager.default.temporaryDirectory
                .appending(path: "MusicForYouTube-update-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (download, _) = try await URLSession.shared.download(from: release.zip)
            let zip = work.appending(path: "update.zip")
            try FileManager.default.moveItem(at: download, to: zip)

            state = .installing
            let unzipped = work.appending(path: "unzipped", directoryHint: .isDirectory)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
            let bundleName = Bundle.main.bundleURL.lastPathComponent
            let candidates = (try? FileManager.default.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)) ?? []
            guard let newApp = candidates.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.badDownload("no app in the download")
            }
            try Self.verify(newApp, expecting: release.version)
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])

            let target = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateError.notWritable(target.deletingLastPathComponent().path)
            }
            Log.write("update: installing \(release.version) over \(target.path) (\(bundleName))")
            try Self.launchSwap(newApp: newApp, target: target, work: work)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
            Log.write("update: install failed — \(error.localizedDescription)")
        }
    }

    /// Same bundle identifier and the version the release claims — so a mislabelled or
    /// foreign zip is never installed over the app.
    private static func verify(_ app: URL, expecting version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.badDownload("the download isn't this app")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError.badDownload("the download isn't version \(version)")
        }
    }

    /// Waits for this process to exit, replaces the bundle (restoring the old one if the
    /// copy fails), and opens the result. Runs detached, so it outlives the app.
    private static func launchSwap(newApp: URL, target: URL, work: URL) throws {
        let backup = work.appending(path: "previous.app")
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if mv "\(target.path)" "\(backup.path)" && ditto "\(newApp.path)" "\(target.path)"; then
            xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
        else
            rm -rf "\(target.path)"; mv "\(backup.path)" "\(target.path)"
        fi
        open "\(target.path)"
        sleep 5; rm -rf "\(work.path)"
        """
        let scriptURL = work.appending(path: "swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { done.resume() }
                else { done.resume(throwing: UpdateError.badDownload("\((tool as NSString).lastPathComponent) failed")) }
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }

    enum UpdateError: LocalizedError {
        case noRelease
        case badDownload(String)
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .noRelease: "Couldn’t find a release to update to."
            case .badDownload(let why): "The update couldn’t be used: \(why)."
            case .notWritable(let folder): "Can’t replace the app in \(folder). Move it to Applications and try again."
            }
        }
    }
}

/// A release version like "0.2.0-beta.2": numbers compared numerically, a final release
/// newer than its betas, and beta identifiers compared piece by piece.
struct Version: Comparable {
    private let core: [Int]
    private let prerelease: [String]

    init(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        core = parts.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x < y }
        }
        // 1.0.0-beta < 1.0.0
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            if let m = Int(x), let n = Int(y) { return m < n }
            return x < y
        }
        return a.prerelease.count < b.prerelease.count
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
