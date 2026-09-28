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
        /// `count` devices are connected (D73).
        case clientConnected(count: Int)
        case clientDisconnected(reason: String)
        case failed(reason: String)
    }

    /// A client's frames, bracketed by its connect and disconnect, in
    /// order. One stream so the consumer opens the session before it
    /// sees the first frame and ends it after the last one — `state`
    /// is a separate stream and gives no ordering against frames.
    /// Every item says which connection it came from (D73).
    public enum Inbound: Sendable, Equatable {
        case connected(UUID)
        case frame(UUID, Data)
        case disconnected(UUID)
    }

    public nonisolated let inbound: AsyncStream<Inbound>
    public nonisolated let state: AsyncStream<State>

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    /// Connections past the handshake; `State.clientConnected` counts these.
    private var ready = Set<UUID>()

    /// Pending re-bind after the listener failed. `nil` when the server
    /// is either healthy or deliberately stopped.
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    private nonisolated let inboundContinuation: AsyncStream<Inbound>.Continuation
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

        var inboundCont: AsyncStream<Inbound>.Continuation!
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
        // half-open connections within ~20 seconds. Default OS
        // keepalive idle is ~2 hours, which means a killed client
        // would leave us showing "Connected" until next reboot. With
        // several devices (D73) a device that reconnects over a dead
        // socket shows twice until the old one is detected, so keep
        // the budget short.
        //
        // Detection budget = keepaliveIdle + (keepaliveInterval *
        // keepaliveCount) = 10 + (5 * 2) = 20 seconds.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 2
        }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }

        listener.stateUpdateHandler = { [weak self, weak listener] nwState in
            guard let listener else { return }
            Task { await self?.handleListenerState(nwState, from: listener) }
        }

        listener.start(queue: networkQueue)
    }

    public func stop() async {
        // Cancel first: a pending retry would otherwise resurrect the
        // listener moments after the user asked for it to stop.
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        for connection in connections.values { connection.cancel() }
        connections = [:]
        ready = []
        listener?.cancel()
        listener = nil
        stateContinuation.yield(.stopped)
    }

    // MARK: - Connection handling

    private func handleListenerState(_ nwState: NWListener.State, from source: NWListener) {
        // Each callback hops in on its own Task, so it can arrive after
        // `stop()` or after a rebind replaced its listener. Acting on it
        // then would schedule a retry nobody wants (a zombie listener
        // after stop) or report `.listening` for a listener that's gone.
        guard source === listener else { return }
        switch nwState {
        case .ready:
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
            stateContinuation.yield(.listening)
        case .failed(let error):
            scheduleRebind(reason: Self.describe(error))
        case .cancelled:
            stateContinuation.yield(.stopped)
        default:
            break
        }
    }

    // MARK: - Recovering a lost listener

    /// A failed `NWListener` never recovers on its own, and the most
    /// common cause is another Beaver already holding the port — which
    /// clears the moment that process quits. Without this the app sits
    /// there alive and silently deaf until someone restarts it.
    private func scheduleRebind(reason: String) {
        // Detach before cancelling: the dead listener's `.cancelled`
        // callback would otherwise overwrite the message below with
        // a plain "stopped".
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        // A listener can report `.failed` more than once; one pending
        // retry is enough.
        guard retryTask == nil else { return }

        retryAttempt += 1
        let delay = Self.rebindDelay(attempt: retryAttempt)
        let seconds = Int(delay.components.seconds)
        stateContinuation.yield(
            .failed(reason: "\(reason) — retrying in \(seconds)s")
        )

        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.rebind()
        }
    }

    private func rebind() async {
        // `stop()` can land between the retry's cancellation check and
        // this hop onto the actor; checked here, it can't race.
        guard !Task.isCancelled else { return }
        retryTask = nil
        do {
            try await start()
        } catch {
            scheduleRebind(reason: Self.describe(error))
        }
    }

    /// 1, 2, 4, 8 then every 15 seconds. A stale socket clears in
    /// seconds; a second copy of the app may run for hours, and polling
    /// it every second for that long is pointless.
    private static func rebindDelay(attempt: Int) -> Duration {
        .seconds(min(15, 1 << min(max(attempt - 1, 0), 4)))
    }

    /// `POSIXErrorCode.EADDRINUSE` reads as "Address already in use",
    /// which doesn't tell a user what to do about it.
    private static func describe(_ error: Error) -> String {
        if case .posix(let code)? = error as? NWError, code == .EADDRINUSE {
            return "Port in use — another Beaver is probably running"
        }
        return error.localizedDescription
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        print("[WSServer] new connection \(id) (endpoint=\(connection.endpoint))")
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnectionState(state, id: id) }
        }
        connection.start(queue: networkQueue)
    }

    private func handleConnectionState(_ state: NWConnection.State, id: UUID) async {
        // A connection that already failed can still report `.cancelled`.
        guard let connection = connections[id] else { return }
        print("[WSServer] connection \(id): \(state)")
        switch state {
        case .ready:
            if let payload = try? ProtocolEncoder.encodeHandshake(id: UUID()) {
                send(payload, on: connection)
            }
            ready.insert(id)
            stateContinuation.yield(.clientConnected(count: ready.count))
            inboundContinuation.yield(.connected(id))
            // Read only after `.connected` is out: a frame the client
            // sends at once would otherwise be yielded first.
            receive(on: connection, id: id)
        case .failed(let error):
            // A failed connection holds its resources — and this handler,
            // which holds it — until cancelled.
            connection.cancel()
            drop(id, reason: error.localizedDescription)
        case .cancelled:
            drop(id, reason: "cancelled")
        case .waiting(let error):
            stateContinuation.yield(.failed(reason: "waiting: \(error.localizedDescription)"))
        case .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    private func drop(_ id: UUID, reason: String) {
        connections[id] = nil
        guard ready.remove(id) != nil else { return }
        stateContinuation.yield(ready.isEmpty
            ? .clientDisconnected(reason: reason)
            : .clientConnected(count: ready.count))
        inboundContinuation.yield(.disconnected(id))
    }

    /// Yields straight from the callback: a `Task` per frame gives no
    /// ordering guarantee, and an older storage snapshot overtaking a
    /// newer one would win as "latest".
    ///
    /// Control frames (ping, pong, close) are delivered here too, even
    /// with `autoReplyPing` answering the ping. They carry no protocol
    /// frame, so only data messages go on to the decoder (PROTOCOL.md §1).
    private nonisolated func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode
            if let data, !data.isEmpty, opcode == .text || opcode == .binary {
                self.inboundContinuation.yield(.frame(id, data))
            }
            if error == nil {
                self.receive(on: connection, id: id)
            }
        }
    }

    /// Closes one client (the Disconnect button, `devices_disconnect`).
    /// Its session ends through the usual `.cancelled` path. An SDK that
    /// reconnects on its own comes back as a new connection.
    public func disconnect(_ connection: UUID) {
        connections[connection]?.cancel()
    }

    // MARK: - Outbound

    /// Send a command frame to one client. No-op when that connection is gone.
    public func send(command: String, to connection: UUID) {
        guard let target = connections[connection],
              let payload = try? ProtocolEncoder.encodeCommand(command) else { return }
        send(payload, on: target)
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
