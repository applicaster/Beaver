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

/// Runs work one piece at a time, in call order.
actor SerialLine {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { await previous?.value; return await work() }
        tail = Task { _ = await task.value }
        return await task.value
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

    @Test("One request at a time: the next is sent after the previous reply, and its call timeout counts from then")
    func oneAtATime() async throws {
        // Like the SDKs, the device handles one MCP message at a time. The
        // queue wait (~300 ms) and the call (~300 ms) each fit fast's 450 ms,
        // together they don't.
        let line = SerialLine()
        let slowStarted = Mutex(false), slowReplied = Mutex(false), fastSawSlowReply = Mutex<Bool?>(nil)
        let (client, device) = connect { method, params in
            await line.run {
                guard method == "tools/call" else { return [:] }
                if params["name"] == "slow" {
                    slowStarted.withLock { $0 = true }
                    try? await Task.sleep(for: .milliseconds(300))
                    slowReplied.withLock { $0 = true }
                } else {
                    fastSawSlowReply.withLock { $0 = slowReplied.withLock { $0 } }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                return ["echo": params["name"] ?? .null]
            }
        }
        async let slow = client.request("tools/call", params: ["name": "slow"], timeout: .seconds(1))
        while !slowStarted.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        let fast = try await client.request("tools/call", params: ["name": "fast"], timeout: .milliseconds(450))
        #expect(try await slow["echo"] == "slow")
        #expect(fast["echo"] == "fast")
        #expect(fastSawSlowReply.withLock { $0 } == true)
        let calls = device.frames.withLock { $0.filter { $0["method"] == "tools/call" }.map { $0["params"]?["name"] } }
        #expect(calls == ["slow", "fast"])
    }

    @Test("Closing fails the request in flight with .disconnected and the queued one with .notSent; the queued one is never sent")
    func closeFailsQueue() async throws {
        let (client, device) = connect { method, _ in method == "initialize" ? [:] : nil }
        let first = Task { try await client.request("tools/call", params: ["name": "a"], timeout: .seconds(5)) }
        while !device.methods.contains("tools/call") { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { try await client.request("tools/call", params: ["name": "b"], timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await client.close()
        await #expect(throws: DeviceMCPError.disconnected) { try await first.value }
        await #expect(throws: DeviceMCPError.notSent("the app disconnected before Beaver sent it")) { try await second.value }
        #expect(device.methods == ["initialize", "notifications/initialized", "tools/call"])
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

    @Test("A native app that misses initialize: .notSent, and the next request tries initialize again")
    func nativeTimeoutRetries() async {
        let (client, device) = connect { _, _ in nil }
        await client.markNative()
        for _ in 0..<2 {
            await #expect(throws: DeviceMCPError.notSent("the app didn't answer initialize in time")) {
                try await client.request("tools/list", timeout: .seconds(1))
            }
        }
        #expect(device.methods == ["initialize", "initialize"])
    }

    @Test("A JSON-RPC error to initialize is .notSent, not .unsupported, and the next request retries")
    func initializeRPCErrorRetries() async throws {
        let attempts = Mutex(0)
        let (client, device) = connect { method, _ in
            guard method == "initialize" else { return Self.tools }
            let n = attempts.withLock { $0 += 1; return $0 }
            return n == 1 ? ["error": ["code": -32603, "message": "not ready"]] : [:]
        }
        await #expect(throws: DeviceMCPError.notSent("the app refused initialize: not ready")) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
        let tools = try await client.request("tools/list", timeout: .seconds(1))
        #expect(tools == Self.tools)
        #expect(device.methods == ["initialize", "initialize", "notifications/initialized", "tools/list"])
    }

    @Test("A handshake after the unsupported latch clears it")
    func markNativeClearsLatch() async {
        let (client, device) = connect { _, _ in nil }
        await #expect(throws: DeviceMCPError.unsupported) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
        await client.markNative()
        await #expect(throws: DeviceMCPError.notSent("the app didn't answer initialize in time")) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
        #expect(device.methods == ["initialize", "initialize"])
    }

    @Test("Closing while initialize waits: .notSent, and the request is never sent")
    func closeDuringInitialize() async throws {
        let (client, device) = connect { _, _ in nil }
        await client.markNative()
        let request = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        while !device.methods.contains("initialize") { try await Task.sleep(for: .milliseconds(5)) }
        await client.close()
        await #expect(throws: DeviceMCPError.notSent("the app disconnected before Beaver sent it")) {
            try await request.value
        }
        #expect(device.methods == ["initialize"])
    }

    @Test("Closing fails the waiting call with .disconnected; later ones are .notSent")
    func closeWhileWaiting() async throws {
        let (client, device) = connect { method, _ in method == "initialize" ? [:] : nil }
        _ = try? await client.request("ping", timeout: .milliseconds(50))  // initialized; ping times out
        let waiting = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await client.close()
        await #expect(throws: DeviceMCPError.disconnected) { try await waiting.value }
        let sent = Mutex(false)
        await #expect(throws: DeviceMCPError.notSent("the app disconnected before Beaver sent it")) {
            try await client.request("tools/list", timeout: .seconds(1), onSent: { sent.withLock { $0 = true } })
        }
        #expect(!sent.withLock { $0 })
        #expect(!device.methods.contains("tools/list"))
    }

    @Test("A request that doesn't get its turn within its timeout: .notSent naming the busy call, never sent; the line goes on")
    func queueWaitTimesOut() async throws {
        let (client, device) = connect { method, params in
            if params["name"] == "slow" { try? await Task.sleep(for: .milliseconds(300)) }
            return ["echo": params["name"] ?? .null]
        }
        let slow = Task { try await client.request("tools/call", params: ["name": "slow"], timeout: .seconds(2)) }
        while !device.methods.contains("tools/call") { try await Task.sleep(for: .milliseconds(5)) }
        // Queued behind it: one gives up, the one after it still gets its turn.
        let sent = Mutex(false)
        let impatient = Task {
            try await client.request("tools/call", params: ["name": "impatient"], timeout: .milliseconds(100),
                                     onSent: { sent.withLock { $0 = true } })
        }
        try await Task.sleep(for: .milliseconds(20))
        let patient = Task { try await client.request("tools/call", params: ["name": "patient"], timeout: .seconds(2)) }
        await #expect(throws: DeviceMCPError.notSent("the app is busy with tools/call")) { try await impatient.value }
        #expect(try await slow.value["echo"] == "slow")
        #expect(try await patient.value["echo"] == "patient")
        #expect(!sent.withLock { $0 })
        let calls = device.frames.withLock { $0.filter { $0["method"] == "tools/call" }.map { $0["params"]?["name"] } }
        #expect(calls == ["slow", "patient"])
        // The line is free again.
        #expect(try await client.request("tools/list", timeout: .seconds(1)) == ["echo": .null])
    }

    @Test("onSent runs once the request's frame is sent, not while it waits in the queue")
    func onSentAfterSend() async throws {
        let release = Mutex(false)
        let (client, device) = connect { _, params in
            if params["name"] == "slow" { while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) } }
            return [:]
        }
        let slow = Task { try await client.request("tools/call", params: ["name": "slow"], timeout: .seconds(5)) }
        while !device.methods.contains("tools/call") { try await Task.sleep(for: .milliseconds(5)) }
        let sentAt = Mutex<Int?>(nil)
        let queued = Task {
            try await client.request("tools/call", params: ["name": "queued"], timeout: .seconds(5), onSent: {
                sentAt.withLock { $0 = device.frames.withLock { $0.count } }
            })
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(sentAt.withLock { $0 } == nil)
        release.withLock { $0 = true }
        _ = try await slow.value
        _ = try await queued.value
        // initialize, initialized, slow, queued: called with its frame already out.
        #expect(sentAt.withLock { $0 } == 4)
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
