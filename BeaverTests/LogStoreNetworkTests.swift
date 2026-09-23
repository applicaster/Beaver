//
//  LogStoreNetworkTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("LogStore network entries")
struct LogStoreNetworkTests {

    private func entry(_ url: String, at ms: UInt64) -> NetworkEntry {
        NetworkEntry.parse(#"{"url":"\#(url)","status":200,"timing":{"startTime":\#(ms),"duration":3}}"#,
                           fallbackMillis: 0)!
    }

    @Test
    func roundTripPreservesEntryAndOrder() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        try await store.recordNetworkEntry(entry("https://b.io", at: 20), sessionId: session.id)
        try await store.recordNetworkEntry(entry("https://a.io", at: 10), sessionId: session.id)

        let all = try await store.networkEntries(sessionId: session.id)
        #expect(all.map(\.url) == ["https://a.io", "https://b.io"])
        #expect(all.allSatisfy { $0.id > 0 })
        #expect(all[0].durationMillis == 3)
        #expect(all[0].status == 200)
    }

    @Test
    func afterIdReturnsOnlyNewerRows() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        try await store.recordNetworkEntry(entry("https://a.io", at: 1), sessionId: session.id)
        let first = try await store.networkEntries(sessionId: session.id)
        try await store.recordNetworkEntry(entry("https://b.io", at: 2), sessionId: session.id)

        let newer = try await store.networkEntries(sessionId: session.id, afterId: first.last!.id)
        #expect(newer.map(\.url) == ["https://b.io"])
    }

    @Test
    func entriesAreScopedToSessionAndClearedWithEvents() async throws {
        let store = try LogStore(source: .inMemory)
        let s1 = try await store.createSession(source: .live)
        let s2 = try await store.createSession(source: .live)
        try await store.recordNetworkEntry(entry("https://a.io", at: 1), sessionId: s1.id)
        try await store.recordNetworkEntry(entry("https://b.io", at: 1), sessionId: s2.id)

        try await store.clearEvents(sessionId: s1.id)

        #expect(try await store.networkEntries(sessionId: s1.id).isEmpty)
        #expect(try await store.networkEntries(sessionId: s2.id).count == 1)
    }

    @Test
    func recordBroadcastsNetworkAppended() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let stream = await store.changes()

        try await store.recordNetworkEntry(entry("https://a.io", at: 1), sessionId: session.id)

        let received = await race(timeout: .seconds(1)) {
            for await change in stream {
                if case .networkAppended(let sid) = change, sid == session.id { return true }
            }
            return false
        }
        #expect(received == true)
    }
}
