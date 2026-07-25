import Foundation
import SonoraCommon

@MainActor
final class UnavailableAudioPlaybackEngine: AudioPlaybackEngine {
    var eventHandler: (@MainActor @Sendable (PlaybackEngineEvent) -> Void)?
    var levelHandler: (@MainActor @Sendable ([Double]) -> Void)?
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var outputStatus = PlaybackOutputStatus()

    func load(
        songs: [Song],
        startingAt index: Int,
        from time: TimeInterval,
        playbackID: UUID
    ) throws -> TimeInterval {
        throw PlaybackEngineError.engineFailedToStart(
            "No playback engine was configured."
        )
    }

    func play() throws {
        throw PlaybackEngineError.engineFailedToStart(
            "No playback engine was configured."
        )
    }

    func pause() {}

    func seek(
        to time: TimeInterval,
        playbackID: UUID,
        shouldPlay: Bool
    ) throws {
        currentTime = time
    }

    func stop() {
        currentTime = 0
    }
}
