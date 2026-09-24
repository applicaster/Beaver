import Testing
import Foundation
@testable import BeaverCore

@Suite("Network tools")
struct NetworkToolsTests {

    private func fixture() async throws -> (ToolContext, [Int64]) {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let payloads = [
            #"{"url":"https://api.x.io/feed","method":"GET","status":200,"timing":{"startTime":1,"duration":80},"responseBody":"[]"}"#,
            #"{"url":"https://api.x.io/oauth/token","method":"POST","status":401,"timing":{"startTime":2,"duration":120},"requestHeaders":{"Authorization":"[REDACTED]"},"requestBody":"grant=refresh"}"#,
            #"{"url":"https://cdn.y.io/a.png","method":"GET","error":"timed out","timing":{"startTime":3}}"#,
        ]
        for p in payloads {
            try await store.recordNetworkEntry(try #require(NetworkCapture(p, fallbackMillis: 0)), sessionId: s.id)
        }
        let ids = try await store.networkEntries(sessionId: s.id).map(\.id)
        return (makeContext(store, ui: HostSnapshot(liveSessionId: s.id)), ids)
    }

    @Test("Query by status, method, host, search")
    func query() async throws {
        let (ctx, allIds) = try await fixture()
        func ids(_ args: [String: JSON]) async throws -> [Int64?] {
            try await NetworkTools.query.run(ToolArguments(args), ctx).structured["requests"]?.array?.map { $0["id"]?.int64 } ?? []
        }
        #expect(try await ids(["status": "errors"]) == [allIds[1], allIds[2]])
        #expect(try await ids(["status": "2xx"]) == [allIds[0]])
        #expect(try await ids(["status": 401]) == [allIds[1]])
        #expect(try await ids(["method": "post"]) == [allIds[1]])
        #expect(try await ids(["host": ["*x.io"]]) == [allIds[0], allIds[1]])
        #expect(try await ids(["search": "token"]) == [allIds[1]])
    }

    @Test("Query lines read like the table")
    func lines() async throws {
        let (ctx, allIds) = try await fixture()
        let r = try await NetworkTools.query.run(ToolArguments(), ctx)
        #expect(r.body.contains("#\(allIds[1]) POST 401 "))
        #expect(r.body.contains("failed (timed out)"))
    }

    @Test("Get shows headers and bodies")
    func get() async throws {
        let (ctx, allIds) = try await fixture()
        let r = try await NetworkTools.get.run(ToolArguments(["id": .number(Double(allIds[1]))]), ctx)
        #expect(r.body.contains("POST https://api.x.io/oauth/token"))
        #expect(r.body.contains("Authorization: [REDACTED]"))
        #expect(r.body.contains("grant=refresh"))
        #expect(r.structured["status"] == 401)
    }

    @Test("Copy as cURL carries the Copy menu's warnings")
    func copy() async throws {
        let (ctx, allIds) = try await fixture()
        let r = try await NetworkTools.copy.run(ToolArguments(["id": .number(Double(allIds[1])), "format": "curl"]), ctx)
        #expect(r.body.hasPrefix("curl -X 'POST'"))
        #expect(r.summary.contains("Authorization redacted by the SDK"))
    }

    @Test("Unknown status pick explains the forms")
    func badStatus() async throws {
        let (ctx, _) = try await fixture()
        await #expect(throws: ToolError.self) { try await NetworkTools.query.run(ToolArguments(["status": "weird"]), ctx) }
    }
}
