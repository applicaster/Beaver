import Testing
import Foundation
import Synchronization
@testable import BeaverCore

/// D89: zapp-support's `scripts/tv-bridge.mjs` feeds Beaver directly. The
/// frames below are built the way the bridge builds them (`send(type, body)`
/// with `JSON.stringify`, `toEvent` for CDP notifications).
@Suite("TV bridge (register, D89)")
struct TVBridgeTests {

    private static func frame(_ type: String, event: [String: Any]) throws -> Data {
        let inner = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "type": type, "event": inner])
    }

    static let register: [String: String] = ["deviceId": "cdp-192.168.1.40:9555", "appName": "Living room Vizio",
                                          "deviceName": "Living room Vizio", "platform": "tv-cdp"]

    private func decodeHandshake(_ data: Data) throws -> ClientHandshake {
        guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(data) else {
            Issue.record("expected .clientHandshake"); throw CancellationError()
        }
        return h
    }

    @Test("register decodes like a handshake: device id, name, a TV model, and logs only")
    func decodesRegister() throws {
        let h = try decodeHandshake(try Self.frame("register", event: Self.register))
        #expect(h.deviceId == "cdp-192.168.1.40:9555")
        #expect(h.appName == "Living room Vizio")
        #expect(h.deviceName == "Living room Vizio")
        #expect(h.platform == "tv-cdp")
        #expect(h.model == "TV (DevTools)")
        #expect(h.logsOnly)
        // The SDK's own handshake is not logs-only.
        let native = try JSONSerialization.data(withJSONObject: ["type": "handshake", "deviceId": "A"])
        #expect(try decodeHandshake(native).logsOnly == false)
    }

    @Test("register with the fields in data, or a bad event, still registers")
    func registerShapes() throws {
        let viaData = try JSONSerialization.data(withJSONObject: [
            "type": "register", "data": ["deviceId": "box-1", "deviceModel": "Hisense", "platform": "vidaa",
                                         "osVersion": "7", "versionName": "2.1"]])
        let h = try decodeHandshake(viaData)
        #expect(h.deviceId == "box-1")
        #expect(h.model == "Hisense")
        #expect(h.platformParts.name == "vidaa")
        #expect(h.platformParts.version == "7")
        #expect(h.version == "2.1")
        let bad = try JSONSerialization.data(withJSONObject: ["type": "register", "event": "not json"])
        #expect(try decodeHandshake(bad) == ClientHandshake(logsOnly: true))
    }

    @Test("Every frame the bridge sends lands in the store with its level, time and text")
    func bridgeFramesReachTheStore() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.applyHandshake(try decodeHandshake(try Self.frame("register", event: Self.register)), to: s.id)

        let now: Int64 = 1_727_512_345_678
        let stack = "TypeError: Cannot read properties of undefined (reading 'id')\n    at Player.load (app.js:10:5)"
        // toEvent(): console → LEVELS[type] ?? "info"; exceptions are errors; Log.entryAdded keeps CDP's
        // fractional millisecond timestamp.
        let events: [[String: Any]] = [
            ["category": "console", "subsystem": "tv-cdp", "level": "info", "timestamp": now, "message": "boot {\"a\":1} 3"],
            ["category": "console", "subsystem": "tv-cdp", "level": "warning", "timestamp": now + 1, "message": "slow"],
            ["category": "console", "subsystem": "tv-cdp", "level": "error", "timestamp": now + 2, "message": "failed"],
            ["category": "console", "subsystem": "tv-cdp", "level": "debug", "timestamp": now + 3, "message": "dbg"],
            ["category": "exception", "subsystem": "tv-cdp", "level": "error", "timestamp": now + 4, "message": stack],
            ["category": "log:network", "subsystem": "tv-cdp", "level": "error", "timestamp": Double(now) + 5.25,
             "message": "Failed to load resource"],
        ]
        for e in events {
            guard case .success(.event(let decoded)) = ProtocolDecoder.decode(try Self.frame("event", event: e)) else {
                Issue.record("bridge event didn't decode: \(e)"); return
            }
            await store.append(decoded, to: s.id)
        }
        try await waitForEvents(events.count, session: s.id, in: store)
        let rows = try await store.eventPage(sessionId: s.id, filter: .none, limit: 10, newestFirst: false).events
        #expect(rows.map(\.level) == [.info, .warning, .error, .debug, .error, .error])
        #expect(rows.map(\.category) == ["console", "console", "console", "console", "exception", "log:network"])
        #expect(rows.allSatisfy { $0.subsystem == "tv-cdp" })
        #expect(rows.map(\.timestampMillis) == [0, 1, 2, 3, 4, 5].map { UInt64(now) + $0 })
        #expect(rows[4].message == stack)

        let session = try #require(try await store.sessions().first { $0.id == s.id })
        #expect(session.appName == "Living room Vizio")
        #expect(session.deviceUID == "cdp-192.168.1.40:9555")
        #expect(session.deviceModel == "TV (DevTools)")
        #expect(session.platform == "tv-cdp")
        #expect(StatusTools.describeDevice(session) == "Living room Vizio (TV (DevTools), tv-cdp)")
    }

    @Test("The console's own level names warn and log are accepted")
    func consoleLevelAliases() throws {
        for (wire, level) in [("warn", LogLevel.warning), ("log", .info)] {
            let data = try Self.frame("event", event: ["subsystem": "web", "level": wire, "timestamp": 1, "message": "m"])
            guard case .success(.event(let e)) = ProtocolDecoder.decode(data) else { Issue.record("\(wire) didn't decode"); continue }
            #expect(e.level == level)
        }
    }

    @Test("A repeated register (the bridge found the app's page) renames the session")
    func reRegisterUpdates() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        var first = Self.register
        first["appName"] = "192.168.1.40:9555"
        try await store.applyHandshake(try decodeHandshake(try Self.frame("register", event: first)), to: s.id)
        var second = Self.register
        second["appName"] = "Zapp App @ 192.168.1.40:9555"
        try await store.applyHandshake(try decodeHandshake(try Self.frame("register", event: second)), to: s.id)
        let row = try #require(try await store.sessions().first { $0.id == s.id })
        #expect(row.appName == "Zapp App @ 192.168.1.40:9555")
        #expect(row.deviceUID == "cdp-192.168.1.40:9555")
    }

    @Test("LiveDevices knows which live sessions only send logs")
    func liveDevicesLogsOnly() {
        var live = LiveDevices()
        let tv = UUID(), phone = UUID()
        _ = live.connect(tv, session: 1, viewing: nil)
        _ = live.connect(phone, session: 2, viewing: nil)
        live.setHandshake(ClientHandshake(deviceId: "cdp-x", logsOnly: true), for: tv)
        live.setHandshake(ClientHandshake(deviceId: "UID-1"), for: phone)
        #expect(live.logsOnlySessions == [1])
        live.disconnect(tv)
        #expect(live.logsOnlySessions.isEmpty)
    }

    @Test("A logs-only client fails MCP at once, without sending initialize")
    func mcpLogsOnly() async {
        let sent = Mutex(0)
        let client = DeviceMCPClient(setupTimeout: .seconds(30)) { _ in sent.withLock { $0 += 1 } }
        await client.markLogsOnly()
        await #expect(throws: DeviceMCPError.unsupported) {
            try await client.request("tools/list", timeout: .seconds(30))
        }
        #expect(sent.withLock { $0 } == 0)
    }

    @Test("Agents: commands and storage refresh aren't sent to a logs-only device; it can still be disconnected")
    func toolsSkipLogsOnly() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        var host = HostSnapshot(liveSessionIds: [s.id])
        host.logsOnly = [s.id]
        let device = FakeDevice()
        let ctx = makeContext(store, ui: host, device: device)
        do {
            _ = try await CommandTools.send.run(ToolArguments(["command": "cmdlist"]), ctx)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("only sends logs"))
            #expect(error.message.contains("logs_query(sessionId: \(s.id)"))
        }
        let snap = try await StorageTools.snapshot.run(ToolArguments([:]), ctx)
        #expect(snap.summary.contains("only sends logs"))
        #expect(device.sent.isEmpty)
        _ = try await CommandTools.disconnect.run(ToolArguments([:]), ctx)
        #expect(device.disconnected == [s.id])
    }
}
