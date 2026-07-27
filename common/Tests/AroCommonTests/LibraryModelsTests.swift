#if canImport(XCTest)
import Foundation
import XCTest
@testable import AroCommon

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

    func testArtistLibraryGroupsAlbumsAndBucketsMissingMetadata() {
        let artwork = Data([1, 2, 3])
        let songs = [
            Song(
                url: URL(fileURLWithPath: "/Music/One.flac"),
                title: "One",
                artist: "Massive Attack",
                album: "Mezzanine",
                artworkData: artwork,
                duration: 180
            ),
            Song(
                url: URL(fileURLWithPath: "/Music/Two.flac"),
                title: "Two",
                artist: "massive attack",
                album: "Mezzanine",
                duration: 240
            ),
            Song(
                url: URL(fileURLWithPath: "/Music/Unknown.flac"),
                title: "Unknown",
                artist: "—",
                duration: 60
            )
        ]

        let artists = ArtistLibrary.artists(from: songs)

        XCTAssertEqual(artists.map(\.name), ["Massive Attack", "Unknown Artist"])
        XCTAssertEqual(artists[0].albums.map(\.name), ["Mezzanine"])
        XCTAssertEqual(artists[0].albums[0].songs.map(\.title), ["One", "Two"])
        XCTAssertEqual(artists[0].albums[0].artworkData, artwork)
        XCTAssertEqual(artists[0].summary, "1 album, 2 songs, 7 mins")
        XCTAssertEqual(artists[1].albums.first?.name, "Unknown Album")
    }

    func testAlbumLibraryGroupsByAlbumAndArtist() {
        let artwork = Data([4, 5, 6])
        let songs = [
            Song(
                url: URL(fileURLWithPath: "/Music/A.flac"),
                title: "A",
                artist: "Portishead",
                album: "Dummy",
                artworkData: artwork,
                duration: 180
            ),
            Song(
                url: URL(fileURLWithPath: "/Music/B.flac"),
                title: "B",
                artist: "portishead",
                album: "dummy",
                duration: 240
            ),
            Song(
                url: URL(fileURLWithPath: "/Music/Other.flac"),
                title: "Other",
                artist: "Another Artist",
                album: "Dummy",
                duration: 60
            )
        ]

        let albums = AlbumLibrary.albums(from: songs)

        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums.map(\.name), ["Dummy", "Dummy"])
        XCTAssertEqual(albums.map(\.artistName), ["Another Artist", "Portishead"])
        XCTAssertEqual(albums[1].songs.map(\.title), ["A", "B"])
        XCTAssertEqual(albums[1].artworkData, artwork)
        XCTAssertEqual(albums[1].summary, "Portishead · 2 songs · 7 mins")
    }

    func testFuzzySearchMatchesSubsequencesAndMultipleTokens() {
        XCTAssertTrue(FuzzySearch.matches("prtshd", in: "Portishead"))
        XCTAssertTrue(FuzzySearch.matches("dum por", in: "Dummy Portishead"))
        XCTAssertTrue(FuzzySearch.matches("bjork", in: "Björk"))
        XCTAssertFalse(FuzzySearch.matches("radio", in: "Portishead"))
        XCTAssertTrue(FuzzySearch.matches("", in: "Anything"))
    }

    func testLibrarySummaryFormatsCountDurationAndAdaptiveFileSize() {
        let songs = [
            makeSong(duration: 185, fileSizeBytes: 750_000_000),
            makeSong(duration: 125, fileSizeBytes: 750_000_000)
        ]

        XCTAssertEqual(
            LibrarySummary(songs: songs).formatted,
            "2 songs, 5 mins, 1.5 GB"
        )
    }

    func testLibrarySummaryUsesSingularSongAndTerabytes() {
        let summary = LibrarySummary(
            songs: [makeSong(duration: 60, fileSizeBytes: 1_200_000_000_000)]
        )

        XCTAssertEqual(summary.formatted, "1 song, 1 min, 1.2 TB")
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
            88_200
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
#endif
