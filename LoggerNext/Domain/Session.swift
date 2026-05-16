//
//  Session.swift
//  LoggerNext
//

import Foundation

/// A single client connection's worth of events.
///
/// Per D2 (one client at a time) each accepted connection starts a new
/// session row. Imported JSON files also create sessions, distinguished
/// by `source`.
public struct Session: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable, Codable {
        case live
        case imported
    }

    public let id: Int64
    public let startedAt: Date
    public var endedAt: Date?
    public let source: Source
    public var clientLabel: String?     // from handshake response, if any

    public init(
        id: Int64,
        startedAt: Date,
        endedAt: Date? = nil,
        source: Source,
        clientLabel: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.clientLabel = clientLabel
    }

    public var isActive: Bool { endedAt == nil && source == .live }
}
