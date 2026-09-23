import AppKit
import Foundation
import WebKit

/// Signs the app in by reusing the YouTube session the user already has in their system
/// default browser, instead of making them log in again through an embedded web view.
///
/// Why this exists: Google's login risk engine distrusts embedded web views (WKWebView),
/// so the in-app sign-in flow gets hit with repeated CAPTCHAs and "this browser may not be
/// secure" blocks. Reusing an already-established, already-trusted browser session sidesteps
/// the login flow entirely — the cookies come from a session Google already trusts.
///
/// This reads only the Google/YouTube auth cookies, only from the browser the user picks
/// (their default one, unless they choose another), and only when the user explicitly asks. It never touches
/// other sites' cookies or other browsers. The user chose this over the in-app window
/// (2026-09-23) knowing it is the one place the app copies a session.
///
/// ## Distribution note
/// Reading another application's cookie store is, as a code pattern, the same thing
/// infostealer malware does — so a shipped build that does this can be flagged by Gatekeeper
/// notarization, third-party AV, and corporate EDR, and (for Chromium browsers) needs the
/// user to grant Full Disk Access. That is a property of the approach, not of this code.
@MainActor
enum BrowserImport {

    // MARK: Which browser is the system default

    /// The browsers we know how to read a session out of. `bundleID` is what
    /// `LSCopyDefaultHandlerForURLScheme` returns for the https scheme.
    enum Browser: String, CaseIterable {
        case safari  = "com.apple.Safari"
        case chrome  = "com.google.Chrome"
        case brave   = "com.brave.Browser"
        case edge    = "com.microsoft.edgemac"
        case arc     = "company.thebrowser.Browser"
        case vivaldi = "com.vivaldi.Vivaldi"
        case opera   = "com.operasoftware.Opera"
        case firefox = "org.mozilla.firefox"

        var displayName: String {
            switch self {
            case .safari:  "Safari"
            case .chrome:  "Chrome"
            case .brave:   "Brave"
            case .edge:    "Edge"
            case .arc:     "Arc"
            case .vivaldi: "Vivaldi"
            case .opera:   "Opera"
            case .firefox: "Firefox"
            }
        }

        /// Safari keeps a documented binary cookie file (behind Full Disk Access); Chromium
        /// browsers an SQLite store encrypted with a Keychain key; Firefox a plain SQLite store.
        var engine: Engine {
            switch self {
            case .safari: .safari
            case .firefox: .firefox
            default: .chromium
            }
        }
        enum Engine { case safari, chromium, firefox }
    }

    /// The user's system default browser, if it's one we can read.
    static var defaultBrowser: Browser? {
        guard let handler = LSCopyDefaultHandlerForURLScheme("https" as CFString)?
            .takeRetainedValue() as String? else { return nil }
        return Browser(rawValue: handler)
    }

    enum ImportError: LocalizedError {
        case notReadable(Browser)
        case keychainDenied(Browser)
        case notImplemented(Browser)

        var errorDescription: String? {
            switch self {
            case .notReadable(let b) where b == .safari:
                "Couldn’t read Safari’s sign-in. Allow Music for YouTube under "
                    + "System Settings › Privacy & Security › Full Disk Access."
            case .notReadable(let b):
                "Couldn’t find \(b.displayName)’s saved sign-in. Open \(b.displayName) once, then try again."
            case .keychainDenied(let b):
                "macOS didn’t allow access to \(b.displayName)’s sign-in key."
            case .notImplemented(let b):
                "Picking up a sign-in from \(b.displayName) isn’t supported yet."
            }
        }
    }

    /// Chromium browsers are hidden for now: in an ad-hoc signed app opened normally (not
    /// from a terminal), macOS refuses the "<Browser> Safe Storage" Keychain read at once
    /// (-25293) without prompting. See HANDOFF.md, "Known issue".
    static func isSupported(_ browser: Browser) -> Bool { browser.engine != .chromium }

    /// Every supported browser installed on this Mac, the default one first.
    static var installedBrowsers: [Browser] {
        let installed = Browser.allCases.filter { isSupported($0) && applicationURL(for: $0) != nil }
        guard let preferred = defaultBrowser, installed.contains(preferred) else { return installed }
        return [preferred] + installed.filter { $0 != preferred }
    }

    /// Where the default browser app lives, to open the sign-in page in it.
    static func applicationURL(for browser: Browser) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.rawValue)
    }

    // MARK: Signing in

    /// Google's sign-in, returning to YouTube Music — the same page the in-app window
    /// loads, opened in the user's own browser instead.
    static let signInURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube"
        + "&continue=https%3A%2F%2Fmusic.youtube.com%2F")!

    static func openSignInPage(in browser: Browser) {
        guard let app = applicationURL(for: browser) else {
            NSWorkspace.shared.open(signInURL)
            return
        }
        NSWorkspace.shared.open([signInURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The browser's Google/YouTube session cookies, or nil when it isn't signed in.
    /// Throws when the store can't be read at all (no Full Disk Access yet).
    static func session(in browser: Browser) throws -> [HTTPCookie]? {
        let cookies = try readYouTubeCookies(from: browser)
        let signedIn = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
        return signedIn ? cookies : nil
    }

    // MARK: Reading (per-browser adapters)

    /// Domains whose cookies carry the YouTube/Google session. We copy only these.
    static let wantedDomains = [".youtube.com", ".google.com", "youtube.com", "accounts.google.com"]

    private static func readYouTubeCookies(from browser: Browser) throws -> [HTTPCookie] {
        switch browser.engine {
        case .safari:   try SafariCookies.read(domains: wantedDomains)
        case .chromium: try ChromiumCookies.read(browser: browser, domains: wantedDomains)
        case .firefox:  try FirefoxCookies.read(domains: wantedDomains)
        }
    }

    // MARK: Installing into the engine

    /// Replaces the account profile's Google/YouTube cookies with the browser's, then brings
    /// the engine up on the account profile. Only our own web view's store is written; the
    /// browser is never modified, and signing out of the app later leaves it signed in.
    static func install(_ cookies: [HTTPCookie], from browser: Browser) async {
        let store = Session.shared.dataStore(for: .account).httpCookieStore
        // Drop whatever an earlier sign-in left, so two accounts' cookies never mix.
        for old in await store.allCookies() where isGoogleDomain(old.domain) {
            await store.deleteCookie(old)
        }
        for cookie in cookies {
            await store.setCookie(cookie)
        }
        Log.write("browser-import: installed \(cookies.count) cookies from \(browser.displayName)")
        if Session.shared.profile == .account {
            WebEngine.shared.reload()
        } else {
            PlayerController.shared.switchProfile(to: .account)
        }
    }

    private static func isGoogleDomain(_ domain: String) -> Bool {
        wantedDomains.contains { domain.hasSuffix($0) }
    }
}
