//
//  Schema.swift
//  Beaver
//

import Foundation
import GRDB

/// SQL schema and migrations for the LogStore.
///
/// Schema reference lives in `ARCHITECTURE.md §4`. Every change to this
/// file is a new numbered migration appended below; never edit existing
/// migrations.
enum Schema {

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Catch programmer errors during schema evolution.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    started_at   INTEGER NOT NULL,
                    ended_at     INTEGER,
                    source       TEXT    NOT NULL,
                    client_label TEXT
                );
            """)

            try db.execute(sql: """
                CREATE TABLE event (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id   INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    timestamp_ms INTEGER NOT NULL,
                    level        TEXT    NOT NULL,
                    subsystem    TEXT    NOT NULL,
                    category     TEXT    NOT NULL,
                    message      TEXT    NOT NULL,
                    data_json    TEXT,
                    context_json TEXT
                );
            """)

            try db.execute(sql: """
                CREATE INDEX idx_event_session_ts
                    ON event(session_id, timestamp_ms);
            """)
            try db.execute(sql: """
                CREATE INDEX idx_event_level
                    ON event(session_id, level);
            """)
            try db.execute(sql: """
                CREATE INDEX idx_event_subsystem
                    ON event(session_id, subsystem);
            """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE event_fts USING fts5(
                    message,
                    subsystem,
                    category,
                    content='event',
                    content_rowid='id'
                );
            """)

            // Keep FTS index in sync with the event table.
            try db.execute(sql: """
                CREATE TRIGGER event_ai AFTER INSERT ON event BEGIN
                    INSERT INTO event_fts(rowid, message, subsystem, category)
                    VALUES (new.id, new.message, new.subsystem, new.category);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER event_ad AFTER DELETE ON event BEGIN
                    INSERT INTO event_fts(event_fts, rowid, message, subsystem, category)
                    VALUES('delete', old.id, old.message, old.subsystem, old.category);
                END;
            """)

            try db.execute(sql: """
                CREATE TABLE storage_snapshot (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id  INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    taken_at    INTEGER NOT NULL,
                    namespace   TEXT    NOT NULL,
                    data_json   TEXT    NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_storage_session_namespace
                    ON storage_snapshot(session_id, namespace, taken_at DESC);
            """)

            try db.execute(sql: """
                CREATE TABLE saved_filter (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    name        TEXT    NOT NULL UNIQUE,
                    min_level   TEXT    NOT NULL,
                    search      TEXT,
                    search_rx   INTEGER NOT NULL DEFAULT 0,
                    exclude     TEXT,
                    exclude_rx  INTEGER NOT NULL DEFAULT 0
                );
            """)

            try db.execute(sql: """
                CREATE TABLE command_history (
                    id        INTEGER PRIMARY KEY AUTOINCREMENT,
                    command   TEXT    NOT NULL,
                    issued_at INTEGER NOT NULL
                );
            """)
        }

        migrator.registerMigration("v2_bookmarks") { db in
            // Bookmark / pinned events. Stores a pointer to an event by
            // (session_id, event_id). UNIQUE on event_id makes the
            // toggle action idempotent — toggling on a bookmarked event
            // just removes it, no duplicate rows possible.
            try db.execute(sql: """
                CREATE TABLE event_bookmark (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id  INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    event_id    INTEGER NOT NULL UNIQUE,
                    note        TEXT,
                    created_at  INTEGER NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_bookmark_session
                    ON event_bookmark(session_id, created_at DESC);
            """)
        }

        migrator.registerMigration("v3_session_device_info") { db in
            // Capture the connected device's identity on the session
            // row itself so past sessions remember which app / device /
            // OS they came from — surfaced both in the toolbar badge
            // when re-opening an old session and in the SessionsView
            // list rows.
            //
            // Pulled from the SDK's applicaster.v2 storage namespace
            // the first time it arrives for a session. Plain TEXT
            // columns (not a JSON blob) so future queries can group
            // by deviceModel etc. without a JSON1 dance. All
            // nullable: imported sessions and SDKs that don't write
            // applicaster.v2 just leave them blank.
            try db.execute(sql: """
                ALTER TABLE session ADD COLUMN app_name      TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE session ADD COLUMN app_version   TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE session ADD COLUMN device_model  TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE session ADD COLUMN platform      TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE session ADD COLUMN os_version    TEXT;
            """)
        }

        return migrator
    }
}
