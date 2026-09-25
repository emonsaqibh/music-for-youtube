import AppKit
import SwiftUI

/// The panel that drops from the menu bar icon, laid out like Control Center: no panel of
/// its own, just separate tiles of Liquid Glass floating over the desktop. Now Playing
/// (artwork, scrubber, transport), Sound, what's up next, and a row of small buttons for
/// the account and the app.
struct MenuBarPlayer: View {
    /// Control Center's tile corner.
    static let tileRadius: CGFloat = 24
    /// The clear gap between tiles.
    static let gap: CGFloat = 10
    /// Clear room round the tiles inside the panel's window, so their glass shadows fade
    /// out instead of being cut off in a hard line at the window's edge. The top stays
    /// tight so the first tile sits just under the menu bar, as in Control Center.
    static let shadowRoom = EdgeInsets(top: 8, leading: 28, bottom: 28, trailing: 28)

    @Environment(PlayerController.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // One glass group. Its spacing is under the gap, so the tiles stay apart instead
        // of melting into each other.
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: Self.gap) {
                if player.hasTrack {
                    nowPlaying.tile(padding: 16)
                    VolumeTile().tile()
                    if !player.upNext.isEmpty {
                        upNext.tile(padding: 8)
                    }
                } else {
                    idle.tile(padding: 22)
                }
                bottomRow
            }
        }
        .frame(width: 330)
        .padding(Self.shadowRoom)
        // No panel: the window's grey is cleared here and its sheet of glass hidden by
        // ClearPanel, which also turns off the tiles' shadows, so only the tiles draw and
        // the gaps between them show the desktop.
        .containerBackground(.clear, for: .window)
        .background(ClearPanel())
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
                // Plain, like the tile's other small buttons: it sits on the tile's glass.
                LikeButton(size: 14)
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
        }
    }

    // MARK: Up next

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up Next")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 4)
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

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 8) {
            ProfileMenu()
            Spacer(minLength: 8)
            RoundGlassButton(symbol: "macwindow", help: "Open Music for YouTube") { showMainWindow() }
            RoundGlassButton(symbol: "pip.enter", help: "Mini Player") {
                openWindow(id: WindowID.miniPlayer)
            }
            RoundGlassButton(symbol: "gearshape", help: "Settings") {
                NSApp.activate()
                openSettings()
            }
            RoundGlassButton(symbol: "power", help: "Quit") { NSApp.terminate(nil) }
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

/// The account capsule in the menu bar panel's bottom row: who you are listening as, and
/// a menu to switch.
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
                AccountAvatar(profile: session.profile, size: 22)
                Text(session.isGuest ? "Guest" : session.title(for: .account))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 11)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: Capsule())
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

/// Control Center's Sound tile: a title with the mute toggle, then speaker, slider, speaker.
private struct VolumeTile: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        @Bindable var player = player
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sound")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                TransportButton(symbol: "speaker.slash.fill", size: 11, isActive: player.isMuted) {
                    player.toggleMute()
                }
                .help(player.isMuted ? "Unmute" : "Mute")
            }
            HStack(spacing: 9) {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 14)
                ProgressSlider(value: $player.volume, accent: .primary, trackHeight: 4)
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

/// A small round glass button for the bottom row.
private struct RoundGlassButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }
}

private extension View {
    /// One Control Center tile: full width, on its own piece of glass.
    func tile(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: MenuBarPlayer.tileRadius, style: .continuous))
    }
}

/// Leaves the panel's window as a bare stage for the tiles.
///
/// - Turns off the window's shadow: the glass casts its own soft one, and the window's
///   would outline it in a hard dark edge.
/// - Hides the sheet of glass SwiftUI puts behind every window-style MenuBarExtra.
///   `.containerBackground(.clear, for: .window)` clears the panel's grey but not that
///   glass, and no public modifier removes it; left in, it fills the gaps between the
///   tiles. It is the one glass whose shape fills the whole window (no tile does: the
///   bottom row always sits apart), and hiding it is only a layer's `isHidden`. If a later
///   macOS draws it differently, nothing matches and the gaps are simply glass again.
private struct ClearPanel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.hasShadow = false
            hidePanelGlass()
        }

        // The panel resizes with its content (playing ⇄ idle, Up Next coming and going).
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            hidePanelGlass()
        }

        private var observers: [any NSObjectProtocol] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            // Reopening the panel and a new glass level both redraw the glass with its
            // default settings, shadow included.
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: Notification.Name("NSGlassEffectDiffusionDidChangeNotification"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hidePanelGlass() }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, note.object as? NSWindow === window,
                          window.occlusionState.contains(.visible) else { return }
                    self.hidePanelGlass()
                }
            })
        }

        required init?(coder: NSCoder) { fatalError() }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private func hidePanelGlass() {
            // On the next turn, once SwiftUI has drawn this pass.
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window?.contentView?.superview?.layer else { return }
                Self.hideGlass(filling: root.bounds.size, under: root)
            }
        }

        private static func hideGlass(filling size: CGSize, under layer: CALayer) {
            if NSStringFromClass(type(of: layer)) == "CABackdropLayer" {
                if contains(elementOfSize: size, layer) {
                    // The sheet is drawn in three sibling layers: the blur (this one), and
                    // after it a portal and the layer that draws its rim and shadow. Left
                    // alone, those outline the whole panel and dim the gaps between tiles.
                    layer.isHidden = true
                    for sibling in layer.superlayer?.sublayers ?? [] where isSheetPart(sibling, size: size) {
                        sibling.isHidden = true
                    }
                } else {
                    dropShadow(layer)
                }
                return
            }
            for sublayer in layer.sublayers ?? [] { hideGlass(filling: size, under: sublayer) }
        }

        /// The tiles' glass casts a shadow about 24pt wide. In the 10pt gaps two of them
        /// overlap and dim the desktop by about 10%, a grey band between tiles; Control
        /// Center's tiles cast none. Only settings the glass filter actually has are touched,
        /// so a later macOS that renames them just keeps its shadow.
        private static func dropShadow(_ backdrop: CALayer) {
            guard let glass = backdrop.filters?.lazy.compactMap({ $0 as? NSObject })
                    .first(where: { $0.value(forKey: "name") as? String == "glassBackground" }),
                  let keys = glass.value(forKey: "inputKeys") as? [String] else { return }
            for key in ["inputShadowOpacity", "inputRingShadowOpacity"] where keys.contains(key) {
                backdrop.setValue(0, forKeyPath: "filters.glassBackground.\(key)")
            }
        }

        private static func isSheetPart(_ layer: CALayer, size: CGSize) -> Bool {
            let name = NSStringFromClass(type(of: layer))
            return name == "CASDFLayer"
                && abs(layer.frame.width - size.width) < 1 && abs(layer.frame.height - size.height) < 1
        }

        private static func contains(elementOfSize size: CGSize, _ layer: CALayer) -> Bool {
            if NSStringFromClass(type(of: layer)) == "CASDFElementLayer",
               abs(layer.frame.width - size.width) < 1, abs(layer.frame.height - size.height) < 1 {
                return true
            }
            return (layer.sublayers ?? []).contains { contains(elementOfSize: size, $0) }
        }
    }
}
