//
//  DeviceMCPClient.swift
//  Beaver
//
//  D75: JSON-RPC to one connected app's MCP server over the same WebSocket
//  as its logs (PROTOCOL.md §3.3, §4.5). One per connection; the envelope
//  is {"type":"mcp","payload":…} and replies are matched by JSON-RPC id.
//  The SDKs handle one MCP message at a time, so requests queue here (FIFO)
//  and each is sent only after the previous one finished; its timeout
//  counts from its own send. It waits in the queue for at most that timeout
//  too, then fails with `.notSent` without ever being sent.

import Foundation

public enum DeviceMCPError: Error, Sendable, Equatable {
    /// The app never answered `initialize` and never sent a handshake: it
    /// has no toolboxes (the JS-only socket sink, an older SDK). Stays so
    /// until it reconnects or sends a handshake.
    case unsupported
    /// No answer in time. The device may still have run the call.
    case timeout
    /// The connection closed after the request was sent.
    case disconnected
    /// The request's frame was never sent to the app; the string says why.
    case notSent(String)
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
    /// The method of the request holding the line, from before
    /// `initialize` until its reply; nil when the line is free.
    private var holder: String?
    private struct Waiter {
        let ticket: Int
        let method: String
        let turn: CheckedContinuation<Void, Error>
    }
    private var queue: [Waiter] = []
    private var nextTicket = 0

    public init(setupTimeout: Duration = .seconds(5), send: @escaping @Sendable (Data) async -> Void) {
        self.setupTimeout = setupTimeout
        self.sendFrame = send
    }

    /// Waits for the requests before it (at most `timeout`), then
    /// initializes the session first, once per connection. `onSent` runs
    /// once the request's frame is handed to the socket, before this returns.
    public func request(_ method: String, params: JSON = [:], timeout: Duration,
                        onSent: (@Sendable () async -> Void)? = nil) async throws -> JSON {
        guard !closed else { throw DeviceMCPError.notSent(Self.droppedBeforeSend) }
        try await takeTurn(method, timeout: timeout)
        defer { endTurn() }
        try await ensureInitialized()
        return try await call(method, params: params, timeout: timeout, onSent: onSent)
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

    /// The app sent `register` (D89): it never answers MCP, so don't wait
    /// out an `initialize` to find that out.
    public func markLogsOnly() {
        if !native { setup = .unsupported }
    }

    /// The connection closed: a call already sent fails with `.disconnected`,
    /// one still queued with `.notSent`.
    public func close() {
        closed = true
        let pending = waiters
        waiters = [:]
        for waiter in pending.values { waiter.resume(throwing: DeviceMCPError.disconnected) }
        let queued = queue
        queue = []
        for waiter in queued { waiter.turn.resume(throwing: DeviceMCPError.notSent(Self.droppedBeforeSend)) }
    }

    static let droppedBeforeSend = "the app disconnected before Beaver sent it"

    private func takeTurn(_ method: String, timeout: Duration) async throws {
        guard holder != nil else { holder = method; return }
        let ticket = nextTicket
        nextTicket += 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.giveUp(ticket)
        }
        defer { timer.cancel() }
        // `endTurn` hands the line over: `holder` becomes this method.
        try await withCheckedThrowingContinuation { queue.append(Waiter(ticket: ticket, method: method, turn: $0)) }
    }

    /// Every resume removes its waiter first, so each is resumed once:
    /// a waiter that got its turn (or was closed) is no longer here.
    private func giveUp(_ ticket: Int) {
        guard let index = queue.firstIndex(where: { $0.ticket == ticket }) else { return }
        queue.remove(at: index).turn.resume(throwing: DeviceMCPError.notSent("the app is busy with \(holder ?? "another request")"))
    }

    private func endTurn() {
        guard !queue.isEmpty else { holder = nil; return }
        let next = queue.removeFirst()
        holder = next.method
        next.turn.resume()
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
            // The request itself was never sent. Back to idle: the next one retries.
            setup = .idle
            switch error {
            case DeviceMCPError.timeout:
                throw DeviceMCPError.notSent("the app didn't answer initialize in time")
            case DeviceMCPError.rpc(_, let message):
                throw DeviceMCPError.notSent("the app refused initialize: \(message)")
            case DeviceMCPError.disconnected:
                throw DeviceMCPError.notSent(Self.droppedBeforeSend)
            default:
                throw error
            }
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

    private func call(_ method: String, params: JSON, timeout: Duration,
                      onSent: (@Sendable () async -> Void)? = nil) async throws -> JSON {
        // Closed while this request waited for its turn.
        guard !closed else { throw DeviceMCPError.notSent(Self.droppedBeforeSend) }
        let id = nextId
        nextId += 1
        let frame = Self.frame(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.fail(id, .timeout)
        }
        defer { timer.cancel() }
        let send = sendFrame
        var sending: Task<Void, Never>?
        // `onSent` finishes before the reply is returned or thrown, so the
        // caller never sees an answer before what it started on send.
        do {
            let reply = try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                sending = Task { await send(frame); await onSent?() }
            }
            await sending?.value
            return reply
        } catch {
            await sending?.value
            throw error
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
