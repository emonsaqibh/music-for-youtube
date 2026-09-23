import AppKit
import SwiftUI

/// The immersive player: artwork and controls on the left, lyrics (or the queue) on the
/// right, over a slowly drifting wash of the album art — the arrangement Music.app uses.
///
/// It covers the main window rather than opening a sheet, so it resizes with the window
/// and the layout reflows instead of being pinned to one size.
struct FullScreenPlayer: View {
    @Environment(PlayerController.self) private var player
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow

    @State private var pane: SidePanel? = AppSettings.shared.fullScreenShowsLyrics ? .lyrics : nil
    @State private var tint: Color = Color(white: 0.2)

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(size: geo.size, showsPane: pane != nil)

            HStack(spacing: layout.gap) {
                leftColumn(artSize: layout.artSize)
                    .frame(maxWidth: pane == nil ? .infinity : layout.leftWidth)

                if let pane {
                    Group {
                        switch pane {
                        case .lyrics: LyricsView(style: .immersive)
                        case .queue: QueueView(compactHeader: true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, layout.gap)
            .padding(.top, 64)
            .padding(.bottom, 40)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 0.5, dampingFraction: 0.88), value: pane)
        }
        .background {
            AmbientBackground(url: player.current?.artwork, fallback: tint,
                              style: AppSettings.shared.fullScreenBackground)
        }
        .overlay(alignment: .topLeading) { topLeftCluster }
        .overlay(alignment: .topTrailing) { topRightCluster }
        .overlay(alignment: .bottomTrailing) { bottomCluster }
        .environment(\.colorScheme, .dark)
        .task(id: player.current?.artwork) { await refreshTint() }
        .animation(.easeInOut(duration: 0.6), value: tint)
    }

    /// Sizes that keep the artwork as large as the window allows while leaving the lyrics
    /// column a readable width.
    private struct Layout {
        let size: CGSize
        let showsPane: Bool

        var gap: CGFloat { size.width < 1100 ? 44 : 64 }
        var leftWidth: CGFloat { max(280, min(520, (size.width - gap * 3) * 0.45)) }
        var artSize: CGFloat {
            let byHeight = size.height - 64 - 40 - 190     // title, scrubber, transport
            let byWidth = showsPane ? leftWidth : min(size.width * 0.5, 560)
            return max(200, min(byHeight, byWidth, 560))
        }
    }

    // MARK: Left column

    private func leftColumn(artSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            Artwork(url: player.current?.artwork, cornerRadius: 12)
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .scaleEffect(player.isPlaying || !player.hasTrack ? 1 : 0.9)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: player.isPlaying)

            Spacer(minLength: 24).frame(maxHeight: 36)

            titleBlock.frame(width: artSize)

            Spacer(minLength: 14).frame(maxHeight: 22)

            scrubber.frame(width: artSize)

            Spacer(minLength: 10).frame(maxHeight: 16)

            transport.frame(width: artSize)

