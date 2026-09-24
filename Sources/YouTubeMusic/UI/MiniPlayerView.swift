import AppKit
import SwiftUI

/// A compact floating player for when the main window is out of the way, in two sizes: a
/// wide bar with a scrubber, and a small square (artwork, title, transport), each a single
/// pane of Liquid Glass. Chrome-free:
/// the window's own buttons are hidden and the whole thing drags; the size switch, "open
/// app" and close appear on hover, as in Music.app's mini player.
struct MiniPlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var hovering = false
    /// Remembered, so the mini player reopens at the size it was left in. The window
    /// follows the content's size.
    @AppStorage("miniPlayer.square") private var isSquare = false

    var body: some View {
        Group {
            if isSquare { square } else { wide }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: isSquare ? 3 : 4) {
                hoverButton(isSquare ? "rectangle" : "square",
                            help: isSquare ? "Wide Mini Player" : "Small Mini Player") {
                    isSquare.toggle()
                }
                hoverButton("arrow.up.left.and.arrow.down.right", help: "Open Music for YouTube") {
                    NSApp.activate()
                    openWindow(id: WindowID.main)
                }
                hoverButton("xmark", help: "Close") { dismissWindow(id: WindowID.miniPlayer) }
            }
            .padding(isSquare ? 6 : 8)
            .opacity(hovering ? 1 : 0)
        }
        // System glass, so it follows the Liquid Glass level in System Settings.
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        // SwiftUI's hosting view claims every mouse-down, so AppKit's "movable by
        // background" never sees one. Drag the window from SwiftUI instead; the buttons
        // and the scrubber's own drag still win where they are.
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .background(ChromelessWindow())
        .containerBackground(.clear, for: .window)
    }

    /// Both sizes share the wide bar's height, so switching keeps the window's top and
    /// bottom where they were.
    static let height: CGFloat = 110

    /// The small square: artwork top-left, title and artist, then previous / play / next.
    private var square: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(url: player.current?.artwork, cornerRadius: 6)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

            Spacer(minLength: 3)

            Text(player.current?.title ?? "Not Playing")
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
            Text(player.current?.artistLine ?? "Music for YouTube")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            HStack(spacing: 0) {
                TransportButton(symbol: "backward.fill", size: 11, isEnabled: player.hasTrack) { player.previous() }
                Spacer(minLength: 0)
                TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                                size: 16, isEnabled: player.hasTrack) { player.toggle() }
                    .contentTransition(.symbolEffect(.replace))
                Spacer(minLength: 0)
                TransportButton(symbol: "forward.fill", size: 11, isEnabled: player.canGoNext) { player.next() }
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 9)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .frame(width: Self.height, height: Self.height, alignment: .topLeading)
    }

    /// The wide bar: artwork beside title, scrubber and transport.
    private var wide: some View {
        HStack(spacing: 14) {
            Artwork(url: player.current?.artwork, cornerRadius: 10)
                .frame(width: 86, height: 86)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? "Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(player.current?.artistLine ?? "Music for YouTube")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.trailing, hovering ? 68 : 0)

                PlaybackSlider(trackHeight: 4, showsKnob: hovering)

                HStack(spacing: 0) {
                    PlaybackTime(kind: .elapsed)
                        .frame(width: 36, alignment: .leading)
                    Spacer()
                    TransportButton(symbol: "backward.fill", size: 13, isEnabled: player.hasTrack) { player.previous() }
                    TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                                    size: 18, isEnabled: player.hasTrack) { player.toggle() }
                        .contentTransition(.symbolEffect(.replace))
                    TransportButton(symbol: "forward.fill", size: 13, isEnabled: player.canGoNext) { player.next() }
                    Spacer()
                    PlaybackTime(kind: .remaining)
                        .frame(width: 36, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 372, height: Self.height)
    }

    private func hoverButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        let side: CGFloat = isSquare ? 18 : 20
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: isSquare ? 8 : 9, weight: .bold))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }
}

/// Hides the hosting window's traffic lights and makes its background transparent so the
/// rounded card is the whole window.
private struct ChromelessWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // The glass casts its own soft shadow; the window's shadow would add a hard dark
        // outline around it.
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }
}
