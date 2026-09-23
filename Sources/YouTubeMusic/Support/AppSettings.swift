import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// User preferences. Each one persists to UserDefaults the moment it changes and takes
/// effect immediately — nothing needs a relaunch.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // MARK: Appearance

    enum ColorSchemeChoice: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum AccentChoice: String, CaseIterable, Identifiable {
        case red, pink, orange, yellow, green, teal, blue, purple, graphite
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        var color: Color {
            switch self {
            case .red: Color(red: 0.98, green: 0.16, blue: 0.26)     // Music.app's
            case .pink: Color(red: 1.0, green: 0.22, blue: 0.52)
            case .orange: Color(red: 1.0, green: 0.46, blue: 0.12)
            case .yellow: Color(red: 0.96, green: 0.7, blue: 0.0)
            case .green: Color(red: 0.2, green: 0.74, blue: 0.36)
            case .teal: Color(red: 0.0, green: 0.68, blue: 0.74)
            case .blue: Color(red: 0.12, green: 0.5, blue: 1.0)
            case .purple: Color(red: 0.62, green: 0.3, blue: 0.95)
            case .graphite: Color(white: 0.55)
            }
        }
    }

    enum FullScreenBackground: String, CaseIterable, Identifiable {
        case colors, animated, still, solid
        var id: String { rawValue }
        var label: String {
            switch self {
            case .colors: "Artwork colours"
            case .animated: "Moving artwork"
            case .still: "Still artwork"
            case .solid: "Solid colour"
            }
        }
    }

    enum LyricsSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var scale: CGFloat {
            switch self {
            case .small: 0.82
            case .medium: 1
            case .large: 1.22
            }
        }
    }

    var colorScheme: ColorSchemeChoice { didSet { save(colorScheme.rawValue, Keys.colorScheme); applyAppearance() } }
    var accent: AccentChoice { didSet { save(accent.rawValue, Keys.accent) } }
    var fullScreenBackground: FullScreenBackground { didSet { save(fullScreenBackground.rawValue, Keys.fullScreenBackground) } }
    var lyricsSize: LyricsSize { didSet { save(lyricsSize.rawValue, Keys.lyricsSize) } }
    /// The full-screen player opens with lyrics beside the artwork.
    var fullScreenShowsLyrics: Bool { didSet { save(fullScreenShowsLyrics, Keys.fullScreenShowsLyrics) } }
    var showsPlaylistsInSidebar: Bool { didSet { save(showsPlaylistsInSidebar, Keys.showsPlaylistsInSidebar) } }

    // MARK: Playback

    /// Keep playing YouTube's radio after a single song ends, as the web player does.
    var autoplayRadio: Bool { didSet { save(autoplayRadio, Keys.autoplayRadio) } }
    var globalShortcuts: Bool { didSet { save(globalShortcuts, Keys.globalShortcuts); GlobalHotkeys.setEnabled(globalShortcuts) } }

    // MARK: Menu bar

    var showsMenuBarItem: Bool { didSet { save(showsMenuBarItem, Keys.showsMenuBarItem) } }
    /// The menu bar item shows the song title next to its icon.
    var menuBarShowsTitle: Bool { didSet { save(menuBarShowsTitle, Keys.menuBarShowsTitle) } }

    // MARK: Launch at login

    /// Read from the system rather than stored — the user can change it in System Settings.
    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    Log.write("launch at login: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Storage

    private init() {
        let d = UserDefaults.standard
        colorScheme = ColorSchemeChoice(rawValue: d.string(forKey: Keys.colorScheme) ?? "") ?? .system
        accent = AccentChoice(rawValue: d.string(forKey: Keys.accent) ?? "") ?? .red
        var background = FullScreenBackground(rawValue: d.string(forKey: Keys.fullScreenBackground) ?? "") ?? .colors
        // Artwork colours became the default after some people had already saved another
        // style; move everyone onto it once. Choices made after this are kept.
        if !d.bool(forKey: Keys.artworkColorsMigrated) {
            d.set(true, forKey: Keys.artworkColorsMigrated)
            background = .colors
            d.set(background.rawValue, forKey: Keys.fullScreenBackground)
        }
        fullScreenBackground = background
        lyricsSize = LyricsSize(rawValue: d.string(forKey: Keys.lyricsSize) ?? "") ?? .medium
        fullScreenShowsLyrics = d.object(forKey: Keys.fullScreenShowsLyrics) as? Bool ?? true
        showsPlaylistsInSidebar = d.object(forKey: Keys.showsPlaylistsInSidebar) as? Bool ?? true
        autoplayRadio = d.object(forKey: Keys.autoplayRadio) as? Bool ?? true
        globalShortcuts = d.object(forKey: Keys.globalShortcuts) as? Bool ?? true
        showsMenuBarItem = d.object(forKey: Keys.showsMenuBarItem) as? Bool ?? true
        menuBarShowsTitle = d.object(forKey: Keys.menuBarShowsTitle) as? Bool ?? false
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Applied to the whole app, so every window, the menu bar panel and the sign-in
    /// window agree.
    func applyAppearance() {
        switch colorScheme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func resetToDefaults() {
        colorScheme = .system
        accent = .red
        fullScreenBackground = .colors
        lyricsSize = .medium
        fullScreenShowsLyrics = true
        showsPlaylistsInSidebar = true
        autoplayRadio = true
        globalShortcuts = true
        showsMenuBarItem = true
        menuBarShowsTitle = false
    }

    private enum Keys {
        static let colorScheme = "settings.colorScheme"
        static let accent = "settings.accent"
        static let fullScreenBackground = "settings.fullScreenBackground"
        static let artworkColorsMigrated = "settings.fullScreenBackground.artworkColorsMigrated"
        static let lyricsSize = "settings.lyricsSize"
        static let fullScreenShowsLyrics = "settings.fullScreenShowsLyrics"
        static let showsPlaylistsInSidebar = "settings.showsPlaylistsInSidebar"
        static let autoplayRadio = "settings.autoplayRadio"
        static let globalShortcuts = "settings.globalShortcuts"
        static let showsMenuBarItem = "settings.showsMenuBarItem"
        static let menuBarShowsTitle = "settings.menuBarShowsTitle"
    }
}
