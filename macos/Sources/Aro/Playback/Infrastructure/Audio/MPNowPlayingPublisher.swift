import AroCommon
import Foundation
import MediaPlayer

final class MPNowPlayingPublisher: NowPlayingPublishing, Sendable {
    init() {}

    func publish(
        song: Song?,
        elapsedTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.nowPlayingInfo(
            song: song,
            elapsedTime: elapsedTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    static func nowPlayingInfo(
        song: Song?,
        elapsedTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) -> [String: Any]? {
        guard let song else {
            return nil
        }
        return [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }
}
