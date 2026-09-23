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
