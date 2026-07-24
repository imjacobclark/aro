import Foundation
import SQLite3

struct DatabaseFolderRecord: Sendable {
    let id: UUID
    let displayName: String
    let path: String
    let bookmarkData: Data?
}

private struct HealthTrackRecord {
    let id: UUID
    let contentHash: String?
    let title: String
    let artist: String
    let duration: TimeInterval?
    var copies: [LibraryHealthCopy]
}

final class LibraryDatabase: @unchecked Sendable {
    static let shared = LibraryDatabase()

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
            guard result == SQLITE_OK else {
                if let opened {
                    sqlite3_close(opened)
                }
                return
            }
            connection = opened
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try migrate()
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
            bind(folder.url.standardizedFileURL.path, to: statement, at: 3)
            bind(folder.bookmarkData, to: statement, at: 4)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            _ = sqlite3_step(statement)
        }
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
                       la.analyzed_at, sm.album, sm.genre, sm.release_year
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
                let fileSize = optionalInt64(statement, 5)
                let modificationDate = optionalDouble(statement, 11).map {
                    Date(timeIntervalSince1970: $0)
                }
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

                songs.append(
                    Song(
                        libraryID: id,
                        url: URL(fileURLWithPath: path),
                        title: text(statement, 2) ?? "Unknown",
                        artist: text(statement, 3) ?? "—",
                        album: text(statement, 16),
                        genre: text(statement, 17),
                        releaseYear: optionalInt(statement, 18),
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

    func cachedContentHash(
        path: String,
        fileSize: Int64,
        modificationDate: Date
    ) -> String? {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT t.content_hash
                FROM file_locations AS l
                JOIN tracks AS t ON t.id = l.track_id
                WHERE l.device_id = ?
                  AND l.path = ?
                  AND l.file_size = ?
                  AND ABS(l.modification_date - ?) < 0.001
                LIMIT 1
                """
            ) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            bind(deviceID.uuidString, to: statement, at: 1)
            bind(path, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, fileSize)
            sqlite3_bind_double(
                statement,
                4,
                modificationDate.timeIntervalSince1970
            )
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return text(statement, 0)
        }
    }

    func setHidden(trackID: UUID, hidden: Bool) {
        lock.withLock {
            do {
                try transaction {
                    try run(
                        """
                        UPDATE track_state
                        SET hidden = ?, updated_at = ?
                        WHERE track_id = ?
                        """
                    ) {
                        sqlite3_bind_int($0, 1, hidden ? 1 : 0)
                        sqlite3_bind_double(
                            $0,
                            2,
                            Date().timeIntervalSince1970
                        )
                        bind(trackID.uuidString, to: $0, at: 3)
                    }
                    try appendChange(
                        entityType: "track_state",
                        entityID: trackID.uuidString,
                        operation: hidden ? "hide" : "unhide",
                        payload: "{\"hidden\":\(hidden)}"
                    )
                }
            } catch {
                return
            }
        }
    }

    func tombstone(trackID: UUID) {
        lock.withLock {
            do {
                try transaction {
                    let now = Date().timeIntervalSince1970
                    try run(
                        """
                        UPDATE track_state
                        SET deleted_at = ?, updated_at = ?
                        WHERE track_id = ?
                        """
                    ) {
                        sqlite3_bind_double($0, 1, now)
                        sqlite3_bind_double($0, 2, now)
                        bind(trackID.uuidString, to: $0, at: 3)
                    }
                    try appendChange(
                        entityType: "track_state",
                        entityID: trackID.uuidString,
                        operation: "delete",
                        payload: "{\"deleted_at\":\(now)}"
                    )
                }
            } catch {
                return
            }
        }
    }

    func exportCopy(to destinationURL: URL) throws {
        try lock.withLock {
            guard let connection else {
                throw LibraryDatabaseError.unavailable
            }

            try execute("PRAGMA wal_checkpoint(FULL)")
            var destination: OpaquePointer?
            guard sqlite3_open(destinationURL.path, &destination) == SQLITE_OK,
                  let destination else {
                if let destination {
                    sqlite3_close(destination)
                }
                throw LibraryDatabaseError.unavailable
            }
            defer { sqlite3_close(destination) }

            guard let backup = sqlite3_backup_init(
                destination,
                "main",
                connection,
                "main"
            ) else {
                throw LibraryDatabaseError.sqlite(
                    String(cString: sqlite3_errmsg(destination))
                )
            }
            defer { sqlite3_backup_finish(backup) }
            guard sqlite3_backup_step(backup, -1) == SQLITE_DONE else {
                throw LibraryDatabaseError.sqlite(
                    String(cString: sqlite3_errmsg(destination))
                )
            }
        }
    }

    func beginListeningSession(trackID: UUID) -> UUID {
        lock.withLock {
            let id = UUID()
            let now = Date().timeIntervalSince1970
            try? run(
                """
                INSERT INTO listening_sessions
                    (id, track_id, device_id, started_at, last_heartbeat_at,
                     listened_seconds, completed)
                VALUES (?, ?, ?, ?, ?, 0, 0)
                """
            ) {
                bind(id.uuidString, to: $0, at: 1)
                bind(trackID.uuidString, to: $0, at: 2)
                bind(deviceID.uuidString, to: $0, at: 3)
                sqlite3_bind_double($0, 4, now)
                sqlite3_bind_double($0, 5, now)
            }
            return id
        }
    }

    func heartbeatListeningSession(id: UUID) {
        updateListeningSession(id: id, ended: false, completed: false)
    }

    func endListeningSession(id: UUID, completed: Bool = false) {
        updateListeningSession(id: id, ended: true, completed: completed)
    }

    func listeningStats(now: Date = Date()) -> ListeningStats {
        lock.withLock {
            var result = ListeningStats()
            if let statement = try? prepare(
                """
                SELECT COALESCE(SUM(listened_seconds), 0),
                       COALESCE(SUM(CASE WHEN started_at >= ?
                           THEN listened_seconds ELSE 0 END), 0),
                       COUNT(*), COUNT(DISTINCT track_id)
                FROM listening_sessions
                """
            ) {
                sqlite3_bind_double(
                    statement,
                    1,
                    now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
                )
                if sqlite3_step(statement) == SQLITE_ROW {
                    result.totalSeconds = sqlite3_column_double(statement, 0)
                    result.last30DaysSeconds = sqlite3_column_double(statement, 1)
                    result.loggedPlays = Int(sqlite3_column_int64(statement, 2))
                    result.uniqueTracksPlayed = Int(
                        sqlite3_column_int64(statement, 3)
                    )
                }
                sqlite3_finalize(statement)
            }

            result.daily = dailyListeningStats(now: now)
            result.currentStreak = listeningStreak(
                dates: result.daily.filter { $0.seconds > 0 }.map(\.date),
                now: now
            )
            result.topTracks = rankedListeningStats(
                groupExpression: "ls.track_id",
                titleExpression: "COALESCE(sm.title, 'Unknown Track')",
                subtitleExpression:
                    "COALESCE(sm.artist, 'Unknown Artist') || ' — ' || COALESCE(sm.album, 'Unknown Album')",
                limit: 5
            )
            result.topArtists = rankedListeningStats(
                groupExpression: "COALESCE(sm.artist, 'Unknown Artist')",
                titleExpression: "COALESCE(sm.artist, 'Unknown Artist')",
                subtitleExpression:
                    "COUNT(DISTINCT ls.track_id) || ' tracks'",
                limit: 5
            )
            result.recent = recentListeningStats(limit: 8)
            return result
        }
    }

    func libraryStats() -> LibraryStats {
        lock.withLock {
            var result = LibraryStats()
            let baseWhere =
                """
                EXISTS (
                    SELECT 1 FROM file_locations l
                    WHERE l.track_id = t.id
                      AND l.device_id = '\(deviceID.uuidString)'
                      AND l.available = 1
                )
                AND ts.hidden = 0
                AND ts.deleted_at IS NULL
                """
            if let statement = try? prepare(
                """
                SELECT COUNT(DISTINCT t.id),
                       COUNT(DISTINCT NULLIF(sm.album, '')),
                       COUNT(DISTINCT NULLIF(sm.artist, '')),
                       COALESCE(SUM(sm.duration), 0),
                       COALESCE(SUM((
                           SELECT MAX(l.file_size) FROM file_locations l
                           WHERE l.track_id = t.id
                             AND l.device_id = ?
                             AND l.available = 1
                       )), 0)
                FROM tracks t
                JOIN scan_metadata sm ON sm.track_id = t.id
                JOIN track_state ts ON ts.track_id = t.id
                WHERE \(baseWhere)
                """
            ) {
                bind(deviceID.uuidString, to: statement, at: 1)
                if sqlite3_step(statement) == SQLITE_ROW {
                    result.trackCount = Int(sqlite3_column_int64(statement, 0))
                    result.albumCount = Int(sqlite3_column_int64(statement, 1))
                    result.artistCount = Int(sqlite3_column_int64(statement, 2))
                    result.totalDuration = sqlite3_column_double(statement, 3)
                    result.fileSizeBytes = sqlite3_column_int64(statement, 4)
                }
                sqlite3_finalize(statement)
            }

            result.formats = libraryBreakdown(
                nameExpression: "UPPER(COALESCE(sm.codec, 'Unknown'))"
            )
            result.genres = libraryBreakdown(
                nameExpression: "COALESCE(NULLIF(sm.genre, ''), 'Unknown')"
            )
            result.decades = libraryBreakdown(
                nameExpression:
                    "CASE WHEN sm.release_year IS NULL THEN 'Unknown' ELSE ((sm.release_year / 10) * 10) || 's' END"
            )
            return result
        }
    }

    func libraryHealthReport() -> LibraryHealthReport {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT t.id, t.content_hash,
                       COALESCE(NULLIF(ts.title_override, ''), sm.title,
                                'Unknown Track'),
                       COALESCE(NULLIF(ts.artist_override, ''), sm.artist,
                                'Unknown Artist'),
                       sm.duration, l.path, l.available,
                       COALESCE(l.file_size, 0),
                       COALESCE(sm.codec, 'Unknown'),
                       sm.sample_rate, sm.bit_depth, sm.bitrate
                FROM tracks t
                JOIN scan_metadata sm ON sm.track_id = t.id
                JOIN track_state ts ON ts.track_id = t.id
                JOIN file_locations l ON l.track_id = t.id
                WHERE l.device_id = ?
                  AND ts.deleted_at IS NULL
                ORDER BY t.id, l.available DESC, l.path COLLATE NOCASE
                """
            ) else {
                return LibraryHealthReport()
            }
            defer { sqlite3_finalize(statement) }
            bind(deviceID.uuidString, to: statement, at: 1)

            var tracks: [UUID: HealthTrackRecord] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idValue = text(statement, 0),
                      let trackID = UUID(uuidString: idValue),
                      let path = text(statement, 5) else {
                    continue
                }
                let copy = LibraryHealthCopy(
                    trackID: trackID,
                    path: path,
                    isAvailable: sqlite3_column_int(statement, 6) != 0,
                    codec: text(statement, 8) ?? "Unknown",
                    sampleRate: optionalDouble(statement, 9),
                    bitDepth: optionalInt(statement, 10),
                    bitrate: optionalDouble(statement, 11),
                    fileSizeBytes: sqlite3_column_int64(statement, 7)
                )
                if tracks[trackID] == nil {
                    tracks[trackID] = HealthTrackRecord(
                        id: trackID,
                        contentHash: text(statement, 1),
                        title: text(statement, 2) ?? "Unknown Track",
                        artist: text(statement, 3) ?? "Unknown Artist",
                        duration: optionalDouble(statement, 4),
                        copies: []
                    )
                }
                tracks[trackID]?.copies.append(copy)
            }
            return makeLibraryHealthReport(
                tracks: Array(tracks.values)
            )
        }
    }

    private func updateListeningSession(
        id: UUID,
        ended: Bool,
        completed: Bool
    ) {
        lock.withLock {
            let now = Date().timeIntervalSince1970
            try? run(
                """
                UPDATE listening_sessions
                SET listened_seconds = listened_seconds
                    + MAX(0, MIN(? - last_heartbeat_at, 10)),
                    last_heartbeat_at = ?,
                    ended_at = CASE WHEN ? THEN ? ELSE ended_at END,
                    completed = MAX(completed, ?)
                WHERE id = ? AND ended_at IS NULL
                """
            ) {
                sqlite3_bind_double($0, 1, now)
                sqlite3_bind_double($0, 2, now)
                sqlite3_bind_int($0, 3, ended ? 1 : 0)
                sqlite3_bind_double($0, 4, now)
                sqlite3_bind_int($0, 5, completed ? 1 : 0)
                bind(id.uuidString, to: $0, at: 6)
            }
        }
    }

    private func dailyListeningStats(now: Date) -> [DailyListeningStat] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(
            for: now.addingTimeInterval(-29 * 86_400)
        )
        var secondsByDay: [Date: TimeInterval] = [:]
        if let statement = try? prepare(
            """
            SELECT date(started_at, 'unixepoch', 'localtime'),
                   SUM(listened_seconds)
            FROM listening_sessions
            WHERE started_at >= ?
            GROUP BY 1
            """
        ) {
            sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            while sqlite3_step(statement) == SQLITE_ROW {
                if let day = text(statement, 0),
                   let date = formatter.date(from: day) {
                    secondsByDay[date] = sqlite3_column_double(statement, 1)
                }
            }
            sqlite3_finalize(statement)
        }
        return (0..<30).compactMap {
            guard let date = calendar.date(byAdding: .day, value: $0, to: start)
            else { return nil }
            return DailyListeningStat(
                date: date,
                seconds: secondsByDay[date] ?? 0
            )
        }
    }

    private func listeningStreak(dates: [Date], now: Date) -> Int {
        let calendar = Calendar.current
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(
                byAdding: .day,
                value: -1,
                to: cursor
            ) else { break }
            cursor = previous
        }
        return streak
    }

    private func rankedListeningStats(
        groupExpression: String,
        titleExpression: String,
        subtitleExpression: String,
        limit: Int
    ) -> [RankedListeningStat] {
        guard let statement = try? prepare(
            """
            SELECT \(groupExpression), \(titleExpression),
                   \(subtitleExpression), COUNT(*)
            FROM listening_sessions ls
            LEFT JOIN scan_metadata sm ON sm.track_id = ls.track_id
            GROUP BY \(groupExpression)
            ORDER BY COUNT(*) DESC, \(titleExpression) COLLATE NOCASE
            LIMIT \(limit)
            """
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [RankedListeningStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(
                RankedListeningStat(
                    id: text(statement, 0) ?? UUID().uuidString,
                    title: text(statement, 1) ?? "Unknown",
                    subtitle: text(statement, 2) ?? "",
                    playCount: Int(sqlite3_column_int64(statement, 3))
                )
            )
        }
        return values
    }

    private func recentListeningStats(limit: Int) -> [RecentPlayStat] {
        guard let statement = try? prepare(
            """
            SELECT ls.id, COALESCE(sm.title, 'Unknown Track'),
                   COALESCE(sm.artist, 'Unknown Artist') || ' — ' ||
                       COALESCE(sm.album, 'Unknown Album'),
                   ls.started_at
            FROM listening_sessions ls
            LEFT JOIN scan_metadata sm ON sm.track_id = ls.track_id
            ORDER BY ls.started_at DESC
            LIMIT \(limit)
            """
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [RecentPlayStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(
                RecentPlayStat(
                    id: text(statement, 0) ?? UUID().uuidString,
                    title: text(statement, 1) ?? "Unknown",
                    subtitle: text(statement, 2) ?? "",
                    playedAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(
                            statement,
                            3
                        )
                    )
                )
            )
        }
        return values
    }

    private func libraryBreakdown(
        nameExpression: String
    ) -> [LibraryBreakdownStat] {
        guard let statement = try? prepare(
            """
            SELECT \(nameExpression), COUNT(DISTINCT t.id),
                   COALESCE(SUM((
                       SELECT MAX(l.file_size) FROM file_locations l
                       WHERE l.track_id = t.id
                         AND l.device_id = ?
                         AND l.available = 1
                   )), 0)
            FROM tracks t
            JOIN scan_metadata sm ON sm.track_id = t.id
            JOIN track_state ts ON ts.track_id = t.id
            WHERE EXISTS (
                SELECT 1 FROM file_locations l
                WHERE l.track_id = t.id
                  AND l.device_id = ?
                  AND l.available = 1
            )
              AND ts.hidden = 0
              AND ts.deleted_at IS NULL
            GROUP BY 1
            ORDER BY COUNT(DISTINCT t.id) DESC, 1 COLLATE NOCASE
            """
        ) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(deviceID.uuidString, to: statement, at: 1)
        bind(deviceID.uuidString, to: statement, at: 2)
        var values: [LibraryBreakdownStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(
                LibraryBreakdownStat(
                    name: text(statement, 0) ?? "Unknown",
                    trackCount: Int(sqlite3_column_int64(statement, 1)),
                    fileSizeBytes: sqlite3_column_int64(statement, 2)
                )
            )
        }
        return values
    }

    private func makeLibraryHealthReport(
        tracks: [HealthTrackRecord]
    ) -> LibraryHealthReport {
        var report = LibraryHealthReport()

        for track in tracks {
            let available = track.copies.filter(\.isAvailable)
            let unavailable = track.copies.filter { !$0.isAvailable }

            if available.count > 1, let contentHash = track.contentHash {
                let copies = available.sorted {
                    $0.path.localizedStandardCompare($1.path)
                        == .orderedAscending
                }
                report.exactDuplicates.append(
                    LibraryHealthRecommendation(
                        id: "exact:\(contentHash)",
                        kind: .exactDuplicate,
                        title: track.title,
                        artist: track.artist,
                        reason: "Byte-for-byte identical content hash.",
                        copies: copies,
                        preferredCopyID: copies.first?.id,
                        potentialSavingsBytes: copies.dropFirst().reduce(0) {
                            $0 + $1.fileSizeBytes
                        }
                    )
                )
            }

            if !available.isEmpty, !unavailable.isEmpty {
                let copies = available + unavailable
                report.movedFiles.append(
                    LibraryHealthRecommendation(
                        id: "moved:\(track.id.uuidString)",
                        kind: .moved,
                        title: track.title,
                        artist: track.artist,
                        reason:
                            "An available copy matches \(unavailable.count) former location\(unavailable.count == 1 ? "" : "s").",
                        copies: copies,
                        preferredCopyID: available.first?.id,
                        potentialSavingsBytes: 0
                    )
                )
            } else if available.isEmpty, !unavailable.isEmpty {
                report.missingFiles.append(
                    LibraryHealthRecommendation(
                        id: "missing:\(track.id.uuidString)",
                        kind: .missing,
                        title: track.title,
                        artist: track.artist,
                        reason: "No scanned location for this track is available.",
                        copies: unavailable,
                        preferredCopyID: nil,
                        potentialSavingsBytes: 0
                    )
                )
            }
        }

        let availableTracks = tracks.filter {
            $0.copies.contains(where: \.isAvailable)
        }
        let metadataGroups = Dictionary(grouping: availableTracks) {
            healthMetadataKey(title: $0.title, artist: $0.artist)
        }
        for (key, candidates) in metadataGroups
        where !key.isEmpty && candidates.count > 1 {
            var remaining = candidates.sorted {
                ($0.duration ?? 0) < ($1.duration ?? 0)
            }
            while let seed = remaining.first {
                remaining.removeFirst()
                let matches = remaining.filter {
                    guard let seedDuration = seed.duration,
                          let duration = $0.duration else {
                        return false
                    }
                    return abs(seedDuration - duration) <= 2
                }
                remaining.removeAll { candidate in
                    matches.contains { $0.id == candidate.id }
                }
                let cluster = [seed] + matches
                guard cluster.count > 1 else {
                    continue
                }

                let copies = cluster.compactMap { track in
                    track.copies
                        .filter(\.isAvailable)
                        .max { $0.qualityScore < $1.qualityScore }
                }
                let formatSignatures = Set(copies.map {
                    [
                        $0.codec.lowercased(),
                        String($0.bitDepth ?? 0),
                        String(Int(($0.sampleRate ?? 0).rounded())),
                        String(Int(($0.bitrate ?? 0).rounded()))
                    ].joined(separator: "|")
                })
                guard copies.count > 1, formatSignatures.count > 1 else {
                    continue
                }
                let preferred = copies.max {
                    $0.qualityScore < $1.qualityScore
                }
                let ids = cluster.map { $0.id.uuidString }.sorted()
                report.alternateEncodings.append(
                    LibraryHealthRecommendation(
                        id: "alternate:\(ids.joined(separator: ":"))",
                        kind: .alternateEncoding,
                        title: seed.title,
                        artist: seed.artist,
                        reason:
                            "Artist, title and duration match. Review before removing a lower-quality encoding.",
                        copies: copies.sorted {
                            $0.qualityScore > $1.qualityScore
                        },
                        preferredCopyID: preferred?.id,
                        potentialSavingsBytes: copies
                            .filter { $0.id != preferred?.id }
                            .reduce(0) { $0 + $1.fileSizeBytes }
                    )
                )
            }
        }

        report.exactDuplicates.sort(by: healthRecommendationSort)
        report.alternateEncodings.sort(by: healthRecommendationSort)
        report.movedFiles.sort(by: healthRecommendationSort)
        report.missingFiles.sort(by: healthRecommendationSort)
        return report
    }

    private func healthMetadataKey(title: String, artist: String) -> String {
        let unknown = ["", "unknown track", "unknown artist"]
        let normalizedTitle = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
        let normalizedArtist = artist.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
        guard !unknown.contains(title.lowercased()),
              !unknown.contains(artist.lowercased()),
              !normalizedTitle.isEmpty,
              !normalizedArtist.isEmpty else {
            return ""
        }
        return "\(normalizedArtist)|\(normalizedTitle)"
    }

    private func healthRecommendationSort(
        _ lhs: LibraryHealthRecommendation,
        _ rhs: LibraryHealthRecommendation
    ) -> Bool {
        let artistOrder = lhs.artist.localizedStandardCompare(rhs.artist)
        if artistOrder != .orderedSame {
            return artistOrder == .orderedAscending
        }
        return lhs.title.localizedStandardCompare(rhs.title)
            == .orderedAscending
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
                        let loudness = song.fileFingerprint.flatMap {
                            loudnessAnalysis(
                                fingerprint: $0.cacheKey,
                                algorithmVersion: LoudnessAnalysis.algorithmVersion
                            )
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
                                duration: song.duration,
                                fileSizeBytes: song.fileSizeBytes,
                                audioProperties: song.audioProperties,
                                fileFingerprint: song.fileFingerprint,
                                loudness: loudness
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

    func loudnessAnalysis(
        fingerprint: String,
        algorithmVersion: Int
    ) -> LoudnessAnalysis? {
        lock.withLock {
            guard let statement = try? prepare(
                """
                SELECT integrated_lufs, peak_amplitude, analyzed_at
                FROM loudness_analysis
                WHERE fingerprint = ? AND algorithm_version = ?
                """
            ) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }
            bind(fingerprint, to: statement, at: 1)
            sqlite3_bind_int(statement, 2, Int32(algorithmVersion))
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return LoudnessAnalysis(
                integratedLUFS: sqlite3_column_double(statement, 0),
                peakAmplitude: sqlite3_column_double(statement, 1),
                analyzedAt: Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 2)
                ),
                algorithmVersion: algorithmVersion
            )
        }
    }

    func saveLoudnessAnalysis(
        _ analysis: LoudnessAnalysis,
        fingerprint: String
    ) {
        lock.withLock {
            try? run(
                """
                INSERT INTO loudness_analysis
                    (fingerprint, algorithm_version, integrated_lufs,
                     peak_amplitude, analyzed_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(fingerprint, algorithm_version) DO UPDATE SET
                    integrated_lufs = excluded.integrated_lufs,
                    peak_amplitude = excluded.peak_amplitude,
                    analyzed_at = excluded.analyzed_at
                """
            ) {
                bind(fingerprint, to: $0, at: 1)
                sqlite3_bind_int($0, 2, Int32(analysis.algorithmVersion))
                sqlite3_bind_double($0, 3, analysis.integratedLUFS)
                sqlite3_bind_double($0, 4, analysis.peakAmplitude)
                sqlite3_bind_double(
                    $0,
                    5,
                    analysis.analyzedAt.timeIntervalSince1970
                )
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
                let storedHash = text(statement, 1)
                if song.fileFingerprint?.contentHash == nil
                    || storedHash == song.fileFingerprint?.contentHash {
                    return id
                }
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
                 release_year)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                release_year = excluded.release_year
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

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                last_seen_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS watched_folders (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                path TEXT NOT NULL,
                bookmark BLOB,
                added_at REAL NOT NULL,
                removed_at REAL
            );
            CREATE TABLE IF NOT EXISTS tracks (
                id TEXT PRIMARY KEY,
                content_hash TEXT UNIQUE,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS scan_metadata (
                track_id TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                title TEXT,
                artist TEXT,
                duration REAL,
                codec TEXT,
                sample_rate REAL,
                bit_depth INTEGER,
                channel_count INTEGER,
                bitrate REAL,
                album TEXT,
                genre TEXT,
                release_year INTEGER,
                scanned_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS track_state (
                track_id TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                hidden INTEGER NOT NULL DEFAULT 0,
                favourite INTEGER NOT NULL DEFAULT 0,
                rating INTEGER,
                title_override TEXT,
                artist_override TEXT,
                deleted_at REAL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS file_locations (
                id TEXT PRIMARY KEY,
                track_id TEXT NOT NULL REFERENCES tracks(id),
                device_id TEXT NOT NULL REFERENCES devices(id),
                folder_id TEXT REFERENCES watched_folders(id),
                path TEXT NOT NULL,
                volume_id TEXT,
                file_size INTEGER,
                modification_date REAL,
                available INTEGER NOT NULL DEFAULT 1,
                last_seen_token TEXT NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(device_id, path)
            );
            CREATE INDEX IF NOT EXISTS file_locations_track
                ON file_locations(track_id);
            CREATE INDEX IF NOT EXISTS file_locations_folder
                ON file_locations(folder_id, device_id, available);
            CREATE TABLE IF NOT EXISTS loudness_analysis (
                fingerprint TEXT NOT NULL,
                algorithm_version INTEGER NOT NULL,
                integrated_lufs REAL NOT NULL,
                peak_amplitude REAL NOT NULL,
                analyzed_at REAL NOT NULL,
                PRIMARY KEY(fingerprint, algorithm_version)
            );
            CREATE TABLE IF NOT EXISTS changes (
                operation_id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                operation TEXT NOT NULL,
                payload TEXT NOT NULL,
                logical_clock INTEGER NOT NULL,
                created_at REAL NOT NULL
            );
            INSERT OR IGNORE INTO schema_migrations(version, applied_at)
                VALUES (1, unixepoch());
            """
        )
        try? execute("ALTER TABLE scan_metadata ADD COLUMN album TEXT")
        try? execute("ALTER TABLE scan_metadata ADD COLUMN genre TEXT")
        try? execute(
            "ALTER TABLE scan_metadata ADD COLUMN release_year INTEGER"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS listening_sessions (
                id TEXT PRIMARY KEY,
                track_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                last_heartbeat_at REAL NOT NULL,
                ended_at REAL,
                listened_seconds REAL NOT NULL DEFAULT 0,
                completed INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS listening_sessions_started
                ON listening_sessions(started_at);
            CREATE INDEX IF NOT EXISTS listening_sessions_track
                ON listening_sessions(track_id);
            INSERT OR IGNORE INTO schema_migrations(version, applied_at)
                VALUES (2, unixepoch());
            """
        )
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

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Sonora", isDirectory: true)
            .appendingPathComponent("Sonora.sqlite3")
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
