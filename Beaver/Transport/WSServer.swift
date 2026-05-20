//
//  WSServer.swift
//  Beaver
//

import Foundation
import Network

/// WebSocket listener for the mobile SDK. Accepts a single client at a
/// time (D2). All inbound text frames are published as raw `Data` on
/// `inbound`; consumers feed them to `ProtocolDecoder`.
///
/// Contract documented in `PROTOCOL.md`.
public actor WSServer {

    /// Connection-level state surfaced to the UI.
    public enum State: Sendable {
        case stopped
        case listening
        case clientConnected
        case clientDisconnected(reason: String)
        case failed(reason: String)
    }

    public nonisolated let inbound: AsyncStream<Data>
    public nonisolated let state: AsyncStream<State>

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var current: NWConnection?

    private nonisolated let inboundContinuation: AsyncStream<Data>.Continuation
    private nonisolated let stateContinuation: AsyncStream<State>.Continuation

    /// The dispatch queue used by `Network.framework` callbacks. Hops
    /// into the actor's executor explicitly via `Task { await … }`.
    // Queue label mirrors the bundle ID (kept as
    // `com.applicaster.LoggerNext`, see D38) for consistency with
    // Console.app traces and the Activity Monitor's grouping.
    private let networkQueue = DispatchQueue(label: "com.applicaster.LoggerNext.WSServer")

    // MARK: - Init

    public init(port: UInt16 = 9080) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            preconditionFailure("Invalid port: \(port)")
        }
        self.port = nwPort

        var inboundCont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { inboundCont = $0 }
        self.inboundContinuation = inboundCont

        var stateCont: AsyncStream<State>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont
    }

    // MARK: - Lifecycle

    public func start() async throws {
        let parameters = NWParameters(tls: nil)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        // PROTOCOL.md §1: accept both IPv4 and IPv6.

        // Enable TCP keepalive with aggressive timing so we detect
        // half-open connections within ~60 seconds. Default OS
        // keepalive idle is ~2 hours, which means a killed client
        // would leave us showing "Connected" until next reboot.
        //
        // Detection budget = keepaliveIdle + (keepaliveInterval *
        // keepaliveCount) = 30 + (10 * 3) = 60 seconds.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 3
        }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }

        listener.stateUpdateHandler = { [weak self] nwState in
            Task { await self?.handleListenerState(nwState) }
        }

        listener.start(queue: networkQueue)
    }

    public func stop() async {
        current?.cancel()
        current = nil
        listener?.cancel()
        listener = nil
        stateContinuation.yield(.stopped)
    }

    // MARK: - Connection handling

    private func handleListenerState(_ nwState: NWListener.State) {
        switch nwState {
        case .ready:
            stateContinuation.yield(.listening)
        case .failed(let error):
            stateContinuation.yield(.failed(reason: error.localizedDescription))
        case .cancelled:
            stateContinuation.yield(.stopped)
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        print("[WSServer] new connection arriving (endpoint=\(connection.endpoint))")
        if let old = current {
            // Take-over policy: assume the previous connection is
            // dead (TCP keepalive may not have proven it yet) and
            // accept the new one. The single-client invariant is
            // preserved — we just always pick "newest wins" rather
            // than rejecting. Rationale: in our debug-tool use case
            // a second incoming client almost always means the same
            // device reconnected, not a competing real client.
            print("[WSServer] replacing existing connection with the new one")
            old.cancel()
        }
        current = connection
        connection.stateUpdateHandler = { [weak self] state in
            print("[WSServer] connection state changed: \(state)")
            Task { await self?.handleConnectionState(state, connection: connection) }
        }
        connection.start(queue: networkQueue)
        receive(on: connection)
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection: NWConnection
    ) async {
        // Guard against stale state callbacks from a connection that
        // was already replaced by a newer one. Without this, the old
        // connection's `.cancelled` event (from `old.cancel()` in
        // handleNewConnection) would race in and clear `current`,
        // wiping out the new connection's reference.
        guard connection === current else {
            print("[WSServer] ignoring stale state update from replaced connection: \(state)")
            return
        }
        print("[WSServer] handleConnectionState: \(state)")
        switch state {
        case .ready:
            print("[WSServer] -> client ready, sending handshake")
            let id = UUID()
            if let payload = try? ProtocolEncoder.encodeHandshake(id: id) {
                send(payload, on: connection)
            }
            stateContinuation.yield(.clientConnected)
        case .failed(let error):
            print("[WSServer] -> client failed: \(error)")
            current = nil
            stateContinuation.yield(.clientDisconnected(reason: error.localizedDescription))
        case .cancelled:
            print("[WSServer] -> client cancelled")
            current = nil
            stateContinuation.yield(.clientDisconnected(reason: "cancelled"))
        case .waiting(let error):
            print("[WSServer] -> client waiting: \(error)")
            stateContinuation.yield(.failed(reason: "waiting: \(error.localizedDescription)"))
        case .preparing:
            print("[WSServer] -> client preparing")
        case .setup:
            print("[WSServer] -> client setup")
        @unknown default:
            print("[WSServer] -> client unknown state")
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { await self.forward(data: data) }
            }
            if error == nil {
                // Continue reading.
                Task { await self.receive(on: connection) }
            }
        }
    }

    private func forward(data: Data) {
        inboundContinuation.yield(data)
    }

    // MARK: - Outbound

    /// Send a command frame to the connected client. No-op if no client.
    public func send(command: String) {
        guard let current else { return }
        guard let payload = try? ProtocolEncoder.encodeCommand(command) else { return }
        send(payload, on: current)
    }

    private nonisolated func send(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed({ _ in })
        )
    }
}
