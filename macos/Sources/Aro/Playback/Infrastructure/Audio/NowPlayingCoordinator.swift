import Foundation
import MediaPlayer

@MainActor
final class NowPlayingCoordinator {
    private weak var playback: PlaybackController?

    init() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.handlePlay() ?? .noSuchContent
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlePause() ?? .noSuchContent
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTogglePlayPause() ?? .noSuchContent
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleNext() ?? .noSuchContent
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handlePrevious() ?? .noSuchContent
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            self?.handleChangePlaybackPosition(event) ?? .noSuchContent
        }
    }

    func rebind(to playback: PlaybackController) {
        self.playback = playback
    }

    private func handlePlay() -> MPRemoteCommandHandlerStatus {
        guard let playback, playback.canTogglePlayback else {
            return .noSuchContent
        }
        if !playback.isPlaying {
            playback.togglePlayPause()
        }
        return .success
    }

    private func handlePause() -> MPRemoteCommandHandlerStatus {
        guard let playback, playback.canTogglePlayback else {
            return .noSuchContent
        }
        if playback.isPlaying {
            playback.togglePlayPause()
        }
        return .success
    }

    private func handleTogglePlayPause() -> MPRemoteCommandHandlerStatus {
        guard let playback, playback.canTogglePlayback else {
            return .noSuchContent
        }
        playback.togglePlayPause()
        return .success
    }

    private func handleNext() -> MPRemoteCommandHandlerStatus {
        guard let playback, playback.canGoNext else {
            return .noSuchContent
        }
        playback.next()
        return .success
    }

    private func handlePrevious() -> MPRemoteCommandHandlerStatus {
        guard let playback else {
            return .noSuchContent
        }
        playback.previous()
        return .success
    }

    private func handleChangePlaybackPosition(
        _ event: MPRemoteCommandEvent
    ) -> MPRemoteCommandHandlerStatus {
        guard let playback,
              let positionEvent = event as? MPChangePlaybackPositionCommandEvent
        else {
            return .noSuchContent
        }
        playback.seek(to: positionEvent.positionTime)
        return .success
    }
}
