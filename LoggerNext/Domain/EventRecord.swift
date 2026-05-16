//
//  EventRecord.swift
//  LoggerNext
//

import Foundation

/// A single log event, as stored in the LogStore.
///
/// Wire shape is documented in `PROTOCOL.md §4.1`. This is the
/// post-decode normalized form: the inner `event` JSON-string has been
/// parsed, `level` has been normalized to the string enum, and `data` /
/// `context` are preserved as raw JSON blobs for the detail pane to
/// render via a recursive tree view.
public struct EventRecord: Identifiable, Hashable, Sendable {
    public let id: Int64                   // primary key in `event` table
    public let sessionId: Int64
    public let timestampMillis: UInt64
    public let level: LogLevel
    public let subsystem: String
    public let category: String
    public let message: String
    public let dataJSON: String?           // raw JSON blob
    public let contextJSON: String?        // raw JSON blob

    public init(
        id: Int64,
        sessionId: Int64,
        timestampMillis: UInt64,
        level: LogLevel,
        subsystem: String,
        category: String,
        message: String,
        dataJSON: String?,
        contextJSON: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.timestampMillis = timestampMillis
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.dataJSON = dataJSON
        self.contextJSON = contextJSON
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000.0)
    }

    /// Formatted as `HH:mm:ss.SSS` — 24-hour with milliseconds. Used in
    /// the table's Time column. Old Logger used the same format; debug
    /// timestamps benefit from explicit 24h (no AM/PM ambiguity) and
    /// millisecond precision for ordering.
    public var timeOfDayWithMillis: String {
        Self.timeFormatter.string(from: date)
    }

    /// Full date + time with millis. Used in the detail pane.
    public var fullTimestamp: String {
        Self.fullFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = .init(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated(unsafe) private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = .init(identifier: "en_US_POSIX")
        return f
    }()
}

/// A pre-persisted event, ready for `LogStore.append(_:)`.
public struct DecodedEvent: Sendable {
    public let timestampMillis: UInt64
    public let level: LogLevel
    public let subsystem: String
    public let category: String
    public let message: String
    public let dataJSON: String?
    public let contextJSON: String?

    public init(
        timestampMillis: UInt64,
        level: LogLevel,
        subsystem: String,
        category: String,
        message: String,
        dataJSON: String?,
        contextJSON: String?
    ) {
        self.timestampMillis = timestampMillis
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.dataJSON = dataJSON
        self.contextJSON = contextJSON
    }
}
