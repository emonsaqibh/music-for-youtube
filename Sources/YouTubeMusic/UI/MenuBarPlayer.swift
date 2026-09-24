import AppKit
import SwiftUI

/// The panel that drops from the menu bar icon — a Now Playing card in the manner of
/// Control Center's: artwork and title, a scrubber, transport, volume, what's up next, and
/// the account and app shortcuts underneath, all on one sheet of Liquid Glass.
struct MenuBarPlayer: View {
    /// The menu bar panel's own corner radius, so the glass fills it exactly.
    static let cornerRadius: CGFloat = 18

    @Environment(PlayerController.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if player.hasTrack {
                nowPlaying
                    .padding(16)
                if !player.upNext.isEmpty {
                    Divider().opacity(0.5)
                    upNext
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                }
            } else {
                idle.padding(22)
            }
            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
        // System glass rather than a material, so it follows the Liquid Glass level
        // chosen in System Settings › Appearance. The panel's own grey is cleared away.
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        .containerBackground(.clear, for: .window)
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Artwork(url: player.current?.artwork, cornerRadius: 10)
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)
                    .onTapGesture { showMainWindow(fullScreen: true) }
                    .help("Open the full-screen player")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(player.current?.title ?? "")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if player.current?.isExplicit == true { ExplicitBadge() }
                    }
                    Text(player.current?.artistLine ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let album = player.current?.album?.name ?? player.queueSource, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 3) {
                PlaybackSlider(trackHeight: 5)
                HStack {
                    PlaybackTime(kind: .elapsed)
                    Spacer()
                    PlaybackTime(kind: .remaining)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                TransportButton(symbol: "shuffle", size: 13, isActive: player.isShuffling) {
                    player.toggleShuffle()
                }
                Spacer()
                TransportButton(symbol: "backward.fill", size: 18, isEnabled: player.hasTrack) {
                    player.previous()
                }
                Spacer()
                TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                                size: 26, isEnabled: player.hasTrack) { player.toggle() }
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                TransportButton(symbol: "forward.fill", size: 18, isEnabled: player.canGoNext) {
                    player.next()
                }
                Spacer()
                TransportButton(symbol: player.repeatMode.symbol, size: 13,
                                isActive: player.repeatMode.isActive) { player.cycleRepeat() }
            }
            .padding(.horizontal, 4)

            VolumeRow()
        }
    }

    // MARK: Up next

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up Next")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(Array(player.upNext.prefix(3).enumerated()), id: \.offset) { offset, track in
                Button {
                    player.go(to: player.index + 1 + offset)
                } label: {
                    HStack(spacing: 10) {
                        Artwork(url: track.artwork, cornerRadius: 5)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(track.artistLine)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(track.seconds == nil ? "" : track.durationText)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .help("Play now")
            }
        }
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.accent.gradient)
                .frame(width: 58, height: 58)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Not Playing")
                .font(.system(size: 14, weight: .semibold))
            Text("Pick something to listen to in Music for YouTube.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Music for YouTube") { showMainWindow() }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            ProfileMenu()
            Spacer(minLength: 8)
            TransportButton(symbol: "macwindow", size: 12) { showMainWindow() }
                .help("Open Music for YouTube")
            TransportButton(symbol: "pip.enter", size: 12) { openWindow(id: WindowID.miniPlayer) }
                .help("Mini Player")
            TransportButton(symbol: "gearshape", size: 12) {
                NSApp.activate()
                openSettings()
            }
            .help("Settings")
            TransportButton(symbol: "power", size: 12) { NSApp.terminate(nil) }
                .help("Quit")
        }
    }

    private func showMainWindow(fullScreen: Bool = false) {
        NSApp.activate()
        openWindow(id: WindowID.main)
        if fullScreen {
            NotificationCenter.default.post(name: .showFullScreenPlayer, object: nil)
        }
    }
}

extension Notification.Name {
    /// Asks the main window to open its full-screen player.
    static let showFullScreenPlayer = Notification.Name("showFullScreenPlayer")
    /// ⌘K: bring up Search with the cursor in the sidebar field.
    static let focusSearch = Notification.Name("focusSearch")
}

/// The account chip in the menu bar panel's footer: who you are listening as, and a menu
/// to switch.
private struct ProfileMenu: View {
    private var session: Session { .shared }

    var body: some View {
        Menu {
            ForEach(Session.Profile.allCases) { profile in
                Button {
                    switchTo(profile)
                } label: {
                    if session.profile == profile {
                        Label(session.title(for: profile), systemImage: "checkmark")
                    } else {
                        Text(session.title(for: profile))
                    }
                }
            }
            Divider()
            if !(session.profile == .account ? session.isSignedIn : session.hasAccount) {
                Button("Sign In…") { SignIn.start() }
            }
        } label: {
            HStack(spacing: 6) {
                AccountAvatar(profile: session.profile, size: 20)
                Text(session.isGuest ? "Guest" : session.title(for: .account))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(HoverRowStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch between your account and guest mode")
    }

    private func switchTo(_ profile: Session.Profile) {
        guard profile != session.profile else { return }
        if profile == .account && !session.hasAccount {
            SignIn.start()
        } else {
            PlayerController.shared.switchProfile(to: profile)
        }
    }
}

/// Speaker, slider, speaker — full width.
private struct VolumeRow: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 9) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            ProgressSlider(value: $player.volume, accent: .primary, trackHeight: 4)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
