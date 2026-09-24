//
//  FeedRowsTests.swift
//  BeaverTests
//

import Testing
@testable import BeaverCore

@Suite("FeedRows")
struct FeedRowsTests {

    private func event(_ id: Int64, ts: UInt64? = nil, _ message: String = "m",
                       level: LogLevel = .info) -> EventRecord {
        EventRecord(id: id, sessionId: 1, timestampMillis: ts ?? UInt64(id),
                    level: level, subsystem: "s", category: "c",
                    message: message, dataJSON: nil, contextJSON: nil)
    }

    /// Rebuilding from scratch is the reference every incremental path
    /// must agree with.
    private func rebuilt(_ feed: FeedRows) -> FeedRows {
        var fresh = FeedRows(collapse: feed.collapse)
        fresh.replace(with: feed.events)
        return fresh
    }

    @Test("Consecutive identical events fold into one row")
    func collapses() {
        var feed = FeedRows(collapse: true)
        feed.replace(with: [event(1, "a"), event(2, "a"), event(3, "b"), event(4, "a")])
        #expect(feed.rows.map(\.id) == [1, 3, 4])
        #expect(feed.rows.map(\.count) == [2, 1, 1])
        #expect(feed.rowId(for: 2) == 1)
        #expect(feed.rowId(for: 4) == 4)
        #expect(feed.rowId(for: 99) == nil)
    }

    @Test("Collapse off gives one row per event")
    func noCollapse() {
        var feed = FeedRows(collapse: false)
        feed.replace(with: [event(1, "a"), event(2, "a")])
        #expect(feed.rows.map(\.id) == [1, 2])
        feed.collapse = true
        #expect(feed.rows.map(\.id) == [1])
        #expect(feed.rows.first?.count == 2)
    }

    @Test("An in-order append extends the last group")
    func appendExtends() {
        var feed = FeedRows(collapse: true)
        feed.replace(with: [event(1, "a"), event(2, "b")])
        feed.merge([event(3, "b"), event(4, "c")])
        #expect(feed.rows.map(\.id) == [1, 2, 4])
        #expect(feed.rows.map(\.count) == [1, 2, 1])
        #expect(feed.events.map(\.id) == [1, 2, 3, 4])
    }

    @Test("A late event lands at its timestamp, and the groups around it are redone")
    func lateEventMerges() {
        var feed = FeedRows(collapse: true)
        feed.replace(with: [event(1, ts: 10, "a"), event(2, ts: 20, "a"), event(3, ts: 30, "b")])
        // Arrived last (higher id) but happened between 1 and 2, and
        // differs from both, so it splits their group.
        feed.merge([event(4, ts: 15, "x"), event(5, ts: 40, "b")])
        #expect(feed.events.map(\.id) == [1, 4, 2, 3, 5])
        #expect(feed.rows.map(\.id) == [1, 4, 2, 3])
        #expect(feed.rows.map(\.count) == [1, 1, 1, 2])
        #expect(feed.rows == rebuilt(feed).rows)
        #expect(feed.rowId(for: 5) == 3)
        #expect(feed.rowId(for: 2) == 2)
    }

    @Test("Ties on timestamp keep id order")
    func tiesByID() {
        var feed = FeedRows(collapse: false)
        feed.replace(with: [event(1, ts: 10), event(3, ts: 10)])
        feed.merge([event(2, ts: 10)])
        // id 2 < 3, but 2 arrived after 3 was loaded: still ordered.
        #expect(feed.events.map(\.id) == [1, 2, 3])
    }

    @Test("Random late arrivals always match a full rebuild")
    func randomMergesMatchRebuild() {
        var generator = SystemRandomNumberGenerator()
        for collapse in [true, false] {
            var feed = FeedRows(collapse: collapse)
            var nextId: Int64 = 1
            for _ in 0..<50 {
                let batch = (0..<Int.random(in: 1...8, using: &generator)).map { _ -> EventRecord in
                    defer { nextId += 1 }
                    let ts = UInt64(nextId * 10 + 100) - UInt64.random(in: 0...60, using: &generator)
                    return event(nextId, ts: ts, ["a", "b"].randomElement(using: &generator)!)
                }
                feed.merge(batch.sorted { ($0.timestampMillis, $0.id) < ($1.timestampMillis, $1.id) })
                #expect(feed.rows == rebuilt(feed).rows)
            }
            for e in feed.events {
                #expect(feed.rowId(for: e.id) == rebuilt(feed).rowId(for: e.id))
            }
        }
    }

    @Test("Row index looks up a row by its id, not by a member event")
    func rowIndex() {
        var feed = FeedRows(collapse: true)
        feed.replace(with: [event(1, "a"), event(2, "a"), event(3, "b")])
        #expect(feed.rowIndex(ofRow: 1) == 0)
        #expect(feed.rowIndex(ofRow: 3) == 1)
        #expect(feed.rowIndex(ofRow: 2) == nil)
    }

    @Test("Next / previous row matching a predicate, without wrapping")
    func nextMatchingRow() {
        var feed = FeedRows(collapse: false)
        feed.replace(with: [event(1, level: .error), event(2), event(3, level: .error), event(4)])
        let isError: (FeedRow) -> Bool = { $0.event.level == .error }
        #expect(feed.rowIndex(after: nil, forward: true, where: isError) == 0)
        #expect(feed.rowIndex(after: nil, forward: false, where: isError) == 2)
        #expect(feed.rowIndex(after: 0, forward: true, where: isError) == 2)
        #expect(feed.rowIndex(after: 2, forward: true, where: isError) == nil)
        #expect(feed.rowIndex(after: 2, forward: false, where: isError) == 0)
    }
}
