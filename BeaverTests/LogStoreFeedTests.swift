//
//  LogStoreFeedTests.swift
//  BeaverTests
//

import Testing
import Foundation
import GRDB
@testable import BeaverCore

@Suite("LogStore feed")
struct LogStoreFeedTests {

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

    // MARK: - Snapshot / tail

    @Test("A capped snapshot keeps the newest rows, in ascending order")
    func snapshotKeepsNewest() async throws {
        let (store, sid) = try await seed((0..<15).map { "e\($0)" })
        let snap = try await store.feedSnapshot(sessionId: sid, filter: .none, limit: 10)
        #expect(snap.events.map(\.message) == (5..<15).map { "e\($0)" })
        #expect(snap.total == 15)
        #expect(snap.unfiltered == 15)
    }

    @Test("Snapshot counts the filter and the whole session")
    func snapshotCounts() async throws {
        let (store, sid) = try await seed(["hit", "miss", "hit"])
        let snap = try await store.feedSnapshot(sessionId: sid, filter: Filter(search: "hit"), limit: 10)
        #expect(snap.total == 2)
        #expect(snap.unfiltered == 3)
    }

    @Test("The tail brings only rows past the watermark that match, and counts all of them")
    func tailIsIncremental() async throws {
        let (store, sid) = try await seed(["a", "b"])
        let filter = Filter(search: "a")
        let snap = try await store.feedSnapshot(sessionId: sid, filter: filter, limit: 10)
        try await store.appendBulk([
            DecodedEvent(timestampMillis: 5, level: .info, subsystem: "s", category: "",
                         message: "late a", dataJSON: nil, contextJSON: nil),
            DecodedEvent(timestampMillis: 5_000, level: .info, subsystem: "s", category: "",
                         message: "zzz", dataJSON: nil, contextJSON: nil),
        ], to: sid)
        // Another session's rows fall in the same id range; they must not count.
        let other = try await store.createSession(source: .live)
        try await store.appendBulk([
            DecodedEvent(timestampMillis: 1, level: .info, subsystem: "s", category: "",
                         message: "a elsewhere", dataJSON: nil, contextJSON: nil),
        ], to: other.id)

        let tail = try await store.feedTail(sessionId: sid, filter: filter, after: snap.watermark)
        #expect(tail.events.map(\.message) == ["late a"])
        #expect(tail.unfiltered == 2)
        #expect(tail.watermark > snap.watermark)

        let again = try await store.feedTail(sessionId: sid, filter: filter, after: tail.watermark)
        #expect(again.events.isEmpty)
        #expect(again.unfiltered == 0)
        #expect(again.watermark == tail.watermark)
    }

    /// The whole point of the tail: it reads the new rows by rowid range,
    /// not the session through an index.
    @Test("The tail query walks the rowid range")
    func tailUsesRowidRange() async throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        let filter = Filter(minLevel: .warning, search: "x", subsystems: ["s"])
        for (sql, args) in [LogStore.tailRangeQuery(sessionId: 1, after: 0),
                            LogStore.tailEventsQuery(sessionId: 1, filter: filter, after: 0)] {
            let arguments: StatementArguments = StatementArguments(args)
            let plan = try await queue.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                    .map { $0["detail"] as String }.joined(separator: " | ")
            }
            #expect(plan.contains("INTEGER PRIMARY KEY (rowid>?"), "plan: \(plan)")
        }
    }
}
