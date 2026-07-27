import Foundation

@main
struct PersistenceAdapterChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "aro-persistence-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Library.sqlite3")
        let database = LibraryDatabase(url: databaseURL)
        precondition(database.isAvailable)

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
        let path = directory.appendingPathComponent("Track.flac").path
        let stored = database.reconcile(
            songs: [
                Song(
                    url: URL(fileURLWithPath: path),
                    title: "Track",
                    artist: "Artist",
                    album: "Album",
                    genre: "Electronic",
                    releaseYear: 2024,
                    duration: 120,
                    fileSizeBytes: 2_048,
                    audioProperties: AudioFileProperties(
                        codec: "FLAC",
                        sampleRate: 96_000,
                        bitDepth: 24,
                        channelCount: 2,
                        bitrate: nil
                    ),
                    fileFingerprint: AudioFileFingerprint(
                        standardizedPath: path,
                        fileSizeBytes: 2_048,
                        modificationDate: Date(timeIntervalSince1970: 1),
                        contentHash: "persistence-track"
                    )
                )
            ],
            folderID: folderID
        )
        precondition(stored.count == 1)

        let hashCache = SQLiteContentHashCache(database: database)
        precondition(
            hashCache.cachedContentHash(
                path: path,
                fileSize: 2_048,
                modificationDate: Date(timeIntervalSince1970: 1)
            ) == "persistence-track"
        )

        let loudness = SQLiteLoudnessAnalysisRepository(database: database)
        loudness.save(
            LoudnessAnalysis(
                integratedLUFS: -15,
                peakAmplitude: 0.7
            ),
            fingerprint: "persistence-track"
        )
        precondition(
            loudness.analysis(
                fingerprint: "persistence-track",
                algorithmVersion: LoudnessAnalysis.algorithmVersion
            )?.integratedLUFS == -15
        )

        let history = SQLiteListeningHistoryRecorder(database: database)
        let sessionID = history.beginSession(trackID: stored[0].libraryID)
        Thread.sleep(forTimeInterval: 0.02)
        history.endSession(sessionID: sessionID, completed: true)

        let dashboard = LoadStatsDashboard(
            stats: SQLiteStatsQuery(database: database)
        ).execute()
        precondition(dashboard.library.trackCount == 1)
        precondition(dashboard.library.formats.first?.name == "FLAC")
        precondition(dashboard.listening.loggedPlays == 1)
        precondition(dashboard.listening.topTracks.first?.title == "Track")

        try SQLiteTrackStateRepository(database: database).setHidden(
            trackID: stored[0].libraryID,
            hidden: true
        )
        precondition(database.songs(folderID: folderID).isEmpty)
        try SQLiteTrackStateRepository(database: database).setHidden(
            trackID: stored[0].libraryID,
            hidden: false
        )
        precondition(database.songs(folderID: folderID).count == 1)
        try SQLiteTrackStateRepository(database: database).tombstone(
            trackID: stored[0].libraryID
        )
        precondition(database.songs(folderID: folderID).isEmpty)

        let exported = directory.appendingPathComponent("Export.sqlite3")
        try SQLiteLibraryFileManager(database: database)
            .exportLibrary(to: exported)
        precondition(FileManager.default.fileExists(atPath: exported.path))

        print("Persistence adapter checks passed")
    }
}
