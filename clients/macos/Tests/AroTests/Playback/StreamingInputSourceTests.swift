#if canImport(XCTest)
import AroStreamingInput
import AVFAudio
import Foundation
import SFBAudioEngine
import XCTest

final class StreamingInputSourceTests: XCTestCase {
    func testReadsSeeksAndReportsKnownLength() throws {
        let payload = Data("abcdefgh".utf8)
        let source = StreamingInputSource(
            url: URL(string: "https://aro.test/blob")!,
            length: Int64(payload.count)
        ) { offset, length in
            let start = Int(offset)
            let end = min(start + Int(length), payload.count)
            return payload.subdata(in: start..<end)
        }
        try source.open()
        var bytes = [UInt8](repeating: 0, count: 3)

        let firstRead = try bytes.withUnsafeMutableBytes {
            try source.read($0.baseAddress!, length: $0.count)
        }
        XCTAssertEqual(firstRead, 3)
        XCTAssertEqual(Data(bytes), Data("abc".utf8))
        XCTAssertEqual(try source.offset, 3)
        XCTAssertEqual(try source.length, payload.count)

        try source.seek(toOffset: 5)
        let secondRead = try bytes.withUnsafeMutableBytes {
            try source.read($0.baseAddress!, length: $0.count)
        }
        XCTAssertEqual(secondRead, 3)
        XCTAssertEqual(Data(bytes), Data("fgh".utf8))
        XCTAssertTrue(source.atEOF)
        try source.close()
    }

    func testDecoderFactoryUsesRegisteredDecoderConstants() throws {
        for kind in [
            StreamingDecoderKind.FLAC,
            .oggVorbis,
            .coreAudio,
        ] {
            let source = StreamingInputSource(
                url: URL(string: "https://aro.test/audio")!,
                length: 0
            ) { _, _ in Data() }

            XCTAssertNoThrow(
                try StreamingInputSource.decoder(
                    inputSource: source,
                    kind: kind
                )
            )
        }
    }

    func testCoreAudioDecoderReadsPCMFromStreamingSource() throws {
        let payload = Self.makePCMTestWAV()
        let source = StreamingInputSource(
            url: URL(string: "https://aro.test/test.wav")!,
            length: Int64(payload.count)
        ) { offset, length in
            // Clamped at both ends: CoreAudio probes past the end while identifying a
            // format, and an unclamped lower bound builds an invalid range rather than
            // reporting end-of-file.
            let start = min(max(Int(offset), 0), payload.count)
            let end = min(start + Int(length), payload.count)
            return payload.subdata(in: start..<end)
        }
        let decoder = try StreamingInputSource.decoder(
            inputSource: source,
            kind: .coreAudio
        )
        try decoder.open()
        defer { try? decoder.close() }
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: decoder.processingFormat,
                frameCapacity: 64
            )
        )

        try decoder.decode(into: buffer, length: 64)

        XCTAssertGreaterThan(buffer.frameLength, 0)
    }

    private static func makePCMTestWAV() -> Data {
        // A tenth of a second rather than 128 frames. CoreAudio reads well beyond the
        // header to identify a format, and a 300-byte file left it hitting end-of-file
        // and reporting the format as unrecognised.
        let frameCount: UInt32 = 4_410
        let sampleRate: UInt32 = 44_100
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataByteCount = frameCount
            * UInt32(channelCount)
            * UInt32(bitsPerSample / 8)
        var data = Data()

        func appendASCII(_ value: String) {
            data.append(contentsOf: value.utf8)
        }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                data.append(contentsOf: $0)
            }
        }

        appendASCII("RIFF")
        appendLE(UInt32(36) + dataByteCount)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(channelCount)
        appendLE(sampleRate)
        appendLE(
            sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        )
        appendLE(channelCount * (bitsPerSample / 8))
        appendLE(bitsPerSample)
        appendASCII("data")
        appendLE(dataByteCount)
        data.append(
            Data(
                repeating: 0,
                count: Int(dataByteCount)
            )
        )
        return data
    }
}
#endif
