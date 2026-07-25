import SonoraCommon

import SQLite3

struct SQLiteSchemaMigrator {
    let connection: OpaquePointer

    func migrate() throws {
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
                track_id TEXT PRIMARY KEY
                    REFERENCES tracks(id) ON DELETE CASCADE,
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
                artwork BLOB,
                scanned_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS track_state (
                track_id TEXT PRIMARY KEY
                    REFERENCES tracks(id) ON DELETE CASCADE,
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

        // These are idempotent compatibility migrations for libraries created
        // before the metadata columns were included in the initial schema.
        try? execute("ALTER TABLE scan_metadata ADD COLUMN album TEXT")
        try? execute("ALTER TABLE scan_metadata ADD COLUMN genre TEXT")
        try? execute(
            "ALTER TABLE scan_metadata ADD COLUMN release_year INTEGER"
        )
        try? execute("ALTER TABLE scan_metadata ADD COLUMN artwork BLOB")

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

        try execute(
            """
            INSERT OR IGNORE INTO schema_migrations(version, applied_at)
                VALUES (3, unixepoch());
            """
        )
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            guard let message = sqlite3_errmsg(connection) else {
                throw LibraryDatabaseError.unavailable
            }
            throw LibraryDatabaseError.sqlite(String(cString: message))
        }
    }
}
