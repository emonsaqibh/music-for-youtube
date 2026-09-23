import AppKit
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    /// Reopens on the pane last used.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            // Each pane sized to its content; the window resizes between them as System
            // Settings' panes do.
            Tab("General", systemImage: "gearshape", value: "general") { GeneralPane().frame(height: 400) }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") { AppearancePane().frame(height: 560) }
            Tab("Playback", systemImage: "play.circle", value: "playback") { PlaybackPane().frame(height: 380) }
            Tab("Account", systemImage: "person.crop.circle", value: "account") { AccountPane().frame(height: 440) }
            Tab("About", systemImage: "info.circle", value: "about") { AboutPane() }
        }
        .frame(width: 540)
        .tint(Theme.accent)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable private var settings = AppSettings.shared
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $settings.launchAtLogin)
            } footer: {
                Text("Starts quietly so music is a click away in the menu bar.")
            }

            Section("Menu Bar") {
                Toggle("Show in menu bar", isOn: $settings.showsMenuBarItem)
                Toggle("Show song title next to the icon", isOn: $settings.menuBarShowsTitle)
                    .disabled(!settings.showsMenuBarItem)
            }

            Section("Sidebar") {
                Toggle("Show playlists", isOn: $settings.showsPlaylistsInSidebar)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults…") { confirmingReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore all settings to their defaults?", isPresented: $confirmingReset) {
            Button("Restore Defaults", role: .destructive) { settings.resetToDefaults() }
        } message: {
            Text("Your account and guest profiles are not affected.")
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Appearance") {
                HStack(spacing: 18) {
                    ForEach(AppSettings.ColorSchemeChoice.allCases) { choice in
                        SchemeCard(choice: choice, isSelected: settings.colorScheme == choice) {
                            settings.colorScheme = choice
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("Accent Colour") {
                HStack(spacing: 12) {
                    ForEach(AppSettings.AccentChoice.allCases) { choice in
                        AccentSwatch(choice: choice, isSelected: settings.accent == choice) {
                            withAnimation(.spring(response: 0.3)) { settings.accent = choice }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section("Full-Screen Player") {
                Picker("Background", selection: $settings.fullScreenBackground) {
                    ForEach(AppSettings.FullScreenBackground.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Open with lyrics showing", isOn: $settings.fullScreenShowsLyrics)
            }

            Section("Lyrics") {
                Picker("Text size", selection: $settings.lyricsSize) {
                    ForEach(AppSettings.LyricsSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

/// A miniature window in the given appearance, like System Settings' Appearance picker.
private struct SchemeCard: View {
    let choice: AppSettings.ColorSchemeChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                    .frame(width: 104, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? Theme.accent : Color.primary.opacity(0.15),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                Text(choice.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        switch choice {
        case .light: miniWindow(dark: false)
        case .dark: miniWindow(dark: true)
        case .system:
            ZStack {
                miniWindow(dark: false)
                miniWindow(dark: true)
                    .mask(HStack(spacing: 0) { Color.clear; Color.black })
            }
        }
    }

    private func miniWindow(dark: Bool) -> some View {
        let base = dark ? Color(white: 0.14) : Color(white: 0.96)
        let side = dark ? Color(white: 0.2) : Color(white: 0.9)
        let ink = dark ? Color.white.opacity(0.75) : Color.black.opacity(0.55)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Theme.accent).frame(width: 18, height: 4)
                Capsule().fill(ink.opacity(0.4)).frame(width: 14, height: 3)
                Capsule().fill(ink.opacity(0.4)).frame(width: 16, height: 3)
                Spacer()
            }
            .padding(6)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .background(side)

            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink).frame(width: 30, height: 5)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent.opacity(0.35 + Double(i) * 0.2))
                            .frame(width: 18, height: 18)
                    }
                }
                Spacer()
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(base)
        }
    }
}

private struct AccentSwatch: View {
    let choice: AppSettings.AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(choice.color.gradient)
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected {
                        Circle().fill(.white).frame(width: 8, height: 8)
                            .transition(.scale)
                    }
                }
                .overlay { Circle().strokeBorder(.black.opacity(0.12)) }
                .padding(3)
                .overlay {
                    Circle().strokeBorder(isSelected ? choice.color : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .help(choice.label)
    }
}

// MARK: - Playback

private struct PlaybackPane: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Keep playing similar songs", isOn: $settings.autoplayRadio)
            } footer: {
                Text("When you play a single song, YouTube Music’s radio continues after it — as it does on the web.")
            }

            Section {
                Toggle("Global keyboard shortcuts", isOn: $settings.globalShortcuts)
                if settings.globalShortcuts {
                    ShortcutRow(title: "Play / Pause", keys: "⌃⌥⌘ Space")
                    ShortcutRow(title: "Next", keys: "⌃⌥⌘ →")
                    ShortcutRow(title: "Previous", keys: "⌃⌥⌘ ←")
                }
            } footer: {
                Text("Work from any app. Hardware media keys always work.")
            }
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.2), value: settings.globalShortcuts)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: String

    var body: some View {
        LabeledContent(title) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Account

private struct AccountPane: View {
    @State private var confirmingClear = false
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                AccountSwitcher(showsSettingsLink: false)
                    .padding(.horizontal, -8)
            } header: {
                Text("Profiles")
            } footer: {
                Text("Your account and the guest profile keep separate sign-ins, history and recommendations. Switching never signs you out.")
            }

            Section {
                LabeledContent {
                    Button(cleared ? "Cleared" : "Clear Guest Data…") { confirmingClear = true }
                        .disabled(cleared)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guest history")
                        Text("Forget what guest mode has listened to, for fresh recommendations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear guest data?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) {
                Task {
                    await WebEngine.shared.clearGuestData()
                    cleared = true
                }
            }
        } message: {
            Text("Guest mode will start over as a new listener. Your account is not affected.")
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            VStack(spacing: 3) {
                Text(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Music for YouTube")
                    .font(.system(size: 20, weight: .bold))
                Text(version)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("A native Mac player for YouTube Music. Playback runs through YouTube’s own web player, so Premium, history and recommendations work as they do on the web.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 10) {
                Button("Engine Diagnostics…") { openWindow(id: WindowID.diagnostics) }
                Button("Show Logs") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }
}
