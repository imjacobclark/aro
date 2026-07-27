import SonoraCommon

import AVFAudio
import Foundation

final class AudioMeterRelay: @unchecked Sendable {
    private struct State {
        var latestLevels: [Double]?
        var deliveryIsScheduled = false
        var isValid = true
    }

    private let handler: @MainActor @Sendable ([Double]) -> Void
    private let lock = NSLock()
    private var state = State()

    init(handler: @escaping @MainActor @Sendable ([Double]) -> Void) {
        self.handler = handler
    }

    nonisolated func process(_ buffer: AVAudioPCMBuffer) {
        let levels = meterLevels(from: buffer, barCount: 9)

        lock.lock()
        guard state.isValid else {
            lock.unlock()
            return
        }
        state.latestLevels = levels
        guard !state.deliveryIsScheduled else {
            lock.unlock()
            return
        }
        state.deliveryIsScheduled = true
        lock.unlock()

        // Audio render callbacks can arrive much faster than SwiftUI can draw.
        // Keep only the newest sample and cap UI delivery at roughly 30 Hz so
        // the main executor never accumulates an unbounded render backlog.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            self?.deliverLatest()
        }
    }

    func invalidate() {
        lock.lock()
        state.isValid = false
        state.latestLevels = nil
        lock.unlock()
    }

    @MainActor
    private func deliverLatest() {
        lock.lock()
        let levels = state.isValid ? state.latestLevels : nil
        state.latestLevels = nil
        state.deliveryIsScheduled = false
        lock.unlock()

        if let levels {
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
