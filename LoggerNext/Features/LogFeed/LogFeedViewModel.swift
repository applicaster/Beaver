//
//  LogFeedViewModel.swift
//  LoggerNext
//

import Foundation
import SwiftUI

/// Drives the live log feed. Subscribes to a single session's events in
/// the store, pages a windowed slice into memory, and exposes a `Filter`
/// the user can mutate. See `ARCHITECTURE.md §5`.
@Observable
@MainActor
final class LogFeedViewModel {

    // MARK: - Public state

    var filter: Filter = .none {
        didSet {
            guard oldValue != filter else { return }
            // SwiftUI Table on macOS Tahoe occasionally panics
            // (`NSRangeException: range field {N, -M}`) inside
            // NSTableView's row-height diff when the underlying
            // data goes from one large set to another large but
            // different set in a single update. Walking through an
            // empty intermediate state turns one buggy "M → N diff"
            // into two safe "M → 0 deletes" + "0 → N inserts" passes.
            //
            // Also clear stale references that the reload would
            // invalidate (selection / match cursor).
            selectedEventId = nil
            currentMatchIndex = nil
            page = []
            requestReload()
            scheduleMatchRecompute()
        }
    }

    /// Total events that match the current filter, for table sizing.
    private(set) var totalCount: Int = 0

    /// In-memory window of events for the visible range.
    private(set) var page: [EventRecord] = []

    /// True when the table content is frozen — new events still
    /// arrive and persist in the store, but they don't enter `page`
    /// so the user can scroll / select / read without interference.
    /// Resuming clears the unseen counter and triggers a reload.
    var isPaused: Bool = false {
        didSet {
            if oldValue && !isPaused {
                // Resuming — catch up to whatever arrived while paused.
                unseenCount = 0
                requestReload()
            }
        }
    }

    /// Number of new events that arrived while paused. Drives the
    /// "↓ N new events" pill next to the Pause/Resume button.
    private(set) var unseenCount: Int = 0

    /// When on, consecutive events with identical (subsystem, category,
    /// message, level) collapse to one visible row showing ×N. Display
    /// only — every event still lives in the store (D8).
    /// Default ON because noisy clients (loops, polling, retries)
    /// make uncollapsed feeds unreadable; users who want strict
    /// chronology can toggle off.
    var collapseRepeats: Bool = true

    /// Cached set of bookmarked event IDs in this session; refreshed
    /// via the store's `.bookmarksChanged` change stream.
    private(set) var bookmarkedIds: Set<Int64> = []

    /// All filter presets the user has saved, alphabetical by name.
    /// Refreshed via the store's `.savedFiltersChanged` broadcast and
    /// surfaced in the ★ menu next to the filter bar.
    private(set) var savedFilters: [SavedFilter] = []

    /// Visual-only highlight term. Doesn't filter rows — just paints
    /// matches in the visible page. Matches the old Logger's "Search &
    /// highlight" field, separate from the include/exclude filters.
    var highlight: String? {
        didSet { scheduleMatchRecompute() }
    }

    /// Whether `highlight` is a regex (per-field flag, D4).
    var highlightIsRegex: Bool = false {
        didSet { scheduleMatchRecompute() }
    }

    /// IDs of events that match `highlight`, ordered by timestamp.
    /// Drives the "N/M ↑↓" navigator next to the highlight pill.
    private(set) var matchIds: [Int64] = []

    /// 0-based position within `matchIds`. Display value is +1.
    private(set) var currentMatchIndex: Int? = nil

    /// Trigger property: the table watches this and scrolls when it
    /// changes. UUID forces SwiftUI to see a unique change even when
    /// the same event id is targeted twice.
    private(set) var scrollTarget: (id: EventRecord.ID, token: UUID)? = nil

    var matchCount: Int { matchIds.count }

    /// Selected row id (for the detail pane).
    var selectedEventId: EventRecord.ID?

    // MARK: - Dependencies

    private let store: LogStore
    private let sessionId: Int64

    // MARK: - Window

    /// Upper bound on how many events `reload` will pull in one query.
    /// Sized well above any realistic single-session count so the
    /// table sees the full filtered set and SwiftUI handles render
    /// virtualization internally. Was previously a sliding 200-row
    /// window, which caused new events (past index 200) to never
    /// appear even though `totalCount` updated.
    private let maxEventsPerFetch: Int = 1_000_000

    /// Retained because `jumpTo(...)` still updates it and other code
    /// reads it for window-aware decisions. With the unbounded fetch
    /// it effectively always equals `0..<totalCount`.
    private var visibleRange: Range<Int> = 0..<0
    private let pageOverscan: Int = 100

