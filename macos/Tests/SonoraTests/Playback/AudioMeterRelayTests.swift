#if canImport(XCTest)
import AVFAudio
import XCTest
@testable import Sonora

@MainActor
final class AudioMeterRelayTests: XCTestCase {
    func testCoalescesRapidAudioCallbacksIntoOneDelivery() async throws {
        let deliveries = DeliveryCounter()
        let relay = AudioMeterRelay { _ in
            deliveries.value += 1
        }
        let buffer = try makeBuffer()

        for _ in 0..<100 {
            relay.process(buffer)
        }

        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(deliveries.value, 1)
        relay.invalidate()
    }

    func testInvalidationDropsScheduledDelivery() async throws {
        let deliveries = DeliveryCounter()
        let relay = AudioMeterRelay { _ in
            deliveries.value += 1
        }

        relay.process(try makeBuffer())
        relay.invalidate()

        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(deliveries.value, 0)
    }

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 2
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)
        )
        buffer.frameLength = 1_024
        return buffer
    }
}

@MainActor
private final class DeliveryCounter {
    var value = 0
}
#endif
