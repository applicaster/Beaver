import Testing
import Foundation
@testable import BeaverCore

@Suite("Follow the device (M26)")
struct FollowDeviceTests {

    private func liveFixture() async throws -> (LogStore, Session, FakeUI) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        try await seed(store, session: a.id, [(.info, "app", "", "before")])
        return (store, a, FakeUI(value: HostSnapshot(deviceConnected: true, liveSessionId: a.id)))
    }

    /// The device drops, comes back in a new session, and logs `message` there.
    private func restart(_ store: LogStore, _ ui: FakeUI, logging message: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ui.update { $0.deviceConnected = false; $0.liveSessionId = nil }
            try? await Task.sleep(for: .milliseconds(400))
            guard let b = try? await store.createSession(source: .live) else { return }
            ui.update { $0.deviceConnected = true; $0.liveSessionId = b.id }
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
            ui.update { $0.deviceConnected = false; $0.liveSessionId = nil }
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
            ui.update { $0.deviceConnected = false; $0.liveSessionId = nil }
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
        let ok = try await ctx.requireDevice(ToolArguments(["deviceId": "current"]), doing: "send a command")
        #expect(ok.liveSessionId == a.id)
        await #expect(throws: ToolError.self) {
            try await ctx.requireDevice(ToolArguments(["deviceId": "pixel-7"]), doing: "send a command")
        }
        ui.update { $0.deviceConnected = false; $0.liveSessionId = nil }
        do {
            _ = try await ctx.requireDevice(ToolArguments(), doing: "send a command")
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.hasPrefix("No device is connected, so Beaver can't send a command."))
            #expect(error.message.contains("beaver_status()"))
        }
    }
}
