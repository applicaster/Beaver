//
//  DefaultDevice.swift
//  Beaver
//
//  D76: the app agents' device tools use when a call names no device.
//  One for all of Beaver, in memory. Kept by the SDK's device id so it
//  survives the app restarting (a new live session each time).

import Foundation

public enum DefaultDevice: Sendable, Equatable {
    /// The SDK's handshake `deviceId` (D77).
    case uid(String)
    /// An app that sent no handshake: only this live session. Such an app
    /// reconnects in a new session, so once it isn't live it is gone for
    /// good and counts as no default (`isGone`).
    case session(Int64)

    public init(session: Session) {
        self = session.deviceUID.map(DefaultDevice.uid) ?? .session(session.id)
    }

    /// Its live session now. `live` is least recent first (tools pass
    /// `LogStore.byRecency`): if one uid has several, the last one wins.
    /// Not the highest id — D97 continues an older session on reconnect.
    public func liveSession(in sessions: [Session], live: [Int64]) -> Int64? {
        switch self {
        case .session(let id): live.contains(id) ? id : nil
        case .uid(let uid): live.last { id in sessions.contains { $0.id == id && $0.deviceUID == uid } }
        }
    }

    /// A `.session` default whose session ended: it never comes back.
    public func isGone(live: [Int64]) -> Bool {
        if case .session(let id) = self { !live.contains(id) } else { false }
    }

    public func matches(_ session: Session) -> Bool {
        switch self {
        case .session(let id): session.id == id
        case .uid(let uid): session.deviceUID == uid
        }
    }
}
