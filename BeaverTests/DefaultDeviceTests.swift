import Testing
import Foundation
@testable import BeaverCore

@Suite("Default device (D76)")
struct DefaultDeviceTests {

    /// Alpha (uid A) and Beta (uid B), both live.
    private func twoDevices(default device: DefaultDevice?) async throws -> (LogStore, Session, Session, ToolContext) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: "1.0", deviceModel: "iPhone 15",
                                             platform: "iOS", osVersion: "18.0", deviceUID: "A")
        try await store.setSessionDeviceInfo(id: b.id, appName: "Beta", appVersion: "2.0", deviceModel: "Pixel 8",
                                             platform: "Android", osVersion: "15", deviceUID: "B")
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [a.id, b.id], defaultDevice: device))
        return (store, a, b, ctx)
    }

    private let call = "commands_send(command: \"cmdlist\")"

    @Test("Without deviceId, the default is used")
    func usesDefault() async throws {
        let (_, _, b, ctx) = try await twoDevices(default: .uid("B"))
        let (_, id) = try await ctx.requireDevice(ToolArguments(), doing: "send a command", call: call)
        #expect(id == b.id)
    }

    @Test("An explicit deviceId beats the default")
    func explicitWins() async throws {
        let (_, a, _, ctx) = try await twoDevices(default: .uid("B"))
        let (_, id) = try await ctx.requireDevice(ToolArguments(["deviceId": JSON(a.id)]), doing: "send", call: call)
        #expect(id == a.id)
    }

    @Test("A default by device id follows the app into its new session")
    func followsRestart() async throws {
        let store = try LogStore(source: .inMemory)
        let old = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: old.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                             platform: nil, osVersion: nil, deviceUID: "A")
        try await store.endSession(old.id)
        let new = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: new.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                             platform: nil, osVersion: nil, deviceUID: "A")
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [new.id], defaultDevice: .uid("A")))
        let (_, id) = try await ctx.requireDevice(ToolArguments(), doing: "send", call: call)
        #expect(id == new.id)
    }

    @Test("A default that isn't connected fails, naming it — never another device")
    func defaultGone() async throws {
        let store = try LogStore(source: .inMemory)
        let gone = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: gone.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                             platform: nil, osVersion: nil, deviceUID: "A")
        let other = try await store.createSession(source: .live)
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [other.id], defaultDevice: .uid("A")))
        do {
            _ = try await ctx.requireDevice(ToolArguments(), doing: "send a command", call: call)
            Issue.record("expected a ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("default device Alpha"))
            #expect(error.message.contains("devices_set_default(deviceId: null)"))
            #expect(!error.message.contains("deviceId: \"\(other.id)\""))
            #expect(error.message.contains("beaver_status()"))
        }
    }

    @Test("B3: devices_disconnect ignores the default: with several apps it needs deviceId")
    func disconnectNeedsDeviceId() async throws {
        let (store, a, b, _) = try await twoDevices(default: .uid("A"))
        let device = FakeDevice()
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [a.id, b.id], defaultDevice: .uid("A")),
                              device: device)
        do {
            _ = try await CommandTools.disconnect.run(ToolArguments(), ctx)
            Issue.record("expected a ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("2 devices are connected"))
            #expect(error.message.contains("devices_disconnect(deviceId: \""))
        }
        #expect(device.disconnected.isEmpty)
        _ = try await CommandTools.disconnect.run(ToolArguments(["deviceId": JSON(b.id)]), ctx)
        #expect(device.disconnected == [b.id])
        let one = makeContext(store, ui: HostSnapshot(liveSessionIds: [a.id], defaultDevice: .uid("B")), device: device)
        _ = try await CommandTools.disconnect.run(ToolArguments(), one)
        #expect(device.disconnected == [b.id, a.id])
    }

    @Test("B3: commands_send names the app, and (default) when the default picked it; B2: logs_wait gets its session")
    func sendNamesTarget() async throws {
        let (_, a, b, ctx) = try await twoDevices(default: .uid("A"))
        let r = try await CommandTools.send.run(ToolArguments(["command": "cmdlist"]), ctx)
        #expect(r.summary.contains("Alpha 1.0 (iPhone 15, iOS 18.0) (default)"))
        #expect(r.next.first?.hasPrefix("logs_wait(sessionId: \(a.id), afterId: ") == true)
        let explicit = try await CommandTools.send.run(ToolArguments(["command": "cmdlist", "deviceId": JSON(b.id)]), ctx)
        #expect(explicit.summary.contains("Beta 2.0"))
        #expect(!explicit.summary.contains("(default)"))
        #expect(explicit.next.first?.hasPrefix("logs_wait(sessionId: \(b.id), ") == true)
    }

    @Test("B5: beaver_status marks only the session device tools would use as default")
    func statusOneDefault() async throws {
        let store = try LogStore(source: .inMemory)
        let stale = try await store.createSession(source: .live)
        let fresh = try await store.createSession(source: .live)
        for s in [stale, fresh] {
            try await store.setSessionDeviceInfo(id: s.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                                 platform: nil, osVersion: nil, deviceUID: "A")
        }
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [stale.id, fresh.id], defaultDevice: .uid("A")))
        let r = try await StatusTools.status.run(ToolArguments(), ctx)
        let flags = r.structured["devices"]?.array?.map { ($0["id"]?.string ?? "", $0["default"]?.bool ?? false) } ?? []
        #expect(flags.filter(\.1).map(\.0) == [String(fresh.id)])
        #expect(r.body.components(separatedBy: "(default)").count == 2)
    }

    @Test("A session default (no handshake) resolves only while that session is live")
    func sessionDefault() {
        let s = Session(id: 7, startedAt: .distantPast, source: .live)
        #expect(DefaultDevice(session: s) == .session(7))
        #expect(DefaultDevice.session(7).liveSession(in: [s], live: [7]) == 7)
        #expect(DefaultDevice.session(7).liveSession(in: [s], live: [8]) == nil)
        #expect(DefaultDevice(session: Session(id: 8, startedAt: .distantPast, source: .live, deviceUID: "U")) == .uid("U"))
        #expect(DefaultDevice.session(7).isGone(live: [8]))
        #expect(!DefaultDevice.session(7).isGone(live: [7]))
        #expect(!DefaultDevice.uid("U").isGone(live: []))
    }

    @Test("Review focus: D97 — of two live sessions of one device, the most recently active, not the highest id")
    func defaultByRecency() async throws {
        let store = try LogStore(source: .inMemory)
        let continued = try await store.createSession(source: .live)   // older id, reconnected (D97)
        let idle = try await store.createSession(source: .live)
        for s in [continued, idle] {
            try await store.setSessionDeviceInfo(id: s.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                                 platform: nil, osVersion: nil, deviceUID: "A")
        }
        try await seed(store, session: idle.id, [(.info, "app", "", "earlier")])
        try await seed(store, session: continued.id, [(.info, "loggernext.session", "", "Reconnected")])
        let ui = HostSnapshot(liveSessionIds: [continued.id, idle.id], defaultDevice: .uid("A"))
        let ctx = makeContext(store, ui: ui)
        let (_, id) = try await ctx.requireDevice(ToolArguments(), doing: "send", call: call)
        #expect(id == continued.id)
        #expect(try await ctx.resolveSession(ToolArguments()).id == continued.id)
        let status = try await StatusTools.status.run(ToolArguments(), ctx)
        let flags = status.structured["devices"]?.array?.filter { $0["default"]?.bool == true }.map { $0["id"]?.string }
        #expect(flags == [String(continued.id)])
    }

    @Test("Review focus: a session default whose session ended counts as no default")
    func deadSessionDefault() async throws {
        let store = try LogStore(source: .inMemory)
        let gone = try await store.createSession(source: .live)
        let back = try await store.createSession(source: .live)   // the app reconnected without a handshake
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [back.id], defaultDevice: .session(gone.id)))
        let (host, id) = try await ctx.requireDevice(ToolArguments(), doing: "send", call: call)
        #expect(id == back.id)
        #expect(try await !ctx.describeTarget(id, ToolArguments(), host).contains("(default)"))
    }

    @Test("Review focus: without sessionId, reads and waits use the default device, not the viewed one")
    func readsUseDefault() async throws {
        let (store, a, b, _) = try await twoDevices(default: .uid("A"))
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [a.id, b.id], viewingSessionId: b.id,
                                                      defaultDevice: .uid("A")))
        #expect(try await ctx.resolveSession(ToolArguments()).id == a.id)
    }
}
