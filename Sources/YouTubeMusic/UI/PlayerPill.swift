import SwiftUI

/// The floating glass capsule Apple Music parks at the bottom of the content area:
/// transport on the left, the now-playing display centred, lyrics / queue / volume on
/// the right. It hovers above the page — content scrolls underneath it.
struct PlayerPill: View {
    @Environment(PlayerController.self) private var player
    @Environment(Router.self) private var router

    /// The stand-in drawn by the full-screen player while it grows out of the pill.
    var isMorphing = false

    @State private var width: CGFloat = 700

    /// Below these widths the secondary controls give way so the title stays readable —
    /// Music.app drops shuffle and repeat first when its window narrows. Like goes before
    /// them.
    private var narrow: Bool { width < 630 }
    private var compact: Bool { width < 580 }
    private var tight: Bool { width < 470 }

    var body: some View {
        // Laid out as a row rather than a centred overlay: when the side panel narrows
        // the pill, an overlay would slide the display underneath the transport buttons.
        // Giving the display every remaining point keeps titles readable at that width.
        HStack(spacing: tight ? 6 : 12) {
            transport
            NowPlayingDisplay()
                .frame(maxWidth: .infinity)
            accessories
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.bottom, 18)
        .padding(.horizontal, 18)
        // While the full-screen player is up, it *is* the pill — see `PillMorph`.
        .opacity(router.showFullScreenPlayer && !isMorphing ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: narrow)
        .animation(.easeInOut(duration: 0.2), value: compact)
        .animation(.easeInOut(duration: 0.2), value: tight)
    }

    private var transport: some View {
        HStack(spacing: 2) {
            if !compact {
                TransportButton(symbol: "shuffle", size: 12, isActive: player.isShuffling) {
                    player.toggleShuffle()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            TransportButton(symbol: "backward.fill", size: 14, isEnabled: player.hasTrack) {
                player.previous()
            }
            TransportButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                            size: 19, isEnabled: player.hasTrack) {
                player.toggle()
            }
            .contentTransition(.symbolEffect(.replace))
            TransportButton(symbol: "forward.fill", size: 14, isEnabled: player.canGoNext) {
                player.next()
            }
            if !compact {
                TransportButton(symbol: player.repeatMode.symbol, size: 12,
                                isActive: player.repeatMode.isActive) {
                    player.cycleRepeat()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    private var accessories: some View {
        HStack(spacing: 2) {
            if !narrow {
                LikeButton(size: 13)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            TransportButton(symbol: "quote.bubble", size: 13,
                            isEnabled: player.hasTrack, isActive: router.panel == .lyrics) {
                router.toggle(.lyrics)
            }
            .help("Lyrics")
            TransportButton(symbol: "list.bullet", size: 13, isActive: router.panel == .queue) {
                router.toggle(.queue)
            }
            .help("Playing Next")
            if !tight {
                VolumeButton()
                    .transition(.opacity)
            }
        }
    }
}

/// Artwork, title and progress. Hovering swaps the artist line for a scrubber, the way
/// Music.app's display does.
struct NowPlayingDisplay: View {
    @Environment(PlayerController.self) private var player
    @Environment(Router.self) private var router

    @State private var hovering = false

    var body: some View {
        Group {
            if player.hasTrack {
                HStack(spacing: 9) {
                    ZStack {
                        // A new song's artwork slides up in place of the last one's.
                        Artwork(url: player.current?.artwork, cornerRadius: 5)
                            .id(player.current?.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .animation(Motion.snappy, value: player.current?.id)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(player.current?.title ?? "")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .contentTransition(.opacity)
                                .animation(Motion.snappy, value: player.current?.id)
                            if player.current?.isExplicit == true { ExplicitBadge() }
                        }

                        if hovering {
                            scrubber
                        } else {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { router.showFullScreenPlayer = true }
                .help("Open the full-screen player")
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .onHover { hovering = $0 && player.hasTrack }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    private var subtitle: String {
        guard let track = player.current else { return "" }
        let album = track.album?.name ?? player.queueSource ?? ""
        return [track.artistLine, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var scrubber: some View {
        HStack(spacing: 6) {
            PlaybackTime(kind: .elapsed)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            PlaybackSlider(trackHeight: 3)

            PlaybackTime(kind: .remaining)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
        }
    }
}

/// Speaker icon that opens a volume slider, as Music.app does in the pill.
struct VolumeButton: View {
    @Environment(PlayerController.self) private var player
    @State private var showing = false

    private var symbol: String {
        if player.isMuted || player.volume < 0.01 { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1.fill" }
        if player.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        TransportButton(symbol: symbol, size: 13) { showing.toggle() }
            .popover(isPresented: $showing, arrowEdge: .top) {
                VolumeSlider().padding(14)
            }
    }
}

struct VolumeSlider: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .onTapGesture { player.toggleMute() }

            ProgressSlider(value: $player.volume, accent: .primary, trackHeight: 4)
                .frame(width: 120)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
