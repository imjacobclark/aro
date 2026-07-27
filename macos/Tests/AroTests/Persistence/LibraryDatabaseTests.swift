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
        recorder.endSession(sessionID: sessionID, completed: true)

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

    private func makeSong(path: String, contentHash: String) -> Song {
        Song(
            url: URL(fileURLWithPath: path),
            title: "Track",
            artist: "Artist",
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