            Spacer(minLength: 0)
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(player.current?.title ?? "Not Playing")
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                    if player.current?.isExplicit == true { ExplicitBadge() }
                }
                if let artists = player.current?.artistLine, !artists.isEmpty {
                    Text(artists)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let track = player.current {
                Menu {
                    if let id = track.artists.first?.id {
                        Button("Go to Artist", systemImage: "music.mic") { go(to: .artist(id)) }
                    }
                    if let id = track.album?.id {
                        Button("Go to Album", systemImage: "square.stack") { go(to: .album(id)) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .glassEffect(.regular.interactive(), in: Circle())
                .fixedSize()
                .disabled(track.artists.first?.id == nil && track.album?.id == nil)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            ProgressSlider(
                value: Binding(get: { player.progress }, set: { _ in }),
                accent: .primary,
                trackHeight: 6,
                onScrub: { player.scrubTarget = $0 * player.duration },
                onCommit: { value in
                    player.scrubTarget = nil
                    player.seek(to: value * player.duration)
                })

            HStack {
                Text(Format.time(player.displayPosition))
                Spacer()
                Text("-" + Format.time(max(0, player.duration - player.displayPosition)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            TransportButton(symbol: "shuffle", size: 15, isActive: player.isShuffling) {
                player.toggleShuffle()
            }
            Spacer()
            TransportButton(symbol: "backward.fill", size: 22, isEnabled: player.hasTrack) {
                player.previous()
            }
            Spacer()
            TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                            size: 30, isEnabled: player.hasTrack) { player.toggle() }
                .contentTransition(.symbolEffect(.replace))
            Spacer()
            TransportButton(symbol: "forward.fill", size: 22, isEnabled: player.canGoNext) {
                player.next()
            }
            Spacer()
            TransportButton(symbol: player.repeatMode.symbol, size: 15,
                            isActive: player.repeatMode.isActive) { player.cycleRepeat() }
        }
    }

    // MARK: Floating clusters

    private var topLeftCluster: some View {
        GlassCluster {
            TransportButton(symbol: "chevron.down", size: 14, weight: .semibold) { close() }
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            TransportButton(symbol: "pip.enter", size: 14) {
                close()
                openWindow(id: WindowID.miniPlayer)
            }
            .help("Mini Player")
        }
        // Clear of the window's traffic lights.
        .padding(.leading, 84)
        .padding(.top, 10)
    }

    private var topRightCluster: some View {
        GlassCluster(spacing: 8) {
            VolumeSlider()
        }
        .padding(16)
    }

    private var bottomCluster: some View {
        GlassCluster {
            TransportButton(symbol: "quote.bubble", size: 14, isActive: pane == .lyrics) {
                pane = pane == .lyrics ? nil : .lyrics
            }
            .help("Lyrics")
            TransportButton(symbol: "list.bullet", size: 14, isActive: pane == .queue) {
                pane = pane == .queue ? nil : .queue
            }
            .help("Playing Next")
        }
        .padding(20)
    }

    private func close() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
            router.showFullScreenPlayer = false
        }
    }

    private func go(to route: Route) {
        close()
        router.open(route)
    }

    private func refreshTint() async {
        guard let url = player.current?.artwork,
              let sampled = await ImageCache.shared.accent(url),
              let ns = sampled.usingColorSpace(.deviceRGB) else { return }
        // Shown until the blurred artwork is ready, and under it at the edges; kept muted
        // so the artwork stays the brightest thing on screen.
        tint = Color(nsColor: NSColor(hue: ns.hueComponent,
                                      saturation: min(0.35, ns.saturationComponent * 0.55),
                                      brightness: 0.26,
                                      alpha: 1))
    }
}

/// Two copies of the blurred artwork turning slowly against each other — the moving
/// colour field behind Music.app's full-screen player. Only rotation is animated, so the
/// loop has no seam; the copies sit off-centre, which turns rotation into drift. The blur
/// is baked into a tiny bitmap up front, so the motion is compositing only.
private struct AmbientBackground: View {
    let url: URL?
    let fallback: Color
    var style: AppSettings.FullScreenBackground = .animated

    @State private var image: NSImage?
    @State private var palette: [Color] = []
    @State private var drifting = false

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 1.5
            ZStack {
                fallback

                if style == .colors, palette.count >= 3 {
                    ArtworkColorsBackground(colors: palette,
                                            blur: AppSettings.artworkBlurRadii[AppSettings.shared.artworkBlur])
                        // A new song's colours cross-fade in over the old ones.
                        .id(palette)
                        .transition(.opacity)
                } else if let image, style != .solid, style != .colors {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: side, height: side)
                            .rotationEffect(.degrees(drifting ? 360 : 0))
                            .offset(x: -side * 0.08, y: -side * 0.04)

                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: side * 0.8, height: side * 0.8)
                            .scaleEffect(x: -1)
                            .rotationEffect(.degrees(drifting ? -360 : 0))
                            .offset(x: side * 0.1, y: side * 0.06)
                            .opacity(0.55)
                            .blendMode(.plusLighter)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.opacity)
                }

                // Keeps white type legible over bright artwork. The colour field is already
                // toned down, so it needs less.
                LinearGradient(colors: style == .colors
                                   ? [.black.opacity(0.12), .black.opacity(0.3)]
                                   : [.black.opacity(0.28), .black.opacity(0.42)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .task(id: url) {
            guard let url else { return }
            if let colors = await ImageCache.shared.palette(url) {
                withAnimation(.easeInOut(duration: 1.2)) { palette = colors.map { Color(nsColor: $0) } }
            }
            let next = await ImageCache.shared.ambient(url)
            withAnimation(.easeInOut(duration: 0.8)) { image = next }
        }
        .onAppear { startDrifting() }
        .onChange(of: style) { _, _ in startDrifting() }
    }

    private func startDrifting() {
        guard style == .animated else {
            // Cancel the repeating animation by setting the value without one.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { drifting = false }
            return
        }
        withAnimation(.linear(duration: 90).repeatForever(autoreverses: false)) { drifting = true }
    }
}

/// Music.app's full-screen background: the artwork's own colours flowing slowly into one
/// another. A 4×4 mesh gradient whose points drift on out-of-step sine waves (30–60s
/// periods), so the motion never visibly repeats, softened by the blur chosen in Settings.
/// Rendered by the GPU; with Reduce Motion on, it holds still.
private struct ArtworkColorsBackground: View {
    let colors: [Color]
    var blur: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The field is drawn at a quarter of the window's size and scaled up: it has no fine
    /// detail to lose, and blurring a small image each frame costs a fraction of blurring
    /// the whole window.
    private let downscale: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            // The drift is slow (a ~40s cycle), so 15fps is indistinguishable from 30.
            TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { context in
                MeshGradient(width: 4, height: 4,
                             points: points(at: context.date.timeIntervalSinceReferenceDate),
                             colors: meshColors,
                             smoothsColors: true)
            }
            .frame(width: geo.size.width / downscale, height: geo.size.height / downscale)
            // Opaque, so the blur doesn't fade the edges of the window to transparent.
            .blur(radius: blur / downscale, opaque: true)
            .drawingGroup()
            .scaleEffect(downscale, anchor: .topLeading)
            .animation(.easeInOut(duration: 0.4), value: blur)
        }
    }

    /// Corners stay put, edge points slide along their edge, inner points wander.
    private func points(at t: Double) -> [SIMD2<Float>] {
        func wave(_ base: Double, _ period: Double, _ phase: Double, _ amplitude: Double) -> Float {
            Float(base + sin(t * 2 * .pi / period + phase) * amplitude)
        }
        let a = 1.0 / 3, b = 2.0 / 3
        return [
            [0, 0], [wave(a, 47, 0.0, 0.1), 0], [wave(b, 53, 1.1, 0.1), 0], [1, 0],
            [0, wave(a, 43, 2.3, 0.1)], [wave(a, 37, 0.4, 0.13), wave(a, 41, 3.1, 0.13)],
            [wave(b, 59, 1.7, 0.13), wave(a, 39, 4.4, 0.13)], [1, wave(a, 51, 5.0, 0.1)],
            [0, wave(b, 57, 3.6, 0.1)], [wave(a, 45, 2.8, 0.13), wave(b, 49, 0.9, 0.13)],
            [wave(b, 38, 5.5, 0.13), wave(b, 55, 1.9, 0.13)], [1, wave(b, 46, 4.1, 0.1)],
            [0, 1], [wave(a, 50, 3.3, 0.1), 1], [wave(b, 42, 0.6, 0.1), 1], [1, 1],
        ]
    }

    /// The most prominent colour takes the middle; the rest spread round so neighbouring
    /// patches differ.
    private var meshColors: [Color] {
        let c = colors
        func at(_ i: Int) -> Color { c[i % c.count] }
        return [at(1), at(2), at(3), at(4),
                at(3), at(0), at(0), at(1),
                at(4), at(0), at(0), at(2),
                at(2), at(1), at(4), at(3)]
    }
}
