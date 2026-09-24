// BeaverTests/AgentJournalTests.swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Agent journal: notes, links, system entries")
struct AgentJournalTests {

    @Test("Links round-trip through links_json")
    func links() throws {
        let links: [JournalLink] = [.event(48211), .network(391), .session(13), .savedFilter("Auth")]
        let text = try #require(JournalLink.encode(links))
        #expect(text == #"[{"eventId":48211},{"networkId":391},{"sessionId":13},{"savedFilter":"Auth"}]"#)
        #expect(JournalLink.decode(text) == links)
        #expect(JournalLink.encode([]) == nil)
        #expect(JournalLink.decode("not json").isEmpty)
        #expect(JournalLink.event(5).label == "event #5")
        #expect(JournalLink.network(9).label == "request #9")
    }

    @Test("A tool result's level, links and notice reach the journal row")
    func recordExtras() async throws {
        let store = try LogStore(source: .inMemory)
        let result = ToolResult(summary: "Login fails: the refresh token expired", level: AgentActivity.attention,
                                links: [.event(7)], notice: "Not notified: notifications are off for Beaver.")
        await AgentJournal(store: store).record(toolName: "journal_note", kind: .note, client: "claude-code/2.1",
                                                result: result, error: nil)
        let row = try #require(try await store.agentActivity().first)
        #expect(row.kind == .note)
        #expect(row.level == "attention")
        #expect(row.links == [.event(7)])
        #expect(row.error == "Not notified: notifications are off for Beaver.")
        #expect(row.isError == false)
        #expect(row.isAttention)
        let line = AgentActivityText.line(row)
        #expect(line.contains("→ event #7"))
        #expect(line.contains("(Not notified: notifications are off for Beaver.)"))
    }

    @Test("System entries and watch notes are posted without a tool call")
    func post() async throws {
        let store = try LogStore(source: .inMemory)
        await AgentJournal(store: store).post(.system, "Device disconnected after \"restart\" → session #14")
        let row = try #require(try await store.agentActivity().first)
        #expect(row.kind == .system)
        #expect(row.client == nil)
        #expect(row.isError == false)
        #expect(row.toast == nil)
    }

    @Test("Notes keep 1 000 characters, every other line 300")
    func caps() async throws {
        let store = try LogStore(source: .inMemory)
        let journal = AgentJournal(store: store)
        let long = String(repeating: "x", count: 1_200)
        await journal.post(.note, long)
        await journal.post(.system, long)
        let lengths = try await store.agentActivity().map(\.summary.count).sorted()
        #expect(lengths == [AgentJournal.lineCap, AgentJournal.noteCap])
    }
}
