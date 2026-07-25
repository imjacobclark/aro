import SonoraCommon

import Foundation
import SQLite3

struct SQLiteContentHashCache: ContentHashCaching {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func cachedContentHash(
        path: String,
        fileSize: Int64,
        modificationDate: Date
    ) -> String? {
        database.withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                """
                SELECT t.content_hash
                FROM file_locations AS l
                JOIN tracks AS t ON t.id = l.track_id
                WHERE l.device_id = ?
                  AND l.path = ?
                  AND l.file_size = ?
                  AND ABS(l.modification_date - ?) < 0.001
                LIMIT 1
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
                  let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            bind(database.deviceID.uuidString, to: statement, at: 1)
            bind(path, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, fileSize)
            sqlite3_bind_double(
                statement,
                4,
                modificationDate.timeIntervalSince1970
            )

            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return String(cString: value)
        } ?? nil
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
