//
//  LogStoreSearchTests.swift
//  BeaverTests
//

import Testing
import Foundation
import GRDB
@testable import BeaverCore

@Suite("LogStore search")
struct LogStoreSearchTests {

    private func seed(_ messages: [String], data: [String?]? = nil,
                      level: LogLevel = .info) async throws -> (LogStore, Int64) {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let events = messages.enumerated().map { i, message in
            DecodedEvent(timestampMillis: UInt64(1_000 + i), level: level,
                         subsystem: "sub", category: "cat", message: message,
                         dataJSON: data?[i], contextJSON: nil)
        }
        try await store.appendBulk(events, to: session.id)
        return (store, session.id)
    }

    private func messages(_ store: LogStore, _ sid: Int64, _ filter: Filter) async throws -> [String] {
        try await store.feedSnapshot(sessionId: sid, filter: filter, limit: 1_000).events.map(\.message)
    }

    // MARK: - LIKE / REGEXP

    @Test("% and _ are literal in a substring search")
    func likeEscapes() async throws {
        let (store, sid) = try await seed(["100% done", "1000 done", "a_b", "axb", #"back\slash"#])
        #expect(try await messages(store, sid, Filter(search: "100%")) == ["100% done"])
        #expect(try await messages(store, sid, Filter(search: "a_b")) == ["a_b"])
        #expect(try await messages(store, sid, Filter(search: #"\s"#)) == [#"back\slash"#])
        #expect(try await messages(store, sid, Filter(exclude: "%")) == ["1000 done", "a_b", "axb", #"back\slash"#])
    }

    @Test("A regex ignores case, like the substring search")
    func regexIgnoresCase() async throws {
        let (store, sid) = try await seed(["Player ready", "other"])
        #expect(try await messages(store, sid, Filter(search: "^player", searchIsRegex: true)) == ["Player ready"])
        let ids = try await store.matchingIds(sessionId: sid, filter: .none, highlight: "PLAYER", isRegex: true)
        #expect(ids.count == 1)
    }

    @Test("An invalid regex constrains nothing instead of emptying the feed")
    func invalidRegexIsIgnored() async throws {
        let (store, sid) = try await seed(["a", "b"])
        #expect(try await messages(store, sid, Filter(search: "(", searchIsRegex: true)) == ["a", "b"])
        #expect(try await messages(store, sid, Filter(exclude: "[", excludeIsRegex: true)) == ["a", "b"])
        #expect(Filter.isValidRegex("(") == false)
        #expect(Filter.isValidRegex("a+") == true)
    }

    // MARK: - Payload search

    @Test("Payloads are searched only when asked")
    func payloadSearch() async throws {
        let (store, sid) = try await seed(["one", "two", "three"],
                                          data: [#"{"url":"https://cdn/player.m3u8"}"#, nil, "{}"])
        #expect(try await messages(store, sid, Filter(search: "m3u8")) == [])
        #expect(try await messages(store, sid, Filter(search: "m3u8", searchPayloads: true)) == ["one"])
        #expect(try await messages(store, sid, Filter(search: "M3U8", searchIsRegex: true, searchPayloads: true)) == ["one"])
        // A row without data must survive an exclude, not vanish on NULL.
        #expect(try await messages(store, sid, Filter(exclude: "m3u8", searchPayloads: true)) == ["two", "three"])
    }

    @Test("Saved filters keep the payload toggle")
    func savedFilterKeepsPayloads() async throws {
        let store = try LogStore(source: .inMemory)
        try await store.upsertSavedFilter(name: "p", filter: Filter(search: "x", searchPayloads: true))
        #expect(try await store.savedFilters().first?.filter.searchPayloads == true)
    }

    // MARK: - Migration

    @Test("The unused FTS table and its triggers are gone")
    func ftsDropped() async throws {
        let queue = try DatabaseQueue()
        var migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v6_network_bookmark")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO session (started_at, source) VALUES (0, 'live')")
            try db.execute(sql: """
                INSERT INTO event (session_id, timestamp_ms, level, subsystem, category, message)
                VALUES (1, 0, 'info', 's', 'c', 'kept')
            """)
        }
        migrator = Schema.migrator()
        try migrator.migrate(queue)
        let leftovers = try await queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE name LIKE 'event_fts%' OR name IN ('event_ai', 'event_ad')
            """)
        }
        #expect(leftovers.isEmpty)
        let kept = try await queue.read { db in try String.fetchAll(db, sql: "SELECT message FROM event") }
        #expect(kept == ["kept"])
    }
}
