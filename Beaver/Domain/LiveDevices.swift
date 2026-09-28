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
        guard let sessionId = sessions.removeValue(forKey: connection) else { return nil }
        commands[sessionId] = nil
        return sessionId
    }

    /// A live session was deleted; its device writes to `new` from now on.
    public mutating func replace(session old: Int64, with new: Int64) {
        guard let connection = connection(for: old) else { return }
        sessions[connection] = new
        commands[new] = commands.removeValue(forKey: old)
    }

    public mutating func setCommands(_ hints: [CommandHint], for sessionId: Int64) {
        commands[sessionId] = hints
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
