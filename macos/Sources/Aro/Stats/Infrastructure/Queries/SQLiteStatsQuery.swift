import AroCommon

import Foundation
import SQLite3

struct SQLiteStatsQuery: StatsQuerying {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func listeningStats(now: Date) -> ListeningStats {
        database.withReadConnection { connection in
            var result = ListeningStats()
            if let statement = prepare(
                """
                SELECT COALESCE(SUM(listened_seconds), 0),
                       COALESCE(SUM(CASE WHEN started_at >= ?
                           THEN listened_seconds ELSE 0 END), 0),
                       COUNT(*), COUNT(DISTINCT track_id)
                FROM listening_sessions
                """,
                connection: connection
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

            result.daily = dailyListeningStats(
                now: now,
                connection: connection
            )
            result.topTracks = rankedListeningStats(
                groupExpression: "ls.track_id",
                titleExpression: "COALESCE(sm.title, 'Unknown Song')",
                subtitleExpression:
                    "COALESCE(sm.artist, 'Unknown Artist') || ' — ' || COALESCE(sm.album, 'Unknown Album')",
                limit: 5,
                connection: connection
            )
            result.topArtists = rankedListeningStats(
                groupExpression: "COALESCE(sm.artist, 'Unknown Artist')",
                titleExpression: "COALESCE(sm.artist, 'Unknown Artist')",
                subtitleExpression:
                    "COUNT(DISTINCT ls.track_id) || ' songs'",
                limit: 5,
                connection: connection
            )
            result.recent = recentListeningStats(
                limit: 8,
                connection: connection
            )
            return result
        } ?? ListeningStats()
    }

    func libraryStats() -> LibraryStats {
        database.withReadConnection { connection in
            var result = LibraryStats()
            let deviceID = database.deviceID.uuidString
            let baseWhere =
                """
                EXISTS (
                    SELECT 1 FROM file_locations l
                    WHERE l.track_id = t.id
                      AND l.device_id = '\(deviceID)'
                      AND l.available = 1
                )
                AND ts.hidden = 0
                AND ts.deleted_at IS NULL
                """
            if let statement = prepare(
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
                """,
                connection: connection
            ) {
                bind(deviceID, to: statement, at: 1)
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
                nameExpression: "UPPER(COALESCE(sm.codec, 'Unknown'))",
                deviceID: deviceID,
                connection: connection
            )
            result.genres = libraryBreakdown(
                nameExpression: "COALESCE(NULLIF(sm.genre, ''), 'Unknown')",
                deviceID: deviceID,
                connection: connection
            )
            result.decades = libraryBreakdown(
                nameExpression:
                    "CASE WHEN sm.release_year IS NULL THEN 'Unknown' ELSE ((sm.release_year / 10) * 10) || 's' END",
                deviceID: deviceID,
                connection: connection
            )
            return result
        } ?? LibraryStats()
    }

    private func dailyListeningStats(
        now: Date,
        connection: OpaquePointer
    ) -> [DailyListeningStat] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(
            for: now.addingTimeInterval(-29 * 86_400)
        )
        var secondsByDay: [Date: TimeInterval] = [:]
        if let statement = prepare(
            """
            SELECT date(started_at, 'unixepoch', 'localtime'),
                   SUM(listened_seconds)
            FROM listening_sessions
            WHERE started_at >= ?
            GROUP BY 1
            """,
            connection: connection
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
            guard let date = calendar.date(
                byAdding: .day,
                value: $0,
                to: start
            ) else {
                return nil
            }
            return DailyListeningStat(
                date: date,
                seconds: secondsByDay[date] ?? 0
            )
        }
    }

    private func rankedListeningStats(
        groupExpression: String,
        titleExpression: String,
        subtitleExpression: String,
        limit: Int,
        connection: OpaquePointer
    ) -> [RankedListeningStat] {
        guard let statement = prepare(
            """
            SELECT \(groupExpression), \(titleExpression),
                   \(subtitleExpression), COUNT(*)
            FROM listening_sessions ls
            LEFT JOIN scan_metadata sm ON sm.track_id = ls.track_id
            GROUP BY \(groupExpression)
            ORDER BY COUNT(*) DESC, \(titleExpression) COLLATE NOCASE
            LIMIT \(limit)
            """,
            connection: connection
        ) else {
            return []
        }
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

    private func recentListeningStats(
        limit: Int,
        connection: OpaquePointer
    ) -> [RecentPlayStat] {
        guard let statement = prepare(
            """
            SELECT ls.id, COALESCE(sm.title, 'Unknown Track'),
                   COALESCE(sm.artist, 'Unknown Artist') || ' — ' ||
                       COALESCE(sm.album, 'Unknown Album'),
                   ls.started_at
            FROM listening_sessions ls
            LEFT JOIN scan_metadata sm ON sm.track_id = ls.track_id
            ORDER BY ls.started_at DESC
            LIMIT \(limit)
            """,
            connection: connection
        ) else {
            return []
        }
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
        nameExpression: String,
        deviceID: String,
        connection: OpaquePointer
    ) -> [LibraryBreakdownStat] {
        guard let statement = prepare(
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
            """,
            connection: connection
        ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(deviceID, to: statement, at: 1)
        bind(deviceID, to: statement, at: 2)
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

    private func prepare(
        _ sql: String,
        connection: OpaquePointer
    ) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        return statement
    }

    private func text(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    private func bind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
