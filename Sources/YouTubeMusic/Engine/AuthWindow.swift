import AppKit
import WebKit

/// A plain browser window for the Google sign-in flow.
///
/// It uses the account profile's `WKWebsiteDataStore` — the one the engine uses in account
/// mode — so the cookies it collects are immediately visible to the engine, and they
/// persist across launches, which is why signing in is a one-time step.
@MainActor
final class AuthWindow: NSObject {
    private static var shared: AuthWindow?

    private let window: NSWindow
    private let webView: WKWebView
    private var onFinish: (() -> Void)?

    static func present(onFinish: (() -> Void)? = nil) {
        if let existing = shared {
            existing.onFinish = onFinish
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = AuthWindow(onFinish: onFinish)
        shared = controller
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(onFinish: (() -> Void)?) {
        self.onFinish = onFinish

        let config = WKWebViewConfiguration()
        // Always the account store — signing in while browsing as a guest lands the
        // session in the account profile, then switches to it.
        config.websiteDataStore = Session.shared.dataStore(for: .account)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 720), configuration: config)
        webView.customUserAgent = WebEngine.userAgent

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Sign in to YouTube Music"
        window.titlebarAppearsTransparent = true
        window.contentView = webView
        window.isReleasedWhenClosed = false

        super.init()
        webView.navigationDelegate = self
        window.delegate = self

        let signIn = URL(string:
            "https://accounts.google.com/ServiceLogin?service=youtube"
            + "&continue=https%3A%2F%2Fmusic.youtube.com%2F")!
        webView.load(URLRequest(url: signIn))
    }

    private func finish() {
        onFinish?()
        onFinish = nil
        window.close()
    }
}

extension AuthWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Landing back on music.youtube.com means Google handed the session back.
        guard let host = webView.url?.host, host.hasSuffix("music.youtube.com") else { return }
        Task {
            // Give the page a beat to write its cookies before we tear the window down.
            try? await Task.sleep(for: .milliseconds(600))
            if Session.shared.profile == .account {
                WebEngine.shared.reload()
            } else {
                PlayerController.shared.switchProfile(to: .account)
            }
            finish()
        }
    }
}

extension AuthWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AuthWindow.shared = nil
    }
}
