import Testing
import Foundation
@testable import BeaverCore

@Suite("UI tools")
struct UIToolsTests {

    struct Fixture {
        let store: LogStore
        let a: Int64            // live: 4 events, 2 requests
        let b: Int64            // imported: 1 event
        let events: [Int64]     // a's: debug feed, error auth, warning player, error auth
        let requests: [Int64]   // a's: GET 200 api.x.io/feed, POST 401 api.x.io/oauth/token
    }

    private func fixture() async throws -> Fixture {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live).id
        try await seed(store, session: a, [
            (.debug, "com.app.feed", "list", "loaded"),
            (.error, "com.app.auth", "token", "refresh failed 401"),
            (.warning, "com.app.player", "", "buffering"),
            (.error, "com.app.auth", "token", "refresh failed again"),
        ])
        let b = try await store.createSession(source: .imported).id
        try await seed(store, session: b, [(.info, "com.other", "", "hello")])
        for p in [#"{"url":"https://api.x.io/feed","method":"GET","status":200,"timing":{"startTime":1,"duration":80}}"#,
                  #"{"url":"https://api.x.io/oauth/token","method":"POST","status":401,"timing":{"startTime":2,"duration":120}}"#] {
            try await store.recordNetworkEntry(try #require(NetworkCapture(p, fallbackMillis: 0)), sessionId: a)
        }
        let events = try await store.eventPage(sessionId: a, filter: .none, limit: 10, newestFirst: false).events.map(\.id)
        let requests = try await store.networkEntries(sessionId: a).map(\.id)
        return Fixture(store: store, a: a, b: b, events: events, requests: requests)
    }

    private func show(_ args: [String: JSON], _ ctx: ToolContext) async throws -> ToolResult {
        try await UITools.show.run(ToolArguments(args), ctx)
    }

    @Test("ui_state reports what the window shows")
    func state() async throws {
        let f = try await fixture()
        var ui = UIState()
        ui.tab = .network
        ui.sessionId = f.a
        ui.networkFilter.status = .errors
        ui.selectedNetworkId = f.requests[1]
        let (ctx, _) = makeUIContext(f.store, ui: HostSnapshot(ui: ui, frontmost: false))
        let r = try await UITools.state.run(ToolArguments(), ctx)
        #expect(r.summary == "Beaver shows Network, session #\(f.a) — status errors; request #\(f.requests[1]) selected. Beaver is in the background.")
        #expect(r.structured["tab"] == "network")
        #expect(r.structured["networkFilter"]?["status"] == "errors")
        #expect(r.structured["selectedNetworkId"]?.int64 == f.requests[1])
        #expect(r.structured["frontmost"] == false)
        #expect(r.body.contains("Network filter: status errors"))
        #expect(r.next.contains("network_get(id: \(f.requests[1]))"))
    }

