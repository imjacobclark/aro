import Foundation

@main
enum LibraryHealthSQLiteChecks {
    static func main() throws {
        try sqliteQueryMapsRecordsAndPreservesRecommendations()
        mapperRejectsInvalidIdentity()
        print("Library health SQLite checks passed")
    }

    private static func sqliteQueryMapsRecordsAndPreservesRecommendations()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let database = LibraryDatabase(
            url: root.appendingPathComponent("Library.sqlite3")
        )
        let folderID = UUID()
        database.save(
            folder: WatchedFolder(
                id: folderID,
                url: root,
                displayName: "Music",
                bookmarkData: nil,
                isAccessible: true,
                didStartSecurityScope: false
            )
        )

        let firstScan = [
            song("Exact A.flac", "Exact", "exact-hash", "FLAC", 24),
            song("Exact B.flac", "Exact", "exact-hash", "FLAC", 24),
            song("Mix.flac", "Mix", "flac-hash", "FLAC", 24),
            song("Mix.mp3", "Mix", "mp3-hash", "MP3", nil),
            song("Old/Moved.flac", "Moved", "moved-hash", "FLAC", 24),
            song("Missing.flac", "Missing", "missing-hash", "FLAC", 24)
        ]
        _ = database.reconcile(songs: firstScan, folderID: folderID)

        let secondScan = [
            firstScan[0],
            firstScan[1],
            firstScan[2],
            firstScan[3],
            song("New/Moved.flac", "Moved", "moved-hash", "FLAC", 24)
        ]
        _ = database.reconcile(songs: secondScan, folderID: folderID)

        let trackQuery = SQLiteLibraryHealthTrackQuery(database: database)
        let tracks = trackQuery.libraryHealthTracks()
        precondition(
            tracks.count == 5,
            "SQLite query did not map the expected stable tracks"
        )

        let report = ReviewLibraryHealth(tracks: trackQuery).execute()
        precondition(
            report.exactDuplicates.count == 1,
            "Exact duplicate classification changed"
        )
        precondition(
            report.alternateEncodings.count == 1,
            "Alternate encoding classification changed"
        )
        precondition(
            report.movedFiles.count == 1,
            "Moved-file classification changed"
        )
        precondition(
            report.missingFiles.count == 1,
            "Missing-file classification changed"
        )
    }

    private static func mapperRejectsInvalidIdentity() {
        let record = LibraryHealthTrackRecord(
            id: "not-a-uuid",
            contentHash: nil,
            title: "Track",
            artist: "Artist",
            duration: 180,
            copies: []
        )
        precondition(
            LibraryHealthTrackMapper().map(record) == nil,
            "Invalid persistence identity entered the domain"
        )
    }

    private static func song(
        _ relativePath: String,
        _ title: String,
        _ contentHash: String,
        _ codec: String,
        _ bitDepth: Int?
    ) -> Song {
        let url = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent(relativePath)
        let fileSize: Int64 = codec == "MP3" ? 4_000 : 20_000
        return Song(
            url: url,
            title: title,
            artist: "Artist",
            duration: 180,
            fileSizeBytes: fileSize,
            audioProperties: AudioFileProperties(
                codec: codec,
                sampleRate: codec == "MP3" ? 44_100 : 96_000,
                bitDepth: bitDepth,
                channelCount: 2,
                bitrate: codec == "MP3" ? 320_000 : nil
            ),
            fileFingerprint: AudioFileFingerprint(
                standardizedPath: url.path,
                fileSizeBytes: fileSize,
                modificationDate: Date(timeIntervalSince1970: 1),
                contentHash: contentHash
            )
        )
    }
}
