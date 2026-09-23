import AppKit
import Foundation
import Observation

/// Tells the user when a newer release is out, and how to install it.
///
/// Installing is always the README's one-line script, run in Terminal: the app only checks
/// and hands over the command. (The script downloads with curl, so the new copy isn't
/// quarantined and opens without Gatekeeper's "could not verify" block.)
///
/// Checks happen shortly after launch, then every six hours while the app runs, and when
/// the app comes back to the front after six hours or more — the time of the last check is
/// kept, so relaunching doesn't ask again. Off in the dev build, which `./build.sh` replaces.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// The app's own (public) repository; each GitHub release carries the app as a zip.
    static let repo = "emonsaqibh/music-for-youtube"

    /// The README's one-line installer. Run in Terminal, it quits the app, installs the
    /// newest release and reopens it; sign-in and settings are kept.
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | bash"

    static let checkInterval: TimeInterval = 6 * 60 * 60

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case failed(String)
    }

    private(set) var available: Release?
    private(set) var state: State = .idle
    private(set) var lastChecked: Date? {
        didSet { UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey) }
    }
    /// The user closed the sidebar card for this version; don't raise it again this launch.
    private(set) var dismissedVersion: String?

    private static let lastCheckedKey = "updates.lastChecked"

    /// Off in the dev build — except under `--demo-update`, which shows the update card in a
    /// demo run (ephemeral session) to check how it looks.
    var isEnabled: Bool { !BuildFlavor.isDev || Self.isDemoing }
    static let isDemoing = CommandLine.arguments.contains("--demo-update")

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Shown in the sidebar while a newer version is waiting.
    var offersUpdate: Bool {
        guard let available else { return false }
        return available.version != dismissedVersion
    }

    private init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    func dismiss() { dismissedVersion = available?.version }

    // MARK: Automatic checks

    private var timer: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    /// Starts (or stops, when the setting is off) the automatic checks.
    func applyAutomaticChecks() {
        timer?.cancel()
        timer = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        guard isEnabled, AppSettings.shared.checksForUpdates else { return }

        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval,
           available == nil { return }
        await check()
    }

    // MARK: Checking

    /// Asks GitHub for the newest release. Returns true when one newer than this build
    /// exists.
    @discardableResult
    func check() async -> Bool {
        guard isEnabled, state != .checking else { return available != nil }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastChecked = Date()
            if Version(release.version) > Version(currentVersion) {
                if available != release { Log.write("update: \(release.version) available (running \(currentVersion))") }
                available = release
                state = .idle
                return true
            }
            available = nil
            state = .upToDate
            return false
        } catch {
            state = .failed("Couldn’t reach GitHub. Check your connection and try again.")
            Log.write("update: check failed — \(error.localizedDescription)")
            return false
        }
    }

    /// The newest release by version that has the app attached (so the install command
    /// will work). Betas are GitHub pre-releases, which `releases/latest` skips, so this
    /// reads the list and picks the highest itself.
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
        if !hasZip(assets), let id = newest["id"] as? Int {
            assets = try await getJSON("https://api.github.com/repos/\(repo)/releases/\(id)/assets")
                as? [[String: Any]] ?? []
        }
        guard hasZip(assets) else { throw UpdateError.noRelease }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: newest["body"] as? String ?? "", page: page)
    }

    private static func hasZip(_ assets: [[String: Any]]) -> Bool {
        assets.contains { ($0["name"] as? String)?.hasSuffix(".zip") == true }
    }

    private static func getJSON(_ url: String) async throws -> Any {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.noRelease }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Installing (in Terminal)

    static func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    static func openTerminal() {
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    enum UpdateError: Error { case noRelease }
}

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
