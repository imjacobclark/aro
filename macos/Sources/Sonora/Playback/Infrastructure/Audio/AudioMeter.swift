import SonoraCommon

import AVFAudio

final class AudioMeterRelay: @unchecked Sendable {
    private let handler: @MainActor @Sendable ([Double]) -> Void

    init(handler: @escaping @MainActor @Sendable ([Double]) -> Void) {
        self.handler = handler
    }

    nonisolated func process(_ buffer: AVAudioPCMBuffer) {
        let levels = meterLevels(from: buffer, barCount: 9)
        Task { @MainActor [handler] in
            handler(levels)
        }
    }
}

nonisolated func makeAudioMeterTapBlock(
    relay: AudioMeterRelay
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        relay.process(buffer)
    }
}

private func meterLevels(
    from buffer: AVAudioPCMBuffer,
    barCount: Int
) -> [Double] {
    guard barCount > 0,
          let channelData = buffer.floatChannelData,
          buffer.frameLength > 0 else {
        return Array(repeating: 0, count: max(barCount, 0))
    }

    let frameCount = Int(buffer.frameLength)
    let channelCount = max(Int(buffer.format.channelCount), 1)

    return (0..<barCount).map { bar in
        let start = frameCount * bar / barCount
        let end = max(frameCount * (bar + 1) / barCount, start + 1)
        var sumOfSquares = 0.0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in start..<min(end, frameCount) {
                let sample = Double(samples[frame])
                sumOfSquares += sample * sample
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return 0
        }

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        // Keep normal programme material close to the core and reserve the
        // outer radius for strong transients.
        let normalized = min(max((decibels + 36) / 33, 0), 1)
        return pow(normalized, 2.2)
    }
}
