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

        try execute(
            """
            CREATE TABLE IF NOT EXISTS hub_memberships (
                hub_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                base_url TEXT NOT NULL,
                tls_fingerprint TEXT NOT NULL,
                replica_mode TEXT NOT NULL DEFAULT 'on_demand',
                server_cursor INTEGER NOT NULL DEFAULT 0,
                joined_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS hub_track_mappings (
                hub_id TEXT NOT NULL REFERENCES hub_memberships(hub_id),
                local_track_id TEXT NOT NULL REFERENCES tracks(id),
                hub_track_id TEXT NOT NULL,
                PRIMARY KEY(hub_id, local_track_id),
                UNIQUE(hub_id, hub_track_id)
            );
            CREATE TABLE IF NOT EXISTS sync_outbox (
                operation_id TEXT PRIMARY KEY,
                hub_id TEXT,
                device_id TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                operation TEXT NOT NULL,
                payload TEXT NOT NULL,
                physical_millis INTEGER NOT NULL,
                logical_counter INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                sent_at REAL
            );
            CREATE INDEX IF NOT EXISTS sync_outbox_pending
                ON sync_outbox(hub_id, sent_at, created_at);
            CREATE TABLE IF NOT EXISTS applied_sync_operations (
                operation_id TEXT PRIMARY KEY,
                hub_id TEXT NOT NULL,
                server_sequence INTEGER NOT NULL,
                applied_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_field_versions (
                hub_id TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                field_name TEXT NOT NULL,
                physical_millis INTEGER NOT NULL,
                logical_counter INTEGER NOT NULL,
                device_id TEXT NOT NULL,
                PRIMARY KEY(hub_id, entity_type, entity_id, field_name)
            );
            CREATE TABLE IF NOT EXISTS blob_availability (
                content_hash TEXT PRIMARY KEY,
                local_path TEXT,
                byte_count INTEGER,
                verified INTEGER NOT NULL DEFAULT 0,
                pinned INTEGER NOT NULL DEFAULT 0,
                last_accessed_at REAL,
                download_state TEXT NOT NULL DEFAULT 'absent'
            );
            CREATE INDEX IF NOT EXISTS blob_cache_lru
                ON blob_availability(pinned, last_accessed_at);
            CREATE TABLE IF NOT EXISTS sync_jobs (
                job_id TEXT PRIMARY KEY,
                hub_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                state TEXT NOT NULL,
                progress_completed INTEGER NOT NULL DEFAULT 0,
                progress_total INTEGER NOT NULL DEFAULT 0,
                resume_payload TEXT,
                error TEXT,
                updated_at REAL NOT NULL
            );
            INSERT OR IGNORE INTO sync_outbox
                (operation_id, device_id, entity_type, entity_id, operation,
                 payload, physical_millis, logical_counter, created_at)
            SELECT operation_id, device_id, entity_type, entity_id, operation,
                   payload, logical_clock, 0, created_at
            FROM changes
            WHERE entity_type = 'track_state';
            INSERT OR IGNORE INTO schema_migrations(version, applied_at)
                VALUES (4, unixepoch());
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_status (
                hub_id TEXT PRIMARY KEY,
                last_attempt_at REAL,
                last_success_at REAL,
                last_error TEXT,
                uploaded_operations INTEGER NOT NULL DEFAULT 0,
                applied_operations INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS sync_activity (
                id TEXT PRIMARY KEY,
                hub_id TEXT,
                kind TEXT NOT NULL,
                message TEXT NOT NULL,
                state TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS sync_activity_created
                ON sync_activity(created_at DESC);
            CREATE TABLE IF NOT EXISTS offline_album_pins (
                hub_id TEXT NOT NULL,
                album TEXT NOT NULL,
                PRIMARY KEY(hub_id, album)
            );
            INSERT OR IGNORE INTO schema_migrations(version, applied_at)
                VALUES (5, unixepoch());
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
