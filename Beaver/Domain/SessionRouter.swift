//
//  SessionRouter.swift
//  Beaver
//

import Foundation

/// What `SessionRouter` needs from the app (`AppEnvironment`).
@MainActor
public protocol SessionRouterHost: AnyObject {
    var live: LiveDevices { get set }
    var viewingSessionId: Int64? { get set }
    /// The device agents' tools use without a deviceId (D76).
    var defaultDevice: DefaultDevice? { get set }
    /// A connection's first frame went to `session` (D73).
    func didSpeak(session: Int64)
    /// Closes a connection whose session another one took over (D97).
    func closeConnection(_ connection: UUID) async
}

/// Which session each WebSocket connection writes: its own from connect,
/// another one for a reconnect of the same app launch (D97), ended at
/// disconnect. BeaverApp's inbound loop calls it for every item, in order.
@MainActor
public final class SessionRouter {
    private let store: LogStore
    private let host: any SessionRouterHost
    /// Connections that sent a frame.
    private var spoke: Set<UUID> = []

    public init(store: LogStore, host: any SessionRouterHost) {
        self.store = store
        self.host = host
    }

    /// The connection gets a session before its first frame.
    public func connected(_ connection: UUID) async {
        guard let session = try? await store.createSession(source: .live) else { return }
        _ = host.live.connect(connection, session: session.id, viewing: host.viewingSessionId)
    }

    /// The session `frame` goes to. Nil while the connection's deleted live
    /// session is being replaced (D75), and once its session was taken over.
    /// The window hears of a first frame only once its session is chosen, so
    /// a reconnect of the viewed device leaves the view as it is.
    public func route(_ frame: Data, from connection: UUID) async -> Int64? {
        let first = spoke.insert(connection).inserted
        guard var session = host.live.session(for: connection) else { return nil }
        if first {
            if case .success(.clientHandshake(let handshake)) = ProtocolDecoder.decode(frame),
               let continued = await continueLaunch(connection, fresh: session, handshake: handshake) {
                session = continued
            }
            if host.viewingSessionId != session { host.didSpeak(session: session) }
        }
        return session
    }

    /// Ends the connection's session; one that never sent a frame is deleted.
    /// A connection whose session was taken over has none left to end. A
    /// `.session` default ends with its session: an app without a handshake
    /// reconnects in a new one (D76).
    public func disconnected(_ connection: UUID) async {
        let spoke = spoke.remove(connection) != nil
        guard let session = host.live.disconnect(connection) else { return }
        if host.defaultDevice == .session(session) { host.defaultDevice = nil }
        try? await store.endSession(session, receivedFrames: spoke)
    }

    /// D97: a handshake from an app launch that already has a session carries
    /// on in it: one still live on another connection (its socket dropped and
    /// the old one hasn't noticed: that connection is closed), else the latest
    /// ended one, reopened. The launch id alone matches; `register` clients
    /// (D89) never do. The empty session this connection opened is deleted
    /// after the connection moved, so it isn't a deleted live session to
    /// replace (D75). Only for the connection's first frame: nothing was
    /// written to the new session yet. Returns the session to write to, nil
    /// to stay in the new one.
    private func continueLaunch(_ connection: UUID, fresh: Int64, handshake: ClientHandshake) async -> Int64? {
        guard let launchId = handshake.launchId, !handshake.logsOnly else { return nil }
        let target: Int64
        if let holder = host.live.connection(launchId: launchId, other: connection),
           let held = host.live.session(for: holder) {
            target = held
        } else if let ended = try? await store.reopenSession(launchId: launchId, replacing: fresh),
                  // ponytail: a Delete all during the await moved the connection; the
                  // reopened row stays open until the next launch's sweep (D87).
                  host.live.session(for: connection) == fresh {
            target = ended
        } else {
            return nil
        }
        if let holder = host.live.rebind(connection, to: target) { await host.closeConnection(holder) }
        if host.viewingSessionId == fresh { host.viewingSessionId = target }
        try? await store.deleteSession(id: fresh)
        await store.append(
            .syntheticInfo(subsystem: "loggernext.session",
                           message: "Reconnected: same app launch. Logs sent while it was disconnected are lost."),
            to: target
        )
        return target
    }

    /// A deleted live session (e.g., right after the user deleted every
    /// session) leaves its device with nowhere to write: give each such
    /// connection a fresh live session. Without this, events from the device
    /// would be silently dropped until it reconnected.
    ///
    /// Detaches first, before any await, so frames stop going to the deleted
    /// rows at once. The window follows the device it showed; with none, it
    /// shows the first fresh session. A device that leaves meanwhile gets its
    /// fresh session dropped. Returns the fresh sessions of SDK clients that
    /// sent a handshake, to ask what their app was built with (D85).
    public func replaceDeleted(viewed: Int64?, where deleted: (Int64) -> Bool) async -> [Int64] {
        let viewedConnection = viewed.flatMap { host.live.connection(for: $0) }
        var identified: [Int64] = []
        for connection in host.live.detach(where: deleted) {
            guard let fresh = try? await store.createSession(source: .live) else { continue }
            guard host.live.attach(connection, session: fresh.id) else {
                try? await store.endSession(fresh.id, receivedFrames: false)
                continue
            }
            if let handshake = host.live.handshake(for: connection) {
                try? await store.applyHandshake(handshake, to: fresh.id)
                if !handshake.logsOnly { identified.append(fresh.id) }
            }
            if connection == viewedConnection || (viewedConnection == nil && host.viewingSessionId == nil) {
                host.viewingSessionId = fresh.id
            }
        }
        return identified
    }
}

// MARK: - Synthetic-event helpers

extension DecodedEvent {
    static func syntheticInfo(subsystem: String, message: String) -> DecodedEvent {
        DecodedEvent(
            timestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
            level: .info,
            subsystem: subsystem,
            category: "loggernext",
            message: message,
            dataJSON: nil,
            contextJSON: nil
        )
    }

    static func syntheticWarning(subsystem: String, message: String) -> DecodedEvent {
        DecodedEvent(
            timestampMillis: UInt64(Date().timeIntervalSince1970 * 1000),
            level: .warning,
            subsystem: subsystem,
            category: "loggernext",
            message: message,
            dataJSON: nil,
            contextJSON: nil
        )
    }
}
