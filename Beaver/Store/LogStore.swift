//
//  LogStore.swift
//  Beaver
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
        /// Emitted when a session's *metadata* changes
        /// (currently just the device-info fields populated from
        /// applicaster.v2). Lets SessionsViewModel rebuild its
        /// rows without having to subscribe to storageUpdated.
        case sessionUpdated(Session)
        case sessionsCleared
        case storageUpdated(sessionId: Int64, namespace: StorageSnapshot.Namespace)
        case bookmarksChanged(sessionId: Int64)
        case savedFiltersChanged
        case networkAppended(sessionId: Int64)
        case networkBookmarksChanged(sessionId: Int64)
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
            let regex   = compiledRegex(pattern)
        else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    /// SQLite calls REGEXP once per row and column with the same pattern;
    /// compiling it each time cost ~350 ms over 50k events. Failures are
    /// remembered too, so a half-typed pattern isn't recompiled per row.
    private nonisolated(unsafe) static let regexCache: NSCache<NSString, RegexBox> = {
        let c = NSCache<NSString, RegexBox>()
        c.countLimit = 32
        return c
    }()

    private final class RegexBox: Sendable {
        let regex: NSRegularExpression?
        init(_ regex: NSRegularExpression?) { self.regex = regex }
    }

    /// Also used by `NetworkFilter`, which asks for `(?i)` patterns.
    nonisolated static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        if let hit = regexCache.object(forKey: pattern as NSString) { return hit.regex }
        let regex = try? NSRegularExpression(pattern: pattern)
        regexCache.setObject(RegexBox(regex), forKey: pattern as NSString)
        return regex
    }

    /// Canonical on-disk location used by the app target.
    public static func defaultStoreURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Intentionally "LoggerNext", not "Beaver" — this is the
        // persistence anchor for every existing install. Renaming
        // would orphan users' sessions / bookmarks / storage
        // snapshots. The bundle ID is kept as
        // com.applicaster.LoggerNext for the same reason (see D38).
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

    /// Record the connected device + app fingerprint on the session
    /// row. Called the first time the SDK's `applicaster.v2` storage
    /// namespace arrives for a session — see
    /// `LogStore.applyStorageSnapshot` and the V3 schema migration.
    ///
    /// Only updates columns whose new value is non-nil so a later
    /// snapshot that omits a field doesn't blow away earlier data.
    /// Idempotent: re-calling with the same values is a no-op as
    /// far as broadcasts are concerned, but we still do the UPDATE
    /// for simplicity.
    public func setSessionDeviceInfo(
        id: Int64,
        appName: String?,
        appVersion: String?,
        deviceModel: String?,
        platform: String?,
        osVersion: String?
    ) async throws {
        let updated: Session? = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE session SET
                        app_name     = COALESCE(?, app_name),
                        app_version  = COALESCE(?, app_version),
                        device_model = COALESCE(?, device_model),
                        platform     = COALESCE(?, platform),
                        os_version   = COALESCE(?, os_version)
                    WHERE id = ?
                """,
                arguments: [
                    appName, appVersion, deviceModel, platform, osVersion, id,
                ]
            )
            return try Self.fetchSession(id: id, db: db)
        }
        if let updated {
            // Use sessionEnded(…) broadcast? No — that has different
            // semantics. The sessions list refreshes off
            // `.sessionStarted` / `.sessionEnded` / `.sessionDeleted`
            // / `.appended`. Device info doesn't fit any of those
            // cleanly, so we piggyback on `.sessionUpdated` (added
            // alongside this method).
            broadcast(.sessionUpdated(updated))
        }
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
            try db.execute(
                sql: "DELETE FROM network_entry WHERE session_id = ?",
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

    /// Subsystem (or category) values with their event counts, for the chip
    /// menus. Every filter applies except this facet's own chips, so picking
    /// subsystems narrows the category menu and vice versa without a pick
    /// hiding its siblings. Empty strings are dropped. Values the filter
    /// includes or excludes but that no longer match come back last with
    /// count 0, so a selection can always be seen and removed.
    public func facetCounts(
        sessionId: Int64,
        facet: Filter.Facet,
        filter: Filter
    ) async throws -> [FacetCount] {
        let column = facet == .subsystem ? "subsystem" : "category"
        var others = filter
        others.clearChips(in: facet)
        let found = try await dbQueue.read { [others] db in
            // `where` always returns a clause starting with WHERE.
            let (whereClause, args) = Self.where(filter: others, sessionId: sessionId)
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT \(column) AS value, COUNT(*) AS n FROM event
                    \(whereClause) AND \(column) <> ''
                    GROUP BY \(column)
                    ORDER BY n DESC, \(column) COLLATE NOCASE
                """,
                arguments: StatementArguments(args)
            ).map { FacetCount(value: $0["value"], count: $0["n"]) }
        }
        let seen = Set(found.map(\.value))
        let stale = filter.included(facet).union(filter.excluded(facet))
            .subtracting(seen)
            .sorted { $0.lowercased() < $1.lowercased() }
            .map { FacetCount(value: $0, count: 0) }
        return found + stale
    }

    /// Highest event id in a session, or `nil` when it has none.
    /// "Clear" uses it as the watermark for what to hide.
    public func latestEventId(sessionId: Int64) async throws -> Int64? {
        try await dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MAX(id) FROM event WHERE session_id = ?",
                arguments: [sessionId]
            )
        }
    }

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

    /// - Parameter includePayloads: when `false`, `data_json` / `context_json`
    ///   come back `nil`. The log-feed table never renders them, and they are
    ///   the bulk of a row: measured on a real store, `data_json` averages
    ///   ~10 KB and peaks at 25 MB, so a session's worth of rows is ~2.6 GB
    ///   with payloads versus ~85 MB without. The detail pane and "Copy as
    ///   JSON" refetch the handful of rows they actually need via
    ///   `events(ids:)`. Export keeps the default and takes the full rows.
    ///
    ///   The size column uses `octet_length`, which SQLite answers from the
    ///   record header. `LENGTH(CAST(x AS BLOB))` looked equivalent but
    ///   loaded every payload to measure it — 859 MB read per reload on a
    ///   67k-event session (160–230 ms warm vs 33 ms).
    public func events(
        sessionId: Int64,
        filter: Filter,
        offset: Int,
        limit: Int,
        includePayloads: Bool = true
    ) async throws -> [EventRecord] {
        try await dbQueue.read { db in
            let (whereClause, args) = Self.where(filter: filter, sessionId: sessionId)
            let payloadColumns = includePayloads
                ? "data_json, context_json"
                : "NULL AS data_json, NULL AS context_json"
            let sql = """
                SELECT id, session_id, timestamp_ms, level, subsystem,
                       category, message, \(payloadColumns),
                       COALESCE(octet_length(data_json), 0)
                     + COALESCE(octet_length(context_json), 0)
                       AS payload_bytes
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

    /// Full rows — payloads included — for a specific set of ids. The feed
    /// loads rows without payloads; this is how the detail pane and the
    /// clipboard actions get the JSON back for the rows in hand.
    public func events(ids: Set<Int64>) async throws -> [EventRecord] {
        guard !ids.isEmpty else { return [] }
        let idList = Array(ids)
        return try await dbQueue.read { db in
            let placeholders = idList.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, session_id, timestamp_ms, level, subsystem,
                           category, message, data_json, context_json,
                           COALESCE(octet_length(data_json), 0)
                         + COALESCE(octet_length(context_json), 0)
                           AS payload_bytes
                    FROM event
                    WHERE id IN (\(placeholders))
                    ORDER BY timestamp_ms ASC, id ASC
                """,
                arguments: StatementArguments(idList)
            )
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

    /// Find the event (respecting the current filter) whose
    /// **time-of-day** is closest to `targetMillisSinceMidnight`.
    /// Ignores the calendar date entirely — typing `12:13:42` lands
    /// on any event at ~12:13:42 regardless of which day it occurred
    /// on. Wraps around midnight, so `23:55` correctly matches an
    /// event at `00:05` (10 min away, not 23h50m).
    ///
    /// `targetMillisSinceMidnight` is UTC milliseconds since UTC
    /// midnight (0…86_399_999). The caller computes this from the
    /// user's typed Date as `timeIntervalSince1970 * 1000 % 86_400_000`.
    /// Events' `timestamp_ms` are also UTC, so % 86_400_000 gives a
    /// directly-comparable value.
    public func nearestEventId(
        sessionId: Int64,
        targetMillisSinceMidnight: Int64,
        filter: Filter
    ) async throws -> Int64? {
        try await dbQueue.read { db in
            let (whereClause, args) = Self.where(filter: filter, sessionId: sessionId)
            // Circular distance on a 24h clock:
            //   raw  = |(ts % 86400000) - target|
            //   dist = MIN(raw, 86400000 - raw)
            // SQLite's MIN(a, b) is scalar when given two arguments.
            let sql = """
                SELECT id FROM event
                \(whereClause)
                ORDER BY MIN(
                    ABS((timestamp_ms % 86400000) - ?),
                    86400000 - ABS((timestamp_ms % 86400000) - ?)
                ) ASC, id ASC
                LIMIT 1
            """
            var fullArgs = args
            fullArgs.append(targetMillisSinceMidnight)
            fullArgs.append(targetMillisSinceMidnight)
            return try Int64.fetchOne(db, sql: sql, arguments: StatementArguments(fullArgs))
        }
    }

    // MARK: - Saved filters

    /// All persisted filter presets, alphabetical by name.
    public func savedFilters() async throws -> [SavedFilter] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, min_level, search, search_rx, exclude, exclude_rx,
                           subsystems, excluded_subsystems, categories, excluded_categories
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
        // `hiddenThroughEventId` is intentionally dropped: it is a
        // per-session view state, and an event id from one session
        // would hide an arbitrary slice of another.
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
                      (name, min_level, search, search_rx, exclude, exclude_rx,
                       subsystems, excluded_subsystems, categories, excluded_categories)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                      min_level           = excluded.min_level,
                      search              = excluded.search,
                      search_rx           = excluded.search_rx,
                      exclude             = excluded.exclude,
                      exclude_rx          = excluded.exclude_rx,
                      subsystems          = excluded.subsystems,
                      excluded_subsystems = excluded.excluded_subsystems,
                      categories          = excluded.categories,
                      excluded_categories = excluded.excluded_categories
                """,
                arguments: [
                    trimmed,
                    filter.minLevel.rawValue,
                    filter.search,
                    filter.searchIsRegex ? 1 : 0,
                    filter.exclude,
                    filter.excludeIsRegex ? 1 : 0,
                    Self.encodeChips(filter.subsystems),
                    Self.encodeChips(filter.excludedSubsystems),
                    Self.encodeChips(filter.categories),
                    Self.encodeChips(filter.excludedCategories),
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
            excludeIsRegex: ((row["exclude_rx"] as Int?) ?? 0) != 0,
            subsystems: decodeChips(row["subsystems"]),
            excludedSubsystems: decodeChips(row["excluded_subsystems"]),
            categories: decodeChips(row["categories"]),
            excludedCategories: decodeChips(row["excluded_categories"])
        )
        return SavedFilter(id: row["id"], name: row["name"], filter: filter)
    }

    /// Chip sets ride in a JSON array: a subsystem or category can hold
    /// any character, so there is no delimiter safe enough to split on.
    /// An empty set stores NULL so pre-v4 rows and empty ones read back
    /// the same.
    private static func encodeChips(_ values: Set<String>) -> String? {
        guard !values.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: values.sorted())
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeChips(_ raw: String?) -> Set<String> {
        guard let raw,
              let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return Set(values)
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

        // Opportunistically harvest device + app metadata out of the
        // session-storage snapshot. The SDK writes a well-known
        // `applicaster.v2` namespace with app_name / version_name /
        // deviceModel / platform / osVersion, etc. — see
        // Schema.v3_session_device_info. Cheap parse; bails fast if
        // the substring isn't even there.
        if namespace == .session, dataJSON.contains("\"applicaster.v2\"") {
            await harvestDeviceInfo(sessionId: sessionId, dataJSON: dataJSON)
        }
    }

    /// Parse `applicaster.v2` out of the just-written snapshot and
    /// patch the session row with the device fingerprint. Errors
    /// here are non-fatal — the snapshot is already saved; the
    /// session just won't have its device columns filled until the
    /// next snapshot arrives.
    private func harvestDeviceInfo(sessionId: Int64, dataJSON: String) async {
        guard let data = dataJSON.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any],
              let v2  = top["applicaster.v2"] as? [String: Any]
        else { return }

        func str(_ keys: String...) -> String? {
            for k in keys {
                if let v = v2[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }

        try? await setSessionDeviceInfo(
            id: sessionId,
            appName:     str("app_name"),
            appVersion:  str("version_name"),
            deviceModel: str("deviceModel", "device_model", "deviceName"),
            platform:    str("platform"),
            osVersion:   str("osVersion")
        )
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

    // MARK: - Network entries

    public func recordNetworkEntry(_ capture: NetworkCapture, sessionId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO network_entry (session_id, timestamp_ms, payload_json)
                    VALUES (?, ?, ?)
                """,
                arguments: [sessionId, Int(capture.entry.startMillis), capture.payloadJSON]
            )
        }
        broadcast(.networkAppended(sessionId: sessionId))
    }

    public func networkEntries(sessionId: Int64, afterId: Int64 = 0) async throws -> [NetworkEntry] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, timestamp_ms, payload_json
                    FROM network_entry
                    WHERE session_id = ? AND id > ?
                    ORDER BY id
                """,
                arguments: [sessionId, afterId]
            ).compactMap { row in
                NetworkEntry.parse(
                    row["payload_json"],
                    id: row["id"],
                    fallbackMillis: UInt64(row["timestamp_ms"] as Int)
                )
            }
        }
    }

    /// One entry's payload as received, for Copy JSON: the in-memory
    /// entries keep only the parsed fields.
    public func networkPayload(id: Int64) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT payload_json FROM network_entry WHERE id = ?", arguments: [id])
        }
    }

    /// Every payload in the session, in arrival order, for Export.
    public func networkPayloads(sessionId: Int64) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT payload_json FROM network_entry WHERE session_id = ? ORDER BY id",
                arguments: [sessionId]
            )
        }
    }

    /// Cheap existence check for the toolbar: a session can hold
    /// requests and no events (an imported HAR).
    public func networkEntryCount(sessionId: Int64) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM network_entry WHERE session_id = ?",
                arguments: [sessionId]
            ) ?? 0
        }
    }

    // MARK: - Network bookmarks

    /// Bookmarks `entryId`, or removes its bookmark. Returns `true` when
    /// the entry is bookmarked afterwards.
    @discardableResult
    public func toggleNetworkBookmark(entryId: Int64, sessionId: Int64) async throws -> Bool {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let isOn = try await dbQueue.write { db -> Bool in
            try db.execute(sql: "DELETE FROM network_bookmark WHERE entry_id = ?", arguments: [entryId])
            guard db.changesCount == 0 else { return false }
            try db.execute(
                sql: "INSERT INTO network_bookmark (session_id, entry_id, created_at) VALUES (?, ?, ?)",
                arguments: [sessionId, entryId, now]
            )
            return true
        }
        broadcast(.networkBookmarksChanged(sessionId: sessionId))
        return isOn
    }

    public func networkBookmarkIds(sessionId: Int64) async throws -> Set<Int64> {
        try await dbQueue.read { db in
            Set(try Int64.fetchAll(
                db,
                sql: "SELECT entry_id FROM network_bookmark WHERE session_id = ?",
                arguments: [sessionId]
            ))
        }
    }

    // MARK: - Helpers

    /// Shared SELECT list — kept in one place so the device-info
    /// columns added in v3 are picked up everywhere.
    private static let sessionColumns = """
        id, started_at, ended_at, source, client_label,
        app_name, app_version, device_model, platform, os_version
    """

    private static func fetchSession(id: Int64, db: Database) throws -> Session? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(sessionColumns) FROM session WHERE id = ?",
            arguments: [id]
        ).map(makeSession)
    }

    private static func fetchAllSessions(db: Database) throws -> [Session] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT \(sessionColumns)
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
            clientLabel: row["client_label"],
            appName:     row["app_name"],
            appVersion:  row["app_version"],
            deviceModel: row["device_model"],
            platform:    row["platform"],
            osVersion:   row["os_version"]
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
            contextJSON: row["context_json"],
            payloadBytes: row["payload_bytes"]
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

        // "Clear" hides what's on screen without deleting it.
        if let hiddenThrough = filter.hiddenThroughEventId {
            clauses.append("id > ?")
            args.append(hiddenThrough)
        }

        // Subsystem / category chips. Sorted so the SQL text is stable
        // for a given filter and SQLite can reuse its prepared plan.
        appendChip(
            column: "subsystem",
            included: filter.subsystems,
            excluded: filter.excludedSubsystems,
            clauses: &clauses,
            args: &args
        )
        appendChip(
            column: "category",
            included: filter.categories,
            excluded: filter.excludedCategories,
            clauses: &clauses,
            args: &args
        )

        return ("WHERE " + clauses.joined(separator: " AND "), args)
    }

    private static func appendChip(
        column: String,
        included: Set<String>,
        excluded: Set<String>,
        clauses: inout [String],
        args: inout [any DatabaseValueConvertible]
    ) {
        if !included.isEmpty {
            let values = included.sorted()
            let placeholders = values.map { _ in "?" }.joined(separator: ", ")
            clauses.append("\(column) IN (\(placeholders))")
            args.append(contentsOf: values)
        }
        if !excluded.isEmpty {
            let values = excluded.sorted()
            let placeholders = values.map { _ in "?" }.joined(separator: ", ")
            clauses.append("\(column) NOT IN (\(placeholders))")
            args.append(contentsOf: values)
        }
    }
}
