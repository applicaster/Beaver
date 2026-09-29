//
//  LiveDevices.swift
//  Beaver
//

import Foundation

/// Which WebSocket connection writes to which live session, and what each
/// live app answered to `cmdlist` (D73). A device is known by its live
/// session id everywhere else: the toolbar menu, the command bar, MCP's
/// `deviceId`.
public struct LiveDevices: Sendable, Equatable {
    public private(set) var sessions: [UUID: Int64] = [:]
    public private(set) var commands: [Int64: [CommandHint]] = [:]
    /// Connections whose live session was deleted, waiting for a fresh one.
    public private(set) var waiting: Set<UUID> = []
    /// Each connection's client handshake (D77). The SDK sends it once per
    /// connection, so a replacement session (the live one was deleted)
    /// gets it from here.
    public private(set) var handshakes: [UUID: ClientHandshake] = [:]
    /// Sessions whose `cmdlist` Beaver sent itself (on connect, the help
    /// popover's refresh). Its reply feeds the popover, not the Log feed.
    private var quietCmdlists: Set<Int64> = []

    public init() {}

    /// Oldest first.
    public var sessionIds: [Int64] { sessions.values.sorted() }

    public func isLive(_ sessionId: Int64?) -> Bool {
        sessionId.map { sessions.values.contains($0) } ?? false
    }

    public func connection(for sessionId: Int64) -> UUID? {
        sessions.first { $0.value == sessionId }?.key
    }

    public func session(for connection: UUID) -> Int64? { sessions[connection] }

    /// Records a new device. Returns whether the window should switch to
    /// it: only when the user isn't already looking at a live device.
    public mutating func connect(_ connection: UUID, session: Int64, viewing: Int64?) -> Bool {
        let takesWindow = !isLive(viewing)
        sessions[connection] = session
        return takesWindow
    }

    @discardableResult
    public mutating func disconnect(_ connection: UUID) -> Int64? {
        handshakes[connection] = nil
        waiting.remove(connection)
        guard let sessionId = sessions.removeValue(forKey: connection) else { return nil }
        commands[sessionId] = nil
        quietCmdlists.remove(sessionId)
        return sessionId
    }

    /// Live sessions were deleted: stop writing to them at once (their
    /// frames are dropped until `attach`). Returns their connections.
    public mutating func detach(where deleted: (Int64) -> Bool) -> [UUID] {
        let gone = sessions.filter { deleted($0.value) }.map(\.key)
        for connection in gone {
            if let sessionId = sessions.removeValue(forKey: connection) {
                commands[sessionId] = nil
                quietCmdlists.remove(sessionId)
            }
            waiting.insert(connection)
        }
        return gone
    }

    /// Gives a detached connection its fresh session. False when the
    /// device disconnected meanwhile: that session should be ended.
    public mutating func attach(_ connection: UUID, session: Int64) -> Bool {
        guard waiting.remove(connection) != nil else { return false }
        sessions[connection] = session
        return true
    }

    public mutating func setCommands(_ hints: [CommandHint], for sessionId: Int64) {
        commands[sessionId] = hints
    }

    public mutating func expectQuietCmdlist(for sessionId: Int64) {
        quietCmdlists.insert(sessionId)
    }

    /// Stores a `cmdlist` reply. True when Beaver asked for it itself,
    /// so the reply stays out of the Log feed.
    public mutating func receiveCmdlist(_ hints: [CommandHint], for sessionId: Int64) -> Bool {
        commands[sessionId] = hints
        return quietCmdlists.remove(sessionId) != nil
    }

    public mutating func setHandshake(_ handshake: ClientHandshake, for connection: UUID) {
        handshakes[connection] = handshake
    }

    public func handshake(for connection: UUID) -> ClientHandshake? { handshakes[connection] }

    /// Live sessions of `register` clients (D89): they take no commands,
    /// storage requests or MCP, so Beaver sends them none.
    public var logsOnlySessions: Set<Int64> {
        Set(sessions.compactMap { handshakes[$0.key]?.logsOnly == true ? $0.value : nil })
    }
}

/// The toolbar device menu (D73).
public enum DeviceMenu {
    /// Connected devices, then the most recent other live sessions.
    /// `sessions` is newest first, as `LogStore.sessions()` returns it.
    public static func sections(sessions: [Session], live: [Int64],
                                recent limit: Int = 5) -> (connected: [Session], recent: [Session]) {
        let connected = sessions.filter { live.contains($0.id) }
        let recent = sessions.filter { $0.source == .live && !live.contains($0.id) }.prefix(limit)
        return (connected, Array(recent))
    }
}
