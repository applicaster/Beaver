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
            #expect(error.message.contains("commands_send(deviceId: \"\(other.id)\""))
        }
    }

    @Test("A session default (no handshake) resolves only while that session is live")
    func sessionDefault() {
        let s = Session(id: 7, startedAt: .distantPast, source: .live)
        #expect(DefaultDevice(session: s) == .session(7))
        #expect(DefaultDevice.session(7).liveSession(in: [s], live: [7]) == 7)
        #expect(DefaultDevice.session(7).liveSession(in: [s], live: [8]) == nil)
        #expect(DefaultDevice(session: Session(id: 8, startedAt: .distantPast, source: .live, deviceUID: "U")) == .uid("U"))
    }
}
