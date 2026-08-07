#if canImport(XCTest)
import Foundation
import AroCommon
import XCTest
@testable import Aro

final class LibraryDatabaseTests: XCTestCase {
    func testReconcileKeepsStableIdentityAcrossMovedCopies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )

        let original = makeSong(
            path: directory.appendingPathComponent("Original.flac").path,
            contentHash: "same-audio"
        )
        let originalResult = database.reconcile(
            songs: [original],
            folderID: folderID
        )
        let originalID = try XCTUnwrap(originalResult.first?.libraryID)

        let moved = makeSong(
            path: directory.appendingPathComponent("Moved.flac").path,
            contentHash: "same-audio"
        )
        let movedResult = database.reconcile(
            songs: [moved],
            folderID: folderID
        )

        XCTAssertEqual(movedResult.first?.libraryID, originalID)
        XCTAssertEqual(database.songs(folderID: folderID).count, 1)
    }

    func testReconcileKeepsStableIdentityWhenFileAtPathIsEdited() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let path = directory.appendingPathComponent("Edited.flac").path
        let original = try XCTUnwrap(
            database.reconcile(
                songs: [makeSong(path: path, contentHash: "first-hash")],
                folderID: folderID
            ).first
        )
        let edited = try XCTUnwrap(
            database.reconcile(
                songs: [makeSong(path: path, contentHash: "second-hash")],
                folderID: folderID
            ).first
        )
        XCTAssertEqual(edited.libraryID, original.libraryID)
        XCTAssertEqual(edited.fileFingerprint?.contentHash, "second-hash")
    }

    func testLoudnessAndHiddenStateSurviveReopeningDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Library.sqlite3")
        let database = LibraryDatabase(url: databaseURL)
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let song = makeSong(
            path: directory.appendingPathComponent("Track.flac").path,
            contentHash: "track-hash"
        )
        let storedSong = try XCTUnwrap(
            database.reconcile(songs: [song], folderID: folderID).first
        )
        SQLiteLoudnessAnalysisRepository(database: database).save(
            LoudnessAnalysis(integratedLUFS: -16, peakAmplitude: 0.8),
            fingerprint: "track-hash"
        )

        let reopened = LibraryDatabase(url: databaseURL)
        XCTAssertEqual(
            SQLiteLoudnessAnalysisRepository(database: reopened).analysis(
                fingerprint: "track-hash",
                algorithmVersion: LoudnessAnalysis.algorithmVersion
            )?.integratedLUFS,
            -16
        )

        try SQLiteTrackStateRepository(database: reopened).setHidden(
            trackID: storedSong.libraryID,
            hidden: true
        )
        XCTAssertTrue(reopened.songs(folderID: folderID).isEmpty)
    }

    func testLibraryAndListeningStatsArePersisted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Library.sqlite3")
        let database = LibraryDatabase(url: databaseURL)
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let source = makeSong(
            path: directory.appendingPathComponent("Track.flac").path,
            contentHash: "stats-track"
        )
        let track = try XCTUnwrap(
            database.reconcile(songs: [source], folderID: folderID).first
        )

        let recorder = SQLiteListeningHistoryRecorder(database: database)
        let sessionID = recorder.beginSession(
            trackID: track.libraryID
        )
        Thread.sleep(forTimeInterval: 0.02)
        recorder.endSession(sessionID: sessionID, completed: true, skipped: false)

        let reopened = LibraryDatabase(url: databaseURL)
        let stats = SQLiteStatsQuery(database: reopened)
        let library = stats.libraryStats()
        XCTAssertEqual(library.trackCount, 1)
        XCTAssertEqual(library.artistCount, 1)
        XCTAssertEqual(library.formats.first?.name, "FLAC")
        XCTAssertEqual(library.formats.first?.trackCount, 1)

        let listening = stats.listeningStats(now: Date())
        XCTAssertEqual(listening.loggedPlays, 1)
        XCTAssertEqual(listening.uniqueTracksPlayed, 1)
        XCTAssertEqual(listening.topTracks.first?.title, "Track")
        XCTAssertGreaterThan(listening.totalSeconds, 0)
    }

    func testArtworkIsPersistedAcrossDatabaseReopening() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Library.sqlite3")
        let folderID = UUID()
        let database = LibraryDatabase(url: databaseURL)
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let source = Song(
            url: directory.appendingPathComponent("Cover.flac"),
            title: "Cover",
            artist: "Artist",
            album: "Album",
            artworkData: Data([0x89, 0x50, 0x4E, 0x47]),
            duration: 180
        )

        _ = database.reconcile(songs: [source], folderID: folderID)
        let reopened = LibraryDatabase(url: databaseURL)

        XCTAssertEqual(
            reopened.songs(folderID: folderID).first?.artworkData,
            source.artworkData
        )
    }

    func testFavouritePersistsAndCreatesSyncOperation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Library.sqlite3")
        let folderID = UUID()
        let database = LibraryDatabase(url: databaseURL)
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let stored = try XCTUnwrap(
            database.reconcile(
                songs: [
                    makeSong(
                        path: directory
                            .appendingPathComponent("Favourite.flac").path,
                        contentHash: "favourite-track"
                    ),
                ],
                folderID: folderID
            ).first
        )

        try SQLiteTrackStateRepository(database: database).setFavourite(
            trackID: stored.libraryID,
            favourite: true
        )

        let reopened = LibraryDatabase(url: databaseURL)
        XCTAssertTrue(
            try XCTUnwrap(
                reopened.songs(folderID: folderID).first
            ).isFavourite
        )
        let favouriteOperation = SQLiteSyncOperationStore(
            database: reopened
        ).pending().last {
            $0.entityID == stored.libraryID.uuidString
                && $0.operation == "favourite"
        }
        XCTAssertEqual(favouriteOperation?.payload, "{\"favourite\":true}")
    }

    func testManualMetadataIsGoldenUntilReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let source = makeSong(
            path: directory.appendingPathComponent("Track.flac").path,
            contentHash: "golden-track"
        )
        let stored = try XCTUnwrap(
            database.reconcile(songs: [source], folderID: folderID).first
        )

        database.applyManualMetadata(
            [
                ManualMetadataEdit(field: .artist, value: "Manual Artist"),
                ManualMetadataEdit(field: .album, value: "Manual Album"),
            ],
            trackIDs: [stored.libraryID]
        )
        XCTAssertTrue(
            database.applyIdentification(
                contentHash: "golden-track",
                title: nil,
                artist: "Identified Artist",
                album: "Identified Album",
                musicbrainzRecordingID: "mbid",
                acoustidID: "aid",
                artworkData: nil
            )
        )

        let protected = try XCTUnwrap(database.songs(folderID: folderID).first)
        XCTAssertEqual(protected.artist, "Manual Artist")
        XCTAssertEqual(protected.album, "Manual Album")

        let snapshot = database.metadataSnapshot(
            song: protected,
            librarySongs: [protected]
        )
        XCTAssertTrue(
            snapshot.candidates[.artist, default: []].contains(
                MetadataCandidate(
                    value: "Identified Artist",
                    source: .identified
                )
            )
        )
        XCTAssertTrue(
            snapshot.candidates[.album, default: []].contains(
                MetadataCandidate(
                    value: "Identified Album",
                    source: .identified,
                    relatedArtist: "Identified Artist"
                )
            )
        )

        _ = database.reconcile(songs: [source], folderID: folderID)
        let rescanned = try XCTUnwrap(database.songs(folderID: folderID).first)
        XCTAssertEqual(rescanned.artist, "Manual Artist")
        XCTAssertEqual(rescanned.album, "Manual Album")

        database.resetManualMetadata(trackIDs: [stored.libraryID])
        let reset = try XCTUnwrap(database.songs(folderID: folderID).first)
        XCTAssertEqual(reset.artist, "Identified Artist")
        XCTAssertEqual(reset.album, "Identified Album")

        let metadataOperations = SQLiteSyncOperationStore(database: database)
            .pending()
            .filter { $0.entityID == stored.libraryID.uuidString }
        XCTAssertEqual(metadataOperations.map(\.operation), ["set_metadata", "reset_metadata"])
    }

    func testStreamingMetadataEditQueuesWithoutAReplicaTrackRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let trackID = UUID()

        database.queueManualMetadata(
            [ManualMetadataEdit(field: .album, value: "Offline Album")],
            trackIDs: [trackID],
            reset: false
        )

        let store = SQLiteSyncOperationStore(database: database)
        XCTAssertEqual(store.pending().count, 1)
        XCTAssertEqual(
            store.pendingManualMetadataEdits()[trackID]?.first?.value,
            "Offline Album"
        )
    }

    func testAlbumCandidatesFollowSelectedArtistAndKeepIdentifiedResult() {
        let song = makeSong(path: "/tmp/Track.flac", contentHash: "candidate-track")
        let snapshot = TrackMetadataSnapshot(
            song: song,
            effectiveValues: [.artist: "Artist A"],
            manualFields: [],
            candidates: [
                .album: [
                    MetadataCandidate(
                        value: "Album A",
                        source: .library,
                        relatedArtist: "Artist A"
                    ),
                    MetadataCandidate(
                        value: "Unrelated Album",
                        source: .library,
                        relatedArtist: "Artist B"
                    ),
                    MetadataCandidate(
                        value: "MusicBrainz Album",
                        source: .identified,
                        relatedArtist: "Artist B"
                    ),
                ],
            ]
        )

        XCTAssertEqual(
            snapshot.candidates(for: .album, selectedArtist: " artist a ")
                .map(\.value),
            ["Album A", "MusicBrainz Album"]
        )
    }

    func testManualArtworkKeepsOriginalAndIdentifiedLayersUntilReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: directory,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )
        let originalArtwork = Data([1, 2, 3])
        let identifiedArtwork = Data([4, 5, 6])
        let manualArtwork = Data([7, 8, 9])
        let source = makeSong(
            path: directory.appendingPathComponent("Artwork.flac").path,
            contentHash: "artwork-track",
            album: "Album",
            artworkData: originalArtwork
        )
        let stored = try XCTUnwrap(
            database.reconcile(songs: [source], folderID: folderID).first
        )
        XCTAssertTrue(
            database.applyIdentification(
                contentHash: "artwork-track",
                title: nil,
                artist: "Artist",
                album: "Album",
                musicbrainzRecordingID: "mbid-art",
                acoustidID: "aid-art",
                artworkData: identifiedArtwork
            )
        )
        XCTAssertEqual(
            database.songs(folderID: folderID).first?.artworkData,
            identifiedArtwork
        )

        let identifiedSong = try XCTUnwrap(database.songs(folderID: folderID).first)
        let snapshot = database.metadataSnapshot(
            song: identifiedSong,
            librarySongs: [identifiedSong]
        )
        XCTAssertTrue(
            snapshot.artworkCandidates.contains {
                $0.source == .file && $0.data == originalArtwork
            }
        )
        XCTAssertTrue(
            snapshot.artworkCandidates.contains {
                $0.source == .identified && $0.data == identifiedArtwork
            }
        )

        database.applyManualArtwork(
            ManualArtworkEdit(data: manualArtwork),
            trackIDs: [stored.libraryID]
        )
        _ = database.reconcile(songs: [source], folderID: folderID)
        XCTAssertEqual(
            database.songs(folderID: folderID).first?.artworkData,
            manualArtwork
        )

        database.resetManualMetadata(trackIDs: [stored.libraryID])
        XCTAssertEqual(
            database.songs(folderID: folderID).first?.artworkData,
            identifiedArtwork
        )
    }

    func testStreamingSnapshotKeepsServerIdentificationSuggestions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = LibraryDatabase(
            url: directory.appendingPathComponent("Library.sqlite3")
        )
        let artwork = Data([10, 11, 12])
        let song = makeSong(
            path: "https://hub.invalid/v1/blobs/track",
            contentHash: "streaming-snapshot",
            album: "Server Album",
            artworkData: artwork
        )

        let snapshot = database.metadataSnapshot(
            song: song,
            librarySongs: [song]
        )

        XCTAssertTrue(
            snapshot.candidates[.artist, default: []].contains(
                MetadataCandidate(value: "Artist", source: .identified)
            )
        )
        XCTAssertTrue(
            snapshot.artworkCandidates.contains {
                $0.source == .identified && $0.data == artwork
            }
        )
    }

    private func makeSong(
        path: String,
        contentHash: String,
        album: String? = nil,
        artworkData: Data? = nil
    ) -> Song {
        Song(
            url: URL(fileURLWithPath: path),
            title: "Track",
            artist: "Artist",
            album: album,
            artworkData: artworkData,
            duration: 180,
            fileSizeBytes: 1_024,
            audioProperties: AudioFileProperties(
                codec: "FLAC",
                sampleRate: 96_000,
                bitDepth: 24,
                channelCount: 2,
                bitrate: nil
            ),
            fileFingerprint: AudioFileFingerprint(
                standardizedPath: path,
                fileSizeBytes: 1_024,
                modificationDate: Date(timeIntervalSince1970: 1),
                contentHash: contentHash
            )
        )
    }
}
#endif
