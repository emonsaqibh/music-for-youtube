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
/// This reads only the Google/YouTube auth cookies, only from the one browser the user has
/// set as their system default, and only when the user explicitly asks. It never touches
/// other sites' cookies or other browsers.
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

        var displayName: String {
            switch self {
            case .safari:  "Safari"
            case .chrome:  "Chrome"
            case .brave:   "Brave"
            case .edge:    "Edge"
            case .arc:     "Arc"
            case .vivaldi: "Vivaldi"
            case .opera:   "Opera"
            }
        }

        /// Safari keeps a documented binary cookie file; the rest are Chromium and keep an
        /// SQLite store whose values are encrypted with a per-app Keychain key.
        var engine: Engine { self == .safari ? .safari : .chromium }
        enum Engine { case safari, chromium }
    }

    /// The user's system default browser, if it's one we can read.
    static var defaultBrowser: Browser? {
        guard let handler = LSCopyDefaultHandlerForURLScheme("https" as CFString)?
            .takeRetainedValue() as String? else { return nil }
        return Browser(rawValue: handler)
    }

    enum ImportError: LocalizedError {
        case noSupportedDefaultBrowser(String?)
        case notReadable(Browser)
        case noSession(Browser)
        case notImplemented(Browser)

        var errorDescription: String? {
            switch self {
            case .noSupportedDefaultBrowser(let id):
                "Your default browser\(id.map { " (\($0))" } ?? "") isn't one this app can "
                    + "import a session from. Supported: "
                    + Browser.allCases.map(\.displayName).joined(separator: ", ") + "."
            case .notReadable(let b):
                "Couldn't read \(b.displayName)'s cookies. If you haven't, grant this app "
                    + "Full Disk Access in System Settings › Privacy & Security."
            case .noSession(let b):
                "You don't appear to be signed in to YouTube in \(b.displayName). "
                    + "Sign in there first, then try again."
            case .notImplemented(let b):
                "Importing from \(b.displayName) isn't wired up yet."
            }
        }
    }

    // MARK: The one public entry point

    /// Reads the YouTube session out of the default browser and installs it into the engine's
    /// account store, then reloads so the app comes up signed in. Returns the browser it used.
    @discardableResult
    static func signInUsingDefaultBrowser() async throws -> Browser {
        guard let browser = defaultBrowser else {
            let id = LSCopyDefaultHandlerForURLScheme("https" as CFString)?
                .takeRetainedValue() as String?
            throw ImportError.noSupportedDefaultBrowser(id)
        }
        let cookies = try readYouTubeCookies(from: browser)
        guard cookies.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" })
        else { throw ImportError.noSession(browser) }

        try await install(cookies)
        Log.write("browser-import: installed \(cookies.count) cookies from \(browser.displayName)")
        return browser
    }

    // MARK: Reading (per-browser adapters)

    /// Domains whose cookies carry the YouTube/Google session. We copy only these.
    static let wantedDomains = [".youtube.com", ".google.com", "youtube.com", "accounts.google.com"]

    private static func readYouTubeCookies(from browser: Browser) throws -> [HTTPCookie] {
        switch browser.engine {
        case .safari:   try SafariCookies.read(domains: wantedDomains)
        case .chromium: try ChromiumCookies.read(browser: browser, domains: wantedDomains)
        }
    }

    // MARK: Installing into the engine

    /// Writes the imported cookies into the account profile's WKWebView cookie store. This is
    /// just our own web view's store — the ordinary, non-sensitive side of the operation.
    private static func install(_ cookies: [HTTPCookie]) async throws {
        let store = Session.shared.dataStore(for: .account).httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
        WebEngine.shared.reload()
    }
}
