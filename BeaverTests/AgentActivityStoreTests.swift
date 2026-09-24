import Testing
import Foundation
@testable import BeaverCore

@Suite("Agent activity journal")
struct AgentActivityStoreTests {

    private func read(_ summary: String, session: Int64? = nil) -> NewAgentActivity {
        NewAgentActivity(client: "claude-code", tool: "logs_query", kind: .read,
                         summary: summary, sessionId: session)
    }

    @Test("Records newest first, counts unseen, marks seen")
    func recordAndSee() async throws {
        let store = try LogStore(source: .inMemory)
        try await store.recordAgentActivity(read("one"))
        try await store.recordAgentActivity(read("two"))
        #expect(try await store.agentActivity().map(\.summary) == ["two", "one"])
        #expect(try await store.unseenAgentActivityCount() == 2)
        try await store.markAgentActivitySeen()
        #expect(try await store.unseenAgentActivityCount() == 0)
    }

    @Test("Keeps only the newest rows past the cap")
    func trims() async throws {
        let store = try LogStore(source: .inMemory)
        for i in 0..<(LogStore.agentActivityCap + 5) {
            try await store.recordAgentActivity(read("\(i)"))
        }
        let rows = try await store.agentActivity(limit: 10_000)
        #expect(rows.count == LogStore.agentActivityCap)
        #expect(rows.first?.summary == "\(LogStore.agentActivityCap + 4)")
        #expect(rows.last?.summary == "5")
    }

    @Test("Survives its session's deletion with the link cleared")
    func sessionDelete() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        try await store.recordAgentActivity(read("x", session: session.id))
        try await store.deleteSession(id: session.id)
        let row = try #require(try await store.agentActivity().first)
        #expect(row.sessionId == nil)
    }

    @Test("A link to a session that doesn't exist is stored as none")
    func missingSession() async throws {
        let store = try LogStore(source: .inMemory)
        try await store.recordAgentActivity(read("x", session: 999))
        #expect(try await store.agentActivity().first?.sessionId == nil)
    }

    @Test("Clear empties it and broadcasts")
    func clear() async throws {
        let store = try LogStore(source: .inMemory)
        let changes = await store.changes()
        try await store.recordAgentActivity(read("x"))
        try await store.clearAgentActivity()
        #expect(try await store.agentActivity().isEmpty)
        var seen = 0
        for await change in changes {
            if case .agentActivityChanged = change { seen += 1 }
            if seen == 2 { break }
        }
        #expect(seen == 2)
    }

    @Test("Text helpers hide reads and copy lines")
    func text() {
        let at = Date(timeIntervalSince1970: 0)
        let read = AgentActivity(id: 1, at: at, client: "claude-code", tool: "logs_query", kind: .read,
                                 summary: "41 events", level: nil, isError: false, error: nil,
                                 linksJSON: nil, sessionId: 13, seen: false)
        let failed = AgentActivity(id: 2, at: at, client: nil, tool: "network_get", kind: .read,
                                   summary: "No request #9", level: nil, isError: true, error: "No request #9",
                                   linksJSON: nil, sessionId: nil, seen: false)
        let change = AgentActivity(id: 3, at: at, client: "cursor", tool: "filters_save", kind: .change,
                                   summary: "saved", level: nil, isError: false, error: nil,
                                   linksJSON: nil, sessionId: nil, seen: false)
        #expect(AgentActivityText.visible([read, change], hideReads: true) == [change])
        #expect(AgentActivityText.line(read).hasSuffix("claude-code logs_query — 41 events"))
        #expect(AgentActivityText.line(failed).hasSuffix("agent network_get — No request #9 ✗"))
        #expect(AgentActivityText.copyText([read, change]).split(separator: "\n").count == 2)
    }
}
