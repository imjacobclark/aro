#if canImport(Testing)
import Foundation
import Testing
@testable import SonoraCommon

@Suite("Library health analysis")
struct LibraryHealthAnalyzerTests {
    private let analyzer = LibraryHealthAnalyzer()

    @Test("Exact duplicates retain path preference and calculate savings")
    func exactDuplicates() throws {
        let trackID = UUID()
        let report = analyzer.analyze([
            LibraryHealthTrack(
                id: trackID,
                contentHash: "same-bytes",
                title: "Track",
                artist: "Artist",
                duration: 180,
                copies: [
                    copy(
                        trackID: trackID,
                        path: "/Music/B.flac",
                        fileSize: 2_000
                    ),
                    copy(
                        trackID: trackID,
                        path: "/Music/A.flac",
                        fileSize: 1_000
                    )
                ]
            )
        ])

        let recommendation = try #require(report.exactDuplicates.first)
        #expect(recommendation.id == "exact:same-bytes")
        #expect(recommendation.copies.map(\.path) == [
            "/Music/A.flac",
            "/Music/B.flac"
        ])
        #expect(
            recommendation.preferredCopyID
                == recommendation.copies.first?.id
        )
        #expect(recommendation.potentialSavingsBytes == 2_000)
    }

    @Test("Current and former locations are moved; former-only is missing")
    func movedAndMissing() {
        let movedID = UUID()
        let missingID = UUID()
        let report = analyzer.analyze([
            LibraryHealthTrack(
                id: movedID,
                contentHash: nil,
                title: "Moved",
                artist: "Artist",
                duration: 120,
                copies: [
                    copy(
                        trackID: movedID,
                        path: "/Music/New.flac"
                    ),
                    copy(
                        trackID: movedID,
                        path: "/Music/Old.flac",
                        available: false
                    )
                ]
            ),
            LibraryHealthTrack(
                id: missingID,
                contentHash: nil,
                title: "Missing",
                artist: "Artist",
                duration: 120,
                copies: [
                    copy(
                        trackID: missingID,
                        path: "/Music/Gone.flac",
                        available: false
                    )
                ]
            )
        ])

        #expect(report.movedFiles.map(\.title) == ["Moved"])
        #expect(report.missingFiles.map(\.title) == ["Missing"])
    }

    @Test("Alternate encodings prefer the highest-quality available copy")
    func alternateEncodings() throws {
        let losslessID = UUID()
        let lossyID = UUID()
        let report = analyzer.analyze([
            LibraryHealthTrack(
                id: lossyID,
                contentHash: "lossy",
                title: "Déjà Vu",
                artist: "Beyoncé",
                duration: 240,
                copies: [
                    copy(
                        trackID: lossyID,
                        path: "/Music/Track.mp3",
                        codec: "MP3",
                        bitrate: 320_000,
                        fileSize: 8_000
                    )
                ]
            ),
            LibraryHealthTrack(
                id: losslessID,
                contentHash: "lossless",
                title: "Deja Vu",
                artist: "Beyonce",
                duration: 241.5,
                copies: [
                    copy(
                        trackID: losslessID,
                        path: "/Music/Track.flac",
                        codec: "FLAC",
                        sampleRate: 96_000,
                        bitDepth: 24,
                        fileSize: 80_000
                    )
                ]
            )
        ])

        let recommendation = try #require(
            report.alternateEncodings.first
        )
        #expect(recommendation.copies.map(\.codec) == ["FLAC", "MP3"])
        #expect(
            recommendation.preferredCopyID
                == recommendation.copies.first?.id
        )
        #expect(recommendation.potentialSavingsBytes == 8_000)
    }

    @Test("Unknown metadata never creates alternate matches")
    func unknownMetadataDoesNotMatch() {
        let report = analyzer.analyze([
            LibraryHealthTrack(
                id: UUID(),
                contentHash: nil,
                title: "Unknown Track",
                artist: "Unknown Artist",
                duration: 180,
                copies: [
                    copy(
                        trackID: UUID(),
                        path: "/Music/A.flac"
                    )
                ]
            ),
            LibraryHealthTrack(
                id: UUID(),
                contentHash: nil,
                title: "Unknown Track",
                artist: "Unknown Artist",
                duration: 180,
                copies: [
                    copy(
                        trackID: UUID(),
                        path: "/Music/B.mp3",
                        codec: "MP3"
                    )
                ]
            )
        ])

        #expect(report.alternateEncodings.isEmpty)
    }

    private func copy(
        trackID: UUID,
        path: String,
        available: Bool = true,
        codec: String = "FLAC",
        sampleRate: Double? = 44_100,
        bitDepth: Int? = 16,
        bitrate: Double? = nil,
        fileSize: Int64 = 1_000
    ) -> LibraryHealthCopy {
        LibraryHealthCopy(
            trackID: trackID,
            path: path,
            isAvailable: available,
            codec: codec,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            bitrate: bitrate,
            fileSizeBytes: fileSize
        )
    }
}

@Suite("Review library health")
struct ReviewLibraryHealthTests {
    @Test("The use case analyzes tracks supplied by its query boundary")
    func executesQuery() {
        let trackID = UUID()
        let useCase = ReviewLibraryHealth(
            tracks: StubLibraryHealthTracks(
                tracks: [
                    LibraryHealthTrack(
                        id: trackID,
                        contentHash: nil,
                        title: "Track",
                        artist: "Artist",
                        duration: 180,
                        copies: [
                            LibraryHealthCopy(
                                trackID: trackID,
                                path: "/Music/Missing.flac",
                                isAvailable: false,
                                codec: "FLAC",
                                sampleRate: 44_100,
                                bitDepth: 16,
                                bitrate: nil,
                                fileSizeBytes: 1_000
                            )
                        ]
                    )
                ]
            )
        )

        let result = useCase.execute()

        #expect(
            result.missingFiles.map(\.id)
                == ["missing:\(trackID.uuidString)"]
        )
    }
}

private struct StubLibraryHealthTracks: LibraryHealthTrackQuerying {
    let tracks: [LibraryHealthTrack]

    func libraryHealthTracks() -> [LibraryHealthTrack] {
        tracks
    }
}
#endif
