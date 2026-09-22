//
//  EventRecord.swift
//  Beaver
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

    /// UTF-8 byte cost of the whole entry — the honest wire/storage
    /// price of one log line. Mirrors the web viewer's Size column, so
    /// "which log is expensive?" gets the same answer in both apps.
    public var sizeBytes: Int {
        var total = message.utf8.count
            + subsystem.utf8.count
            + category.utf8.count
        total += dataJSON?.utf8.count ?? 0
        total += contextJSON?.utf8.count ?? 0
        return total
    }

    public enum SizeClass: Sendable {
        case normal
        case average
        case oversized
    }

    /// Same thresholds as the web viewer: under 1 KB is unremarkable,
    /// 8 KB and up is worth asking about.
    public var sizeClass: SizeClass {
        switch sizeBytes {
        case ..<1024:      .normal
        case ..<(8 * 1024): .average
        default:            .oversized
        }
    }

    /// Compact and human-readable: "512 B", "3.2 KB", "1.4 MB".
    public var sizeText: String {
        let bytes = sizeBytes
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return kb < 10
                ? String(format: "%.1f KB", kb)
                : "\(Int(kb.rounded())) KB"
        }
        let mb = kb / 1024
        return mb < 10
            ? String(format: "%.1f MB", mb)
            : "\(Int(mb.rounded())) MB"
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

    // DateFormatter is Sendable as of macOS 14 / iOS 17, so the
    // previous `nonisolated(unsafe)` annotation is no longer needed
    // — Swift 6 flags it as redundant.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = .init(identifier: "en_US_POSIX")
        return f
    }()

    private static let fullFormatter: DateFormatter = {
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
