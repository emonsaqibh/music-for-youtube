import AppKit
import SwiftUI

@main
enum Launch {
    @MainActor static func main() {
        // Before SwiftUI builds the app: its property initializers already read settings.
        LegacyMigration.run()
        YouTubeMusicApp.main()
    }
}

struct YouTubeMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings = AppSettings.shared

    private var player: PlayerController { .shared }

    var body: some Scene {
        // A single main window: it hosts the audio engine, so there must never be two.
        Window("Music for YouTube", id: WindowID.main) {
            RootView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 810)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .commands { PlaybackCommands() }

        Window("Mini Player", id: WindowID.miniPlayer) {
            MiniPlayerView()
                .environment(player)
        }
        .windowStyle(.plain)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Engine Diagnostics", id: WindowID.diagnostics) {
            DiagnosticsView()
        }
        .defaultSize(width: 760, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(player)
        }

        MenuBarExtra(isInserted: $settings.showsMenuBarItem) {
            MenuBarPlayer()
                .environment(player)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item: the app icon's glyph, or — if chosen in Settings — the glyph (dimmed
/// while paused) and the song title.
private struct MenuBarLabel: View {
    private var player: PlayerController { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        if settings.menuBarShowsTitle, let track = player.current {
            let title = track.title.count > 28 ? String(track.title.prefix(27)) + "…" : track.title
            Image(nsImage: player.isPlaying ? Self.glyph : Self.pausedGlyph)
            Text(title)
        } else {
            Image(nsImage: Self.glyph)
        }
    }

    private static let glyph = menuBarGlyph(opacity: 1)
    private static let pausedGlyph = menuBarGlyph(opacity: 0.5)

    /// The ring and play symbol of Resources/AppIcon.icon/Assets without the background,
    /// cropped to the ring: a 16pt vector template, so the menu bar tints and highlights it.
    /// (The label ignores SwiftUI sizing, so the image carries its own size.)
    private static func menuBarGlyph(opacity: Double) -> NSImage {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="158 158 708 708">\
            <g opacity="\(opacity)">\
            <path fill-rule="evenodd" d="M 180.0 512.0 A 332.0 332.0 0 1 0 844.0 512.0 A 332.0 332.0 0 1 0 180.0 512.0 Z \
            M 250.0 512.0 A 262.0 262.0 0 1 0 774.0 512.0 A 262.0 262.0 0 1 0 250.0 512.0 Z"/>\
            <path d="M 433.33 424.77 A 38.0 38.0 0 0 1 489.87 391.59 L 645.97 478.83 A 38.0 38.0 0 0 1 645.97 545.17 \
            L 489.87 632.41 A 38.0 38.0 0 0 1 433.33 599.23 Z"/>\
            </g></svg>
            """
        let image = NSImage(data: Data(svg.utf8))!
        image.isTemplate = true
        return image
    }
}

enum WindowID {
    static let main = "main"
    static let miniPlayer = "mini-player"
    static let diagnostics = "diagnostics"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if WebEngine.tracesPerf {
            // Seconds since the process started, to put the other perf lines in context.
            Log.write("perf launch: didFinishLaunching at \(Int(ProcessInfo.processInfo.systemUptime * 1000 - Double(Self.processStartMillis)))ms")
        }
        NSApp.setActivationPolicy(.regular)
        AppSettings.shared.applyAppearance()
        if NavProbe.isRequested {
            Task { await NavProbe.run() }
            return
        }
        if PlaylistProbe.isRequested {
            Task { await PlaylistProbe.run() }
            return
        }
        if PlaybackProbe.isRequested {
            Task { await PlaybackProbe.run() }
            return
        }
        if SelfTest.isRequested {
            Task { await SelfTest.run() }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        PlayerController.shared.attach()
        if DemoMode.isRequested {
            Task { await DemoMode.start() }
            if Updater.isDemoing { Task { await Updater.shared.check() } }
        } else {
            Updater.shared.applyAutomaticChecks()
        }
    }

    /// When this process started, in systemUptime milliseconds.
    static let processStartMillis: Int = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        let startDate = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
        return Int((ProcessInfo.processInfo.systemUptime - Date().timeIntervalSince(startDate)) * 1000)
    }()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Menus

struct PlaybackCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private var player: PlayerController { .shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") {
                openWindow(id: WindowID.main)
                NSApp.activate()
                LibraryEditor.shared.startNewPlaylist()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!LibraryEditor.shared.canEdit)
        }

        CommandGroup(after: .textEditing) {
            Button("Search") {
                // The main window may be closed; open it, then focus its search field.
                openWindow(id: WindowID.main)
                NSApp.activate()
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateCommand.checkNow() }
        }

        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!player.hasTrack)

            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.canGoNext)

            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.hasTrack)

            Divider()

            Button("Shuffle") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Repeat") { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Volume Up") { player.volume = min(1, player.volume + 0.05) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { player.volume = max(0, player.volume - 0.05) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        CommandGroup(after: .windowArrangement) {
            Button("Mini Player") { openWindow(id: WindowID.miniPlayer) }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .help) {
            Button("Sign in to YouTube Music…") { SignIn.start() }
            Button("Sign In with Another Browser…") { SignIn.chooseBrowser() }
            Button(Session.shared.isGuest ? "Switch to Account" : "Switch to Guest Mode") {
                let session = Session.shared
                if session.isGuest && !session.hasAccount { SignIn.start() }
                else { PlayerController.shared.switchProfile(to: session.isGuest ? .account : .guest) }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Sign Out") { Task { await WebEngine.shared.signOut() } }
            Divider()
            Button("Engine Diagnostics…") { openWindow(id: WindowID.diagnostics) }
        }
    }
}
