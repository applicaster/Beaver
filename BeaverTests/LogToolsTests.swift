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
}
