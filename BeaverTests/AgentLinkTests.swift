import Testing
import Foundation
@testable import BeaverCore

@Suite("Journal links")
struct AgentLinkTests {

    @Test("Links round-trip in journal_note's shape")
    func roundTrip() throws {
        let links = [AgentLink(eventId: 48211), AgentLink(networkId: 391), AgentLink(savedFilter: "Auth")]
        let json = try #require(AgentLink.encode(links))
        #expect(json == #"[{"eventId":48211},{"networkId":391},{"savedFilter":"Auth"}]"#)
        #expect(AgentLink.decode(json) == links)
        #expect(AgentLink.encode([]) == nil)
        #expect(AgentLink.decode(nil).isEmpty)
        #expect(AgentLink.decode("not json").isEmpty)
        #expect(AgentLink.decode("[{}]").isEmpty)
    }

    @Test("Labels name what a link opens")
    func labels() {
        #expect(AgentLink(eventId: 5).label == "Event #5")
        #expect(AgentLink(networkId: 6).label == "Request #6")
        #expect(AgentLink(savedFilter: "Auth").label == "Filter “Auth”")
        #expect(AgentLink(sessionId: 7).label == "Session #7")
    }

    @Test("A row links to its stored links, else to its session")
    func rowLinks() {
        func row(links: String?, session: Int64?) -> AgentActivity {
            AgentActivity(id: 1, at: Date(), client: nil, tool: "x", kind: .read, summary: "",
                          level: nil, isError: false, error: nil, linksJSON: links, sessionId: session, seen: false)
        }
        #expect(row(links: #"[{"eventId":9}]"#, session: 2).links == [AgentLink(eventId: 9)])
        #expect(row(links: nil, session: 2).links == [AgentLink(sessionId: 2)])
        #expect(row(links: nil, session: nil).links.isEmpty)
    }

    @Test("The journal stores a result's links")
    func journal() async throws {
        let store = try LogStore(source: .inMemory)
        await AgentJournal(store: store).record(
            toolName: "network_get", kind: .read, client: nil,
            result: ToolResult(summary: "Request #3", links: [AgentLink(networkId: 3)]), error: nil)
        let row = try #require(try await store.agentActivity().first)
        #expect(row.links == [AgentLink(networkId: 3)])
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
        #expect(events.links == eventIds.map { AgentLink(eventId: $0) })
        let request = try await NetworkTools.get.run(ToolArguments(["id": JSON(requestId)]), ctx)
        #expect(request.links == [AgentLink(networkId: requestId)])
        let copy = try await NetworkTools.copy.run(ToolArguments(["id": JSON(requestId)]), ctx)
        #expect(copy.links == [AgentLink(networkId: requestId)])
    }
}
