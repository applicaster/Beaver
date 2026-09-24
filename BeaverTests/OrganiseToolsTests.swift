import Testing
import Foundation
@testable import BeaverCore

@Suite("Bookmarks, saved filters, Clear")
struct OrganiseToolsTests {

    @Test("bookmarks_set on an event: on, again (idempotent), off")
    func eventBookmark() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.error, "a", "", "boom")])
        let id = try #require(try await store.latestEventId(sessionId: s.id))
        let ctx = makeContext(store)
        let r = try await StateTools.bookmarksSet.run(ToolArguments(["eventId": JSON(id)]), ctx)
        #expect(r.summary == "Bookmarked event #\(id).")
        #expect(r.links == [.event(id)])
        _ = try await StateTools.bookmarksSet.run(ToolArguments(["eventId": JSON(id), "on": true]), ctx)
        #expect(try await store.bookmarkedEventIds(sessionId: s.id) == [id])
        _ = try await StateTools.bookmarksSet.run(ToolArguments(["eventId": JSON(id), "on": false]), ctx)
        #expect(try await store.bookmarkedEventIds(sessionId: s.id).isEmpty)
        #expect(StateTools.bookmarksSet.listing["annotations"]?["idempotentHint"] == true)
    }

    @Test("bookmarks_set on a request sets, never toggles")
    func requestBookmark() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.recordNetworkEntry(try #require(NetworkCapture(#"{"url":"https://a.example","status":500}"#, fallbackMillis: 0)),
                                           sessionId: s.id)
        let id = try #require(try await store.networkEntries(sessionId: s.id).first?.id)
        #expect(try await store.networkEntrySessionId(id: id) == s.id)
        let ctx = makeContext(store)
        for _ in 0..<2 { _ = try await StateTools.bookmarksSet.run(ToolArguments(["networkId": JSON(id)]), ctx) }
        #expect(try await store.networkBookmarkIds(sessionId: s.id) == [id])
        await #expect(throws: ToolError.self) {
            try await StateTools.bookmarksSet.run(ToolArguments(["networkId": 999_999]), ctx)
        }
        await #expect(throws: ToolError.self) {
            try await StateTools.bookmarksSet.run(ToolArguments(), ctx)
        }
    }

    @Test("filters_save resolves globs to exact names, replaces by name; filters_delete names the choices")
    func savedFilters() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.warning, "com.app.auth", "", "x")])
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionId: s.id))
        let r = try await StateTools.filtersSave.run(
            ToolArguments(["name": "Auth problems", "filter": ["minLevel": "warn", "subsystems": ["*auth*"]]]), ctx)
        #expect(r.summary.hasPrefix("Saved filter “Auth problems”: level ≥ warning; subsystems com.app.auth"))
        let again = try await StateTools.filtersSave.run(
            ToolArguments(["name": "Auth problems", "filter": ["minLevel": "error"]]), ctx)
        #expect(again.summary.contains("replaced"))
        #expect(try await store.savedFilters().map(\.filter.minLevel) == [.error])
        await #expect(throws: ToolError.self) {
            try await StateTools.filtersSave.run(ToolArguments(["name": "Empty", "filter": [:]]), ctx)
        }
        do {
            _ = try await StateTools.filtersDelete.run(ToolArguments(["name": "nope"]), ctx)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("Auth problems"))
        }
        _ = try await StateTools.filtersDelete.run(ToolArguments(["name": "auth problems"]), ctx)
        #expect(try await store.savedFilters().isEmpty)
    }

    @Test("filters_save works on a fresh install when the filter needs no names")
    func savedFilterNoSessions() async throws {
        let store = try LogStore(source: .inMemory)
        _ = try await StateTools.filtersSave.run(ToolArguments(["name": "Errors", "filter": ["minLevel": "error"]]),
                                                 makeContext(store))
        #expect(try await store.savedFilters().map(\.name) == ["Errors"])
    }

    @Test("logs_clear hides the viewed session up to its latest event, and nothing else")
    func clear() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        let other = try await store.createSession(source: .imported)
        try await seed(store, session: s.id, [(.info, "a", "", "one"), (.info, "a", "", "two")])
        let latest = try #require(try await store.latestEventId(sessionId: s.id))
        let ui = FakeUI(value: HostSnapshot(liveSessionId: s.id, viewingSessionId: s.id))
        let r = try await LogTools.clear.run(ToolArguments(), makeContext(store, fakeUI: ui))
        #expect(ui.clears == [FakeUI.Clear(sessionId: s.id, through: latest)])
        #expect(r.summary.contains("Nothing was deleted"))
        #expect(try await store.eventCount(sessionId: s.id, filter: .none) == 2)
        await #expect(throws: ToolError.self) {
            try await LogTools.clear.run(ToolArguments(["sessionId": JSON(other.id)]), makeContext(store, fakeUI: ui))
        }
        await #expect(throws: ToolError.self) {
            try await LogTools.clear.run(ToolArguments(), makeContext(store))   // nothing viewed
        }
    }
}
