import AppKit
import SwiftUI

@main
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

/// The menu bar item: a note, or — if chosen in Settings — the note and the song title.
private struct MenuBarLabel: View {
    private var player: PlayerController { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        if settings.menuBarShowsTitle, let track = player.current {
            let title = track.title.count > 28 ? String(track.title.prefix(27)) + "…" : track.title
            Image(systemName: player.isPlaying ? "music.note" : "pause.fill")
            Text(title)
        } else {
            Image(systemName: "music.note")
        }
    }
}

enum WindowID {
    static let main = "main"
    static let miniPlayer = "mini-player"
    static let diagnostics = "diagnostics"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppSettings.shared.applyAppearance()
        if NavProbe.isRequested {
            Task { await NavProbe.run() }
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
        if DemoMode.isRequested {
            Task { await DemoMode.start() }
            if Updater.isDemoing { Task { await Updater.shared.check() } }
        } else {
            Updater.shared.applyAutomaticChecks()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Menus

struct PlaybackCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private var player: PlayerController { .shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

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
