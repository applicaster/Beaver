//
//  Filter.swift
//  LoggerNext
//

import Foundation

/// User-facing filter applied to a session's event stream.
///
/// Translated to a SQL `WHERE` clause (plus FTS5 for substring search)
/// inside `LogStore.query(...)`. The view model never re-filters in
/// Swift — that's what fixes the freeze at 3k+ events.
public struct Filter: Equatable, Hashable, Sendable {
    /// Minimum level. The level filter is "show this level and above":
    /// e.g., `.info` means info, warning, and error are visible.
    public var minLevel: LogLevel

    /// Substring or regex to include. Rows match if any of
    /// message/subsystem/category contains/matches it.
    public var search: String?

    /// Whether `search` is a regex (D4).
    public var searchIsRegex: Bool

    /// Substring or regex to exclude. Rows are dropped if any of
    /// message/subsystem/category contains/matches it.
    public var exclude: String?

    /// Whether `exclude` is a regex (D4).
    public var excludeIsRegex: Bool

    public init(
        minLevel: LogLevel = .verbose,
        search: String? = nil,
        searchIsRegex: Bool = false,
        exclude: String? = nil,
        excludeIsRegex: Bool = false
    ) {
        self.minLevel = minLevel
        self.search = search?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.searchIsRegex = searchIsRegex
        self.exclude = exclude?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.excludeIsRegex = excludeIsRegex
    }

    public static let none = Filter()

    public var isEmpty: Bool {
        minLevel == .verbose && search == nil && exclude == nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
