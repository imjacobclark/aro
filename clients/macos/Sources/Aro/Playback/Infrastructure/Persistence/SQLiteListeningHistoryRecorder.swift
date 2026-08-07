import AroCommon

import Foundation
import SQLite3

struct SQLiteListeningHistoryRecorder: ListeningHistoryRecording {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func beginSession(trackID: UUID) -> UUID {
        let id = UUID()
        database.withConnection { connection in
            let now = Date().timeIntervalSince1970
            guard let statement = prepare(
                """
                INSERT INTO listening_sessions
                    (id, track_id, device_id, started_at, last_heartbeat_at,
                     listened_seconds, completed)
                VALUES (?, ?, ?, ?, ?, 0, 0)
                """,
                connection: connection
            ) else {
                return
            }
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, to: statement, at: 1)
            bind(trackID.uuidString, to: statement, at: 2)
            bind(database.deviceID.uuidString, to: statement, at: 3)
            sqlite3_bind_double(statement, 4, now)
            sqlite3_bind_double(statement, 5, now)
            sqlite3_step(statement)
        }
        return id
    }

    func heartbeat(sessionID: UUID) {
        update(
            sessionID: sessionID,
            ended: false,
            completed: false,
            skipped: false
        )
    }

    func endSession(sessionID: UUID, completed: Bool, skipped: Bool) {
        update(
            sessionID: sessionID,
            ended: true,
            completed: completed,
            skipped: skipped
        )
    }

    private func update(
        sessionID: UUID,
        ended: Bool,
        completed: Bool,
        skipped: Bool
    ) {
        database.withConnection { connection in
            let now = Date().timeIntervalSince1970
            guard let statement = prepare(
                """
                UPDATE listening_sessions
                SET listened_seconds = listened_seconds
                    + MAX(0, MIN(? - last_heartbeat_at, 10)),
                    last_heartbeat_at = ?,
                    ended_at = CASE WHEN ? THEN ? ELSE ended_at END,
                    completed = MAX(completed, ?),
                    skipped = MAX(skipped, ?)
                WHERE id = ? AND ended_at IS NULL
                """,
                connection: connection
            ) else {
                return
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now)
            sqlite3_bind_double(statement, 2, now)
            sqlite3_bind_int(statement, 3, ended ? 1 : 0)
            sqlite3_bind_double(statement, 4, now)
            sqlite3_bind_int(statement, 5, completed ? 1 : 0)
            sqlite3_bind_int(statement, 6, skipped ? 1 : 0)
            bind(sessionID.uuidString, to: statement, at: 7)
            sqlite3_step(statement)
            if ended, sqlite3_changes(connection) == 1 {
                appendCompletedSession(
                    sessionID: sessionID,
                    now: now,
                    connection: connection
                )
            }
        }
    }

    private func appendCompletedSession(
        sessionID: UUID,
        now: TimeInterval,
        connection: OpaquePointer
    ) {
        guard let statement = prepare(
            """
            INSERT OR IGNORE INTO sync_outbox
                (operation_id, device_id, entity_type, entity_id, operation,
                 payload, physical_millis, logical_counter, created_at)
            SELECT ?, device_id, 'listening_session', id, 'upsert',
                   printf(
                       '{"track_id":"%s","started_at":%f,"ended_at":%f,"listened_seconds":%f,"completed":%s,"skipped":%s}',
                       track_id, started_at, ended_at, listened_seconds,
                       CASE completed WHEN 1 THEN 'true' ELSE 'false' END,
                       CASE skipped WHEN 1 THEN 'true' ELSE 'false' END
                   ),
                   ?, 0, ?
            FROM listening_sessions WHERE id = ?
            """,
            connection: connection
        ) else {
            return
        }
        defer { sqlite3_finalize(statement) }
        bind(UUID().uuidString, to: statement, at: 1)
        sqlite3_bind_int64(statement, 2, Int64(now * 1_000))
        sqlite3_bind_double(statement, 3, now)
        bind(sessionID.uuidString, to: statement, at: 4)
        sqlite3_step(statement)
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
