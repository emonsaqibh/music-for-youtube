import AppKit
import Observation
import SwiftUI

/// Every "Sign In" in the app lands here. Signing in happens in a browser the user already
/// uses, where Google knows them; the app then picks the session up. In order:
///
/// 1. the default browser, if it's one we can read (Safari, Chromium browsers, Firefox);
/// 2. otherwise a choice of the supported browsers that are installed;
/// 3. only with none installed — or on request — the in-app sign-in window.
@MainActor
enum SignIn {
    static func start() {
        let installed = BrowserImport.installedBrowsers
        guard !installed.isEmpty else {
            AuthWindow.present()
            return
        }
        if let preferred = BrowserImport.defaultBrowser, installed.contains(preferred) {
            BrowserSignInWindow.present(browser: preferred)
        } else {
            BrowserSignInWindow.present(browser: nil)
        }
    }

    /// Straight to the browser list — for when the YouTube account lives in a browser other
    /// than the default one (the default route finishes on its own before there's a chance
    /// to switch).
    static func chooseBrowser() {
        guard !BrowserImport.installedBrowsers.isEmpty else { return AuthWindow.present() }
        BrowserSignInWindow.present(browser: nil)
    }
}

/// Drives the hand-over: let the user pick a browser if needed, get access to its sign-in
/// (Full Disk Access for Safari, a Keychain prompt for Chromium browsers), open Google's
/// sign-in there, and watch for the session to appear.
@MainActor
@Observable
final class BrowserSignInModel {
    enum Phase: Equatable {
        /// Choosing which browser to sign in with.
        case choosing
        case checking
        /// Chromium: the macOS Keychain prompt for the browser's cookie key is up.
        case unlocking
        /// Chromium: the user declined the Keychain prompt.
        case keychainDenied
        /// Safari: Full Disk Access hasn't been granted yet.
        case needsAccess
        /// The sign-in page is open in the browser; waiting for the session.
        case waiting
        case signingIn
        case done
    }

    private(set) var browser: BrowserImport.Browser?
    private(set) var phase: Phase = .choosing
    let installed = BrowserImport.installedBrowsers
    private var openedBrowser = false
    private var watcher: Task<Void, Never>?

    init(browser: BrowserImport.Browser?) {
        self.browser = browser
    }

    func start() {
        guard let browser else { phase = .choosing; return }
        use(browser)
    }

    /// Starts over with `browser`.
    func use(_ browser: BrowserImport.Browser) {
        stop()
        self.browser = browser
        openedBrowser = false
        watcher = Task { [weak self] in
            guard let self else { return }
            if browser.engine == .chromium, !(await self.unlock(browser)) { return }
            while !Task.isCancelled {
                if await self.check(browser) { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func chooseAnother() {
        stop()
        phase = .choosing
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    func reopenBrowser() {
        if let browser { BrowserImport.openSignInPage(in: browser) }
    }

    /// Asks the Keychain for a Chromium browser's cookie key — once; the macOS prompt is
    /// never raised again by the polling that follows.
    private func unlock(_ browser: BrowserImport.Browser) async -> Bool {
        if ChromiumCookies.isUnlocked(browser) { return true }
        phase = .unlocking
        let result = await Task.detached { () -> Bool in
            do { try ChromiumCookies.unlock(browser); return true } catch { return false }
        }.value
        if !result {
            Log.write("browser-signin: \(browser.displayName) keychain access declined or missing")
            phase = .keychainDenied
        }
        return result
    }

    /// One look at the browser. True once signed in (or given up).
    private func check(_ browser: BrowserImport.Browser) async -> Bool {
        let cookies: [HTTPCookie]?
        do {
            cookies = try BrowserImport.session(in: browser)
        } catch {
            if browser == .safari {
                // Keep watching: granting Full Disk Access takes effect without a relaunch.
                if phase != .needsAccess { Log.write("browser-signin: Safari not readable yet") }
                phase = .needsAccess
            } else {
                Log.write("browser-signin: \(browser.displayName) not readable — \(error.localizedDescription)")
                // Nothing on disk yet (a never-opened browser): open it and keep watching.
                if !openedBrowser {
                    openedBrowser = true
                    BrowserImport.openSignInPage(in: browser)
                }
                phase = .waiting
            }
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

    static func present(browser: BrowserImport.Browser?) {
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

    private init(browser: BrowserImport.Browser?) {
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
        let host = NSHostingView(rootView: BrowserSignInView(model: model))
        host.sizingOptions = [.preferredContentSize]
        window.contentView = host
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.shared = nil
    }
}

private struct BrowserSignInView: View {
    let model: BrowserSignInModel

    private var browserName: String { model.browser?.displayName ?? "your browser" }
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
            if let browser = model.browser, model.phase != .choosing {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                BrowserIcon(browser: browser, size: 56)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .choosing:
            text(title: "Sign in with your browser",
                 body: "Pick the browser you use YouTube in. You sign in there as usual, and "
                     + "\(appName) picks it up — no signing in inside the app.")
            VStack(spacing: 6) {
                ForEach(model.installed, id: \.self) { browser in
                    BrowserRow(browser: browser, isDefault: browser == BrowserImport.defaultBrowser) {
                        model.use(browser)
                    }
                }
            }
            fallback

        case .checking:
            status("Checking \(browserName)…")

        case .unlocking:
            text(title: "Allow access to \(browserName)’s sign-in",
                 body: "\(browserName) keeps its sign-in locked with a key in your Keychain. macOS "
                     + "is asking whether \(appName) may use it — choose **Always Allow**. Only your "
                     + "Google and YouTube sign-in is read.")
            status("Waiting for your answer…")
            otherBrowser

        case .keychainDenied:
            text(title: "\(browserName)’s sign-in stayed locked",
                 body: "Without that permission \(appName) can’t read \(browserName)’s sign-in. Try "
                     + "again and choose Always Allow, or pick another browser.")
            HStack {
                Button("Use Another Browser") { model.chooseAnother() }
                Spacer()
                Button("Try Again") { if let browser = model.browser { model.use(browser) } }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            fallback

        case .needsAccess:
            text(title: "Allow access to your Safari sign-in",
                 body: "You sign in to YouTube in Safari, and \(appName) picks it up — no "
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
            otherBrowser

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
            otherBrowser

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
            Text(.init(body))
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

    /// Switch browsers, when more than one is installed; the in-app window after that.
    @ViewBuilder
    private var otherBrowser: some View {
        if model.installed.count > 1 {
            Button("Use a different browser") { model.chooseAnother() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        } else {
            fallback
        }
    }

    /// The embedded window: the last resort, for when no browser route works.
    private var fallback: some View {
        Button("Sign in inside the app instead") {
            BrowserSignInWindow.close()
            AuthWindow.present()
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

/// One browser in the chooser: its icon, name, and a "Default" tag for the system default.
private struct BrowserRow: View {
    let browser: BrowserImport.Browser
    let isDefault: Bool
    let action: () -> Void

    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                BrowserIcon(browser: browser, size: 32)
                Text(browser.displayName)
                    .font(.system(size: 14, weight: .semibold))
                if isDefault {
                    Text("Default")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(shape.fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct BrowserIcon: View {
    let browser: BrowserImport.Browser
    let size: CGFloat

    var body: some View {
        if let app = BrowserImport.applicationURL(for: browser) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "globe").font(.system(size: size * 0.6))
        }
    }
}
