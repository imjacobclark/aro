import Foundation
import XCTest
@testable import Sonora

final class LibraryModelsTests: XCTestCase {
    func testAggregateDeduplicatesCanonicalSongURLs() {
        let idA = UUID()
        let idB = UUID()
        let sharedURL = URL(fileURLWithPath: "/Music/Shared.mp3")
        let sharedSong = Song(
            url: sharedURL,
            title: "Shared",
            artist: "Artist",
            duration: 90
        )
        let uniqueSong = Song(
            url: URL(fileURLWithPath: "/Music/Unique.mp3"),
            title: "Unique",
            artist: "Artist",
            duration: 120
        )

        let songs = SongLibrary.aggregate([
            idA: [sharedSong],
            idB: [sharedSong, uniqueSong]
        ])

        XCTAssertEqual(songs.map(\.title), ["Shared", "Unique"])
    }

    func testDurationFormatting() {
        XCTAssertEqual(makeSong(duration: 185).formattedDuration, "3:05")
        XCTAssertEqual(makeSong(duration: 3_661).formattedDuration, "1:01:01")
        XCTAssertEqual(makeSong(duration: nil).formattedDuration, "—")
    }

    func testLibrarySummaryFormatsCountDurationAndAdaptiveFileSize() {
        let songs = [
            makeSong(duration: 185, fileSizeBytes: 750_000_000),
            makeSong(duration: 125, fileSizeBytes: 750_000_000)
        ]

        XCTAssertEqual(
            LibrarySummary(songs: songs).formatted,
            "2 songs, 5 mins, 1.5 gb"
        )
    }

    func testLibrarySummaryUsesSingularSongAndTerabytes() {
        let summary = LibrarySummary(
            songs: [
                makeSong(
                    duration: 60,
                    fileSizeBytes: 1_200_000_000_000
                )
            ]
        )

        XCTAssertEqual(summary.formatted, "1 song, 1 mins, 1.2 tb")
    }

    func testNormalizationGainIsCappedByPeakCeiling() {
        let analysis = LoudnessAnalysis(
            integratedLUFS: -20,
            peakAmplitude: 0.9
        )

        let gain = analysis.safeGainDecibels(targetLUFS: -14)

        XCTAssertLessThan(gain, 0)
        XCTAssertEqual(gain, -0.0848501888, accuracy: 0.0001)
    }

    func testNormalizationReachesTargetWhenHeadroomAllows() {
        let analysis = LoudnessAnalysis(
            integratedLUFS: -18,
            peakAmplitude: 0.25
        )

        XCTAssertEqual(analysis.safeGainDecibels(targetLUFS: -14), 4)
    }

    func testAudioDeviceSupportsEveryRateInsideAdvertisedRanges() {
        let device = AudioOutputDevice(
            id: 1,
            uid: "test",
            name: "Test Device",
            sampleRateRanges: [
                AudioSampleRateRange(minimum: 22_050, maximum: 64_000),
                AudioSampleRateRange(minimum: 88_200, maximum: 192_000)
            ]
        )

        XCTAssertTrue(device.supports(sampleRate: 22_050))
        XCTAssertTrue(device.supports(sampleRate: 32_000))
        XCTAssertTrue(device.supports(sampleRate: 64_000))
        XCTAssertTrue(device.supports(sampleRate: 96_000))
        XCTAssertFalse(device.supports(sampleRate: 80_000))
        XCTAssertEqual(
            device.nearestSupportedSampleRate(to: 80_000),
            64_000
        )
    }

    private func makeSong(
        duration: TimeInterval?,
        fileSizeBytes: Int64? = nil
    ) -> Song {
        Song(
            url: URL(fileURLWithPath: "/Music/Test.mp3"),
            title: "Test",
            artist: "Artist",
            duration: duration,
            fileSizeBytes: fileSizeBytes
        )
    }
}
