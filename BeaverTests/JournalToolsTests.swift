// BeaverTests/JournalToolsTests.swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("journal_note")
struct JournalToolsTests {

    private func call(_ server: MCPServer, _ arguments: JSON) async throws -> JSON {
        let body = JSON.object(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                "params": ["name": "journal_note", "arguments": arguments]]).data()
        let data = try #require(await server.handle(body, client: "claude-code/2.1", protocolVersion: "2025-06-18"))
        return try #require(try JSON.parse(data)["result"])
    }

    private func fixture() async throws -> (LogStore, FakeUI, MCPServer, Int64) {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.error, "com.app.auth", "", "refresh failed 401")])
        let id = try #require(try await store.latestEventId(sessionId: s.id))
        let ui = FakeUI(value: HostSnapshot(liveSessionId: s.id))
        let server = MCPServer(tools: BeaverTools.all, context: makeContext(store, fakeUI: ui),
                               journal: AgentJournal(store: store))
        return (store, ui, server, id)
    }

    @Test("An info note is a journal entry with its links, and notifies nobody")
    func info() async throws {
        let (store, ui, server, id) = try await fixture()
        let result = try await call(server, ["text": "Login fails: the refresh token expired", "links": [["eventId": JSON(id)]]])
        #expect(result["isError"] == false)
        #expect(result["structuredContent"]?["notified"] == false)
        #expect(ui.notes.isEmpty)
        let row = try #require(try await store.agentActivity().first)
        #expect(row.kind == .note)
        #expect(row.tool == "journal_note")
        #expect(row.level == "info")
        #expect(row.summary == "Login fails: the refresh token expired")
        #expect(row.links == [.event(id)])
        #expect(row.error == nil)
    }

    @Test("An attention note asks the app to notify, and says so")
    func attention() async throws {
        let (store, ui, server, id) = try await fixture()
        let result = try await call(server, ["text": "Cause found", "level": "attention", "links": [["eventId": JSON(id)]]])
        #expect(result["structuredContent"]?["notified"] == true)
        #expect(ui.notes == [AgentNote(text: "Cause found", links: [.event(id)])])
        #expect(try await store.agentActivity().first?.isAttention == true)
    }

    @Test("An undelivered attention note is marked in the journal and tells the agent where to enable")
    func notNotified() async throws {
        let (store, ui, server, _) = try await fixture()
        ui.setNotifyOutcome(AgentNotifications.outcome(state: .denied, frontmost: false, held: false))
        let result = try await call(server, ["text": "Look now", "level": "attention"])
        #expect(result["structuredContent"]?["notified"] == false)
        #expect(result["structuredContent"]?["howToEnable"] == .string(AgentNotifications.howToEnable))
        let text = result["content"]?.array?.first?["text"]?.string ?? ""
        #expect(text.contains(AgentNotifications.howToEnable))
        let row = try #require(try await store.agentActivity().first)
        #expect(row.error == "Not notified: Notifications are off for Beaver.")
        #expect(row.isError == false)
    }

    @Test("Review focus: links to things that don't exist are refused, with an example")
    func badLinks() async throws {
        let (store, _, server, _) = try await fixture()
        for link: JSON in [["eventId": 999_999], ["networkId": 5], ["sessionId": 77], ["savedFilter": "Nope"], ["foo": 1]] {
            let result = try await call(server, ["text": "x", "links": [link]])
            #expect(result["isError"] == true)
            #expect(result["content"]?.array?.first?["text"]?.string?.contains("Example: links:") == true)
        }
        #expect(try await store.agentActivity().allSatisfy { $0.isError })
    }

    @Test("Text is required and capped; level is info or attention")
    func validation() async throws {
        let (_, _, server, _) = try await fixture()
        #expect(try await call(server, [:])["isError"] == true)
        #expect(try await call(server, ["text": .string(String(repeating: "x", count: 1_001))])["isError"] == true)
        #expect(try await call(server, ["text": "x", "level": "urgent"])["isError"] == true)
    }
}
