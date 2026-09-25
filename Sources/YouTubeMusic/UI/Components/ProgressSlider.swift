import SwiftUI

/// A thin draggable track. Grows on hover the way Apple Music's scrubber does, and
/// reports drag start/end so the player can suspend position updates while scrubbing.
struct ProgressSlider: View {
    @Binding var value: Double          // 0...1
    var accent: Color = .primary
    var trackHeight: CGFloat = 4
    var showsKnob = true
    var onScrub: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?

    @State private var hovering = false
    @State private var dragging = false

    private var active: Bool { hovering || dragging }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let filled = width * min(max(value, 0), 1)
            let height = active ? trackHeight + 2 : trackHeight

            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.18)).frame(height: height)
                Capsule().fill(accent.opacity(0.85)).frame(width: filled, height: height)

                if showsKnob {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .frame(width: 11, height: 11)
                        .offset(x: filled - 5.5)
                        .opacity(active ? 1 : 0)
                }
            }
            .frame(height: max(height, 11))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: active)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let next = min(max(g.location.x / width, 0), 1)
                        value = next
                        onScrub?(next)
                    }
                    .onEnded { g in
                        let next = min(max(g.location.x / width, 0), 1)
                        value = next
                        dragging = false
                        onCommit?(next)
                    }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: 13)
    }
}

/// The current song's scrubber.
///
/// The bridge reports the position only twice a second, so a bar drawn from that alone
/// moves in visible half-second steps. This one extrapolates between reports on the
/// display's clock, so it glides — and it is its own view, so the redraw stays inside it
/// instead of re-running whichever player hosts it.
struct PlaybackSlider: View {
    var trackHeight: CGFloat = 4
    var showsKnob = true
    /// How often the bar moves while playing. Wide bars need more steps to look smooth.
    var framesPerSecond: Double = 20

    @Environment(PlayerController.self) private var player
    /// Off screen (menu bar panel closed, window minimised or covered) the bar stands
    /// still.
    @State private var onScreen = false

    var body: some View {
        let still = !onScreen || !player.isPlaying || player.isBuffering || player.scrubTarget != nil
        TimelineView(.animation(minimumInterval: 1 / framesPerSecond, paused: still)) { context in
            ProgressSlider(
                value: Binding(get: { fraction(at: context.date) }, set: { _ in }),
                accent: .primary,
                trackHeight: trackHeight,
                showsKnob: showsKnob,
                onScrub: { player.scrubTarget = $0 * player.duration },
                onCommit: { value in
                    player.scrubTarget = nil
                    player.seek(to: value * player.duration)
                })
        }
        .background(OnScreenReader { onScreen = $0 })
    }

    private func fraction(at date: Date) -> Double {
        guard player.duration > 0 else { return 0 }
        return min(1, player.livePosition(at: date) / player.duration)
    }
}

/// Elapsed or remaining time. A separate view so each position report redraws only
/// this text.
struct PlaybackTime: View {
    enum Kind { case elapsed, remaining }

    let kind: Kind

    @Environment(PlayerController.self) private var player

    var body: some View {
        switch kind {
        case .elapsed:
            Text(Format.time(player.displayPosition))
        case .remaining:
            Text("-" + Format.time(max(0, player.duration - player.displayPosition)))
        }
    }
}
