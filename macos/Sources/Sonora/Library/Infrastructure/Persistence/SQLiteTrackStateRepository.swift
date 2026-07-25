import SonoraCommon

import Foundation
import SQLite3

struct SQLiteTrackStateRepository: TrackStateRepository {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func setHidden(trackID: UUID, hidden: Bool) throws {
        try mutate(
            trackID: trackID,
            operation: hidden ? "hide" : "unhide",
            payload: "{\"hidden\":\(hidden)}"
        ) { connection, now in
            try run(
                """
                UPDATE track_state
                SET hidden = ?, updated_at = ?
                WHERE track_id = ?
                """,
                connection: connection
            ) {
                sqlite3_bind_int($0, 1, hidden ? 1 : 0)
                sqlite3_bind_double($0, 2, now)
                bind(trackID.uuidString, to: $0, at: 3)
            }
        }
    }

    func tombstone(trackID: UUID) throws {
        let now = Date().timeIntervalSince1970
        try mutate(
            trackID: trackID,
            operation: "delete",
            payload: "{\"deleted_at\":\(now)}",
            now: now
        ) { connection, timestamp in
            try run(
                """
                UPDATE track_state
                SET deleted_at = ?, updated_at = ?
                WHERE track_id = ?
                """,
                connection: connection
            ) {
                sqlite3_bind_double($0, 1, timestamp)
                sqlite3_bind_double($0, 2, timestamp)
                bind(trackID.uuidString, to: $0, at: 3)
            }
        }
    }

    private func mutate(
        trackID: UUID,
        operation: String,
        payload: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        update: (OpaquePointer, TimeInterval) throws -> Void
    ) throws {
        let result: Result<Void, Error>? = database.withConnection {
            connection in
            do {
                try execute("BEGIN IMMEDIATE", connection: connection)
                try update(connection, now)
                try appendChange(
                    trackID: trackID,
                    operation: operation,
                    payload: payload,
                    now: now,
                    connection: connection
                )
                try execute("COMMIT", connection: connection)
                return .success(())
            } catch {
                try? execute("ROLLBACK", connection: connection)
                return .failure(error)
            }
        }

        guard let result else {
            throw LibraryDatabaseError.unavailable
        }
        try result.get()
    }

    private func appendChange(
        trackID: UUID,
        operation: String,
        payload: String,
        now: TimeInterval,
        connection: OpaquePointer
    ) throws {
        try run(
            """
            INSERT INTO changes
                (operation_id, device_id, entity_type, entity_id, operation,
                 payload, logical_clock, created_at)
            VALUES (?, ?, 'track_state', ?, ?, ?, ?, ?)
            """,
            connection: connection
        ) {
            bind(UUID().uuidString, to: $0, at: 1)
            bind(database.deviceID.uuidString, to: $0, at: 2)
            bind(trackID.uuidString, to: $0, at: 3)
            bind(operation, to: $0, at: 4)
            bind(payload, to: $0, at: 5)
            sqlite3_bind_int64($0, 6, Int64(now * 1_000))
            sqlite3_bind_double($0, 7, now)
        }
    }

    private func run(
        _ sql: String,
        connection: OpaquePointer,
        bindings: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw databaseError(for: connection)
        }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(for: connection)
        }
    }

    private func execute(
        _ sql: String,
        connection: OpaquePointer
    ) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(for: connection)
        }
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

    private func databaseError(for connection: OpaquePointer) -> Error {
        guard let message = sqlite3_errmsg(connection) else {
            return LibraryDatabaseError.unavailable
        }
        return LibraryDatabaseError.sqlite(String(cString: message))
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
