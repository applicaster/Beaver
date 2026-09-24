import Testing
import Foundation
@testable import BeaverCore

@Suite("Log tools")
struct LogToolsTests {

    /// auth: info, error, error; player: warning, info.
    private func fixture() async throws -> (ToolContext, Int64, [Int64]) {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [
            (.info, "com.app.auth", "token", "start"),
            (.error, "com.app.auth", "token", "refresh failed 401"),
            (.warning, "player.core", "", "buffering"),
            (.error, "com.app.auth", "", "logout"),
            (.info, "player.core", "", "play"),
        ])
        let ids = try await store.eventPage(sessionId: s.id, filter: .none, limit: 10, newestFirst: false).events.map(\.id)
        return (makeContext(store, ui: HostSnapshot(liveSessionId: s.id)), s.id, ids)
    }

    @Test("Facets: levels, subsystems, categories, under the filter")
    func facets() async throws {
        let (ctx, _, _) = try await fixture()
        let r = try await LogTools.facets.run(ToolArguments(["filter": ["minLevel": "warning"]]), ctx)
        #expect(r.structured["matching"] == 3)
        #expect(r.structured["levels"]?["error"] == 2)
        #expect(r.structured["subsystems"]?.array?.first?["value"] == "com.app.auth")
        #expect(r.summary.contains("3 of 5"))
        #expect(r.next.first?.contains("logs_query") == true)
    }

    @Test("Query: newest first by default, lines, cursor, resolution notes")
    func query() async throws {
        let (ctx, _, ids) = try await fixture()
        let r = try await LogTools.query.run(ToolArguments([
            "filter": ["subsystems": ["auth"]], "limit": 2,
        ]), ctx)
        #expect(r.structured["total"] == 3)
        #expect(r.structured["events"]?.array?.map { $0["id"]?.int64 } == [ids[3], ids[1]])
        #expect(r.structured["nextCursor"]?["beforeId"]?.int64 == ids[1])
        #expect(r.body.hasPrefix("#\(ids[3]) "))
        #expect(r.summary.contains("subsystems auth → com.app.auth"))
        #expect(r.next.contains { $0.contains("beforeId: \(ids[1])") })
    }

    @Test("Query oldest first after a cursor, no more pages")
    func queryAfter() async throws {
        let (ctx, _, ids) = try await fixture()
        let r = try await LogTools.query.run(ToolArguments(["afterId": .number(Double(ids[2])), "order": "oldest"]), ctx)
        #expect(r.structured["events"]?.array?.map { $0["id"]?.int64 } == [ids[3], ids[4]])
        #expect(r.structured["nextCursor"] == .null)
    }

    @Test("Query with nothing matching says so and suggests loosening")
    func queryEmpty() async throws {
        let (ctx, _, _) = try await fixture()
        let r = try await LogTools.query.run(ToolArguments(["filter": ["search": "no-such-text"]]), ctx)
        #expect(r.structured["total"] == 0)
        #expect(r.summary.hasPrefix("No events match"))
        #expect(!r.next.isEmpty)
    }

    @Test("A subsystem that doesn't exist fails with suggestions")
    func querySuggests() async throws {
        let (ctx, _, _) = try await fixture()
        await #expect(throws: ToolError.self) {
            try await LogTools.query.run(ToolArguments(["filter": ["subsystems": ["plaeyr"]]]), ctx)
        }
    }

    @Test("Query with includeData: true shows truncated data and dataTruncated flag")
    func queryWithLargeData() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)

        // Large payload: 3 KB of data
        let largeData = String(repeating: "x", count: 3 * 1024)
        // Small payload: 100 bytes
        let smallData = String(repeating: "y", count: 100)

        try await seed(store, session: s.id, [
            (.info, "com.app.auth", "", "with large data"),
        ], data: largeData)
        try await seed(store, session: s.id, [
            (.info, "com.app.auth", "", "with small data"),
        ], data: smallData)

        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: s.id))
        let r = try await LogTools.query.run(ToolArguments([
            "includeData": true, "order": "oldest"
        ]), ctx)

        let rows = r.structured["events"]?.array ?? []
        #expect(rows.count == 2)

        // First event: large data, should be truncated at 2 KB
        let largeRow = rows[0]
        #expect(largeRow["dataTruncated"]?.bool == true)
        let largeDataText = largeRow["data"]?.string ?? ""
        #expect(largeDataText.count <= 2048)
        #expect(largeDataText.count > 0)

        // Second event: small data, should not be truncated
        let smallRow = rows[1]
        #expect(smallRow["dataTruncated"]?.bool == false)
        #expect(smallRow["data"]?.string == smallData)
    }

    @Test("Facets with >100 subsystems caps array at 100 and reports remainder in subsystemsMore")
    func facetsWithManySubsystems() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)

        // Create events with 150 distinct subsystems
        var events: [(LogLevel, String, String, String)] = []
        for i in 0..<150 {
            events.append((.info, "subsys.\(String(format: "%03d", i))", "", "event \(i)"))
        }
        try await seed(store, session: s.id, events)

        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: s.id))
        let r = try await LogTools.facets.run(ToolArguments([:]), ctx)

        let subsystemsArray = r.structured["subsystems"]?.array ?? []
        #expect(subsystemsArray.count == 100)

        let subsystemsMore = r.structured["subsystemsMore"]?.int ?? 0
        #expect(subsystemsMore == 50)
    }

    @Test("Get: full events, missing ids named")
    func get() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.error, "a", "b", "boom")], data: #"{"code":401}"#)
        let id = try #require(try await store.latestEventId(sessionId: s.id))
        let r = try await LogTools.get.run(ToolArguments(["ids": [.number(Double(id)), 999_999]]), makeContext(store))
        #expect(r.structured["events"]?.array?.first?["data"]?["code"] == 401)
        #expect(r.structured["missing"] == [999_999])
        #expect(r.body.contains("boom"))
        #expect(r.sessionId == s.id)
    }

    @Test("Review focus: a 25 MB payload comes back capped")
    func getHuge() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let huge = #"{"blob":""# + String(repeating: "x", count: 25 * 1024 * 1024) + #""}"#
        try await seed(store, session: s.id, [(.info, "a", "", "big")], data: huge)
        let id = try #require(try await store.latestEventId(sessionId: s.id))
        let r = try await LogTools.get.run(ToolArguments(["ids": [.number(Double(id))]]), makeContext(store))
        let event = try #require(r.structured["events"]?.array?.first)
        #expect(event["dataTruncated"] == true)
        #expect((event["data"]?.string?.utf8.count ?? .max) <= ToolText.payloadCap)
        #expect(r.text.utf8.count < 2 * ToolText.payloadCap)
    }

    @Test("Get without ids explains")
    func getNoIds() async throws {
        let store = try LogStore(source: .inMemory)
        await #expect(throws: ToolError.self) { try await LogTools.get.run(ToolArguments(), makeContext(store)) }
    }
}
