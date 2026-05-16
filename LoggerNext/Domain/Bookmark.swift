//
//  Bookmark.swift
//  LoggerNext
//

import Foundation

/// A starred / pinned event the user wants to navigate back to later.
/// Persists in the `event_bookmark` table; survives across app restarts
/// because the underlying event also persists in the per-session log
/// store.
public struct Bookmark: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let sessionId: Int64
    public let eventId: Int64
    public let note: String?
    public let createdAt: Date

    public init(
        id: Int64,
        sessionId: Int64,
        eventId: Int64,
        note: String?,
        createdAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.eventId = eventId
        self.note = note
        self.createdAt = createdAt
    }
}

/// Bookmark joined with its underlying event for display in the
/// bookmarks popover. The event provides level/message/subsystem for
/// the row preview without a separate fetch.
public struct BookmarkedEvent: Identifiable, Hashable, Sendable {
    public let bookmark: Bookmark
    public let event: EventRecord
    public var id: Int64 { bookmark.id }
}
