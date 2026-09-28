import Testing
import Foundation
@testable import BeaverCore

@Suite("Follow the device (M26)")
struct FollowDeviceTests {

    private func liveFixture() async throws -> (LogStore, Session, FakeUI) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        try await seed(store, session: a.id, [(.info, "app", "", "before")])
        return (store, a, FakeUI(value: HostSnapshot(liveSessionIds: [a.id])))
    }

    /// The device drops, comes back in a new session, and logs `message` there.
    private func restart(_ store: LogStore, _ ui: FakeUI, logging message: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ui.update { $0.liveSessionIds = [] }
            try? await Task.sleep(for: .milliseconds(400))
            guard let b = try? await store.createSession(source: .live) else { return }
            ui.update { $0.liveSessionIds = [b.id] }
            try? await Task.sleep(for: .milliseconds(300))
            await store.append(event(message), to: b.id)
        }
    }

    @Test("Review focus: omitted sessionId carries a wait across a restart and says so")
    func follows() async throws {
        let (store, a, ui) = try await liveFixture()
        restart(store, ui, logging: "App started")
        let r = try await LogTools.wait.run(
            ToolArguments(["filter": ["search": "App started"], "timeoutMs": 5000]),
            makeContext(store, fakeUI: ui))
        #expect(r.structured["timedOut"] == false)
        #expect(r.body.contains("App started"))
        #expect(r.structured["sessionChanged"]?["from"] == JSON(a.id))
        #expect(r.structured["sessionId"] != JSON(a.id))
        #expect(r.summary.contains("reconnected"))
    }

    @Test("A pinned session reports that it ended, without waiting out the timeout")
    func pinnedEnds() async throws {
        let (store, a, ui) = try await liveFixture()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ui.update { $0.liveSessionIds = [] }
        }
        let started = ContinuousClock.now
        let r = try await LogTools.wait.run(ToolArguments(["sessionId": JSON(a.id), "timeoutMs": 10_000]),
                                            makeContext(store, fakeUI: ui))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(r.structured["sessionEnded"] == true)
        #expect(r.structured["deviceDisconnected"] == true)
        #expect(r.summary.contains("ended"))
    }

    @Test("A device that doesn't come back is reported when the wait ends")
    func disconnected() async throws {
        let (store, _, ui) = try await liveFixture()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            ui.update { $0.liveSessionIds = [] }
        }
        let r = try await LogTools.wait.run(ToolArguments(["timeoutMs": 1000]), makeContext(store, fakeUI: ui))
        #expect(r.structured["timedOut"] == true)
        #expect(r.structured["deviceDisconnected"] == true)
    }

    @Test("Collecting keeps everything that arrived in the window")
    func collects() async throws {
        let (store, a, ui) = try await liveFixture()
        let ctx = makeContext(store, fakeUI: ui)
        let start = try await ctx.resolveSession(ToolArguments())
        let after = try await store.latestEventId(sessionId: a.id) ?? 0
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await store.append(event("one"), to: a.id)
            try? await Task.sleep(for: .milliseconds(300))
            await store.append(event("two"), to: a.id)
        }
        let w = try await ctx.waitForEvents(from: start, afterId: after, filter: .none, limit: 50,
                                            timeout: .milliseconds(1200), untilFirst: false)
        #expect(w.events.map(\.message) == ["one", "two"])
        #expect(w.total == 2)
        #expect(!w.timedOut)
    }

    @Test("An unknown deviceId lists the devices; no device says how to connect")
    func requireDevice() async throws {
        let (store, a, ui) = try await liveFixture()
        let ctx = makeContext(store, fakeUI: ui)
        let ok = try await ctx.requireDevice(ToolArguments(["deviceId": JSON(String(a.id))]), doing: "send a command")
        #expect(ok.liveSessionId == a.id)
        await #expect(throws: ToolError.self) {
            try await ctx.requireDevice(ToolArguments(["deviceId": "pixel-7"]), doing: "send a command")
        }
        ui.update { $0.liveSessionIds = [] }
        do {
            _ = try await ctx.requireDevice(ToolArguments(), doing: "send a command")
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.hasPrefix("No device is connected, so Beaver can't send a command."))
            #expect(error.message.contains("beaver_status()"))
        }
    }

    private func session(_ id: Int64, app: String? = nil, model: String? = nil) -> Session {
        Session(id: id, startedAt: Date(), source: .live, appName: app, deviceModel: model, platform: "iOS")
    }

    @Test("successor: same fingerprint wins; a different one is never followed")
    func successorByFingerprint() {
        let a = session(1, app: "Alpha", model: "iPhone")
        #expect(DeviceFollower.successor(of: a, live: [session(2, app: "Beta", model: "Pixel"),
                                                       session(3, app: "Alpha", model: "iPhone")],
                                         appeared: [3]) == 3)
        #expect(DeviceFollower.successor(of: a, live: [session(2, app: "Beta", model: "Pixel")],
                                         appeared: [2]) == nil)
    }

    @Test("successor: unknown fingerprint follows only the one session that just came up")
    func successorWithoutFingerprint() {
        let a = session(1, app: "Alpha", model: "iPhone")
        #expect(DeviceFollower.successor(of: a, live: [session(4)], appeared: [4]) == 4)
        #expect(DeviceFollower.successor(of: a, live: [session(4), session(5)], appeared: [4, 5]) == nil)
        // Connected before A dropped: not A's restart.
        #expect(DeviceFollower.successor(of: a, live: [session(2)], appeared: []) == nil)
    }

    @Test("Review focus: A restarts while B stays connected — the wait follows A, not B")
    func followsTheRightDevice() async throws {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: nil, deviceModel: "iPhone",
                                             platform: "iOS", osVersion: nil)
        try await store.setSessionDeviceInfo(id: b.id, appName: "Beta", appVersion: nil, deviceModel: "Pixel",
                                             platform: "Android", osVersion: nil)
        let ui = FakeUI(value: HostSnapshot(liveSessionIds: [a.id, b.id], viewingSessionId: a.id))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ui.update { $0.liveSessionIds = [b.id] }
            await store.append(event("App started"), to: b.id)   // B's log must not count
            try? await Task.sleep(for: .milliseconds(400))
            guard let a2 = try? await store.createSession(source: .live) else { return }
            ui.update { $0.liveSessionIds = [b.id, a2.id] }
            try? await Task.sleep(for: .milliseconds(300))
            await store.append(event("App started"), to: a2.id)
        }
        let r = try await LogTools.wait.run(
            ToolArguments(["filter": ["search": "App started"], "timeoutMs": 5000]),
            makeContext(store, fakeUI: ui))
        #expect(r.structured["timedOut"] == false)
        #expect(r.structured["sessionChanged"]?["from"] == JSON(a.id))
        #expect(r.structured["sessionChanged"]?["to"] != JSON(b.id))
        #expect(r.structured["sessionId"] != JSON(b.id))
    }

    @Test("Review focus: another device connecting doesn't end a pinned wait")
    func otherDeviceDoesNotEndPinned() async throws {
        let (store, a, ui) = try await liveFixture()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard let b = try? await store.createSession(source: .live) else { return }
            ui.update { $0.liveSessionIds = [a.id, b.id] }
        }
        let r = try await LogTools.wait.run(ToolArguments(["sessionId": JSON(a.id), "timeoutMs": 1500]),
                                            makeContext(store, fakeUI: ui))
        #expect(r.structured["sessionEnded"] == false)
        #expect(r.structured["timedOut"] == true)
    }

    @Test("Another device restarting doesn't move a wait off the device it follows")
    func otherDeviceRestartIsIgnored() async throws {
        let store = try LogStore(source: .inMemory)
        let b = try await store.createSession(source: .live)
        let a = try await store.createSession(source: .live)
        let ui = FakeUI(value: HostSnapshot(liveSessionIds: [b.id, a.id], viewingSessionId: b.id))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ui.update { $0.liveSessionIds = [b.id] }
            try? await Task.sleep(for: .milliseconds(400))
            guard let a2 = try? await store.createSession(source: .live) else { return }
            ui.update { $0.liveSessionIds = [b.id, a2.id] }
        }
        let r = try await LogTools.wait.run(ToolArguments(["timeoutMs": 1500]), makeContext(store, fakeUI: ui))
        #expect(r.structured["sessionChanged"] == .null)
        #expect(r.structured["sessionId"] == JSON(b.id))
        #expect(r.structured["deviceDisconnected"] == false)
    }

    @Test("Twins: a device connected alongside A is never A's restart, even with the same fingerprint")
    func twinsAreNotRestarts() async throws {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        for id in [a.id, b.id] {
            try await store.setSessionDeviceInfo(id: id, appName: "Alpha", appVersion: nil, deviceModel: "iPhone",
                                                 platform: "iOS", osVersion: nil)
        }
        var follower = DeviceFollower(start: a.id, live: [a.id, b.id])
        let dropped = await follower.step(live: [b.id], store: store)
        #expect(dropped == .gone)
        let a2 = try await store.createSession(source: .live)
        let back = await follower.step(live: [b.id, a2.id], store: store)
        #expect(back == .moved(a2.id))
    }
}
