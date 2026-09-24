import SwiftUI

/// The queue panel: "Continue Playing", with autoplay and shuffle toggles above it.
struct QueueView: View {
    /// In the full-screen player the panel sits in open space, not under the player pill.
    var compactHeader = false

    @Environment(PlayerController.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modes
            if let current = player.current { nowPlaying(current) }
            header

            if player.upNext.isEmpty {
                Text("There’s no music in the queue.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 30)
            } else {
                ReorderableQueue(bottomClearance: compactHeader ? 60 : Theme.playerClearance - 40)
            }
        }
    }

    private var modes: some View {
        HStack(spacing: 8) {
            Spacer()
            modeButton("infinity", isOn: player.repeatMode == .all) { player.cycleRepeat() }
            modeButton("shuffle", isOn: player.isShuffling) { player.toggleShuffle() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func modeButton(_ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : Color.primary.opacity(0.8))
                .frame(width: 56, height: 26)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func nowPlaying(_ track: Track) -> some View {
        HStack(spacing: 11) {
            Artwork(url: track.artwork, cornerRadius: 6)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Now Playing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(track.artistLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if player.isPlaying { PlayingIndicator() }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 14)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Playing Next")
                .font(.system(size: 17, weight: .bold))
            Spacer()
            Button("Clear") { player.clearQueue() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(player.upNext.isEmpty ? Color.secondary : Theme.accent)
                .disabled(player.upNext.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct QueueRow: View {
    let track: Track
    /// Being dragged: raised off the list, as iOS lifts a row.
    var isLifted = false
    let onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Artwork(url: track.artwork, cornerRadius: 4)
                    .frame(width: 38, height: 38)
                    .opacity(hovering ? 0.45 : 1)
                if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12)).lineLimit(1)
                Text(track.artistLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // The row itself drags (the list's reordering); the handle says so.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .help("Drag to reorder")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isLifted ? AnyShapeStyle(.regularMaterial)
                      : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
                .shadow(color: .black.opacity(isLifted ? 0.28 : 0), radius: isLifted ? 12 : 0, y: isLifted ? 6 : 0)
        }
        .scaleEffect(isLifted ? 1.035 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
    }
}

/// "Playing Next", reordered by dragging the way iOS lists do: the song lifts under the
/// pointer, the others slide aside on springs as it passes, and on release it settles into
/// its slot. Rows have one fixed height, so every position is arithmetic, not measurement.
private struct ReorderableQueue: View {
    let bottomClearance: CGFloat

    @Environment(PlayerController.self) private var player

    private static let rowHeight: CGFloat = 48
    private static let settle = Animation.spring(response: 0.32, dampingFraction: 0.82)

    /// The row being dragged, where the pointer has taken it, and the slot it would land in.
    @State private var dragged: Int?
    @State private var dragOffset: CGFloat = 0
    @State private var target: Int?

    /// Stable identities: a song queued twice gets "#2", so SwiftUI never sees duplicates.
    private var rows: [(id: String, track: Track)] {
        var seen: [String: Int] = [:]
        return player.upNext.map { track in
            let n = (seen[track.id] ?? 0) + 1
            seen[track.id] = n
            return (n == 1 ? track.id : "\(track.id)#\(n)", track)
        }
    }

    var body: some View {
        let rows = rows
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                    let position = player.index + 1 + offset
                    let lifted = dragged == offset
                    QueueRow(track: row.track, isLifted: lifted) { player.go(to: position) }
                        .frame(height: Self.rowHeight)
                        .contextMenu { menu(offset: offset, position: position, count: rows.count) }
                        .offset(y: yOffset(for: offset))
                        .zIndex(lifted ? 1 : 0)
                        .gesture(drag(for: offset, count: rows.count))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, bottomClearance)
            // Songs added (Play Next) or removed slide rather than jump. A drop turns this off
            // for the instant its data catches up with what's already on screen.
            .animation(Self.settle, value: rows.map(\.id))
        }
        .scrollIndicators(.automatic)
    }

    /// Where a row sits while something is being dragged.
    private func yOffset(for offset: Int) -> CGFloat {
        guard let dragged, let target else { return 0 }
        if offset == dragged { return dragOffset }
        if dragged < target, offset > dragged, offset <= target { return -Self.rowHeight }
        if dragged > target, offset >= target, offset < dragged { return Self.rowHeight }
        return 0
    }

    private func drag(for offset: Int, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragged == nil {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        dragged = offset
                        target = offset
                    }
                }
                dragOffset = value.translation.height
                let slot = min(max(offset + Int((dragOffset / Self.rowHeight).rounded()), 0), count - 1)
                if slot != target {
                    withAnimation(Self.settle) { target = slot }
                }
            }
            .onEnded { _ in drop(from: offset) }
    }

    /// Springs the song into its slot, then moves it in the queue once it's there — with
    /// animations off, since the screen already shows the result.
    private func drop(from offset: Int) {
        guard let target else { return clear() }
        withAnimation(Self.settle) {
            dragOffset = CGFloat(target - offset) * Self.rowHeight
        } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                if target != offset {
                    let base = player.index + 1
                    player.moveInQueue(from: [base + offset],
                                       to: base + target + (target > offset ? 1 : 0))
                }
                clear()
            }
        }
    }

    private func clear() {
        dragged = nil
        target = nil
        dragOffset = 0
    }

    @ViewBuilder
    private func menu(offset: Int, position: Int, count: Int) -> some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.moveInQueue(from: [position], to: player.index + 1)
        }
        .disabled(offset == 0)
        Button("Move to End", systemImage: "text.line.last.and.arrowtriangle.forward") {
            player.moveInQueue(from: [position], to: player.queue.count)
        }
        .disabled(offset == count - 1)
        Divider()
        Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
            player.removeFromQueue(at: [position])
        }
    }
}
