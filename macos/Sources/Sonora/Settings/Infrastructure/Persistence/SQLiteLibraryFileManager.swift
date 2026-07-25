import SonoraCommon

import Foundation
import SQLite3

struct SQLiteLibraryFileManager: LibraryFileManaging {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    var libraryURL: URL {
        database.url
    }

    func exportLibrary(to destinationURL: URL) throws {
        let result: Result<Void, Error>? = database.withConnection {
            source in
            if sqlite3_exec(
                source,
                "PRAGMA wal_checkpoint(FULL)",
                nil,
                nil,
                nil
            ) != SQLITE_OK {
                return .failure(databaseError(for: source))
            }

            var destination: OpaquePointer?
            guard sqlite3_open(destinationURL.path, &destination) == SQLITE_OK,
                  let destination else {
                if let destination {
                    sqlite3_close(destination)
                }
                return .failure(LibraryDatabaseError.unavailable)
            }
            defer { sqlite3_close(destination) }

            guard let backup = sqlite3_backup_init(
                destination,
                "main",
                source,
                "main"
            ) else {
                return .failure(databaseError(for: destination))
            }
            defer { sqlite3_backup_finish(backup) }

            guard sqlite3_backup_step(backup, -1) == SQLITE_DONE else {
                return .failure(databaseError(for: destination))
            }
            return .success(())
        }

        guard let result else {
            throw LibraryDatabaseError.unavailable
        }
        try result.get()
    }

    private func databaseError(for connection: OpaquePointer) -> Error {
        guard let message = sqlite3_errmsg(connection) else {
            return LibraryDatabaseError.unavailable
        }
        return LibraryDatabaseError.sqlite(String(cString: message))
    }
}
