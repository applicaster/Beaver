import Testing
import Foundation
@testable import BeaverCore

@Suite("LogStore id ranges")
struct LogStoreRangeTests {

    /// Five events at t = 1000…1004 ms: levels info, error, info, warning, error;
    /// subsystems a, b, a, b, a.
    private func seeded() async throws -> (LogStore, Int64) {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let levels: [LogLevel] = [.info, .error, .info, .warning, .error]
        for (i, level) in levels.enumerated() {
            await store.append(
                DecodedEvent(timestampMillis: UInt64(1000 + i), level: level,
                             subsystem: i.isMultiple(of: 2) ? "a" : "b", category: "",
                             message: "m\(i)", dataJSON: nil, contextJSON: nil),
                to: session.id)
        }
        try await waitForEvents(5, session: session.id, in: store)
        return (store, session.id)
    }

    @Test("Pages by id both ways, with the total")
    func pages() async throws {
        let (store, sid) = try await seeded()
        let all = try await store.eventPage(sessionId: sid, filter: .none, limit: 10, newestFirst: false)
        let ids = all.events.map(\.id)
        #expect(all.total == 5)

        let newest = try await store.eventPage(sessionId: sid, filter: .none, limit: 2, newestFirst: true)
        #expect(newest.events.map(\.id) == [ids[4], ids[3]])
        #expect(newest.total == 5)

        let after = try await store.eventPage(sessionId: sid, filter: .none, afterId: ids[1], limit: 10, newestFirst: false)
        #expect(after.events.map(\.id) == [ids[2], ids[3], ids[4]])

        let window = try await store.eventPage(sessionId: sid, filter: .none, afterId: ids[0], beforeId: ids[4], limit: 10, newestFirst: false)
        #expect(window.events.map(\.id) == [ids[1], ids[2], ids[3]])
        #expect(window.total == 3)
    }

    @Test("Level counts ignore minLevel but honour the rest")
    func levels() async throws {
        let (store, sid) = try await seeded()
        let counts = try await store.levelCounts(sessionId: sid, filter: Filter(minLevel: .error, subsystems: ["a"]))
        #expect(counts == [.info: 2, .error: 1])
    }

    @Test("Facet counts respect the id range")
    func facetRange() async throws {
        let (store, sid) = try await seeded()
        let ids = try await store.eventPage(sessionId: sid, filter: .none, limit: 10, newestFirst: false).events.map(\.id)
        let counts = try await store.facetCounts(sessionId: sid, facet: .subsystem, filter: .none, afterId: ids[2])
        #expect(counts == [FacetCount(value: "a", count: 1), FacetCount(value: "b", count: 1)])
    }

    @Test("First event at or after a time")
    func firstAt() async throws {
        let (store, sid) = try await seeded()
        let ids = try await store.eventPage(sessionId: sid, filter: .none, limit: 10, newestFirst: false).events.map(\.id)
        #expect(try await store.firstEventId(sessionId: sid, atOrAfterMillis: 1002) == ids[2])
        #expect(try await store.firstEventId(sessionId: sid, atOrAfterMillis: 9999) == nil)
    }

    @Test("Network entry by id")
    func networkById() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let capture = try #require(NetworkCapture(#"{"url":"https://a.io/x","status":201,"timing":{"startTime":5,"duration":3}}"#, fallbackMillis: 0))
        try await store.recordNetworkEntry(capture, sessionId: session.id)
        let id = try #require(try await store.networkEntries(sessionId: session.id).first?.id)
        let entry = try await store.networkEntry(id: id)
        #expect(entry?.status == 201)
        #expect(try await store.networkEntry(id: id + 100) == nil)
    }
}
