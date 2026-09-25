import AppKit
import SwiftUI
import Foundation
import WebKit

// MARK: - Bridge value types

/// One poll of the YouTube player's state.
struct PlayerSnapshot: Sendable, Equatable {
    var ok = false
    var videoId = ""
    var title = ""
    var author = ""
    /// YouTube player state: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
    var state = -1
    var time: Double = 0
    var duration: Double = 0
    var loaded: Double = 0
    var volume: Double = 100
    var muted = false
    var ad = false

    init() {}

    init(_ d: [String: Any]) {
        ok = d["ok"] as? Bool ?? false
        videoId = d["videoId"] as? String ?? ""
        title = d["title"] as? String ?? ""
        author = d["author"] as? String ?? ""
        state = (d["state"] as? NSNumber)?.intValue ?? -1
        time = (d["time"] as? NSNumber)?.doubleValue ?? 0
        duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
        loaded = (d["loaded"] as? NSNumber)?.doubleValue ?? 0
        volume = (d["volume"] as? NSNumber)?.doubleValue ?? 100
        muted = d["muted"] as? Bool ?? false
        ad = d["ad"] as? Bool ?? false
    }

    var isPlaying: Bool { state == 1 }
    var isBuffering: Bool { state == 3 }
    var hasEnded: Bool { state == 0 }
    var isUnstarted: Bool { state == -1 }
}

enum BridgeEvent: Sendable {
    /// The script was injected into a new document.
    case injected(url: String, signedIn: Bool)
    /// The `#movie_player` object became available and we bound to it.
    case ready(signedIn: Bool, snapshot: PlayerSnapshot)
    /// Player state changed, or a routine progress tick.
    case snapshot(PlayerSnapshot)
    /// A hardware media key / Control Center action arrived via the page.
    case remote(action: String, time: Double?)
    case playerError(code: Int)
    case log(String)
}

enum EngineError: LocalizedError {
    case notReady
    case badResponse
    case javaScript(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "The YouTube Music player is not ready yet."
        case .badResponse: "YouTube returned an unreadable response."
        case .javaScript(let m): m
        }
    }
}

enum InnerTubeClient {
    /// YouTube Music's Android app. Timed lyrics are only served to this client.
    static let androidMusic: [String: Any] = [
        "clientName": "ANDROID_MUSIC", "clientVersion": "7.21.50", "androidSdkVersion": 34,
    ]
}

// MARK: - Engine

/// Owns the offscreen `WKWebView` that plays audio and proxies YouTube's private API.
///
/// Nothing from this view is ever shown; the app's entire UI is native SwiftUI. The
/// web view exists because it is the only way to play a YouTube Music stream with the
/// account's real session — ads, Premium entitlement, listening history and radio all
/// keep working, and there is no stream-URL extraction to break.
@MainActor
final class WebEngine: NSObject {
    static let shared = WebEngine()

    /// Replaced when the profile switches — a web view's cookie store is fixed at creation.
    private(set) var webView: WKWebView
    /// The player's handler — the one consumer that drives playback state.
    var onEvent: ((BridgeEvent) -> Void)?
    /// An extra listener (Engine Diagnostics) that sees every event after the player. It
    /// must never take `onEvent`: that silently freezes the player's time, seek bar and
    /// play/pause icon while the music keeps going.
    var eventTap: ((BridgeEvent) -> Void)?

    private func emit(_ event: BridgeEvent) {
        onEvent?(event)
        eventTap?(event)
    }

    private(set) var isBound = false
    private(set) var currentURL: URL?

    /// Kept for existing callers; the observable source of truth is `Session`.
    var isSignedIn: Bool { Session.shared.isSignedIn }

