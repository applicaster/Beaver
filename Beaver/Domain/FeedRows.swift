//
//  FeedRows.swift
//  Beaver
//

import Foundation

/// One Log-feed table row: an event, or a run of identical consecutive
/// events folded into it (D8). The row takes the first event's id.
public struct FeedRow: Identifiable, Hashable, Sendable {
    public let event: EventRecord
    public let count: Int
    public var id: EventRecord.ID { event.id }
}

/// The Log feed's loaded events and the rows built from them, kept up to
/// date incrementally.
///
/// Events stay ordered by `(timestamp, id)`. New events usually belong
/// at the end, but a device's timestamps are not arrival order: on a
/// real store ~30% of events arrive after one with a later timestamp,
/// up to ~20 s late. `merge` therefore places each batch where it
/// belongs and redoes only the rows from that point on, so an append
/// costs the late tail rather than the whole session.
public struct FeedRows: Sendable {
    public private(set) var events: [EventRecord] = []
    public private(set) var rows: [FeedRow] = []

    /// Index into `events` where each row starts, parallel to `rows`.
    private var rowStarts: [Int] = []
    private var indexById: [EventRecord.ID: Int] = [:]

    public var collapse: Bool {
        didSet { if collapse != oldValue { rebuildRows(from: 0) } }
    }

    public init(collapse: Bool) {
        self.collapse = collapse
    }

    /// `events` must be ordered by `(timestamp, id)`.
    public mutating func replace(with events: [EventRecord]) {
        self.events = events
        indexById = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($1.id, $0) })
        rebuildRows(from: 0)
    }

    /// Adds events newer (by id) than any loaded, ordered by
    /// `(timestamp, id)` among themselves.
    public mutating func merge(_ batch: [EventRecord]) {
        guard let first = batch.first else { return }
        let start = insertionIndex(for: first)
        let merged = Self.mergeSorted(events[start...], batch)
        events.replaceSubrange(start..., with: merged)
        for index in start..<events.count {
            indexById[events[index].id] = index
        }
        // The row holding the event just before the insertion point may
        // now continue into the new events, so start one row earlier.
        rebuildRows(from: start == 0 ? 0 : rowIndex(containing: start - 1))
    }

    public func contains(eventId: EventRecord.ID) -> Bool {
        indexById[eventId] != nil
    }

    /// The id of the row showing `eventId`, or `nil` when not loaded.
    public func rowId(for eventId: EventRecord.ID) -> EventRecord.ID? {
        guard let index = indexById[eventId] else { return nil }
        return rows[rowIndex(containing: index)].id
    }

    /// Position of the row whose id is `rowId`.
    public func rowIndex(ofRow rowId: EventRecord.ID) -> Int? {
        guard let index = indexById[rowId] else { return nil }
        let row = rowIndex(containing: index)
        return rowStarts[row] == index ? row : nil
    }

    /// The first row past `index` (or from the edge, when `nil`) in the
    /// given direction that satisfies `predicate`. Does not wrap.
    public func rowIndex(after index: Int?, forward: Bool,
                         where predicate: (FeedRow) -> Bool) -> Int? {
        if forward {
            let from = index.map { $0 + 1 } ?? 0
            guard from < rows.count else { return nil }
            return rows[from...].firstIndex(where: predicate)
        }
        let upTo = index ?? rows.count
        guard upTo > 0 else { return nil }
        return rows[..<upTo].lastIndex(where: predicate)
    }

    // MARK: - Private

    private static func isSameKind(_ a: EventRecord, _ b: EventRecord) -> Bool {
        a.level == b.level && a.subsystem == b.subsystem
            && a.category == b.category && a.message == b.message
    }

    private static func precedes(_ a: EventRecord, _ b: EventRecord) -> Bool {
        (a.timestampMillis, a.id) < (b.timestampMillis, b.id)
    }

    /// First index whose event sorts after `event`.
    private func insertionIndex(for event: EventRecord) -> Int {
        var low = 0, high = events.count
        while low < high {
            let mid = (low + high) / 2
            if Self.precedes(events[mid], event) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func mergeSorted(_ a: ArraySlice<EventRecord>,
                                    _ b: [EventRecord]) -> [EventRecord] {
        var result: [EventRecord] = []
        result.reserveCapacity(a.count + b.count)
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex {
            if precedes(b[j], a[i]) { result.append(b[j]); j += 1 } else { result.append(a[i]); i += 1 }
        }
        result.append(contentsOf: a[i...])
        result.append(contentsOf: b[j...])
        return result
    }

    /// Row containing the event at `index`: the last row starting at or
    /// before it.
    private func rowIndex(containing index: Int) -> Int {
        var low = 0, high = rowStarts.count
        while low < high {
            let mid = (low + high) / 2
            if rowStarts[mid] <= index { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    /// Drops rows from `row` on and regroups the events they covered.
    /// Rows before `row` are untouched: the event that starts `row` did
    /// not change, so neither did the boundary in front of it.
    private mutating func rebuildRows(from row: Int) {
        // Out of range only for row 0 of an empty table.
        let start = rowStarts.indices.contains(row) ? rowStarts[row] : 0
        rows.removeSubrange(row...)
        rowStarts.removeSubrange(row...)
        var index = start
        while index < events.count {
            let head = events[index]
            var end = index + 1
            if collapse {
                while end < events.count, Self.isSameKind(head, events[end]) { end += 1 }
            }
            rows.append(FeedRow(event: head, count: end - index))
            rowStarts.append(index)
            index = end
        }
    }
}
