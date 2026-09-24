import Testing
import Foundation
@testable import BeaverCore

@Suite("Journal links from tool calls")
struct JournalLinkTests {

    @Test("A row shows its stored links, else its session")
    func shownLinks() {
        func row(links: String?, session: Int64?) -> AgentActivity {
            AgentActivity(id: 1, at: Date(), client: nil, tool: "x", kind: .read, summary: "",
                          level: nil, isError: false, error: nil, linksJSON: links, sessionId: session, seen: false)
        }
        #expect(row(links: #"[{"eventId":9}]"#, session: 2).shownLinks == [.event(9)])
        #expect(row(links: nil, session: 2).shownLinks == [.session(2)])
        #expect(row(links: nil, session: 2).links.isEmpty)   // toasts only follow stored links
        #expect(row(links: nil, session: nil).shownLinks.isEmpty)
    }

    @Test("The journal stores a result's links")
    func journal() async throws {
        let store = try LogStore(source: .inMemory)
        await AgentJournal(store: store).record(
            toolName: "network_get", kind: .read, client: nil,
            result: ToolResult(summary: "Request #3", links: [.network(3)]), error: nil)
        let row = try #require(try await store.agentActivity().first)
        #expect(row.links == [.network(3)])
    }

    @Test("Reads that point at something link to it")
    func toolLinks() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.info, "a", "", "one"), (.info, "a", "", "two")])
        try await store.recordNetworkEntry(
            try #require(NetworkCapture(#"{"url":"https://api.x.io/feed","method":"GET","status":200,"timing":{"startTime":1}}"#,
                                        fallbackMillis: 0)),
            sessionId: s.id)
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: s.id))
        let eventIds = try await store.eventPage(sessionId: s.id, filter: .none, limit: 10, newestFirst: false).events.map(\.id)
        let requestId = try #require(try await store.networkEntries(sessionId: s.id).first?.id)

        let events = try await LogTools.get.run(ToolArguments(["ids": .array(eventIds.map { JSON($0) })]), ctx)
        #expect(events.links == eventIds.map { .event($0) })
        let request = try await NetworkTools.get.run(ToolArguments(["id": JSON(requestId)]), ctx)
        #expect(request.links == [.network(requestId)])
        let copy = try await NetworkTools.copy.run(ToolArguments(["id": JSON(requestId)]), ctx)
        #expect(copy.links == [.network(requestId)])
    }

    @Test("A person reads the error without the agent's example call")
    func personMessage() {
        #expect(ToolError("No event #5. Example: logs_query() lists event ids.").personMessage == "No event #5.")
        #expect(ToolError("No such thing.").personMessage == "No such thing.")
    }
}