    /// Where the web view lives in the window hierarchy. The engine owns it (rather than
    /// the SwiftUI view that places it) so it can swap the web view inside without the UI
    /// having to know.
    let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))

    /// A `WKWebView` outside any window is throttled by WebKit until playback stalls, so
    /// the engine keeps its own window: 2×2 points, transparent, click-through, on every
    /// Space, absent from the Window menu and ⌘`. It is what lets music keep playing with
    /// the main window closed — and what the self-test relies on when no UI is up.
    private lazy var hostWindow: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = hostView
        return panel
    }()

    /// A genuine Safari UA — Google rejects sign-in from anything it detects as an
    /// embedded web view. The `Version/` token is read from the copy of Safari actually
    /// installed on this machine so it never drifts out of date: a stale Safari version
    /// is exactly the kind of mismatch Google's login checks flag. Falls back to a recent
    /// version if Safari can't be read. (Safari freezes the "Intel Mac OS X 10_15_7"
    /// platform token even on Apple Silicon, so that part is intentionally left as-is.)
    static let userAgent: String = {
        let version = installedSafariVersion() ?? "18.6"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    private static func installedSafariVersion() -> String? {
        guard let dict = NSDictionary(contentsOf: URL(
                fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")),
              let version = dict["CFBundleShortVersionString"] as? String,
              !version.isEmpty else { return nil }
        return version
    }

    static let home = URL(string: "https://music.youtube.com/")!

    /// Posted after sign-in, sign-out or a profile switch, so navigation and library can be
    /// re-fetched.
    static let sessionDidChange = Notification.Name("WebEngine.sessionDidChange")

    private override init() {
        webView = WKWebView()
        super.init()
        webView = makeWebView(for: Session.shared.profile)
        host(webView)
    }

    /// Diagnostic launch modes that play music on a loop get a throwaway, always-signed-out
    /// cookie store, so running them repeatedly never touches the real account's session or
    /// pads its listening history — automated playback on the real account is what most
    /// looks like bot activity. `--probe-nav` is deliberately excluded: it exists to inspect
    /// the *signed-in* account, so it stays on the real store.
    static var usesEphemeralSession: Bool {
        (SelfTest.isRequested || PlaybackProbe.isRequested || DemoMode.isRequested)
            // `YTM_SIGNED_IN=1` runs these with the real account — signed-in accounts can get
            // a different web-player build, which the signed-out runs never see.
            && ProcessInfo.processInfo.environment["YTM_SIGNED_IN"] != "1"
    }

    private func makeWebView(for profile: Session.Profile) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.usesEphemeralSession
            ? .nonPersistent()
            : Session.shared.dataStore(for: profile)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = true
        // Audio keeps playing with the main window closed; don't let WebKit park the page.
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController = WKUserContentController()
        config.userContentController.addUserScript(
            WKUserScript(source: BridgeScript.source,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
        config.userContentController.add(self, name: BridgeScript.handlerName)

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), configuration: config)
        web.customUserAgent = Self.userAgent
        web.navigationDelegate = self
        return web
    }

    private func host(_ web: WKWebView) {
        web.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            web.topAnchor.constraint(equalTo: hostView.topAnchor),
            web.widthAnchor.constraint(equalToConstant: 480),
            web.heightAnchor.constraint(equalToConstant: 360),
        ])
    }

    // MARK: Lifecycle

    func start() {
        if !hostWindow.isVisible {
            if let screen = NSScreen.main {
                hostWindow.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
            }
            hostWindow.orderFrontRegardless()
        }
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: Self.home))
    }

    func reload() {
        isBound = false
        webView.load(URLRequest(url: Self.home))
        NotificationCenter.default.post(name: Self.sessionDidChange, object: nil)
    }

    /// Moves the engine to the other cookie store. The old web view (and its audio) is torn
    /// down; the player picks the current track back up once the new page binds.
    func switchProfile(to profile: Session.Profile) {
        guard profile != Session.shared.profile else { return reload() }
        Log.write("session: switching to \(profile.rawValue)")

        let old = webView
        old.pauseAllMediaPlayback {}
        old.stopLoading()
        old.configuration.userContentController.removeScriptMessageHandler(forName: BridgeScript.handlerName)
        old.navigationDelegate = nil
        old.removeFromSuperview()

        isBound = false
        currentURL = nil
        Session.shared.setProfile(profile)

        webView = makeWebView(for: profile)
        host(webView)
        webView.load(URLRequest(url: Self.home))
        NotificationCenter.default.post(name: Self.sessionDidChange, object: nil)
    }

    // MARK: Calling into the page

    @discardableResult
    func call(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: args, contentWorld: .page)
        } catch {
            // WebKit hides the actual thrown message in userInfo; without it every
            // failure reads as the useless "A JavaScript exception occurred".
            let info = (error as NSError).userInfo
            let detail = info["WKJavaScriptExceptionMessage"] as? String
                ?? info[NSLocalizedDescriptionKey] as? String
                ?? error.localizedDescription
            throw EngineError.javaScript(detail)
        }
    }

    /// Waits for the bridge to bind the page's player. The first request after launch
    /// races the web view's initial load, so callers wait rather than fail.
    @discardableResult
    func waitUntilReady(timeout: Duration = .seconds(30)) async -> Bool {
        if isBound { return true }
        start()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isBound, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
        return isBound
    }

    /// Calls a YouTube InnerTube endpoint (`browse`, `search`, `next`, `player`, …)
    /// from inside the authenticated page.
    ///
    /// `client` presents the request as a different InnerTube client — e.g.
    /// `InnerTubeClient.androidMusic`, the only client YouTube serves timed lyrics to.
    ///
    /// `changesAccount` marks a request that edits the library. Those are only retried when
    /// the bridge was missing and the request never left: a "Load failed" can mean YouTube
    /// got it and the answer was lost, and sending it again would add a song twice.
    func innertube(_ endpoint: String, _ body: [String: Any],
                   client: [String: Any]? = nil, changesAccount: Bool = false) async throws -> JSON {
        guard await waitUntilReady() else { throw EngineError.notReady }

        // A request issued while the page is starting a media load can come back as a
        // bare "TypeError: Load failed", and one issued while the page is swapping its
        // document finds no bridge at all. Both are transient, so retry before giving up.
        var lastError: (any Error)?
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(900))
                guard await waitUntilReady() else { throw EngineError.notReady }
            }
            do {
                let started = ContinuousClock.now
                let raw = try await call(
                    "return await window.__ytm.innertube(endpoint, body, client);",
                    ["endpoint": endpoint, "body": body, "client": client ?? NSNull()])
                guard let text = raw as? String else { throw EngineError.badResponse }
                let received = ContinuousClock.now
                // Responses run to megabytes; parsing on the main thread stalls the UI.
                let json = try await Task.detached(priority: .userInitiated) { try JSON(parsing: text) }.value
                if Self.tracesPerf {
                    Log.write("perf swift \(endpoint) total=\(Self.ms(received - started)) "
                              + "parse=\(Self.ms(ContinuousClock.now - received)) \(text.utf8.count)B")
                }
                return json
            } catch {
                lastError = error
                let message = (error as? EngineError)?.errorDescription ?? ""
                let unsent = message.contains("__ytm")
                let transient = unsent
                    || (!changesAccount && (message.contains("Load failed") || message.contains("network")))
                guard transient else { throw error }
            }
        }
        throw lastError ?? EngineError.badResponse
    }

    @discardableResult
    func command(_ name: String, _ arg: Any = NSNull()) async -> Bool {
        let result = try? await call(
            "return window.__ytm ? window.__ytm.command(name, arg) : false;",
            ["name": name, "arg": arg])
        return (result as? Bool) ?? false
    }

    func snapshot() async -> PlayerSnapshot {
        let result = try? await call("return window.__ytm ? window.__ytm.snapshot() : null;")
        guard let d = result as? [String: Any] else { return PlayerSnapshot() }
        return PlayerSnapshot(d)
    }

    /// Whether a scrubber is on screen. Without one nobody is watching the position move,
    /// so the page reports it every 5s instead of twice a second. Changes of state, track
    /// or volume, and jumps, still arrive within half a second.
    private(set) var positionWatched = false

    func setPositionWatched(_ watched: Bool) {
        guard watched != positionWatched else { return }
        positionWatched = watched
        webView.evaluateJavaScript("window.__ytm && window.__ytm.setWatched(\(watched))")
    }

    func setPageMetadata(title: String, artist: String, album: String, artwork: String?) async {
        _ = try? await call(
            "return window.__ytm ? window.__ytm.setMetadata(meta) : false;",
            ["meta": ["title": title, "artist": artist, "album": album,
                      "artwork": artwork ?? ""] as [String: Any]])
    }

    func playability() async -> [String: Any] {
        let result = try? await call("return window.__ytm ? window.__ytm.playability() : null;")
        return (result as? [String: Any]) ?? [:]
    }

    func diagnostics() async -> [String: Any] {
        let result = try? await call("return window.__ytm ? window.__ytm.diagnostics() : null;")
        return (result as? [String: Any]) ?? [:]
    }

    /// Full-page fallback used when `loadVideoById` cannot start a track — navigating
    /// to the watch URL always works, it is just slower.
    func navigateToWatch(videoId: String, playlistId: String? = nil) {
        var s = "https://music.youtube.com/watch?v=\(videoId)"
        if let playlistId { s += "&list=\(playlistId)" }
        guard let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: Session

    /// Signs the account out: clears the account store only. The guest store is untouched.
    func signOut() async {
        let store = Session.shared.dataStore(for: .account)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        Session.shared.forgetAccount()
        Session.shared.pageReported(signedIn: false)
        if Session.shared.profile == .account { reload() }
    }

    /// Wipes the guest profile's cookies and history — a fresh anonymous listener.
    func clearGuestData() async {
        let store = Session.shared.dataStore(for: .guest)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        if Session.shared.profile == .guest { reload() }
    }
}

