import Foundation

@main
enum LibraryHealthDomainChecks {
    static func main() throws {
        try exactDuplicates()
        movedAndMissing()
        try alternateEncodings()
        unknownMetadataDoesNotMatch()
        reviewLibraryHealthUsesBoundary()
        print("Library health domain checks passed")
    }

    private static func exactDuplicates() throws {
        let trackID = UUID()
        let report = LibraryHealthAnalyzer().analyze([
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

        let recommendation = try require(
            report.exactDuplicates.first,
            "Expected an exact-duplicate recommendation"
        )
        check(
            recommendation.id == "exact:same-bytes",
            "Exact duplicate ID changed"
        )
        check(
            recommendation.copies.map(\.path)
                == ["/Music/A.flac", "/Music/B.flac"],
            "Exact duplicates are no longer ordered by path on a tie"
        )
        check(
            recommendation.preferredCopyID
                == recommendation.copies.first?.id,
            "Exact duplicate preferred copy changed"
        )
        check(
            recommendation.potentialSavingsBytes == 2_000,
            "Exact duplicate savings changed"
        )
    }

    private static func movedAndMissing() {
        let movedID = UUID()
        let missingID = UUID()
        let report = LibraryHealthAnalyzer().analyze([
            LibraryHealthTrack(
                id: movedID,
                contentHash: nil,
                title: "Moved",
                artist: "Artist",
                duration: 120,
                copies: [
                    copy(trackID: movedID, path: "/Music/New.flac"),
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

        check(
            report.movedFiles.map(\.title) == ["Moved"],
            "Moved-file classification changed"
        )
        check(
            report.missingFiles.map(\.title) == ["Missing"],
            "Missing-file classification changed"
        )
    }

    private static func alternateEncodings() throws {
        let losslessID = UUID()
        let lossyID = UUID()
        let report = LibraryHealthAnalyzer().analyze([
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

        let recommendation = try require(
            report.alternateEncodings.first,
            "Expected an alternate-encoding recommendation"
        )
        check(
            recommendation.copies.map(\.codec) == ["FLAC", "MP3"],
            "Alternate copy quality preference changed"
        )
        check(
            recommendation.preferredCopyID
                == recommendation.copies.first?.id,
            "Alternate preferred copy changed"
        )
        check(
            recommendation.potentialSavingsBytes == 8_000,
            "Alternate savings changed"
        )
    }

    private static func unknownMetadataDoesNotMatch() {
        let firstID = UUID()
        let secondID = UUID()
        let report = LibraryHealthAnalyzer().analyze([
            LibraryHealthTrack(
                id: firstID,
                contentHash: nil,
                title: "Unknown Track",
                artist: "Unknown Artist",
                duration: 180,
                copies: [
                    copy(trackID: firstID, path: "/Music/A.flac")
                ]
            ),
            LibraryHealthTrack(
                id: secondID,
                contentHash: nil,
                title: "Unknown Track",
                artist: "Unknown Artist",
                duration: 180,
                copies: [
                    copy(
                        trackID: secondID,
                        path: "/Music/B.mp3",
                        codec: "MP3"
                    )
                ]
            )
        ])

        check(
            report.alternateEncodings.isEmpty,
            "Unknown metadata created an alternate match"
        )
    }

    private static func reviewLibraryHealthUsesBoundary() {
        let trackID = UUID()
        let result = ReviewLibraryHealth(
            tracks: StubTracks(
                tracks: [
                    LibraryHealthTrack(
                        id: trackID,
                        contentHash: nil,
                        title: "Track",
                        artist: "Artist",
                        duration: 180,
                        copies: [
                            copy(
                                trackID: trackID,
                                path: "/Music/Missing.flac",
                                available: false
                            )
                        ]
                    )
                ]
            )
        ).execute()

        check(
            result.missingFiles.map(\.id)
                == ["missing:\(trackID.uuidString)"],
            "Review use case did not analyze the boundary's tracks"
        )
    }

    private static func copy(
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

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        precondition(condition(), message)
    }

    private static func require<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else {
            throw CheckError.failed(message)
        }
        return value
    }

    private enum CheckError: Error {
        case failed(String)
    }
}

private struct StubTracks: LibraryHealthTrackQuerying {
    let tracks: [LibraryHealthTrack]

    func libraryHealthTracks() -> [LibraryHealthTrack] {
        tracks
    }
}
