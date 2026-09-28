//
//  SavedFilter.swift
//  Beaver
//
//  A named, persisted Filter that the user can apply with one click
//  instead of re-typing common search/exclude terms every session.
//

import Foundation

/// One entry in the user's saved-filter list. Stored in the
/// `saved_filter` table (schema v1) and surfaced by the filter
/// popover in the log-feed toolbar.
///
/// Identity rules:
///   - `id` is the SQLite rowid, auto-assigned on insert.
///   - `name` is uniquely indexed; the UI uses it as the human label
///     and lookups can use it for "rename or replace" semantics.
public struct SavedFilter: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let filter: Filter
    /// A new session starts from this one (D82). At most one is.
    public let isDefault: Bool

    public init(id: Int64, name: String, filter: Filter, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.filter = filter
        self.isDefault = isDefault
    }

    /// ⌘1…⌘9 apply the first nine, in `LogStore.savedFilters()` order (D82).
    public static func shortcut(at index: Int) -> String? {
        (0..<9).contains(index) ? "⌘\(index + 1)" : nil
    }
}
