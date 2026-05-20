//
//  LogLevel.swift
//  Beaver
//

import SwiftUI

/// Severity levels emitted by the mobile SDK.
///
/// Wire encoding from the SDK is heterogeneous — the same level may arrive
/// as a string ("info") or an integer (`2`). See `PROTOCOL.md §4.1.1`.
/// Beaver normalizes to the string form on decode and stores the
/// string in `event.level`.
public enum LogLevel: String, CaseIterable, Codable, Comparable, Sendable {
    case verbose
    case debug
    case info
    case warning
    case error

    /// Numeric severity, used for ordering and for decoding integer-form
    /// wire values.
    public var severity: Int {
        switch self {
        case .verbose: 0
        case .debug:   1
        case .info:    2
        case .warning: 3
        case .error:   4
        }
    }

    public init?(numericLevel: Int) {
        switch numericLevel {
        case 0: self = .verbose
        case 1: self = .debug
        case 2: self = .info
        case 3: self = .warning
        case 4: self = .error
        default: return nil
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    public var displayName: String {
        rawValue.uppercased()
    }

    /// UI color for the level dot. Resolved against the system palette so
    /// it adapts to light/dark mode.
    public var displayColor: Color {
        switch self {
        case .verbose: .blue
        case .debug:   .purple
        case .info:    .green
        case .warning: .yellow
        case .error:   .red
        }
    }
}
