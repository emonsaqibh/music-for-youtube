import AppKit
import SwiftUI

/// How to install an update, as two steps: copy the command, paste it into Terminal.
/// Shared by the sidebar card and Settings › General.
struct UpdateSteps: View {
    var compact = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            HStack(spacing: 8) {
                number(1)
                Button {
                    Updater.copyInstallCommand()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Command",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .help(Updater.installCommand)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                number(2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paste it into Terminal and press Return.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Terminal") { Updater.openTerminal() }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: compact ? 11 : 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func number(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Theme.accent))
    }
}

/// The sidebar's "a new version is out" card, above the account row.
struct UpdateCard: View {
    private var updater: Updater { .shared }

    var body: some View {
        if updater.offersUpdate, let release = updater.available {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update Available")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Version \(release.version)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { updater.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Not now")
                }
                UpdateSteps(compact: true)
            }
            .padding(12)
            // Pinned to the sidebar's width: left to size itself, text here asks for one
            // wide line and blows out the whole sidebar.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Bindable private var settings = AppSettings.shared
    private var updater: Updater { .shared }

    var body: some View {
        Section("Updates") {
            if updater.isEnabled {
                Toggle("Check for updates automatically", isOn: $settings.checksForUpdates)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(updater.currentVersion)")
                        Text(lastChecked)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updater.state == .checking {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(updater.state == .checking)
                }

                if let release = updater.available {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("Version \(release.version) is available.")
                                .font(.system(size: 12, weight: .semibold))
                            Button("What’s New") { NSWorkspace.shared.open(release.page) }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                        }
                        UpdateSteps()
                    }
                    .padding(.vertical, 4)
                } else if updater.state == .upToDate {
                    Label("You’re up to date.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else if case .failed(let message) = updater.state {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            } else {
                Text("Updates are off in the dev build — it’s replaced by ./build.sh.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastChecked: String {
        guard let date = updater.lastChecked else { return "Not checked yet" }
        return "Last checked " + date.formatted(.relative(presentation: .named))
    }
}

/// "Check for Updates…" from the app menu: always answers, unlike the automatic checks.
@MainActor
enum UpdateCommand {
    static func checkNow() {
        let updater = Updater.shared
        guard updater.isEnabled else {
            alert("Updates are off in the dev build", "Rebuild with ./build.sh, or install a release.")
            return
        }
        Task {
            let found = await updater.check()
            if found, let release = updater.available {
                let alert = NSAlert()
                alert.messageText = "Version \(release.version) is available"
                alert.informativeText = "You have \(updater.currentVersion). To update:\n\n"
                    + "1. Copy the install command.\n2. Paste it into Terminal and press Return.\n\n"
                    + "It quits the app, installs the new version and reopens it. "
                    + "Your sign-in and settings are kept."
                alert.addButton(withTitle: "Copy Command")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    Updater.copyInstallCommand()
                    Updater.openTerminal()
                }
            } else if case .failed(let message) = updater.state {
                alert("Couldn’t check for updates", message)
            } else {
                alert("You’re up to date", "Music for YouTube \(updater.currentVersion) is the newest version.")
            }
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
