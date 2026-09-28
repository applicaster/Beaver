//
//  SessionRetentionTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("Session retention (D83)")
struct SessionRetentionTests {

    private let day: TimeInterval = 86_400

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SessionRetentionTests-\(UUID().uuidString)")!
    }

    @Test("expired: only old, live-source, unbookmarked sessions that aren't connected")
    func selection() {
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let old = cutoff.addingTimeInterval(-1)
        let c = [
            SessionRetention.Candidate(id: 1, source: .live, lastActivity: old, bookmarked: false),
            SessionRetention.Candidate(id: 2, source: .imported, lastActivity: old, bookmarked: false),
            SessionRetention.Candidate(id: 3, source: .live, lastActivity: old, bookmarked: true),
            SessionRetention.Candidate(id: 4, source: .live, lastActivity: old, bookmarked: false),
            SessionRetention.Candidate(id: 5, source: .live, lastActivity: cutoff, bookmarked: false),
        ]
        #expect(SessionRetention.expired(c, before: cutoff, live: [4]) == [1])
    }

    @Test("The setting defaults to 30 days; unknown values fall back to it")
    func setting() {
        let d = freshDefaults()
        #expect(SessionRetention.current(d) == .month)
        d.set(0, forKey: SessionRetention.key)
        #expect(SessionRetention.current(d) == .never)
        d.set(13, forKey: SessionRetention.key)
        #expect(SessionRetention.current(d) == .month)
    }

    @Test("Store: first pass only announces; the next deletes, keeping live, imported, bookmarked and recent sessions")
    func purge() async throws {
        let store = try LogStore(source: .inMemory)
        let now = Date().addingTimeInterval(40 * day)   // every session below started "40 days ago"
        let recentMillis = UInt64(now.addingTimeInterval(-10 * day).timeIntervalSince1970 * 1000)

        let old = try await store.createSession(source: .live)
        try await seed(store, session: old.id, [(.info, "a", "", "x")])
        try await store.endSession(old.id)
        let connected = try await store.createSession(source: .live)
        let imported = try await store.createSession(source: .imported)
        let eventMarked = try await store.createSession(source: .live)
        try await seed(store, session: eventMarked.id, [(.info, "a", "", "keep")])
        let eventId = try #require(try await store.latestEventId(sessionId: eventMarked.id))
        try await store.addBookmark(eventId: eventId, sessionId: eventMarked.id)
        let requestMarked = try await store.createSession(source: .live)
        try await store.recordNetworkEntry(try #require(NetworkCapture(#"{"url":"https://a.example","status":200}"#, fallbackMillis: 0)),
                                           sessionId: requestMarked.id)
        let entryId = try #require(try await store.networkEntries(sessionId: requestMarked.id).first?.id)
        _ = try await store.toggleNetworkBookmark(entryId: entryId, sessionId: requestMarked.id)
        // Unended (a crash): its last event, 10 days before `now`, is what counts.
        let crashed = try await store.createSession(source: .live)
        try await seed(store, session: crashed.id, [(.info, "a", "", "late")], startMillis: recentMillis)
        let journaled = try await store.recordAgentActivity(
            NewAgentActivity(client: nil, tool: "logs_query", kind: .read, summary: "read", sessionId: old.id))

        let defaults = freshDefaults()
        let first = try await SessionRetention.run(store: store, live: [connected.id], now: now, defaults: defaults)
        #expect(first == .notice(pending: 1))
        #expect(try await store.sessions().count == 6)

        let changes = await store.changes()
        let second = try await SessionRetention.run(store: store, live: [connected.id],
                                                    now: now.addingTimeInterval(day), defaults: defaults)
        guard case .deleted(let count, _) = second else { Issue.record("expected .deleted, got \(second)"); return }
        #expect(count == 1)
        let left = Set(try await store.sessions().map(\.id))
        #expect(left == [connected.id, imported.id, eventMarked.id, requestMarked.id, crashed.id])
        // Like a manual delete: one broadcast, the journal entry kept without its link.
        for await change in changes {
            if case .sessionsDeleted(let ids) = change { #expect(ids == [old.id]); break }
        }
        let entry = try await store.agentActivity().first { $0.id == journaled }
        #expect(entry != nil && entry?.sessionId == nil)

        // Nothing more to do: no toast.
        #expect(try await SessionRetention.run(store: store, live: [connected.id],
                                               now: now.addingTimeInterval(day), defaults: defaults) == .nothing)
    }

    @Test("Never: nothing is deleted or announced, and the grace day doesn't start")
    func never() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.endSession(s.id)
        let defaults = freshDefaults()
        defaults.set(SessionRetention.never.rawValue, forKey: SessionRetention.key)
        let r = try await SessionRetention.run(store: store, live: [], now: Date().addingTimeInterval(400 * day), defaults: defaults)
        #expect(r == .nothing)
        #expect(defaults.object(forKey: SessionRetention.startsAtKey) == nil)
        #expect(try await store.sessions().count == 1)
    }

    @Test("reclaimSpace converts to incremental auto-vacuum, then runs it again")
    func reclaim() async throws {
        let store = try LogStore(source: .inMemory)
        try await store.reclaimSpace()
        try await store.reclaimSpace()
        #expect(try await store.databaseSize() > 0)
    }

    @Test("beaver_status reports the retention setting and the store's size")
    func status() async throws {
        let store = try LogStore(source: .inMemory)
        let r = try await StatusTools.status.run(ToolArguments(), makeContext(store, ui: HostSnapshot(retention: .quarter)))
        #expect(r.structured["retentionDays"] == 90)
        #expect((r.structured["storeBytes"]?.int ?? 0) > 0)
        #expect(r.body.contains("older than 90 days"))
        let never = try await StatusTools.status.run(ToolArguments(), makeContext(store, ui: HostSnapshot(retention: .never)))
        #expect(never.structured["retentionDays"] == .null)
        #expect(never.body.contains("kept until deleted"))
    }
}
