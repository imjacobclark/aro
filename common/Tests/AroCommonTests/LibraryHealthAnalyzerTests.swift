#if canImport(Testing)
import Foundation
import Testing
@testable import AroCommon

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

    @Test("A folder whose tracks span several albums is reported, even when its dominant artist owns other, fully-converged folders")
    func fragmentedFolderIsReported() {
        // Four tracks in the same folder, split across two album values -- the
        // convergence failure this check exists to catch. A second, unrelated folder for
        // the same artist is fully converged and must not itself be flagged (this is what
        // proves the check is folder-keyed, not artist-keyed -- an artist legitimately
        // spanning several albums, each in its own folder, is not a problem).
        var tracks = (1...4).map { index in
            albumTrack(
                title: "Track \(index)",
                artist: "The Beatles",
                album: index <= 2 ? "1" : "The Beatles",
                path: "/Music/The Beatles/1/\(index).m4a"
            )
        }
        tracks += (1...3).map { index in
            albumTrack(
                title: "AM Track \(index)",
                artist: "Arctic Monkeys",
                album: "AM",
                path: "/Music/Arctic Monkeys/AM/\(index).m4a"
            )
        }

        let report = analyzer.analyze(tracks)

        #expect(report.fragmentedFolders.map(\.title) == ["1"])
        #expect(report.fragmentedFolders.first?.artist == "The Beatles")
    }

    @Test("A folder converged on a single album is not reported")
    func convergedFolderIsNotReported() {
        let tracks = (1...5).map { index in
            albumTrack(
                title: "Track \(index)",
                artist: "Arctic Monkeys",
                album: "AM",
                path: "/Music/Arctic Monkeys/AM/\(index).m4a"
            )
        }

        let report = analyzer.analyze(tracks)

        #expect(report.fragmentedFolders.isEmpty)
    }

    @Test("A folder below the minimum track count is not reported even if its albums differ")
    func folderBelowTrackThresholdIsNotReported() {
        let tracks = [
            albumTrack(title: "A", artist: "Artist", album: "Album 1", path: "/Music/Folder/a.m4a"),
            albumTrack(title: "B", artist: "Artist", album: "Album 2", path: "/Music/Folder/b.m4a"),
            albumTrack(title: "C", artist: "Artist", album: "Album 3", path: "/Music/Folder/c.m4a")
        ]

        let report = analyzer.analyze(tracks)

        #expect(report.fragmentedFolders.isEmpty)
    }

    @Test("Tracks with no album yet don't count as their own distinct album value")
    func unidentifiedAlbumIsNotCounted() {
        // Four tracks in one folder: two share "AM", two have no album at all (not yet
        // identified). This must NOT be reported as 3 albums (AM + two distinct "unknowns")
        // -- an unidentified track is "no signal", not evidence of fragmentation.
        let tracks = [
            albumTrack(title: "A", artist: "Artist", album: "AM", path: "/Music/Folder/a.m4a"),
            albumTrack(title: "B", artist: "Artist", album: "AM", path: "/Music/Folder/b.m4a"),
            albumTrack(title: "C", artist: "Artist", album: nil, path: "/Music/Folder/c.m4a"),
            albumTrack(title: "D", artist: "Artist", album: nil, path: "/Music/Folder/d.m4a")
        ]

        let report = analyzer.analyze(tracks)

        #expect(report.fragmentedFolders.isEmpty)
    }

    private func albumTrack(
        title: String,
        artist: String,
        album: String?,
        path: String
    ) -> LibraryHealthTrack {
        let trackID = UUID()
        return LibraryHealthTrack(
            id: trackID,
            contentHash: path,
            title: title,
            artist: artist,
            album: album,
            duration: 180,
            copies: [copy(trackID: trackID, path: path)]
        )
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
    func executesQuery() async {
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

        let result = await useCase.execute()

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
