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

    @Test("Get: a >256 KB body is capped in structured too, consistent with bodiesTruncated")
    func getCapsStructuredBody() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let big = String(repeating: "y", count: 300 * 1024)
        let payload = #"{"url":"https://api.x.io/big","method":"GET","status":200,"timing":{"startTime":1},"responseBody":""#
            + big + #""}"#
        try await store.recordNetworkEntry(try #require(NetworkCapture(payload, fallbackMillis: 0)), sessionId: s.id)
        let id = try #require(try await store.networkEntries(sessionId: s.id).first?.id)
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: s.id))
        let r = try await NetworkTools.get.run(ToolArguments(["id": .number(Double(id))]), ctx)
        #expect(r.structured["bodiesTruncated"] == true)
        let structuredBody = try #require(r.structured["responseBody"]?.string)
        #expect(structuredBody.utf8.count <= ToolText.payloadCap)
        #expect(r.body.contains("[cut at 256 KB]"))
    }

    @Test("Copy as cURL carries the Copy menu's warnings")
    func copy() async throws {
        let (ctx, allIds) = try await fixture()
        let r = try await NetworkTools.copy.run(ToolArguments(["id": .number(Double(allIds[1])), "format": "curl"]), ctx)
        #expect(r.body.hasPrefix("curl -X 'POST'"))
        #expect(r.summary.contains("Authorization redacted by the SDK"))
    }

    @Test("Copy: text over 256 KB is capped, with a note and a truncated flag")
    func copyCapsLargeText() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let big = String(repeating: "z", count: 300 * 1024)
        let payload = #"{"url":"https://api.x.io/big","method":"POST","status":200,"timing":{"startTime":1},"requestBody":""#
            + big + #""}"#
        try await store.recordNetworkEntry(try #require(NetworkCapture(payload, fallbackMillis: 0)), sessionId: s.id)
        let id = try #require(try await store.networkEntries(sessionId: s.id).first?.id)
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: s.id))
        let r = try await NetworkTools.copy.run(ToolArguments(["id": .number(Double(id)), "format": "curl"]), ctx)
        #expect(r.body.utf8.count <= ToolText.payloadCap)
        #expect(r.summary.contains("(cut at 256 KB)"))
        #expect(r.structured["truncated"] == true)
    }

    @Test("Unknown status pick explains the forms")
    func badStatus() async throws {
        let (ctx, _) = try await fixture()
        await #expect(throws: ToolError.self) { try await NetworkTools.query.run(ToolArguments(["status": "weird"]), ctx) }
    }

    @Test("Unknown host throws and names closest")
    func badHost() async throws {
        let (ctx, _) = try await fixture()
        await #expect(throws: ToolError.self) { try await NetworkTools.query.run(ToolArguments(["host": ["totallywrong.tld"]]), ctx) }
    }
}
