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

    /// A client's frames, bracketed by its connect and disconnect, in
    /// order. One stream so the consumer opens the session before it
    /// sees the first frame and ends it after the last one — `state`
    /// is a separate stream and gives no ordering against frames.
    public enum Inbound: Sendable, Equatable {
        case connected
        case frame(Data)
        case disconnected
    }

    public nonisolated let inbound: AsyncStream<Inbound>
    public nonisolated let state: AsyncStream<State>

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var current: NWConnection?

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
        current?.cancel()
        current = nil
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
            // Read only after `.connected` is out: a frame the client
            // sends at once would otherwise be yielded first.
            inboundContinuation.yield(.connected)
            receive(on: connection)
        case .failed(let error):
            print("[WSServer] -> client failed: \(error)")
            // A failed connection holds its resources — and this handler,
            // which holds it — until cancelled.
            connection.cancel()
            current = nil
            stateContinuation.yield(.clientDisconnected(reason: error.localizedDescription))
            inboundContinuation.yield(.disconnected)
        case .cancelled:
            print("[WSServer] -> client cancelled")
            current = nil
            stateContinuation.yield(.clientDisconnected(reason: "cancelled"))
            inboundContinuation.yield(.disconnected)
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

    /// Yields straight from the callback: a `Task` per frame gives no
    /// ordering guarantee, and an older storage snapshot overtaking a
    /// newer one would win as "latest".
    private nonisolated func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inboundContinuation.yield(.frame(data))
            }
            if error == nil {
                // Continue reading.
                self.receive(on: connection)
            }
        }
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