    /// `nonisolated(unsafe)` so the nonisolated `deinit` can cancel
    /// these. Task<Void, Never> is Sendable; properties are only
    /// written from `@MainActor` methods and read once from deinit
    /// after all references are gone — no concurrent access is
    /// possible.
    private nonisolated(unsafe) var loadTask: Task<Void, Never>?
    private nonisolated(unsafe) var reloadDebounce: Task<Void, Never>?
    private nonisolated(unsafe) var subscription: Task<Void, Never>?
    private nonisolated(unsafe) var matchTask: Task<Void, Never>?

    private let reloadDebounceInterval: Duration = .milliseconds(150)

    // MARK: - Init

    init(store: LogStore, sessionId: Int64) {
        self.store = store
        self.sessionId = sessionId
        requestReload()
        Task { await self.subscribeToChanges() }
        Task { await self.reloadBookmarks() }
        Task { await self.reloadSavedFilters() }
    }

    deinit {
        loadTask?.cancel()
        reloadDebounce?.cancel()
        subscription?.cancel()
        matchTask?.cancel()
    }

    // MARK: - Debounced reload

    /// Coalesce reload triggers (filter typing, append broadcasts,
    /// window scroll) into a single SQL pass that runs after the
    /// activity quiets down. Replaces direct `reload()` calls
    /// everywhere except one-shot user actions like jump-to-match.
    private func requestReload(rangeOnly: Bool = false) {
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: self?.reloadDebounceInterval ?? .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.reload(rangeOnly: rangeOnly)
        }
    }

    // MARK: - Row presentation

    /// A row as the table sees it. When `collapseRepeats` is off this
    /// is one CollapsedRow per page event with count=1. When it's on
    /// consecutive identical events fold into a single row whose
    /// `count` is the run length.
    struct CollapsedRow: Identifiable, Hashable {
        let event: EventRecord
        let count: Int
        var id: EventRecord.ID { event.id }
    }

    var collapsedRows: [CollapsedRow] {
        guard collapseRepeats else {
            return page.map { CollapsedRow(event: $0, count: 1) }
        }
        var result: [CollapsedRow] = []
        result.reserveCapacity(page.count)
        for event in page {
            if let last = result.last, isSameKind(last.event, event) {
                result[result.count - 1] = CollapsedRow(
                    event: last.event,
                    count: last.count + 1
                )
            } else {
                result.append(CollapsedRow(event: event, count: 1))
            }
        }
        return result
    }

    private func isSameKind(_ a: EventRecord, _ b: EventRecord) -> Bool {
        a.level == b.level &&
        a.subsystem == b.subsystem &&
        a.category == b.category &&
        a.message == b.message
    }

    // MARK: - Visible range driving

    func didReachEnd() {
        // Expand window when the table approaches the end of the page.
        let newEnd = min(totalCount, visibleRange.upperBound + pageOverscan)
        guard newEnd != visibleRange.upperBound else { return }
        visibleRange = visibleRange.lowerBound..<newEnd
        requestReload(rangeOnly: true)
    }

    // MARK: - Reload

    func reload() async {
        await reload(rangeOnly: false)
    }

    private func reload(rangeOnly: Bool) async {
        loadTask?.cancel()
        let snapshotFilter = filter
        let limit = maxEventsPerFetch
        loadTask = Task { [store, sessionId] in
            do {
                if !rangeOnly {
                    let count = try await store.eventCount(
                        sessionId: sessionId,
                        filter: snapshotFilter
                    )
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.totalCount = count
                        // Keep visibleRange in sync for downstream
                        // code (jumpTo, didReachEnd). Now always
                        // covers the full filtered result set.
                        self.visibleRange = 0..<count
                    }
                }
                let events = try await store.events(
                    sessionId: sessionId,
                    filter: snapshotFilter,
                    offset: 0,
                    limit: limit
                )
                if Task.isCancelled { return }
                await MainActor.run { self.page = events }
            } catch {
                // TODO: surface to UI as a banner.
                print("LogFeedViewModel.reload: \(error)")
            }
        }
    }

    private func subscribeToChanges() async {
        let stream = await store.changes()
        subscription = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                switch change {
                case .appended(let sid, let count) where sid == self.sessionId:
                    await self.handleAppended(count: count)
                case .cleared(let sid) where sid == self.sessionId:
                    self.unseenCount = 0
                    self.requestReload()
                case .bookmarksChanged(let sid) where sid == self.sessionId:
                    await self.reloadBookmarks()
                case .savedFiltersChanged:
                    await self.reloadSavedFilters()
                default:
                    break
                }
            }
        }
    }

    private func handleAppended(count: Int) async {
        if isPaused {
            // Frozen view — don't pull the new events into `page`.
            // Just track the gap so the UI shows the user how much
            // is waiting for them when they resume.
            unseenCount += count
            return
        }
        // Debounce: high event rates coalesce into one reload.
        requestReload()
    }

    /// Resume the live feed. Identical to setting `isPaused = false`;
    /// kept as a named action so the UI (pill click) reads cleanly.
    func resume() {
        isPaused = false
        // didSet on isPaused handles unseenCount reset + reload.
    }

    // MARK: - Bookmarks

    func isBookmarked(_ eventId: Int64) -> Bool {
        bookmarkedIds.contains(eventId)
    }

    /// Toggle the bookmark state for an event. Fire-and-forget; the
    /// store's `.bookmarksChanged` broadcast refreshes `bookmarkedIds`.
    func toggleBookmark(_ eventId: Int64) {
        let isOn = bookmarkedIds.contains(eventId)
        print("[Bookmarks] toggle event=\(eventId) session=\(sessionId) wasOn=\(isOn)")
        Task { [store, sessionId] in
            do {
                if isOn {
                    try await store.removeBookmark(eventId: eventId, sessionId: sessionId)
                } else {
                    try await store.addBookmark(eventId: eventId, sessionId: sessionId)
                }
            } catch {
                print("[Bookmarks] toggle ERROR: \(error)")
            }
        }
    }

    /// Jump the table to a bookmarked event — reuses the match-navigation
    /// scroll path so the row gets centered and selected.
    func jumpToBookmark(eventId: Int64) {
        Task { await jumpTo(eventId: eventId) }
    }

    private func reloadBookmarks() async {
        do {
            bookmarkedIds = try await store.bookmarkedEventIds(sessionId: sessionId)
        } catch {
            print("reloadBookmarks: \(error)")
        }
    }

    // MARK: - Saved filter presets

    /// Apply a preset wholesale. Overwrites `filter`; leaves the
    /// separate `highlight` field alone since highlight is a
    /// session-local visual aid, not part of the persisted preset.
    func applySavedFilter(_ saved: SavedFilter) {
        filter = saved.filter
    }

    /// Persist the current `filter` under `name`. Upserts — saving a
    /// second time with the same name overwrites cleanly. Empty names
    /// are rejected at the store boundary.
    func saveCurrentFilter(as name: String) {
        let snapshot = filter
        Task { [weak self] in
            do {
                try await self?.store.upsertSavedFilter(name: name, filter: snapshot)
            } catch {
                print("saveCurrentFilter: \(error)")
            }
        }
    }

    /// Remove a preset by id. The `.savedFiltersChanged` broadcast
    /// reloads the in-memory list.
    func deleteSavedFilter(id: Int64) {
        Task { [weak self] in
            do {
                try await self?.store.deleteSavedFilter(id: id)
            } catch {
                print("deleteSavedFilter: \(error)")
            }
        }
    }

    private func reloadSavedFilters() async {
        do {
            savedFilters = try await store.savedFilters()
        } catch {
            print("reloadSavedFilters: \(error)")
        }
    }

    // MARK: - Search & highlight: match navigation

    /// Step to the next matching event (wraps). Pauses Follow so the
    /// jump isn't immediately undone by tail-scroll.
    func nextMatch() {
        guard !matchIds.isEmpty else { return }
        let curr = currentMatchIndex ?? -1
        let next = (curr + 1) % matchIds.count
        currentMatchIndex = next
        Task { await jumpTo(eventId: matchIds[next]) }
    }

    /// Step to the previous matching event (wraps).
    func previousMatch() {
        guard !matchIds.isEmpty else { return }
        let curr = currentMatchIndex ?? 1
        let prev = curr <= 0 ? matchIds.count - 1 : curr - 1
        currentMatchIndex = prev
        Task { await jumpTo(eventId: matchIds[prev]) }
    }

    private func scheduleMatchRecompute() {
        matchTask?.cancel()
        matchTask = Task { [weak self] in
            // Light debounce so typing doesn't fire a query per keystroke.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.recomputeMatches()
        }
    }

    private func recomputeMatches() async {
        guard let term = highlight, !term.isEmpty else {
            matchIds = []
            currentMatchIndex = nil
            return
        }
        do {
            let ids = try await store.matchingIds(
                sessionId: sessionId,
                filter: filter,
                highlight: term,
                isRegex: highlightIsRegex
            )
            guard !Task.isCancelled else { return }
            matchIds = ids
            currentMatchIndex = ids.isEmpty ? nil : 0
            if let first = ids.first {
                await jumpTo(eventId: first)
            }
        } catch {
            print("recomputeMatches: \(error)")
        }
    }

    /// Adjust the page window to include `eventId`, reload, and signal
    /// the table to scroll-and-select.
    private func jumpTo(eventId: Int64) async {
        // Find target's position in the filtered ordering and center
        // the page window on it.
        let offset = (try? await store.offset(
            of: eventId,
            sessionId: sessionId,
            filter: filter
        )) ?? 0
        let half = pageOverscan
        let lower = max(0, offset - half)
        let upper = offset + half + 1
        visibleRange = lower..<upper
        await reload(rangeOnly: true)
        // Auto-pause so incoming events don't scroll us off the
        // match we just navigated to.
        isPaused = true
        // Trigger scroll + selection.
        scrollTarget = (eventId, UUID())
        selectedEventId = eventId
    }
}
