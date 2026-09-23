import AppKit
import Observation
import SwiftUI

/// Every "Sign In" in the app lands here. Signing in happens in the user's own default
/// browser, where Google already knows them; the app then picks the session up. Only a
/// browser we can't read from falls back to the in-app window.
@MainActor
enum SignIn {
    static func start() {
        guard let browser = BrowserImport.defaultBrowser, BrowserImport.isSupported(browser) else {
            AuthWindow.present()
            return
        }
        BrowserSignInWindow.present(browser: browser)
    }
}

/// Drives the hand-over: get read access to the browser if needed, open Google's sign-in
/// there, and watch for the session to appear.
@MainActor
@Observable
final class BrowserSignInModel {
    enum Phase: Equatable {
        case checking
        /// macOS hasn't granted access to the browser's cookie store yet.
        case needsAccess
        /// The sign-in page is open in the browser; waiting for the session.
        case waiting
        case signingIn
        case done
    }

    let browser: BrowserImport.Browser
    private(set) var phase: Phase = .checking
    private var openedBrowser = false
    private var watcher: Task<Void, Never>?

    init(browser: BrowserImport.Browser) {
        self.browser = browser
    }

    func start() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.check() { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func reopenBrowser() {
        BrowserImport.openSignInPage(in: browser)
    }

    /// One look at the browser. True once signed in (or given up).
    private func check() async -> Bool {
        let cookies: [HTTPCookie]?
        do {
            cookies = try BrowserImport.session(in: browser)
        } catch {
            // Keep watching: granting Full Disk Access takes effect without a relaunch.
            if phase != .needsAccess { Log.write("browser-signin: \(browser.displayName) not readable yet") }
            phase = .needsAccess
            return false
        }

        guard let cookies else {
            // Readable but signed out there: send the user to Google's sign-in, once.
            if !openedBrowser {
                openedBrowser = true
                BrowserImport.openSignInPage(in: browser)
                Log.write("browser-signin: opened sign-in in \(browser.displayName)")
            }
            phase = .waiting
            return false
        }

        phase = .signingIn
        await BrowserImport.install(cookies, from: browser)
        phase = .done
        try? await Task.sleep(for: .milliseconds(900))
        BrowserSignInWindow.close()
        return true
    }
}

/// A small window that explains what's happening while the user signs in in their browser.
@MainActor
final class BrowserSignInWindow: NSObject, NSWindowDelegate {
    private static var shared: BrowserSignInWindow?

    private let window: NSWindow
    private let model: BrowserSignInModel

    static func present(browser: BrowserImport.Browser) {
        if let existing = shared {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = BrowserSignInWindow(browser: browser)
        shared = controller
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.model.start()
    }

    static func close() { shared?.window.close() }

    private init(browser: BrowserImport.Browser) {
        model = BrowserSignInModel(browser: browser)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init()
        window.contentView = NSHostingView(rootView: BrowserSignInView(model: model))
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.shared = nil
    }
}

private struct BrowserSignInView: View {
    let model: BrowserSignInModel

    private var browserName: String { model.browser.displayName }
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Music for YouTube"
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            content
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
            if let app = BrowserImport.applicationURL(for: model.browser) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 56, height: 56)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            status("Checking \(browserName)…")

        case .needsAccess:
            text(title: "Allow access to your \(browserName) sign-in",
                 body: "You sign in to YouTube in \(browserName), and \(appName) picks it up — no "
                     + "signing in inside the app. macOS asks you to allow this under Full Disk "
                     + "Access. Only your Google and YouTube sign-in is read.")
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Open Privacy Settings below.")
                step(2, "Turn on \(appName). If it isn’t listed, click +, or drag it in from Finder.")
                step(3, "Come back here — it carries on by itself.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Show App in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Spacer()
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
            fallback

        case .waiting:
            text(title: "Sign in with \(browserName)",
                 body: "Google’s sign-in is open in \(browserName). Sign in there as you "
                     + "normally would, and \(appName) will pick it up automatically.")
            status("Waiting for you to sign in…")
            HStack {
                Button("Cancel") { BrowserSignInWindow.close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open \(browserName) Again") { model.reopenBrowser() }
            }
            fallback

        case .signingIn:
            status("Signing you in…")

        case .done:
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.vertical, 8)
        }
    }

    private func text(title: String, body: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .multilineTextAlignment(.center)
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func step(_ number: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent))
            Text(label)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The embedded window stays available for when the browser route can't be used.
    private var fallback: some View {
        Button("Sign in inside the app instead") {
            BrowserSignInWindow.close()
            AuthWindow.present()
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}
