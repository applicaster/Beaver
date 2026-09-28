import Testing
import Foundation
import Synchronization
@testable import BeaverCore

/// The app's MCP server on the other end of the socket. `answer` returns
/// a result, `["error": …]` for a JSON-RPC error, or nil to stay silent.
final class ScriptedDevice: Sendable {
    let frames = Mutex<[JSON]>([])
    let client = Mutex<DeviceMCPClient?>(nil)
    let answer: @Sendable (String, JSON) async -> JSON?

    init(answer: @escaping @Sendable (String, JSON) async -> JSON?) { self.answer = answer }

    var methods: [String] { frames.withLock { $0.compactMap { $0["method"]?.string } } }

    func handle(_ data: Data) async {
        guard let frame = try? JSON.parse(data), frame["type"] == "mcp", let payload = frame["payload"] else { return }
        frames.withLock { $0.append(payload) }
        guard let id = payload["id"], let method = payload["method"]?.string else { return }
        let params = payload["params"] ?? .null
        Task {
            guard let result = await answer(method, params) else { return }
            let reply: JSON = if let error = result["error"] {
                ["jsonrpc": "2.0", "id": id, "error": error]
            } else {
                ["jsonrpc": "2.0", "id": id, "result": result]
            }
            await client.withLock { $0 }?.receive(reply)
        }
    }
}

@Suite("DeviceMCPClient (D75)")
struct DeviceMCPClientTests {

    private func connect(_ answer: @escaping @Sendable (String, JSON) async -> JSON?) -> (DeviceMCPClient, ScriptedDevice) {
        let device = ScriptedDevice(answer: answer)
        let client = DeviceMCPClient(setupTimeout: .milliseconds(200)) { await device.handle($0) }
        device.client.withLock { $0 = client }
        return (client, device)
    }

    private static let tools: JSON = ["tools": [["name": "app.restart"]]]

    @Test("Initializes once, then answers by id")
    func initializesOnce() async throws {
        let (client, device) = connect { method, _ in method == "tools/list" ? Self.tools : [:] }
        let first = try await client.request("tools/list", timeout: .seconds(1))
        let second = try await client.request("tools/list", timeout: .seconds(1))
        #expect(first == Self.tools)
        #expect(second == Self.tools)
        #expect(device.methods == ["initialize", "notifications/initialized", "tools/list", "tools/list"])
    }

    @Test("Concurrent requests get their own replies, even out of order")
    func outOfOrder() async throws {
        let (client, _) = connect { method, params in
            guard method == "tools/call" else { return [:] }
            if params["name"] == "slow" { try? await Task.sleep(for: .milliseconds(150)) }
            return ["echo": params["name"] ?? .null]
        }
        async let slow = client.request("tools/call", params: ["name": "slow"], timeout: .seconds(1))
        async let fast = client.request("tools/call", params: ["name": "fast"], timeout: .seconds(1))
        let (s, f) = try await (slow, fast)
        #expect(s["echo"] == "slow")
        #expect(f["echo"] == "fast")
    }

    @Test("A JSON-RPC error becomes .rpc")
    func rpcError() async {
        let (client, _) = connect { method, _ in
            method == "initialize" ? [:] : ["error": ["code": -32601, "message": "Method not found: x"]]
        }
        await #expect(throws: DeviceMCPError.rpc(code: -32601, message: "Method not found: x")) {
            try await client.request("x", timeout: .seconds(1))
        }
    }

    @Test("A request from the app, even reusing a pending call's id, is ignored")
    func ignoresRequestsFromDevice() async throws {
        let (client, device) = connect { method, _ in
            if method == "tools/call" { try? await Task.sleep(for: .milliseconds(100)); return ["real": true] }
            return [:]
        }
        async let result = client.request("tools/call", timeout: .seconds(1))
        // Wait for the call to be on the wire so we know the id it used.
        while device.frames.withLock({ $0.last?["method"]?.string }) != "tools/call" {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pendingId = device.frames.withLock { $0.last?["id"] } ?? .null
        await client.receive(["jsonrpc": "2.0", "id": pendingId, "method": "ping"])
        let value = try await result
        #expect(value["real"] == true)
    }

    @Test("Review focus: a reply after the timeout is ignored")
    func lateReply() async throws {
        let (client, _) = connect { method, _ in
            if method == "tools/call" { try? await Task.sleep(for: .milliseconds(300)); return ["late": true] }
            return [:]
        }
        await #expect(throws: DeviceMCPError.timeout) {
            try await client.request("tools/call", timeout: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(400))   // the late reply lands; nothing to resume
        let next = try await client.request("ping", timeout: .seconds(1))
        #expect(next == [:])
    }

    @Test("No answer to initialize: unsupported, and later calls fail at once without sending")
    func unsupported() async {
        let (client, device) = connect { _, _ in nil }
        await #expect(throws: DeviceMCPError.unsupported) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
        let start = ContinuousClock.now
        await #expect(throws: DeviceMCPError.unsupported) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .milliseconds(100))
        #expect(device.methods == ["initialize"])
    }

    @Test("Closing fails the waiting call with .disconnected, and later ones too")
    func closeWhileWaiting() async throws {
        let (client, _) = connect { method, _ in method == "initialize" ? [:] : nil }
        _ = try? await client.request("ping", timeout: .milliseconds(50))  // initialized; ping times out
        let waiting = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await client.close()
        await #expect(throws: DeviceMCPError.disconnected) { try await waiting.value }
        await #expect(throws: DeviceMCPError.disconnected) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
    }

    @Test("mcp frames decode, as an object, a string, or bare JSON-RPC")
    func decodesFrames() throws {
        let object = try JSONSerialization.data(withJSONObject: ["type": "mcp", "payload": ["jsonrpc": "2.0", "id": 3, "result": [:]]])
        let string = try JSONSerialization.data(withJSONObject: ["type": "mcp", "payload": #"{"jsonrpc":"2.0","id":4,"result":{}}"#])
        let bare = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 5, "result": [:]])
        for (data, id) in [(object, 3), (string, 4), (bare, 5)] {
            guard case .success(.mcp(let message)) = ProtocolDecoder.decode(data) else {
                Issue.record("expected .mcp for id \(id)"); continue
            }
            #expect(message["id"]?.int == id)
        }
        let broken = try JSONSerialization.data(withJSONObject: ["type": "mcp", "payload": 7])
        guard case .failure(.malformedMCP) = ProtocolDecoder.decode(broken) else {
            Issue.record("expected .malformedMCP"); return
        }
    }
}
