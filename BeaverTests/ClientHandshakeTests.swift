import Testing
import Foundation
@testable import BeaverCore

@Suite("Client handshake (D77)")
struct ClientHandshakeTests {

    private func frame(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test("The SDK's handshake is decoded with every field")
    func decodesAllFields() throws {
        let data = try frame(["type": "handshake", "deviceId": "8F2C-A", "deviceName": "Apple iPhone15,2",
                              "model": "iPhone15,2", "platform": "iOS 18.6",
                              "appPackage": "com.example.app", "version": "11.0.1"])
        guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(data) else {
            Issue.record("expected .clientHandshake"); return
        }
        #expect(h.deviceId == "8F2C-A")
        #expect(h.model == "iPhone15,2")
        #expect(h.appPackage == "com.example.app")
        #expect(h.version == "11.0.1")
        #expect(h.platformParts.name == "iOS")
        #expect(h.platformParts.version == "18.6")
    }

    @Test("A handshake with no fields, empty strings or extra keys still decodes")
    func decodesSparse() throws {
        let data = try frame(["type": "handshake", "deviceId": "", "somethingNew": 1])
        guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(data) else {
            Issue.record("expected .clientHandshake"); return
        }
        #expect(h == ClientHandshake())
        #expect(h.platformParts.name == nil)
    }

    @Test("A deviceId equal to model (the SDK's fallback) is ignored")
    func modelAsDeviceIdIgnored() throws {
        let data = try frame(["type": "handshake", "deviceId": "iPhone15,2", "model": "iPhone15,2"])
        guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(data) else {
            Issue.record("expected .clientHandshake"); return
        }
        #expect(h.deviceId == nil)
        #expect(h.model == "iPhone15,2")
    }

    @Test("A platform without a version keeps the name")
    func platformWithoutVersion() {
        #expect(ClientHandshake(platform: "tvOS").platformParts.name == "tvOS")
        #expect(ClientHandshake(platform: "tvOS").platformParts.version == nil)
    }

    @Test("The handshake fills the session; applicaster.v2, arriving later, wins where it has a value")
    func storeKeepsHarvestFirst() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.applyHandshake(ClientHandshake(deviceId: "UID-1", model: "iPhone15,2", platform: "iOS 18.6",
                                                       appPackage: "com.example.app", version: "11.0.1"), to: s.id)
        try await store.recordStorageSnapshot(
            sessionId: s.id, namespace: .session,
            dataJSON: #"{"applicaster.v2":{"app_name":"Miami Heat","deviceModel":"iPhone 15 Pro"}}"#)
        let row = try #require(try await store.sessions().first { $0.id == s.id })
        #expect(row.deviceUID == "UID-1")
        #expect(row.appPackage == "com.example.app")
        #expect(row.appName == "Miami Heat")
        #expect(row.deviceModel == "iPhone 15 Pro")
        #expect(row.appVersion == "11.0.1")
        #expect(row.platform == "iOS")
        #expect(row.osVersion == "18.6")
    }

    @Test("Review focus: LiveDevices keeps a connection's handshake across a deleted session, drops it on disconnect")
    func liveDevicesKeepHandshake() {
        var live = LiveDevices()
        let c = UUID()
        _ = live.connect(c, session: 1, viewing: nil)
        live.setHandshake(ClientHandshake(deviceId: "UID-1"), for: c)
        _ = live.detach { $0 == 1 }
        #expect(live.handshake(for: c)?.deviceId == "UID-1")
        _ = live.attach(c, session: 2)
        #expect(live.handshake(for: c)?.deviceId == "UID-1")
        live.disconnect(c)
        #expect(live.handshake(for: c) == nil)
    }
}
