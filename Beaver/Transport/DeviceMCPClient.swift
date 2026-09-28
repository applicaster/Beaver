//
//  DeviceMCPClient.swift
//  Beaver
//
//  D75: JSON-RPC to one connected app's MCP server over the same WebSocket
//  as its logs (PROTOCOL.md §3.3, §4.5). One per connection; the envelope
//  is {"type":"mcp","payload":…} and replies are matched by JSON-RPC id.
//  The SDKs handle one MCP message at a time, so requests queue here (FIFO)
//  and each is sent only after the previous one finished; its timeout
//  counts from its own send.

import Foundation

public enum DeviceMCPError: Error, Sendable, Equatable {
    /// The app never answered `initialize` and never sent a handshake: it
    /// has no toolboxes (the JS-only socket sink, an older SDK). Stays so
    /// until it reconnects or sends a handshake.
    case unsupported
    /// No answer in time. The device may still have run the call.
    case timeout
    /// The connection closed, or was already gone.
    case disconnected
    /// The app's JSON-RPC error reply.
    case rpc(code: Int, message: String)
}

public actor DeviceMCPClient {
    public static let listTimeout: Duration = .seconds(5)
    /// The device gives up on a React tool after 15 s; this leaves it room to say so.
    public static let callTimeout: Duration = .seconds(20)

    private enum Setup { case idle, ready, unsupported }

    private let sendFrame: @Sendable (Data) async -> Void
    private let setupTimeout: Duration
    private var setup: Setup = .idle
    private var nextId = 1
    private var waiters: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var closed = false
    private var native = false
    /// A request holds the line from before `initialize` until its reply.
    private var busy = false
    private var queue: [CheckedContinuation<Void, Error>] = []

    public init(setupTimeout: Duration = .seconds(5), send: @escaping @Sendable (Data) async -> Void) {
        self.setupTimeout = setupTimeout
        self.sendFrame = send
    }

    /// Waits for the requests before it, then initializes the session
    /// first, once per connection.
    public func request(_ method: String, params: JSON = [:], timeout: Duration) async throws -> JSON {
        guard !closed else { throw DeviceMCPError.disconnected }
        try await takeTurn()
        defer { endTurn() }
        try await ensureInitialized()
        return try await call(method, params: params, timeout: timeout)
    }

    /// A JSON-RPC response from the app. Unknown ids (a reply after its
    /// timeout) are ignored, as are requests from the app itself (they carry
    /// their own `method`, possibly reusing one of our ids).
    public func receive(_ message: JSON) {
        guard message["method"] == nil,
              let id = message["id"]?.int, let waiter = waiters.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            waiter.resume(throwing: DeviceMCPError.rpc(code: error["code"]?.int ?? 0,
                                                       message: error["message"]?.string ?? "error"))
        } else {
            waiter.resume(returning: message["result"] ?? .null)
        }
    }

    /// The app sent a client `handshake`: a native sink, which has an MCP
    /// server. A missed `initialize` is then retried, never latched.
    public func markNative() {
        native = true
        if case .unsupported = setup { setup = .idle }
    }

    /// The connection closed: every waiting and queued call fails with `.disconnected`.
    public func close() {
        closed = true
        let pending = waiters
        waiters = [:]
        for waiter in pending.values { waiter.resume(throwing: DeviceMCPError.disconnected) }
        let queued = queue
        queue = []
        for turn in queued { turn.resume(throwing: DeviceMCPError.disconnected) }
    }

    private func takeTurn() async throws {
        guard busy else { busy = true; return }
        // `endTurn` hands the line over: `busy` stays true.
        try await withCheckedThrowingContinuation { queue.append($0) }
    }

    private func endTurn() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    private func ensureInitialized() async throws {
        switch setup {
        case .ready: return
        case .unsupported: throw DeviceMCPError.unsupported
        case .idle: break
        }
        do {
            try await initialize()
            setup = .ready
        } catch DeviceMCPError.timeout where !native {
            // Silence from a sink that never sent a handshake: the JS-only
            // sink has no MCP server, so don't ask again.
            setup = .unsupported
            throw DeviceMCPError.unsupported
        } catch {
            setup = .idle
            throw error
        }
    }

    private func initialize() async throws {
        _ = try await call("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Beaver", "version": "1"],
        ], timeout: setupTimeout)
        await sendFrame(Self.frame(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    private func call(_ method: String, params: JSON, timeout: Duration) async throws -> JSON {
        guard !closed else { throw DeviceMCPError.disconnected }
        let id = nextId
        nextId += 1
        let frame = Self.frame(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.fail(id, .timeout)
        }
        defer { timer.cancel() }
        let send = sendFrame
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            Task { await send(frame) }
        }
    }

    private func fail(_ id: Int, _ error: DeviceMCPError) {
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private static func frame(_ payload: JSON) -> Data {
        let envelope: JSON = ["type": "mcp", "payload": payload]
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }
}
