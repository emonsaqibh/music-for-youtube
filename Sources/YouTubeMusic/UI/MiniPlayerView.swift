import AppKit
import SwiftUI

/// A compact floating player for when the main window is out of the way. Chrome-free:
/// the window's own buttons are hidden and the whole thing drags; close and "open app"
/// appear on hover, as in Music.app's mini player.
struct MiniPlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var hovering = false

    var body: some View {
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
                .padding(.trailing, hovering ? 44 : 0)

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
        .frame(width: 372, height: 110)
        .background { NowPlayingBackdrop(url: player.current?.artwork) }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                hoverButton("arrow.up.left.and.arrow.down.right", help: "Open Music for YouTube") {
                    NSApp.activate()
                    openWindow(id: WindowID.main)
                }
                hoverButton("xmark", help: "Close") { dismissWindow(id: WindowID.miniPlayer) }
            }
            .padding(8)
            .opacity(hovering ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    private func hoverButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
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
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }
}
