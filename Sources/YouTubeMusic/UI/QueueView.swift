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
                List {
                    ForEach(Array(player.upNext.enumerated()), id: \.element.id) { offset, track in
                        let position = player.index + 1 + offset
                        QueueRow(track: track) { player.go(to: position) }
                            .contextMenu {
                                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    player.moveInQueue(from: [position], to: player.index + 1)
                                }
                                .disabled(offset == 0)
                                Button("Move to End", systemImage: "text.line.last.and.arrowtriangle.forward") {
                                    player.moveInQueue(from: [position], to: player.queue.count)
                                }
                                .disabled(offset == player.upNext.count - 1)
                                Divider()
                                Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                                    player.removeFromQueue(at: [position])
                                }
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    }
                    .onMove { source, destination in
                        let base = player.index + 1
                        player.moveInQueue(from: IndexSet(source.map { $0 + base }),
                                           to: destination + base)
                    }
                    .onDelete { offsets in
                        let base = player.index + 1
                        player.removeFromQueue(at: IndexSet(offsets.map { $0 + base }))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: compactHeader ? 60 : Theme.playerClearance - 40)
                }
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
    }
}
