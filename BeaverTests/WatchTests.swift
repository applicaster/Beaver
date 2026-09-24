import Testing
import Foundation
@testable import BeaverCore

@Suite("Watches (M29)")
struct WatchTests {

    private func live() async throws -> (LogStore, Session, FakeUI, ToolContext) {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.error, "player.core", "", "old error")])
        let ui = FakeUI(value: HostSnapshot(deviceConnected: true, liveSessionId: s.id))
        return (store, s, ui, makeContext(store, fakeUI: ui))
    }

    @Test("Counts match logs_query over the same range, with a breakdown")
    func counts() async throws {
        let (store, s, _, ctx) = try await live()
        // Globs resolve against the session's names when the watch starts.
        try await seed(store, session: s.id, [(.info, "player.ads", "", "ads ready")])
        let start = try await WatchTools.start.run(ToolArguments(["name": "player errors",
            "filter": ["minLevel": "error", "subsystems": ["player*"]]]), ctx)
        let startId = try #require(start.structured["startId"]?.int64)
        try await seed(store, session: s.id, [(.error, "player.core", "", "e1"), (.warning, "player.core", "", "w"),
                                              (.error, "player.ads", "", "e2"), (.error, "com.app.auth", "", "other")])
        let status = try await WatchTools.status.run(ToolArguments(["name": "player errors"]), ctx)
        let query = try await LogTools.query.run(ToolArguments(["afterId": JSON(startId),
            "filter": ["minLevel": "error", "subsystems": ["player.core", "player.ads"]]]), ctx)
        #expect(status.structured["watches"]?.array?.first?["total"] == query.structured["total"])
        #expect(status.structured["watches"]?.array?.first?["total"] == 2)
        #expect(status.body.contains("player.core 1"))
        #expect(status.body.contains("player.ads 1"))
    }

    @Test("notify fires once at atCount: an attention note in the journal and one notification")
    func notifyOnce() async throws {
        let (store, s, ui, ctx) = try await live()
        let start = try await WatchTools.start.run(ToolArguments(["name": "errs", "filter": ["minLevel": "error"],
                                                                  "notify": ["atCount": 2]]), ctx)
        let startId = try #require(start.structured["startId"]?.int64)
        try await seed(store, session: s.id, [(.error, "a", "", "one"), (.error, "a", "", "two")])
        var notes: [AgentActivity] = []
        for _ in 0..<50 where notes.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            notes = try await store.agentActivity().filter(\.isAttention)
        }
        #expect(notes.count == 1)
        #expect(notes.first?.summary.hasPrefix("Watch “errs”: 2 matches") == true)
        let firstId = try #require(try await store.eventPage(sessionId: s.id, filter: Filter(minLevel: .error),
                                                             afterId: startId, limit: 1, newestFirst: false).events.first?.id)
        #expect(notes.first?.links == [.event(firstId)])
        try await seed(store, session: s.id, [(.error, "a", "", "three")])
        try await Task.sleep(for: .milliseconds(1200))
        #expect(try await store.agentActivity().filter(\.isAttention).count == 1)
        #expect(ui.notes.count == 1)
        let status = try await WatchTools.status.run(ToolArguments(["name": "errs"]), ctx)
        #expect(status.body.contains("fired"))
    }

    @Test("A following watch counts the device's new session; a pinned one doesn't")
    func follows() async throws {
        let (store, a, ui, ctx) = try await live()
        _ = try await WatchTools.start.run(ToolArguments(["name": "follow", "filter": ["search": "hit"]]), ctx)
        _ = try await WatchTools.start.run(ToolArguments(["name": "pinned", "filter": ["search": "hit"],
                                                          "sessionId": JSON(a.id)]), ctx)
        let b = try await store.createSession(source: .live)
        ui.update { $0.liveSessionId = b.id }
        try await seed(store, session: b.id, [(.info, "a", "", "hit")])
        let status = try await WatchTools.status.run(ToolArguments(), ctx)
        let byName = Dictionary(uniqueKeysWithValues: (status.structured["watches"]?.array ?? [])
            .map { ($0["name"]?.string ?? "", $0) })
        #expect(byName["follow"]?["total"] == 1)
        #expect(byName["follow"]?["sessions"] == [JSON(a.id), JSON(b.id)])
        #expect(byName["pinned"]?["total"] == 0)
    }

    @Test("notify counts across the device's new session and links the first match")
    func notifyFollows() async throws {
        let (store, a, ui, ctx) = try await live()
        _ = try await WatchTools.start.run(ToolArguments(["name": "errs", "filter": ["minLevel": "error"],
                                                          "notify": ["atCount": 2]]), ctx)
        try await seed(store, session: a.id, [(.error, "a", "", "before restart")])
        let firstId = try #require(try await store.latestEventId(sessionId: a.id))
        try await Task.sleep(for: .milliseconds(700))
        let b = try await store.createSession(source: .live)
        ui.update { $0.liveSessionId = b.id }
        try await seed(store, session: b.id, [(.info, "a", "", "noise"), (.error, "a", "", "after restart")])
        var notes: [AgentActivity] = []
        for _ in 0..<50 where notes.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            notes = try await store.agentActivity().filter(\.isAttention)
        }
        #expect(notes.map(\.summary).first?.hasPrefix("Watch “errs”: 2 matches") == true)
        #expect(notes.first?.links == [.event(firstId)])
        #expect(ui.notes.count == 1)
    }

    @Test("watch_stop returns the final status and forgets the watch; missing names are not errors")
    func stop() async throws {
        let (_, _, _, ctx) = try await live()
        _ = try await WatchTools.start.run(ToolArguments(["name": "w", "filter": ["minLevel": "error"]]), ctx)
        let r = try await WatchTools.stop.run(ToolArguments(["name": "w"]), ctx)
        #expect(r.summary.hasPrefix("Stopped “w”"))
        #expect(await ctx.watches.all().isEmpty)
        let again = try await WatchTools.stop.run(ToolArguments(["name": "w"]), ctx)
        #expect(again.summary.hasPrefix("No watch “w”"))
        let none = try await WatchTools.status.run(ToolArguments(), ctx)
        #expect(none.summary.hasPrefix("No watches"))
    }

    @Test("Bad input says what to do")
    func errors() async throws {
        let (_, _, _, ctx) = try await live()
        await #expect(throws: ToolError.self) { try await WatchTools.start.run(ToolArguments(["filter": ["minLevel": "error"]]), ctx) }
        await #expect(throws: ToolError.self) {
            try await WatchTools.start.run(ToolArguments(["name": "x", "notify": ["atCount": 0]]), ctx)
        }
        await #expect(throws: ToolError.self) { try await WatchTools.status.run(ToolArguments(["name": "nope"]), ctx) }
    }

    @Test("markFired checks identity: a stale in-flight check for a replaced watch can't mark the replacement fired")
    func markFiredIdentity() async {
        let watches = Watches()
        let old = Watches.Watch(name: "w", filter: .none, filterText: "no filter", follows: false,
                                sessionId: 1, startId: 0, startedAt: Date(timeIntervalSince1970: 1),
                                notifyAt: 1, firedAt: nil)
        _ = await watches.add(old)
        let new = Watches.Watch(name: "w", filter: .none, filterText: "no filter", follows: false,
                                sessionId: 1, startId: 0, startedAt: Date(timeIntervalSince1970: 2),
                                notifyAt: 1, firedAt: nil)
        // watch_start replaced "w" while the old watch's notify task was
        // mid-await; its stale `startedAt` must not mark the new watch fired.
        _ = await watches.add(new)
        #expect(await watches.markFired("w", startedAt: old.startedAt, at: Date()) == false)
        #expect(await watches.get("w")?.firedAt == nil)
        // Only the current watch's own identity can fire it, and only once.
        #expect(await watches.markFired("w", startedAt: new.startedAt, at: Date()) == true)
        #expect(await watches.markFired("w", startedAt: new.startedAt, at: Date()) == false)
    }
}
