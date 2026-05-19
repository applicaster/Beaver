//
//  LogStore.swift
//  LoggerNext
//

import Foundation
import GRDB

/// Single-writer, multi-reader event store backed by SQLite via GRDB.
///
/// All persistence flows through this actor. View models read snapshots
/// and subscribe to `changes(for:filter:)` for live updates. See
/// `ARCHITECTURE.md §4`.
public actor LogStore {

    /// Notification of a state change in the store.
    public enum Change: Sendable {
        case appended(sessionId: Int64, count: Int)
        case cleared(sessionId: Int64)
        case sessionStarted(Session)
        case sessionEnded(Session)
        case sessionDeleted(id: Int64)
        case sessionsCleared
        case storageUpdated(sessionId: Int64, namespace: StorageSnapshot.Namespace)
        case bookmarksChanged(sessionId: Int64)
        case savedFiltersChanged
    }

    public enum Source {
        /// On-disk store at the canonical Application Support location.
        case onDisk(URL)
        /// In-memory store for tests.
        case inMemory
    }

    private let dbQueue: DatabaseQueue

    /// Batched-append queue. Flushed at most every `flushInterval`.
    private var pendingAppends: [(sessionId: Int64, event: DecodedEvent)] = []
    private var flushTask: Task<Void, Never>?
    private let flushInterval: Duration = .milliseconds(50)

    /// Continuations for live change subscribers. Each subscriber gets
    /// every change; filtering happens at the view-model layer.
    private var subscribers: [UUID: AsyncStream<Change>.Continuation] = [:]

    // MARK: - Lifecycle

    public init(source: Source) throws {
        let configuration: Configuration = {
            var c = Configuration()
            c.foreignKeysEnabled = true
            // Register the `REGEXP` SQL function on every connection so
            // queries can use `column REGEXP ?` for regex matching.
            // SQLite invokes this as REGEXP(pattern, value); the matcher
            // is NSRegularExpression so patterns follow ICU syntax.
            c.prepareDatabase { db in
                db.add(function: Self.regexpFunction)
            }
            return c
        }()

        switch source {
        case .onDisk(let url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            self.dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        case .inMemory:
            self.dbQueue = try DatabaseQueue(configuration: configuration)
        }

        try Schema.migrator().migrate(self.dbQueue)
    }

    /// SQLite custom function exposed as `REGEXP`.
    ///
    /// Invocation: `value REGEXP pattern` → SQLite rewrites to
    /// `REGEXP(pattern, value)`. Returns 1 / 0 (NSNumber-bridged Bool).
    /// On invalid pattern or NULL value, returns 0 (no match) rather
    /// than throwing — keeping a malformed regex from killing a query.
    nonisolated static let regexpFunction = DatabaseFunction(
        "REGEXP",
        argumentCount: 2,
        pure: true
    ) { values -> Bool in
        guard
            let pattern = String.fromDatabaseValue(values[0]),
            let value   = String.fromDatabaseValue(values[1]),
            let regex   = try? NSRegularExpression(pattern: pattern)
        else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    /// Canonical on-disk location used by the app target.
    public static func defaultStoreURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("LoggerNext", isDirectory: true)
        return dir.appendingPathComponent("store.sqlite", isDirectory: false)
    }

    // MARK: - Subscriptions

    public func changes() -> AsyncStream<Change> {
        AsyncStream { continuation in
            let token = UUID()
            self.register(token: token, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unregister(token: token) }
            }
        }
    }

    private func register(token: UUID, continuation: AsyncStream<Change>.Continuation) {
        subscribers[token] = continuation
    }

    private func unregister(token: UUID) {
        subscribers[token] = nil
    }

    private func broadcast(_ change: Change) {
        for continuation in subscribers.values {
            continuation.yield(change)
        }
    }

    // MARK: - Sessions

    public func createSession(
        source: Session.Source,
        clientLabel: String? = nil
    ) async throws -> Session {
        let now = Date()
        let id = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session (started_at, source, client_label)
                    VALUES (?, ?, ?)
                """,
                arguments: [
                    Int(now.timeIntervalSince1970 * 1000),
                    source.rawValue,
                    clientLabel,
                ]
            )
            return db.lastInsertedRowID
        }
        let session = Session(id: id, startedAt: now, source: source, clientLabel: clientLabel)
        broadcast(.sessionStarted(session))
        return session
    }

    public func endSession(_ id: Int64) async throws {
        let now = Date()
        let endedSession: Session? = try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE session SET ended_at = ? WHERE id = ?",
                arguments: [Int(now.timeIntervalSince1970 * 1000), id]
            )
            return try Self.fetchSession(id: id, db: db)
        }
        if let endedSession {
            broadcast(.sessionEnded(endedSession))
        }
    }

    public func sessions() async throws -> [Session] {
        try await dbQueue.read { db in
            try Self.fetchAllSessions(db: db)
        }
    }

    /// Delete a single session row. Cascading FKs wipe its events,
    /// storage snapshots, and bookmarks. Broadcasts
    /// `.sessionDeleted(id:)` so view models can refresh their lists
    /// and clear viewing-state if it pointed at this row.
    ///
    /// No-op if `id` doesn't exist (idempotent so the UI can fire
    /// repeated deletes safely).
    public func deleteSession(id: Int64) async throws {
        let deleted: Bool = try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM session WHERE id = ?",
                arguments: [id]
            )
            return db.changesCount > 0
        }
        if deleted {
            broadcast(.sessionDeleted(id: id))
        }
    }

    /// Delete every session row. Cascades through events, storage
    /// snapshots, and bookmarks. Broadcasts `.sessionsCleared` once,
    /// even on an empty store, so the UI's "are you sure?" path can
    /// safely settle into the empty state.
    public func deleteAllSessions() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM session")
        }
        broadcast(.sessionsCleared)
    }

    /// Delete every event row in a session plus any bookmarks that
    /// pointed at those events. Used by the "Clear" toolbar button.
    /// The session row itself is kept.
    public func clearEvents(sessionId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM event WHERE session_id = ?",
                arguments: [sessionId]
            )
            // Bookmarks reference event ids by value (no FK cascade on
            // event.id), so wipe them alongside their events to avoid
            // orphaned rows.
            try db.execute(
                sql: "DELETE FROM event_bookmark WHERE session_id = ?",
                arguments: [sessionId]
            )
        }
        broadcast(.cleared(sessionId: sessionId))
        broadcast(.bookmarksChanged(sessionId: sessionId))
    }

    /// Append a batch of decoded events in a single transaction. Used by
    /// the Import flow (D7) which creates a session and writes events
    /// from a JSON file as a single bulk operation.
    public func appendBulk(_ events: [DecodedEvent], to sessionId: Int64) async throws {
        guard !events.isEmpty else { return }
        try await dbQueue.write { db in
            for event in events {
                try db.execute(
                    sql: """
                        INSERT INTO event
                          (session_id, timestamp_ms, level, subsystem,
                           category, message, data_json, context_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        sessionId,
                        Int(event.timestampMillis),
                        event.level.rawValue,
                        event.subsystem,
                        event.category,
                        event.message,
                        event.dataJSON,
                        event.contextJSON,
                    ]
                )
            }
        }
        broadcast(.appended(sessionId: sessionId, count: events.count))
    }

    // MARK: - Events: append

    /// Enqueue a decoded event for batched insertion. Returns immediately;
    /// the actual write happens within `flushInterval`.
    public func append(_ event: DecodedEvent, to sessionId: Int64) {
        pendingAppends.append((sessionId, event))
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard !pendingAppends.isEmpty else { return }
        let batch = pendingAppends
        pendingAppends.removeAll(keepingCapacity: true)

        do {
            try await dbQueue.write { db in
                for (sessionId, event) in batch {
                    try db.execute(
                        sql: """
                            INSERT INTO event
                              (session_id, timestamp_ms, level, subsystem,
                               category, message, data_json, context_json)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            sessionId,
                            Int(event.timestampMillis),
                            event.level.rawValue,
                            event.subsystem,
                            event.category,
                            event.message,
                            event.dataJSON,
                            event.contextJSON,
                        ]
                    )
                }
            }
            let bySession = Dictionary(grouping: batch, by: \.sessionId)
            for (sessionId, items) in bySession {
                broadcast(.appended(sessionId: sessionId, count: items.count))
            }
        } catch {
            // Surface via a dedicated error stream in a future iteration.
            // TODO: append a synthetic error event tagged
            // 'loggernext.store' so the user sees write failures in-feed.
            print("LogStore flush failed: \(error)")
        }
    }

    // MARK: - Events: query

    public func eventCount(sessionId: Int64, filter: Filter) async throws -> Int {
        try await dbQueue.read { db in
            let (whereClause, args) = Self.where(filter: filter, sessionId: sessionId)
            // Use Int.fetchOne so GRDB does the SQLite INTEGER -> Int
            // conversion correctly. The previous `row?["c"] as? Int`
            // pattern returned nil because COUNT(*) arrives as Int64,
            // which doesn't cast directly to Int in Swift.
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM event \(whereClause)",
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    public func events(
        sessionId: Int64,
        filter: Filter,
        offset: Int,
        limit: Int
    ) async throws -> [EventRecord] {
        try await dbQueue.read { db in
            let (whereClause, args) = Self.where(filter: filter, sessionId: sessionId)
            let sql = """
                SELECT id, session_id, timestamp_ms, level, subsystem,
                       category, message, data_json, context_json
                FROM event
                \(whereClause)
                ORDER BY timestamp_ms ASC, id ASC
                LIMIT ? OFFSET ?
            """
            var fullArgs = args
            fullArgs.append(contentsOf: [limit, offset])
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(fullArgs))
            return rows.map(Self.makeEventRecord)
        }
    }

    // MARK: - Bookmarks

    /// Add a bookmark for `eventId` in `sessionId`. If already
    /// bookmarked, this is a no-op (the UNIQUE constraint on event_id
    /// is honored by `INSERT OR IGNORE`).
    public func addBookmark(
        eventId: Int64,
        sessionId: Int64,
        note: String? = nil
    ) async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let inserted = try await dbQueue.write { db -> Int in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO event_bookmark
                        (session_id, event_id, note, created_at)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [sessionId, eventId, note, now]
            )
            return db.changesCount
        }
        print("[Bookmarks] addBookmark event=\(eventId) session=\(sessionId) inserted=\(inserted)")
        broadcast(.bookmarksChanged(sessionId: sessionId))
    }

    /// Remove the bookmark for `eventId`. Broadcasts even if no row
    /// was deleted (e.g., already removed) so subscribers refresh
    /// idempotently.
    public func removeBookmark(eventId: Int64, sessionId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM event_bookmark WHERE event_id = ?",
                arguments: [eventId]
            )
        }
        broadcast(.bookmarksChanged(sessionId: sessionId))
    }

    /// Return the set of bookmarked event IDs in a session — used to
    /// drive the per-row star indicator in the table.
    public func bookmarkedEventIds(sessionId: Int64) async throws -> Set<Int64> {
        let ids: [Int64] = try await dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT event_id FROM event_bookmark WHERE session_id = ?",
                arguments: [sessionId]
            )
        }
        return Set(ids)
    }

    /// Bookmarks joined with their underlying events, ordered newest
    /// bookmark first, for the bookmarks popover.
    public func bookmarks(sessionId: Int64) async throws -> [BookmarkedEvent] {
        let result: [BookmarkedEvent] = try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT b.id            AS bid,
                           b.session_id    AS bsid,
                           b.event_id      AS beid,
                           b.note          AS bnote,
                           b.created_at    AS bca,
                           e.id            AS eid,
                           e.session_id    AS esid,
                           e.timestamp_ms  AS ets,
                           e.level         AS elevel,
                           e.subsystem     AS esub,
                           e.category      AS ecat,
                           e.message       AS emsg,
                           e.data_json     AS edata,
                           e.context_json  AS ectx
                    FROM event_bookmark b
                    INNER JOIN event e ON e.id = b.event_id
                    WHERE b.session_id = ?
                    ORDER BY b.created_at DESC
                """,
                arguments: [sessionId]
            )
            return rows.map { row in
                let bookmark = Bookmark(
                    id: row["bid"],
                    sessionId: row["bsid"],
                    eventId: row["beid"],
                    note: row["bnote"],
                    createdAt: Date(timeIntervalSince1970: TimeInterval(row["bca"] as Int) / 1000.0)
                )
                let event = EventRecord(
                    id: row["eid"],
                    sessionId: row["esid"],
                    timestampMillis: UInt64(row["ets"] as Int),
                    level: LogLevel(rawValue: row["elevel"]) ?? .info,
                    subsystem: row["esub"],
                    category: row["ecat"],
                    message: row["emsg"],
                    dataJSON: row["edata"],
                    contextJSON: row["ectx"]
                )
                return BookmarkedEvent(bookmark: bookmark, event: event)
            }
        }
        // Diagnostic: also count rows in event_bookmark directly so we
        // can see if it's the INNER JOIN that's losing them.
        let rawCount = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM event_bookmark WHERE session_id = ?",
                arguments: [sessionId]
            ) ?? 0
        }
        print("[Bookmarks] bookmarks(session=\(sessionId)) -> joined=\(result.count) raw=\(rawCount)")
        return result
    }

    // MARK: - Match navigation (Search & highlight)

    /// Returns the event IDs in the filtered ordering (timestamp ASC,
    /// id ASC) that ALSO match the highlight term. Used for the
    /// jump-to-match navigation.
    public func matchingIds(
        sessionId: Int64,
        filter: Filter,
        highlight: String,
        isRegex: Bool
    ) async throws -> [Int64] {
        try await dbQueue.read { db in
            let (whereClause, args) = Self.where(filter: filter, sessionId: sessionId)
            var sql = "SELECT id FROM event \(whereClause)"
            var fullArgs = args
            if isRegex {
                sql += " AND (message REGEXP ? OR subsystem REGEXP ? OR category REGEXP ?)"
                fullArgs.append(contentsOf: [highlight, highlight, highlight])
            } else {
                let likeTerm = "%\(highlight)%"
                sql += " AND (message LIKE ? OR subsystem LIKE ? OR category LIKE ?)"
                fullArgs.append(contentsOf: [likeTerm, likeTerm, likeTerm])
            }
            sql += " ORDER BY timestamp_ms ASC, id ASC"
            return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(fullArgs))
        }
    }

    /// Earliest event timestamp in the session, regardless of filter.
    /// Used by the Jump-to-Time UI to rebase a typed time-of-day onto
    /// the session's calendar day (so an imported session from 2026-05-15
    /// jumps correctly when the user types "12:13:42" even though
    /// "today" is 2026-05-19). Returns nil if the session is empty.
    public func sessionFirstEventTimestampMillis(
        sessionId: Int64
    ) async throws -> Int64? {
        try await dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT timestamp_ms FROM event
                    WHERE session_id = ?
                    ORDER BY timestamp_ms ASC
                    LIMIT 1
                """,
                arguments: [sessionId]
            )
        }
    }

    /// Find the event in the session (respecting the current filter)
    /// whose `timestamp_ms` is closest to `targetMillis`. Used by the
    /// "Jump to Time" toolbar action — "the app crashed at 14:13:42" →
    /// scroll to the nearest visible event. Returns nil if no events
    /// match the filter.
    public func nearestEventId(
        sessionId: Int64,
        targetMillis: Int64,
        filter: Filter
    ) async throws -> Int64? {
        try await dbQueue.read { db in
            let (whereClause, args) = Self.where(filter: filter, sessionId: sessionId)
            let sql = """
                SELECT id FROM event
                \(whereClause)
                ORDER BY ABS(timestamp_ms - ?) ASC, id ASC
                LIMIT 1
            """
            var fullArgs = args
            fullArgs.append(targetMillis)
            return try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(fullArgs))
        }
    }

    /// Returns the zero-based offset of `eventId` in the filtered
    /// ordering. Used by jump-to-match to figure out which page-window
    /// position to scroll to.
    public func offset(of eventId: Int64,
                       sessionId: Int64,
                       filter: Filter) async throws -> Int? {
        try await dbQueue.read { db in
            // 1) Look up the target's timestamp_ms.
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT timestamp_ms FROM event WHERE id = ? AND session_id = ?",
                arguments: [eventId, sessionId]
            ) else { return nil }
            let ts: Int = row["timestamp_ms"]

            // 2) Count filtered events that sort before it.
            let (whereClause, args) = Self.where(filter: filter, sessionId: sessionId)
            let sql = """
                SELECT COUNT(*) FROM event
                \(whereClause)
                AND (timestamp_ms < ? OR (timestamp_ms = ? AND id < ?))
            """
            var fullArgs = args
            fullArgs.append(ts)
            fullArgs.append(ts)
            fullArgs.append(eventId)
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(fullArgs)) ?? 0
        }
    }

    // MARK: - Saved filters

    /// All persisted filter presets, alphabetical by name.
    public func savedFilters() async throws -> [SavedFilter] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, min_level, search, search_rx, exclude, exclude_rx
                    FROM saved_filter
                    ORDER BY name COLLATE NOCASE
                """
            ).map(Self.makeSavedFilter)
        }
    }

    /// Insert a preset, or update the existing one if `name` is taken
    /// (upsert by name). The schema has a UNIQUE index on `name`, so
    /// the "save as" UX maps cleanly onto INSERT OR REPLACE.
    @discardableResult
    public func upsertSavedFilter(
        name: String,
        filter: Filter
    ) async throws -> SavedFilter {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Invariant should be enforced by the UI's Save button
            // being disabled when the name field is empty.
            throw NSError(
                domain: "LogStore.SavedFilter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Saved-filter name must not be empty."]
            )
        }
        let id = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO saved_filter
                      (name, min_level, search, search_rx, exclude, exclude_rx)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                      min_level  = excluded.min_level,
                      search     = excluded.search,
                      search_rx  = excluded.search_rx,
                      exclude    = excluded.exclude,
                      exclude_rx = excluded.exclude_rx
                """,
                arguments: [
                    trimmed,
                    filter.minLevel.rawValue,
                    filter.search,
                    filter.searchIsRegex ? 1 : 0,
                    filter.exclude,
                    filter.excludeIsRegex ? 1 : 0,
                ]
            )
            // Need the id after upsert — fetch it back by name.
            return try Int64.fetchOne(
                db,
                sql: "SELECT id FROM saved_filter WHERE name = ?",
                arguments: [trimmed]
            ) ?? -1
        }
        broadcast(.savedFiltersChanged)
        return SavedFilter(id: id, name: trimmed, filter: filter)
    }

    public func deleteSavedFilter(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM saved_filter WHERE id = ?",
                arguments: [id]
            )
        }
        broadcast(.savedFiltersChanged)
    }

    private static func makeSavedFilter(_ row: Row) -> SavedFilter {
        let level = LogLevel(rawValue: row["min_level"] as String) ?? .verbose
        let filter = Filter(
            minLevel: level,
            search: row["search"] as String?,
            searchIsRegex: ((row["search_rx"] as Int?) ?? 0) != 0,
            exclude: row["exclude"] as String?,
            excludeIsRegex: ((row["exclude_rx"] as Int?) ?? 0) != 0
        )
        return SavedFilter(id: row["id"], name: row["name"], filter: filter)
    }

    // MARK: - Storage snapshots

    public func recordStorageSnapshot(
        sessionId: Int64,
        namespace: StorageSnapshot.Namespace,
        dataJSON: String
    ) async throws {
        let now = Date()
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO storage_snapshot
                      (session_id, taken_at, namespace, data_json)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    sessionId,
                    Int(now.timeIntervalSince1970 * 1000),
                    namespace.rawValue,
                    dataJSON,
                ]
            )
        }
        broadcast(.storageUpdated(sessionId: sessionId, namespace: namespace))
    }

    public func latestStorageSnapshot(
        sessionId: Int64,
        namespace: StorageSnapshot.Namespace
    ) async throws -> StorageSnapshot? {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, session_id, taken_at, namespace, data_json
                    FROM storage_snapshot
                    WHERE session_id = ? AND namespace = ?
                    ORDER BY taken_at DESC
                    LIMIT 1
                """,
                arguments: [sessionId, namespace.rawValue]
            )
            return row.map(Self.makeStorageSnapshot)
        }
    }

    // MARK: - Helpers

    private static func fetchSession(id: Int64, db: Database) throws -> Session? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, started_at, ended_at, source, client_label
                FROM session WHERE id = ?
            """,
            arguments: [id]
        ).map(makeSession)
    }

    private static func fetchAllSessions(db: Database) throws -> [Session] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, started_at, ended_at, source, client_label
                FROM session
                ORDER BY started_at DESC
            """
        ).map(makeSession)
    }

    private static func makeSession(_ row: Row) -> Session {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(row["started_at"] as Int) / 1000.0)
        let endedAt = (row["ended_at"] as Int?).map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000.0)
        }
        let sourceRaw: String = row["source"]
        return Session(
            id: row["id"],
            startedAt: startedAt,
            endedAt: endedAt,
            source: Session.Source(rawValue: sourceRaw) ?? .live,
            clientLabel: row["client_label"]
        )
    }

    private static func makeEventRecord(_ row: Row) -> EventRecord {
        EventRecord(
            id: row["id"],
            sessionId: row["session_id"],
            timestampMillis: UInt64(row["timestamp_ms"] as Int),
            level: LogLevel(rawValue: row["level"]) ?? .info,
            subsystem: row["subsystem"],
            category: row["category"],
            message: row["message"],
            dataJSON: row["data_json"],
            contextJSON: row["context_json"]
        )
    }

    private static func makeStorageSnapshot(_ row: Row) -> StorageSnapshot {
        let takenAt = Date(timeIntervalSince1970: TimeInterval(row["taken_at"] as Int) / 1000.0)
        return StorageSnapshot(
            id: row["id"],
            sessionId: row["session_id"],
            takenAt: takenAt,
            namespace: StorageSnapshot.Namespace(rawValue: row["namespace"]) ?? .session,
            dataJSON: row["data_json"]
        )
    }

    /// Translate a `Filter` into a SQL WHERE clause + bound arguments.
    ///
    /// Substring search uses `LIKE '%x%'` across message/subsystem/
    /// category. Regex uses the custom `REGEXP` function registered in
    /// `init`. FTS5 was tried first but its prefix-match semantics
    /// (`'l*'` returns every word starting with `l`) produced huge
    /// candidate sets for short terms, making `NOT IN` exclude queries
    /// pathological. `LIKE` on session-narrowed rows is fast enough
    /// at our scale (~100k events).
    private static func `where`(
        filter: Filter,
        sessionId: Int64
    ) -> (String, [any DatabaseValueConvertible]) {
        var clauses: [String] = ["session_id = ?"]
        var args: [any DatabaseValueConvertible] = [sessionId]

        // Level
        if filter.minLevel != .verbose {
            let allowed = LogLevel.allCases
                .filter { $0.severity >= filter.minLevel.severity }
                .map(\.rawValue)
            let placeholders = allowed.map { _ in "?" }.joined(separator: ", ")
            clauses.append("level IN (\(placeholders))")
            args.append(contentsOf: allowed)
        }

        // Search
        if let search = filter.search {
            if filter.searchIsRegex {
                clauses.append(
                    "(message REGEXP ? OR subsystem REGEXP ? OR category REGEXP ?)"
                )
                args.append(contentsOf: [search, search, search])
            } else {
                let likeTerm = "%\(search)%"
                clauses.append(
                    "(message LIKE ? OR subsystem LIKE ? OR category LIKE ?)"
                )
                args.append(contentsOf: [likeTerm, likeTerm, likeTerm])
            }
        }

        // Exclude
        if let exclude = filter.exclude {
            if filter.excludeIsRegex {
                clauses.append(
                    "NOT (message REGEXP ? OR subsystem REGEXP ? OR category REGEXP ?)"
                )
                args.append(contentsOf: [exclude, exclude, exclude])
            } else {
                let likeTerm = "%\(exclude)%"
                clauses.append(
                    "NOT (message LIKE ? OR subsystem LIKE ? OR category LIKE ?)"
                )
                args.append(contentsOf: [likeTerm, likeTerm, likeTerm])
            }
        }

        return ("WHERE " + clauses.joined(separator: " AND "), args)
    }
}
