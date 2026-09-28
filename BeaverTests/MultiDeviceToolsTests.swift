import Testing
import Foundation
@testable import BeaverCore

@Suite("Several devices (D73)")
struct MultiDeviceToolsTests {

    /// Two live sessions: a = "Alpha" on an iPhone, b = "Beta" on a Pixel.
    private func twoDevices(viewing: Int64? = nil) async throws -> (LogStore, Session, Session, FakeUI) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: "1.0",
                                             deviceModel: "iPhone 15", platform: "iOS", osVersion: "18.0")
        try await store.setSessionDeviceInfo(id: b.id, appName: "Beta", appVersion: "2.0",
                                             deviceModel: "Pixel 8", platform: "Android", osVersion: "15")
        let ui = FakeUI(value: HostSnapshot(serverState: "clientConnected", liveSessionIds: [a.id, b.id],
                                            viewingSessionId: viewing))
        return (store, a, b, ui)
    }

    @Test("Review focus: with two devices, a call without deviceId lists both")
    func severalDevicesNeedDeviceId() async throws {
        let (store, a, b, ui) = try await twoDevices()
        let device = FakeDevice()
        do {
            _ = try await CommandTools.send.run(ToolArguments(["command": "cmdlist"]),
                                                makeContext(store, fakeUI: ui, device: device))
            Issue.record("expected a ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("\"\(a.id)\" (Alpha"))
            #expect(error.message.contains("\"\(b.id)\" (Beta"))
            #expect(error.message.contains("deviceId"))
        }
        #expect(device.sent.isEmpty)
    }

    @Test("commands_send with deviceId reaches that device")
    func routesByDeviceId() async throws {
        let (store, _, b, ui) = try await twoDevices()
        let device = FakeDevice()
        let r = try await CommandTools.send.run(ToolArguments(["command": "cmdlist", "deviceId": JSON(b.id)]),
                                                makeContext(store, fakeUI: ui, device: device))
        #expect(device.targets == [b.id])
        #expect(r.structured["sessionId"] == JSON(b.id))
    }

    @Test("An unknown deviceId fails with the list")
    func unknownDeviceId() async throws {
        let (store, _, _, ui) = try await twoDevices()
        await #expect(throws: ToolError.self) {
            try await makeContext(store, fakeUI: ui).requireDevice(ToolArguments(["deviceId": "999"]), doing: "send a command")
        }
    }

    @Test("beaver_status lists every device")
    func status() async throws {
        let (store, a, _, ui) = try await twoDevices()
        let r = try await StatusTools.status.run(ToolArguments(), makeContext(store, fakeUI: ui))
        #expect(r.structured["devices"]?.array?.count == 2)
        #expect(r.structured["devices"]?.array?.first?["id"] == JSON(String(a.id)))
        #expect(r.summary.contains("2 devices"))
        #expect(r.summary.contains("Beta"))
    }

    @Test("commands_list answers for the chosen device")
    func commandsPerDevice() async throws {
        let (store, a, b, ui) = try await twoDevices()
        ui.update { $0.commandsBySession = [a.id: [CommandHint(name: "alpha.only", syntax: nil, description: nil)],
                                            b.id: [CommandHint(name: "beta.only", syntax: nil, description: nil)]] }
        let r = try await StateTools.commandsList.run(ToolArguments(["deviceId": JSON(b.id)]), makeContext(store, fakeUI: ui))
        #expect(r.body.contains("beta.only"))
        #expect(!r.body.contains("alpha.only"))
    }

    @Test("Without sessionId, reads use the viewed live device, else the newest")
    func resolveAmongSeveral() async throws {
        let (store, a, b, ui) = try await twoDevices(viewing: nil)
        let ctx = makeContext(store, fakeUI: ui)
        #expect(try await ctx.resolveSession(ToolArguments()).id == b.id)
        ui.update { $0.viewingSessionId = a.id }
        #expect(try await ctx.resolveSession(ToolArguments()).id == a.id)
    }
}
