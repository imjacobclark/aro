import Foundation
import SonoraCommon
import SQLite3

struct DatabaseFolderRecord: Sendable {
    let id: UUID
    let displayName: String
    let path: String
    let bookmarkData: Data?
}

/// SQLite is opened in full-mutex mode and every handle access is serialized
/// by `lock`, which is why this reference type can cross task boundaries.
final class LibraryDatabase: @unchecked Sendable {
    let url: URL
    let deviceID: UUID

    private let lock = NSRecursiveLock()
    private var connection: OpaquePointer?

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()

        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "library.deviceID"),
           let id = UUID(uuidString: stored) {
            deviceID = id
        } else {
            let id = UUID()
            deviceID = id
            defaults.set(id.uuidString, forKey: "library.deviceID")
        }

        do {
            try FileManager.default.createDirectory(
                at: self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var opened: OpaquePointer?
            let result = sqlite3_open_v2(
                self.url.path,
                &opened,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard result == SQLITE_OK, let opened else {
                if let opened {
                    sqlite3_close(opened)
                }
                return
            }
            connection = opened
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try SQLiteSchemaMigrator(connection: opened).migrate()
            try registerLocalDevice()
        } catch {
            if let connection {
                sqlite3_close(connection)
                self.connection = nil
            }
        }
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    var isAvailable: Bool {
        lock.withLock { connection != nil }
    }

    func withReadConnection<Value>(
        _ operation: (OpaquePointer) -> Value
    ) -> Value? {
        withConnection(operation)
    }

    func withConnection<Value>(
        _ operation: (OpaquePointer) -> Value
    ) -> Value? {
        lock.withLock {
            guard let connection else {
                return nil
            }
            return operation(connection)
        }
    }

    func watchedFolders() -> [DatabaseFolderRecord] {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT id, display_name, path, bookmark
                FROM watched_folders
                WHERE removed_at IS NULL
                ORDER BY display_name COLLATE NOCASE
                """
            ) else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var records: [DatabaseFolderRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idString = text(statement, 0),
                      let id = UUID(uuidString: idString),
                      let displayName = text(statement, 1),
                      let path = text(statement, 2) else {
                    continue
                }
                records.append(
                    DatabaseFolderRecord(
                        id: id,
                        displayName: displayName,
                        path: path,
                        bookmarkData: blob(statement, 3)
                    )
                )
            }
            return records
        }
    }

    func save(folder: WatchedFolder) {
        lock.withLock {
            guard let statement = try? prepare(
                """
                INSERT INTO watched_folders
                    (id, display_name, path, bookmark, added_at, removed_at)
                VALUES (?, ?, ?, ?, ?, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    path = excluded.path,
                    bookmark = excluded.bookmark,
                    removed_at = NULL
                """
            ) else {
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(folder.id.uuidString, to: statement, at: 1)
            bind(folder.displayName, to: statement, at: 2)
            bind(
                Self.persistedLocation(for: folder.url),
                to: statement,
                at: 3
            )
            bind(folder.bookmarkData, to: statement, at: 4)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            _ = sqlite3_step(statement)
        }
    }

    private static func persistedLocation(for url: URL) -> String {
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url.absoluteString
        }
        return url.standardizedFileURL.path
    }

    func removeFolder(id: UUID) {
        lock.withLock {
            do {
                try transaction {
                    let now = Date().timeIntervalSince1970
                    try run(
                        "UPDATE watched_folders SET removed_at = ? WHERE id = ?"
                    ) {
                        sqlite3_bind_double($0, 1, now)
                        bind(id.uuidString, to: $0, at: 2)
                    }
                    try run(
                        """
                        UPDATE file_locations
                        SET available = 0, updated_at = ?
                        WHERE folder_id = ? AND device_id = ?
                        """
                    ) {
                        sqlite3_bind_double($0, 1, now)
                        bind(id.uuidString, to: $0, at: 2)
                        bind(deviceID.uuidString, to: $0, at: 3)
                    }
                    try appendChange(
                        entityType: "folder",
                        entityID: id.uuidString,
                        operation: "remove",
                        payload: "{}"
                    )
                }
            } catch {
                return
            }
        }
    }

    func markFolderUnavailable(id: UUID) {
        lock.withLock {
            try? run(
                """
                UPDATE file_locations
                SET available = 0, updated_at = ?
                WHERE folder_id = ? AND device_id = ?
                """
            ) {
                sqlite3_bind_double($0, 1, Date().timeIntervalSince1970)
                bind(id.uuidString, to: $0, at: 2)
                bind(deviceID.uuidString, to: $0, at: 3)
            }
        }
    }

    func songs(folderID: UUID) -> [Song] {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT t.id, l.path, sm.title, sm.artist, sm.duration,
                       l.file_size, sm.codec, sm.sample_rate, sm.bit_depth,
                       sm.channel_count, sm.bitrate, l.modification_date,
                       t.content_hash, la.integrated_lufs, la.peak_amplitude,
                       la.analyzed_at, sm.album, sm.genre, sm.release_year,
                       sm.artwork
                FROM file_locations AS l
                JOIN tracks AS t ON t.id = l.track_id
                JOIN scan_metadata AS sm ON sm.track_id = t.id
                JOIN track_state AS ts ON ts.track_id = t.id
                LEFT JOIN loudness_analysis AS la
                  ON la.fingerprint = t.content_hash
                 AND la.algorithm_version = ?
                WHERE l.folder_id = ?
                  AND l.device_id = ?
                  AND l.available = 1
                  AND ts.hidden = 0
                  AND ts.deleted_at IS NULL
                """
            ) else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(
                statement,
                1,
                Int32(LoudnessAnalysis.algorithmVersion)
            )
            bind(folderID.uuidString, to: statement, at: 2)
            bind(deviceID.uuidString, to: statement, at: 3)

            var songs: [Song] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idString = text(statement, 0),
                      let id = UUID(uuidString: idString),
                      let path = text(statement, 1) else {
                    continue
                }

                let contentHash = text(statement, 12)
                let isRemotePath = URL(string: path).map {
                    ["http", "https"].contains(
                        $0.scheme?.lowercased() ?? ""
                    )
                } ?? false
                let fileSize = optionalInt64(statement, 5)
                let modificationDate = optionalDouble(statement, 11).map {
                    Date(timeIntervalSince1970: $0)
                } ?? (isRemotePath ? .distantPast : nil)
                let fingerprint = fileSize.flatMap { size in
                    modificationDate.map {
                        AudioFileFingerprint(
                            standardizedPath: path,
                            fileSizeBytes: size,
                            modificationDate: $0,
                            contentHash: contentHash
                        )
                    }
                }
                let properties = text(statement, 6).map {
                    AudioFileProperties(
                        codec: $0,
                        sampleRate: optionalDouble(statement, 7),
                        bitDepth: optionalInt(statement, 8),
                        channelCount: optionalInt(statement, 9),
                        bitrate: optionalDouble(statement, 10)
                    )
                }
                let loudness: LoudnessAnalysis?
                if sqlite3_column_type(statement, 13) != SQLITE_NULL {
                    loudness = LoudnessAnalysis(
                        integratedLUFS: sqlite3_column_double(statement, 13),
                        peakAmplitude: sqlite3_column_double(statement, 14),
                        analyzedAt: Date(
                            timeIntervalSince1970: sqlite3_column_double(
                                statement,
                                15
                            )
                        )
                    )
                } else {
                    loudness = nil
                }

                let url = URL(string: path).flatMap {
                    ["http", "https"].contains($0.scheme?.lowercased() ?? "")
                        ? $0
                        : nil
                } ?? URL(fileURLWithPath: path)
                songs.append(
                    Song(
                        libraryID: id,
                        url: url,
                        title: text(statement, 2) ?? "Unknown",
                        artist: text(statement, 3) ?? "—",
                        album: text(statement, 16),
                        genre: text(statement, 17),
                        releaseYear: optionalInt(statement, 18),
                        artworkData: blob(statement, 19),
                        duration: optionalDouble(statement, 4),
                        fileSizeBytes: fileSize,
                        audioProperties: properties,
                        fileFingerprint: fingerprint,
                        loudness: loudness
                    )
                )
            }
            return SongLibrary.deduplicated(songs)
        }
    }

    func reconcile(songs: [Song], folderID: UUID) -> [Song] {
        lock.withLock {
            guard connection != nil else {
                return songs
            }

            let scanToken = UUID().uuidString
            var reconciled: [Song] = []
            do {
                try transaction {
                    for song in songs {
                        let trackID = try resolveTrackID(for: song)
                        try upsert(trackID: trackID, song: song)
                        try upsertLocation(
                            trackID: trackID,
                            song: song,
                            folderID: folderID,
                            scanToken: scanToken
                        )

                        guard try !isHidden(trackID: trackID) else {
                            continue
                        }
                        reconciled.append(
                            Song(
                                libraryID: trackID,
                                url: song.url,
                                title: song.title,
                                artist: song.artist,
                                album: song.album,
                                genre: song.genre,
                                releaseYear: song.releaseYear,
                                artworkData: song.artworkData,
                                duration: song.duration,
                                fileSizeBytes: song.fileSizeBytes,
                                audioProperties: song.audioProperties,
                                fileFingerprint: song.fileFingerprint,
                                loudness: song.loudness
                            )
                        )
                    }

                    try run(
                        """
                        UPDATE file_locations
                        SET available = 0, updated_at = ?
                        WHERE folder_id = ?
                          AND device_id = ?
                          AND last_seen_token <> ?
                        """
                    ) {
                        sqlite3_bind_double($0, 1, Date().timeIntervalSince1970)
                        bind(folderID.uuidString, to: $0, at: 2)
                        bind(deviceID.uuidString, to: $0, at: 3)
                        bind(scanToken, to: $0, at: 4)
                    }
                }
                return SongLibrary.deduplicated(reconciled)
            } catch {
                return songs
            }
        }
    }

    private func resolveTrackID(for song: Song) throws -> UUID {
        let path = song.url.standardizedFileURL.path
        if let statement = try? prepare(
            """
            SELECT t.id, t.content_hash
            FROM file_locations AS l
            JOIN tracks AS t ON t.id = l.track_id
            WHERE l.device_id = ? AND l.path = ?
            LIMIT 1
            """
        ) {
            defer { sqlite3_finalize(statement) }
            bind(deviceID.uuidString, to: statement, at: 1)
            bind(path, to: statement, at: 2)
            if sqlite3_step(statement) == SQLITE_ROW,
               let idString = text(statement, 0),
               let id = UUID(uuidString: idString) {
                // A source path is the stable logical identity. Replacing the
                // file updates the same song and preserves ratings/history.
                return id
            }
        }

        if let contentHash = song.fileFingerprint?.contentHash,
           let statement = try? prepare(
               "SELECT id FROM tracks WHERE content_hash = ? LIMIT 1"
           ) {
            defer { sqlite3_finalize(statement) }
            bind(contentHash, to: statement, at: 1)
            if sqlite3_step(statement) == SQLITE_ROW,
               let idString = text(statement, 0),
               let id = UUID(uuidString: idString) {
                return id
            }
        }
        return UUID()
    }

    private func upsert(trackID: UUID, song: Song) throws {
        let now = Date().timeIntervalSince1970
        try run(
            """
            INSERT INTO tracks (id, content_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content_hash = COALESCE(excluded.content_hash, tracks.content_hash),
                updated_at = excluded.updated_at
            """
        ) {
            bind(trackID.uuidString, to: $0, at: 1)
            bind(song.fileFingerprint?.contentHash, to: $0, at: 2)
            sqlite3_bind_double($0, 3, now)
            sqlite3_bind_double($0, 4, now)
        }

        try run(
            """
            INSERT INTO scan_metadata
                (track_id, title, artist, duration, codec, sample_rate,
                 bit_depth, channel_count, bitrate, scanned_at, album, genre,
                 release_year, artwork)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                title = excluded.title,
                artist = excluded.artist,
                duration = excluded.duration,
                codec = excluded.codec,
                sample_rate = excluded.sample_rate,
                bit_depth = excluded.bit_depth,
                channel_count = excluded.channel_count,
                bitrate = excluded.bitrate,
                scanned_at = excluded.scanned_at,
                album = excluded.album,
                genre = excluded.genre,
                release_year = excluded.release_year,
                artwork = excluded.artwork
            """
        ) {
            bind(trackID.uuidString, to: $0, at: 1)
            bind(song.title, to: $0, at: 2)
            bind(song.artist, to: $0, at: 3)
            bind(song.duration, to: $0, at: 4)
            bind(song.audioProperties?.codec, to: $0, at: 5)
            bind(song.audioProperties?.sampleRate, to: $0, at: 6)
            bind(song.audioProperties?.bitDepth, to: $0, at: 7)
            bind(song.audioProperties?.channelCount, to: $0, at: 8)
            bind(song.audioProperties?.bitrate, to: $0, at: 9)
            sqlite3_bind_double($0, 10, now)
            bind(song.album, to: $0, at: 11)
            bind(song.genre, to: $0, at: 12)
            bind(song.releaseYear, to: $0, at: 13)
            bind(song.artworkData, to: $0, at: 14)
        }

        try run(
            """
            INSERT INTO track_state
                (track_id, hidden, favourite, rating, updated_at)
            VALUES (?, 0, 0, NULL, ?)
            ON CONFLICT(track_id) DO NOTHING
            """
        ) {
            bind(trackID.uuidString, to: $0, at: 1)
            sqlite3_bind_double($0, 2, now)
        }
    }

    private func upsertLocation(
        trackID: UUID,
        song: Song,
        folderID: UUID,
        scanToken: String
    ) throws {
        try run(
            """
            INSERT INTO file_locations
                (id, track_id, device_id, folder_id, path, volume_id,
                 file_size, modification_date, available, last_seen_token,
                 updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(device_id, path) DO UPDATE SET
                track_id = excluded.track_id,
                folder_id = excluded.folder_id,
                volume_id = excluded.volume_id,
                file_size = excluded.file_size,
                modification_date = excluded.modification_date,
                available = 1,
                last_seen_token = excluded.last_seen_token,
                updated_at = excluded.updated_at
            """
        ) {
            bind(UUID().uuidString, to: $0, at: 1)
            bind(trackID.uuidString, to: $0, at: 2)
            bind(deviceID.uuidString, to: $0, at: 3)
            bind(folderID.uuidString, to: $0, at: 4)
            bind(song.url.standardizedFileURL.path, to: $0, at: 5)
            bind(volumeIdentifier(for: song.url), to: $0, at: 6)
            bind(song.fileSizeBytes, to: $0, at: 7)
            bind(
                song.fileFingerprint?.modificationDate.timeIntervalSince1970,
                to: $0,
                at: 8
            )
            bind(scanToken, to: $0, at: 9)
            sqlite3_bind_double($0, 10, Date().timeIntervalSince1970)
        }
    }

    private func isHidden(trackID: UUID) throws -> Bool {
        let statement = try prepare(
            """
            SELECT hidden OR deleted_at IS NOT NULL
            FROM track_state
            WHERE track_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
            && sqlite3_column_int(statement, 0) != 0
    }

    private func volumeIdentifier(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString
    }

    private func registerLocalDevice() throws {
        try run(
            """
            INSERT INTO devices (id, name, last_seen_at)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                last_seen_at = excluded.last_seen_at
            """
        ) {
            bind(deviceID.uuidString, to: $0, at: 1)
            bind(Host.current().localizedName ?? "Mac", to: $0, at: 2)
            sqlite3_bind_double($0, 3, Date().timeIntervalSince1970)
        }
    }

    private func appendChange(
        entityType: String,
        entityID: String,
        operation: String,
        payload: String
    ) throws {
        let clock = Int64(Date().timeIntervalSince1970 * 1_000)
        try run(
            """
            INSERT INTO changes
                (operation_id, device_id, entity_type, entity_id, operation,
                 payload, logical_clock, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) {
            bind(UUID().uuidString, to: $0, at: 1)
            bind(deviceID.uuidString, to: $0, at: 2)
            bind(entityType, to: $0, at: 3)
            bind(entityID, to: $0, at: 4)
            bind(operation, to: $0, at: 5)
            bind(payload, to: $0, at: 6)
            sqlite3_bind_int64($0, 7, clock)
            sqlite3_bind_double($0, 8, Date().timeIntervalSince1970)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func run(
        _ sql: String,
        bindings: (OpaquePointer) -> Void = { _ in }
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let connection else {
            throw LibraryDatabaseError.unavailable
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
            == SQLITE_OK,
              let statement else {
            throw databaseError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard let connection else {
            throw LibraryDatabaseError.unavailable
        }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func databaseError() -> Error {
        guard let connection,
              let message = sqlite3_errmsg(connection) else {
            return LibraryDatabaseError.unavailable
        }
        return LibraryDatabaseError.sqlite(String(cString: message))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        return Data(
            bytes: bytes,
            count: Int(sqlite3_column_bytes(statement, column))
        )
    }

    private func optionalDouble(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, column)
    }

    private func optionalInt(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, column))
    }

    private func optionalInt64(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, column)
    }

    private func bind(
        _ value: String?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
    }

    private func bind(
        _ value: Data?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes {
            sqlite3_bind_blob(
                statement,
                index,
                $0.baseAddress,
                Int32($0.count),
                Self.transient
            )
        }
    }

    private func bind(
        _ value: Double?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(
        _ value: Int?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(
        _ value: Int64?,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Sonora", isDirectory: true)
            .appendingPathComponent("Library Data", isDirectory: true)
            .appendingPathComponent("Sonora.sqlite3")
    }

    static func legacyDefaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Sonora", isDirectory: true)
            .appendingPathComponent("Sonora.sqlite3")
    }

    static func prepareDefaultStore() {
        copyStoreIfNeeded(from: legacyDefaultURL(), to: defaultURL())
    }

    static func copyStoreIfNeeded(from source: URL, to destination: URL) {
        let files = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL,
              files.fileExists(atPath: source.path),
              !files.fileExists(atPath: destination.path) else {
            return
        }
        do {
            try files.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try files.copyItem(at: source, to: destination)
            for suffix in ["-wal", "-shm"] {
                let sourceSidecar = URL(fileURLWithPath: source.path + suffix)
                let destinationSidecar = URL(
                    fileURLWithPath: destination.path + suffix
                )
                if files.fileExists(atPath: sourceSidecar.path) {
                    try files.copyItem(
                        at: sourceSidecar,
                        to: destinationSidecar
                    )
                }
            }
        } catch {
            // The original database remains untouched and will be retried on
            // the next launch.
        }
    }
}

enum LibraryDatabaseError: LocalizedError {
    case unavailable
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The Sonora library database is unavailable."
        case .sqlite(let message):
            return "The Sonora library database failed: \(message)"
        }
    }
}
