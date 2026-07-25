import SonoraCommon

import Foundation
import SQLite3

struct SQLiteLibraryHealthTrackQuery: LibraryHealthTrackQuerying {
    private let database: LibraryDatabase
    private let mapper: LibraryHealthTrackMapper

    init(
        database: LibraryDatabase,
        mapper: LibraryHealthTrackMapper = LibraryHealthTrackMapper()
    ) {
        self.database = database
        self.mapper = mapper
    }

    func libraryHealthTracks() -> [LibraryHealthTrack] {
        let records =
            database.withReadConnection { connection in
                loadRecords(
                    from: connection,
                    deviceID: database.deviceID.uuidString
                )
            } ?? []
        return records.compactMap(mapper.map)
    }

    private func loadRecords(
        from connection: OpaquePointer,
        deviceID: String
    ) -> [LibraryHealthTrackRecord] {
        let sql =
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
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                connection,
                sql,
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement
        else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bind(deviceID, to: statement, at: 1)

        var records: [String: LibraryHealthTrackRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0),
                let path = text(statement, 5)
            else {
                continue
            }
            if records[id] == nil {
                records[id] = LibraryHealthTrackRecord(
                    id: id,
                    contentHash: text(statement, 1),
                    title: text(statement, 2),
                    artist: text(statement, 3),
                    duration: optionalDouble(statement, 4),
                    copies: []
                )
            }
            records[id]?.copies.append(
                LibraryHealthCopyRecord(
                    path: path,
                    isAvailable:
                        sqlite3_column_int(statement, 6) != 0,
                    codec: text(statement, 8),
                    sampleRate: optionalDouble(statement, 9),
                    bitDepth: optionalInt(statement, 10),
                    bitrate: optionalDouble(statement, 11),
                    fileSizeBytes: sqlite3_column_int64(statement, 7)
                )
            )
        }
        return Array(records.values)
    }

    private func text(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String? {
        guard let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
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

    private func bind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) {
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
    }

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}