    @Test("Without reveal nothing takes focus; reveal: true is passed on (M12)")
    func reveal() async throws {
        let f = try await fixture()
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(viewingSessionId: f.a))
        let quiet = try await show(["tab": "network"], ctx)
        #expect(await fake.changes.last?.reveal == false)
        #expect(quiet.summary.hasPrefix("Changed in the background, nothing took focus: Network, session #\(f.a)"))
        #expect(quiet.next == ["ui_show(reveal: true) when the user asks to see it"])
        let loud = try await show(["reveal": true], ctx)
        #expect(await fake.changes.last == UIChange(reveal: true))
        #expect(loud.summary.hasPrefix("Brought Beaver forward: "))
    }

    @Test("Tabs: aliases, inferred from what is set, unknown fails with an example")
    func tabs() async throws {
        let f = try await fixture()
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(viewingSessionId: f.a))
        _ = try await show(["tab": "Requests"], ctx)
        #expect(await fake.value.ui.tab == .network)
        _ = try await show(["filter": ["minLevel": "error"]], ctx)
        #expect(await fake.value.ui.tab == .logs)
        _ = try await show(["storage": ["layer": "keychain", "search": "token"]], ctx)
        let s = await fake.value.ui
        #expect(s.tab == .storages)
        #expect(s.storageLayer == .keychain)
        #expect(s.storageSearch == "token")
        do {
            _ = try await show(["tab": "graphs"], ctx)
            Issue.record("expected a ToolError")
        } catch let e as ToolError {
            #expect(e.message.contains("Example: ui_show(tab: \"network\")"))
        }
        await #expect(throws: ToolError.self) { try await show(["storage": ["layer": "all"]], ctx) }
    }

    @Test("Log filter: names resolved, the person's Clear kept, filter: {} shows everything")
    func logFilter() async throws {
        let f = try await fixture()
        var ui = UIState()
        ui.sessionId = f.a
        ui.logFilter.hiddenThroughEventId = f.events[0]
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(ui: ui))

        let r = try await show(["filter": ["subsystems": ["*AUTH*"]]], ctx)
        let set = await fake.value.ui.logFilter
        #expect(set.subsystems == ["com.app.auth"])
        #expect(set.hiddenThroughEventId == f.events[0])
        #expect(r.summary.contains("Resolved: subsystems *AUTH* → com.app.auth."))

        _ = try await show(["minLevel": "warn"], ctx)            // top level, lifted into filter
        #expect(await fake.value.ui.logFilter.minLevel == .warning)

        _ = try await show(["filter": [:]], ctx)
        #expect(await fake.value.ui.logFilter == .none)
    }

    @Test("The resolved session is pinned in the change itself, not just read back from the snapshot")
    func sessionPinned() async throws {
        let f = try await fixture()
        var ui = UIState()
        ui.sessionId = f.a
        ui.logFilter.hiddenThroughEventId = f.events[0]
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(ui: ui))

        let r = try await show(["filter": ["minLevel": "error"]], ctx)
        #expect(await fake.changes.last?.sessionId == f.a)
        #expect(r.structured["sessionId"]?.int64 == f.a)
        // Same session: the person's Clear watermark survives the call.
        #expect(await fake.value.ui.logFilter.hiddenThroughEventId == f.events[0])
    }

    @Test("select first / last resolve against the filter being set")
    func firstLast() async throws {
        let f = try await fixture()
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(viewingSessionId: f.a))
        _ = try await show(["filter": ["minLevel": "error"], "select": "first"], ctx)
        #expect(await fake.value.ui.selectedEventId == f.events[1])
        let last = try await show(["select": "last"], ctx)
        #expect(await fake.value.ui.selectedEventId == f.events[3])
        #expect(last.links == [AgentLink(eventId: f.events[3])])

        _ = try await show(["networkFilter": ["status": "errors"], "select": "first"], ctx)
        let s = await fake.value.ui
        #expect(s.tab == .network)
        #expect(s.selectedNetworkId == f.requests[1])

        let none = try await show(["tab": "logs", "filter": ["search": "no such text"], "select": "first"], ctx)
        #expect(none.summary.contains("nothing matches the log filter, so nothing is selected"))

        await #expect(throws: ToolError.self) { try await show(["tab": "storages", "select": "first"], ctx) }
    }

    @Test("select an event: opens its session; hidden or missing fails with what to do")
    func selectEvent() async throws {
        let f = try await fixture()
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(viewingSessionId: f.b))
        let r = try await show(["select": ["eventId": JSON(f.events[1])], "filter": ["minLevel": "error"]], ctx)
        let s = await fake.value.ui
        #expect(s.sessionId == f.a)
        #expect(s.tab == .logs)
        #expect(s.logFilter.minLevel == .error)
        #expect(s.selectedEventId == f.events[1])
        #expect(r.links == [AgentLink(eventId: f.events[1])])

        do {   // the warning is hidden by level ≥ error
            _ = try await show(["select": ["eventId": JSON(f.events[2])]], ctx)
            Issue.record("expected a ToolError")
        } catch let e as ToolError {
            #expect(e.message.contains("hidden by the log filter"))
            #expect(e.message.contains("ui_show(filter: {}, select: {eventId: \(f.events[2])})"))
        }
        await #expect(throws: ToolError.self) {
            try await show(["sessionId": JSON(f.b), "select": ["eventId": JSON(f.events[1])]], ctx)
        }
        await #expect(throws: ToolError.self) { try await show(["select": ["eventId": 999_999]], ctx) }
    }

    @Test("Network filter: one method, status and host; lists of one and numbers accepted")
    func networkFilter() async throws {
        let f = try await fixture()
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(viewingSessionId: f.a))
        _ = try await show(["networkFilter": ["method": ["post"], "status": 401, "host": "*x.io"]], ctx)
        let s = await fake.value.ui
        #expect(s.tab == .network)
        #expect(s.networkFilter.method == "POST")
        #expect(s.networkFilter.status == .code(401))
        #expect(s.networkFilter.host == "api.x.io")

        do {
            _ = try await show(["networkFilter": ["method": ["GET", "POST"]]], ctx)
            Issue.record("expected a ToolError")
        } catch let e as ToolError {
            #expect(e.message.contains("one method at a time"))
        }
        do {
            _ = try await show(["networkFilter": ["host": "nothing.example"]], ctx)
            Issue.record("expected a ToolError")
        } catch let e as ToolError {
            #expect(e.message.contains("Closest: api.x.io"))
        }
        do {   // the 200 is hidden by status 401
            _ = try await show(["select": ["networkId": JSON(f.requests[0])]], ctx)
            Issue.record("expected a ToolError")
        } catch let e as ToolError {
            #expect(e.message.contains("ui_show(networkFilter: {}, select: {networkId: \(f.requests[0])})"))
        }
        _ = try await show(["tab": "network", "select": JSON(f.requests[1])], ctx)   // a bare number on the network tab
        #expect(await fake.value.ui.selectedNetworkId == f.requests[1])
    }

    @Test("No sessions: tab changes work, a selection says what to do")
    func noSessions() async throws {
        let store = try LogStore(source: .inMemory)
        let (ctx, fake) = makeUIContext(store, ui: HostSnapshot(windowOpen: false))
        let r = try await show(["tab": "network", "reveal": true], ctx)
        #expect(await fake.value.ui.tab == .network)
        #expect(r.next == ["ask the user to click Beaver in the Dock: its window is closed"])
        do {
            _ = try await show(["select": "first"], ctx)
            Issue.record("expected a ToolError")
        } catch let e as ToolError {
            #expect(e.message.contains("no sessions"))
        }
    }

    @Test("Links open through the same path, in context")
    func openLinks() async throws {
        let f = try await fixture()
        var ui = UIState()
        ui.sessionId = f.a
        ui.logFilter = Filter(minLevel: .error, hiddenThroughEventId: f.events[0])
        ui.networkFilter.status = .errors
        let (ctx, fake) = makeUIContext(f.store, ui: HostSnapshot(ui: ui))

        _ = try await UITools.open(AgentLink(eventId: f.events[2]), reveal: false, ctx)   // hidden by level ≥ error
        var s = await fake.value.ui
        #expect(s.tab == .logs)
        #expect(s.selectedEventId == f.events[2])
        #expect(s.logFilter == Filter(hiddenThroughEventId: f.events[0]))   // Clear kept: it doesn't hide the event
        #expect(await fake.changes.last?.reveal == false)

        _ = try await UITools.open(AgentLink(networkId: f.requests[0]), reveal: true, ctx)   // hidden by errors
        s = await fake.value.ui
        #expect(s.tab == .network)
        #expect(s.selectedNetworkId == f.requests[0])
        #expect(s.networkFilter == NetworkFilter())
        #expect(await fake.changes.last?.reveal == true)

        _ = try await UITools.open(AgentLink(sessionId: f.b), reveal: false, ctx)
        s = await fake.value.ui
        #expect(s.sessionId == f.b)
        #expect(s.tab == .logs)

        _ = try await f.store.upsertSavedFilter(name: "Auth", filter: Filter(minLevel: .warning, subsystems: ["com.app.auth"]))
        _ = try await UITools.open(AgentLink(savedFilter: "Auth"), reveal: false, ctx)
        #expect(await fake.value.ui.logFilter.subsystems == ["com.app.auth"])

        await #expect(throws: ToolError.self) { try await UITools.open(AgentLink(eventId: 999_999), reveal: false, ctx) }
        await #expect(throws: ToolError.self) { try await UITools.open(AgentLink(savedFilter: "Gone"), reveal: false, ctx) }
    }
}
