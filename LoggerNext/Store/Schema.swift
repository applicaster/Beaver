//
//  Schema.swift
//  LoggerNext
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

        // Future migrations:
        // migrator.registerMigration("v2_<change>") { db in ... }

        return migrator
    }
}
