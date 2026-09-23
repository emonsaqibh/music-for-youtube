import AppKit
import SwiftUI

/// The sidebar's "a new version is out" card, above the account row — installing is one
/// click: the app downloads the release, swaps itself and relaunches.
struct UpdateCard: View {
    private var updater: Updater { .shared }

    var body: some View {
        if updater.offersUpdate, let release = updater.available {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update Available")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Version \(release.version)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if updater.state != .downloading && updater.state != .installing {
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
                }

                switch updater.state {
                case .downloading, .installing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(updater.state == .downloading ? "Downloading…" : "Installing…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    installButton
                default:
                    installButton
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var installButton: some View {
        HStack(spacing: 8) {
            Button("Install & Relaunch") { Task { await updater.install() } }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.small)
            if let page = updater.available?.page {
                Button("What’s New") { NSWorkspace.shared.open(page) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }
}

/// "Check for Updates…" from the app menu: always answers, unlike the background check.
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
                alert.informativeText = "You have \(updater.currentVersion). The app will download the update, "
                    + "replace itself and relaunch."
                alert.addButton(withTitle: "Install & Relaunch")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { await updater.install() }
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
