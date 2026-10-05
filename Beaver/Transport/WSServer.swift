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
    /// Ready connections that have not sent a thing yet, not even a ping.
    private var silent = Set<UUID>()
    private let silenceTimeout: Duration

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

    /// - Parameter silenceTimeout: how long a connection may stay mute after
    ///   the handshake before it is closed. The SDK sends its own handshake
    ///   at once, so a socket mute for this long is a zombie (see `closeIfSilent`).
    public init(port: UInt16 = 9080, silenceTimeout: Duration = .seconds(15)) {
        self.silenceTimeout = silenceTimeout
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
            silent.insert(id)
            Task { [silenceTimeout] in
                try? await Task.sleep(for: silenceTimeout)
                self.closeIfSilent(id)
            }
            stateContinuation.yield(.clientConnected(count: ready.count))
            inboundContinuation.yield(.connected(id))
            // Read only after `.connected` is out: a frame the client
            // sends at once would otherwise be yielded first.
            receive(on: connection, id: id, heard: false)
        case .failed(let error):
            // Once reading, `receive` still gets the frames buffered before
            // the failure, then cancels and ends the session after the last
            // one. Cancelling here would discard them.
            if ready.contains(id) { break }
            // A failed connection holds its resources — and this handler,
            // which holds it — until cancelled.
            connection.cancel()
            drop(id, reason: error.localizedDescription)
        case .cancelled:
            if !ready.contains(id) { drop(id, reason: "cancelled") }
        case .waiting(let error):
            stateContinuation.yield(.failed(reason: "waiting: \(error.localizedDescription)"))
        case .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    private func heard(_ id: UUID) { silent.remove(id) }

    /// An iPhone whose sink loses its ping/pong opens a fresh socket every
    /// ~30 s and never closes the old one; each passes TCP keepalive and
    /// would stay a live session for good. Closing ends it through
    /// `receive`, like `disconnect`.
    private func closeIfSilent(_ id: UUID) {
        guard silent.remove(id) != nil else { return }
        print("[WSServer] connection \(id) sent nothing in \(silenceTimeout), closing")
        connections[id]?.cancel()
    }

    private func drop(_ id: UUID, reason: String) {
        connections[id] = nil
        silent.remove(id)
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
    ///
    /// This loop ends the session: the end of the peer's stream (a FIN,
    /// with or without a close frame) reaches only this callback, and the
    /// connection stays `.ready`. The error for the peer's close can come
    /// with a frame while later ones are still buffered, so reading goes on
    /// until a callback brings no data — the SDK flushes its buffer right
    /// after connecting, and stopping early lost those logs. `.disconnected`
    /// is yielded after the last frame, never before it.
    private nonisolated func receive(on connection: NWConnection, id: UUID, heard: Bool) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if !heard { Task { await self.heard(id) } }
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode
            if let data, !data.isEmpty, opcode == .text || opcode == .binary {
                self.inboundContinuation.yield(.frame(id, data))
            }
            if context?.isFinal != true, error == nil || data?.isEmpty == false {
                self.receive(on: connection, id: id, heard: true)
            } else {
                connection.cancel()
                Task { await self.drop(id, reason: error?.localizedDescription ?? "closed") }
            }
        }
    }

    /// Closes one client (the Disconnect button, `devices_disconnect`) with
    /// close code 4000 (D98, PROTOCOL.md §3.4): an SDK that reads it stops
    /// reconnecting until the app returns to the foreground or relaunches.
    /// Beaver's other closes never use 4000, so those apps come back. The
    /// client answers the close and `receive` ends the session; one that
    /// doesn't answer is cancelled after a second.
    public func disconnect(_ connection: UUID) {
        guard let target = connections[connection] else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(4000)
        let context = NWConnection.ContentContext(identifier: "disconnect", metadata: [metadata])
        target.send(content: Data("disconnected by Beaver".utf8), contentContext: context,
                    isComplete: true, completion: .contentProcessed({ _ in }))
        networkQueue.asyncAfter(deadline: .now() + 1) { target.cancel() }
    }

    // MARK: - Outbound

    /// Send a command frame to one client. No-op when that connection is gone.
    public func send(command: String, to connection: UUID) {
        guard let target = connections[connection],
              let payload = try? ProtocolEncoder.encodeCommand(command) else { return }
        send(payload, on: target)
    }

    /// Send a ready-made frame (an `mcp` request, D75) to one client.
    /// No-op when that connection is gone.
    public func send(data: Data, to connection: UUID) {
        guard let target = connections[connection] else { return }
        send(data, on: target)
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