// MARK: - Messages from the page

extension WebEngine: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        // WebKit always delivers script messages on the main thread.
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            let payload = body["payload"] as? [String: Any] ?? [:]
            handle(type: type, payload: payload)
        }
    }

    /// `YTM_TRACE_TICKS=1` logs every snapshot the page sends — for diagnosing a player
    /// display that stops following playback.
    private static let tracesTicks = ProcessInfo.processInfo.environment["YTM_TRACE_TICKS"] == "1"
    /// `YTM_TRACE_PERF=1` times every InnerTube request: network inside the page, the
    /// total seen from here (the difference is the bridge), and parsing.
    static let tracesPerf = ProcessInfo.processInfo.environment["YTM_TRACE_PERF"] == "1"

    static func ms(_ d: Duration) -> String {
        "\(Int((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000))ms"
    }

    private func handle(type: String, payload: [String: Any]) {
        switch type {
        case "injected":
            if let signedIn = payload["signedIn"] as? Bool { Session.shared.pageReported(signedIn: signedIn) }
            emit(.injected(url: payload["href"] as? String ?? "", signedIn: isSignedIn))

        case "ready":
            isBound = true
            if Self.tracesPerf { webView.evaluateJavaScript("window.__ytmTracePerf = true") }
            // A new page starts out watched.
            if !positionWatched { webView.evaluateJavaScript("window.__ytm.setWatched(false)") }
            if let signedIn = payload["signedIn"] as? Bool { Session.shared.pageReported(signedIn: signedIn) }
            let snap = PlayerSnapshot(payload["snapshot"] as? [String: Any] ?? [:])
            emit(.ready(signedIn: isSignedIn, snapshot: snap))

        case "state", "tick":
            if Self.tracesTicks {
                Log.write("trace \(type): ok=\(payload["ok"] ?? "-") state=\(payload["state"] ?? "-") "
                          + "time=\(payload["time"] ?? "-") id=\(payload["videoId"] ?? "-")")
            }
            emit(.snapshot(PlayerSnapshot(payload)))

        case "remote":
            emit(.remote(action: payload["action"] as? String ?? "",
                             time: (payload["time"] as? NSNumber)?.doubleValue))

        case "error":
            emit(.playerError(code: (payload["code"] as? NSNumber)?.intValue ?? 0))

        case "log":
            emit(.log(payload["text"] as? String ?? ""))

        default:
            break
        }
    }
}

// MARK: - Navigation

extension WebEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A new document is on its way and the bridge goes with the old one; callers
        // should wait for it to bind again rather than call into a page without it.
        isBound = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        emit(.log("navigation failed: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        emit(.log("navigation failed: \(error.localizedDescription)"))
    }
}
