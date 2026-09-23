import AppKit
import MediaPlayer

/// Publishes the current track to Control Center / the Now Playing widget and routes
/// the hardware media keys back into `PlayerController`.
///
/// There are two paths a media key can take here. The system may deliver it to us
/// directly through `MPRemoteCommandCenter`, or — because the audio is genuinely coming
/// out of the WebKit process — WebKit may claim the Now Playing session and deliver it
/// to the page instead. The injected bridge forwards that second case back to us, so
/// both routes end up in the same place.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    private var installed = false
    private var lastTrackId: String?
    private var artworkTask: Task<Void, Never>?

    /// What Control Center was last told. The system advances the elapsed time on its own
    /// from the playback rate, so re-sending everything on each bridge report (twice a
    /// second) is wasted work; only a change, or real drift such as a seek, is published.
    private var published: (trackId: String, playing: Bool, duration: Double, position: Double, at: Date)?

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        let center = MPRemoteCommandCenter.shared()
        let player = PlayerController.shared

        center.playCommand.addTarget { _ in player.play(); return .success }
        center.pauseCommand.addTarget { _ in player.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in player.toggle(); return .success }
        center.nextTrackCommand.addTarget { _ in player.next(); return .success }
        center.previousTrackCommand.addTarget { _ in player.previous(); return .success }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player.seek(to: e.positionTime)
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in player.skipForward(); return .success }
        center.skipBackwardCommand.addTarget { _ in player.skipBackward(); return .success }

        for command in [center.seekForwardCommand, center.seekBackwardCommand,
                        center.changeShuffleModeCommand, center.changeRepeatModeCommand] {
            command.isEnabled = false
        }
    }

    func update(from player: PlayerController) {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = player.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lastTrackId = nil
            published = nil
            return
        }

        if let last = published, last.trackId == track.id,
           last.playing == player.isPlaying, last.duration == player.duration {
            let expected = last.position + (last.playing ? Date.now.timeIntervalSince(last.at) : 0)
            if abs(expected - player.position) < 1.5 { return }
        }

        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artistLine
        info[MPMediaItemPropertyAlbumTitle] = track.album?.name ?? player.queueSource ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        if track.id != lastTrackId {
            lastTrackId = track.id
            info[MPMediaItemPropertyArtwork] = nil
            loadArtwork(for: track)
            // Mirror onto the page's Media Session too, so Control Center still shows the
            // right track in the case where WebKit owns the system session.
            Task {
                await WebEngine.shared.setPageMetadata(
                    title: track.title,
                    artist: track.artistLine,
                    album: track.album?.name ?? "",
                    artwork: track.artwork?.absoluteString)
            }
        }

        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
        published = (track.id, player.isPlaying, player.duration, player.position, .now)
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        guard let url = track.artwork else { return }
        artworkTask = Task { [weak self] in
            guard let image = await ImageCache.shared.image(Parse.upscaled(url, to: 600), pixels: 600),
                  !Task.isCancelled,
                  self?.lastTrackId == track.id else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
