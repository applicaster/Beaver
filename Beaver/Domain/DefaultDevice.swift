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
    /// An app that sent no handshake: only this live session, lost on reconnect.
    case session(Int64)

    public init(session: Session) {
        self = session.deviceUID.map(DefaultDevice.uid) ?? .session(session.id)
    }

    /// Its live session now; the newest if one uid has several.
    public func liveSession(in sessions: [Session], live: [Int64]) -> Int64? {
        switch self {
        case .session(let id): live.contains(id) ? id : nil
        case .uid(let uid): sessions.filter { live.contains($0.id) && $0.deviceUID == uid }.map(\.id).max()
        }
    }

    public func matches(_ session: Session) -> Bool {
        switch self {
        case .session(let id): session.id == id
        case .uid(let uid): session.deviceUID == uid
        }
    }
}
