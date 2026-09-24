//
//  LogFeedViewModel.swift
//  Beaver
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
            Self.remember(filter)
            // SwiftUI Table on macOS Tahoe occasionally panics
            // (`NSRangeException: range field {N, -M}`) inside
            // NSTableView's row-height diff when the underlying
            // data goes from one large set to another large but
            // different set in a single update. Walking through an
            // empty intermediate state turns one buggy "M → N diff"
            // into two safe "M → 0 deletes" + "0 → N inserts" passes.
            //
            // The selection is put back once the reload lands, where
            // its rows still match; the match cursor starts over.
            selectionToRestore = selectedEventIds
            currentMatchIndex = nil
            feed.replace(with: [])
            watermark = nil
            requestReload()
            scheduleMatchRecompute()
            scheduleFacetRefresh(after: reloadDebounceInterval)
        }
    }

    /// Total events that match the current filter, for table sizing.
    private(set) var totalCount: Int = 0

    /// Events in the session before any filtering, so the bar can say
    /// "shown / total" and make the filter's effect visible.
    private(set) var unfilteredCount: Int = 0

    /// The loaded events and the table rows built from them. A live
    /// append extends both in place instead of refetching the session.
    private(set) var feed = FeedRows(collapse: true)

    /// Loaded events, oldest first, without payloads.
    var page: [EventRecord] { feed.events }

    /// True when the table content is frozen — new events still
    /// arrive and persist in the store, but they don't enter `page`
    /// so the user can scroll / select / read without interference.
    /// Resuming follows the tail again and fetches what arrived.
    var isPaused: Bool = false {
        didSet {
            guard oldValue != isPaused else { return }
            if isPaused {
                follow.stop()
            } else {
                follow.resume()
                requestTail()
            }
        }
    }

    /// Follow-the-tail state (D3): at the bottom means following; away
    /// from it, arrivals are counted for the "N new ↓" pill.
    private(set) var follow = TailFollow()

    /// Events that arrived while not following or paused.
    var unseenCount: Int { follow.unseen }

    /// Bumped to make the table scroll to the newest row.
    private(set) var latestScrollToken = UUID()

    /// When on, consecutive events with identical (subsystem, category,
    /// message, level) collapse to one visible row showing ×N. Display
    /// only — every event still lives in the store (D8).
    /// Default ON because noisy clients (loops, polling, retries)
    /// make uncollapsed feeds unreadable; users who want strict
    /// chronology can toggle off.
    var collapseRepeats: Bool {
        get { feed.collapse }
        set { feed.collapse = newValue }
    }

    /// Cached set of bookmarked event IDs in this session; refreshed
    /// via the store's `.bookmarksChanged` change stream.
    private(set) var bookmarkedIds: Set<Int64> = []

    /// All filter presets the user has saved, alphabetical by name.
    /// Refreshed via the store's `.savedFiltersChanged` broadcast and
    /// surfaced in the ★ menu next to the filter bar.
    private(set) var savedFilters: [SavedFilter] = []

    /// Values offered by the Subsystem / Category chip menus, with how many
    /// events each would show under the rest of the filter. Refreshed when
    /// the filter changes and as events arrive.
    private(set) var availableSubsystems: [FacetCount] = []

    private(set) var availableCategories: [FacetCount] = []

    /// Number of facet popovers (subsystem/category) currently visible.
    /// `reloadFacetValues` runs a full `GROUP BY` scan per facet on the
    /// store's single serial `DatabaseQueue`, competing with page reloads
    /// and ingestion writes — worth paying only while a popover is
    /// actually showing the result. Set from the popover's
    /// `onAppear`/`onDisappear` in `LogFeedView`.
    var facetPopoverOpen: Int = 0 {
        didSet {
            guard facetPopoverOpen == 0, oldValue != 0 else { return }
            facetTask?.cancel()
            facetTask = nil
        }
    }

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

    /// Selected row ids. Several can be selected for copying.
    var selectedEventIds: Set<EventRecord.ID> = [] {
        didSet {
            guard oldValue != selectedEventIds else { return }
            loadSelectedEvent()
        }
    }

    /// The selected row when exactly one is — what the detail pane,
    /// `j` / `k` and the Δ column work from.
    var selectedEventId: EventRecord.ID? {
        get { selectedEventIds.count == 1 ? selectedEventIds.first : nil }
        set { selectedEventIds = newValue.map { [$0] } ?? [] }
    }

    /// The selection as it was when the filter changed; re-applied, to
    /// the rows that still match, when the new snapshot lands.
    private var selectionToRestore: Set<EventRecord.ID>?

    /// Bumped by ⌘F; the Search & highlight field takes focus.
    private(set) var searchFocusRequest = 0

    /// The selected row *with* its JSON payloads. Rows in `page` are
    /// fetched without payloads (see `reload`), so the detail pane reads
    /// this instead of looking the selection up in `page`.
    private(set) var selectedEvent: EventRecord?

    /// `selectedEvent`'s DATA / CONTEXT as trees. Parsed once per
    /// selection, off the main actor — parsing inside the pane's `body`
    /// cost 115 ms per evaluation on a real 25 MB payload.
    private(set) var selectedData: StorageRecord?
    private(set) var selectedContext: StorageRecord?

    // MARK: - Dependencies

    private let store: LogStore
    /// The session this view-model is bound to. Exposed (not
    /// private) so the owning view can compare against
    /// `env.viewingSessionId` and decide whether to replace the
    /// instance when the user switches sessions.
    let sessionId: Int64

    // MARK: - Window

    /// Upper bound on how many events `reload` will pull in one query.
    /// Sized well above any realistic single-session count so the
    /// table sees the full filtered set and SwiftUI handles render
    /// virtualization internally. Was previously a sliding 200-row
    /// window, which caused new events (past index 200) to never
    /// appear even though `totalCount` updated.
    ///
    /// A snapshot keeps the *newest* this many. Live appends may run a
    /// tenth past it before a fresh snapshot trims the oldest, so a
    /// busy stream at the cap doesn't refetch on every append.
    private let maxEventsPerFetch: Int = 1_000_000

    /// Highest event id the loaded rows account for — every row past it
    /// is new. `nil` while a snapshot is pending.
    private var watermark: Int64?

    /// The filter `feed` was loaded with. A tail uses this, not `filter`,
    /// which may already hold an edit whose reload hasn't run yet.
    private var loadedFilter: Filter = .none

    /// Set when an append lands while a tail fetch is in flight.
    private var tailPending = false

    /// Marked `nonisolated(unsafe)` so the nonisolated `deinit` can
    /// cancel them. `Task<Void, Never>` is Sendable and the
    /// properties are written only from `@MainActor` methods + read
    /// once from deinit after all other references are gone, so
    /// the "unsafe" is notational, not an actual data race.
    ///
    /// Xcode 26 emits a "'nonisolated(unsafe)' has no effect,
    /// consider using 'nonisolated'" warning on these four. The
    /// suggestion is wrong: plain `nonisolated` is rejected on
    /// mutable stored properties. Known compiler false positive;
    /// ignore it.
    private nonisolated(unsafe) var loadTask: Task<Void, Never>?
    private nonisolated(unsafe) var reloadDebounce: Task<Void, Never>?
    private nonisolated(unsafe) var subscription: Task<Void, Never>?
    private nonisolated(unsafe) var matchTask: Task<Void, Never>?
    private nonisolated(unsafe) var facetTask: Task<Void, Never>?
    private nonisolated(unsafe) var selectionTask: Task<Void, Never>?
    private nonisolated(unsafe) var tailTask: Task<Void, Never>?

    /// Bumped by every `reload`. A queued reload compares it before
    /// issuing SQL and skips the query outright if a newer one has
    /// been requested since — `Task.cancel()` alone can't do that,
    /// because a cancelled task still runs its `store.events(...)`
    /// call to completion once the actor gets to it (D16).
    private var reloadGeneration: UInt64 = 0

    /// Bumped by every `scheduleFacetRefresh`. Mirrors `reloadGeneration`:
    /// `Task.cancel()` alone doesn't stop a facet task already past its
    /// debounce sleep from running its SQL to completion, so
    /// `reloadFacetValues` checks this before issuing the queries, not
    /// just after.
    private var facetGeneration: UInt64 = 0

    private let reloadDebounceInterval: Duration = .milliseconds(150)

    // MARK: - Init

    /// - Parameter filter: what to start with — the previous session's
    ///   filter, so a reconnect or relaunch doesn't drop it.
    init(store: LogStore, sessionId: Int64, filter: Filter = .none) {
        self.store = store
        self.sessionId = sessionId
        self.filter = filter
        requestReload()
        Task { await self.subscribeToChanges() }
        Task { await self.reloadBookmarks() }
        Task { await self.reloadSavedFilters() }
        // Facet counts are loaded lazily, on first popover open —
        // see `facetPopoverOpen`. No point computing them here when
        // nothing may ever show them.
    }

    deinit {
        loadTask?.cancel()
        reloadDebounce?.cancel()
        subscription?.cancel()
        matchTask?.cancel()
        facetTask?.cancel()
        selectionTask?.cancel()
        tailTask?.cancel()
    }

    // MARK: - Debounced reload

    /// Coalesce reload triggers (filter typing, append broadcasts,
    /// window scroll) into a single SQL pass that runs after the
    /// activity quiets down. Replaces direct `reload()` calls
    /// everywhere except one-shot user actions like jump-to-match.
    private func requestReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: self?.reloadDebounceInterval ?? .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: - Row presentation

    /// A row as the table sees it — one event, or with Collapse on a
    /// run of identical events shown once with its count (D8). Kept up
    /// to date by `feed`; this used to be recomputed from the whole page
    /// on every body pass.
    typealias CollapsedRow = FeedRow

    var collapsedRows: [FeedRow] { feed.rows }

    /// The row that actually displays `eventId`.
    ///
    /// With Collapse on, a run of identical events becomes one row
    /// represented by the first of them; the rest have no row of their
    /// own. Selecting or scrolling to a folded id silently does
    /// nothing, which is what made match navigation look dead — the
    /// counter advanced while the table never moved.
    func displayedRowId(for eventId: EventRecord.ID) -> EventRecord.ID {
        feed.rowId(for: eventId) ?? eventId
    }

    // MARK: - Reload

    /// A full reload: filter changes, Clear, and catching up past the
    /// cap. Live appends don't come here — see `requestTail`.
    ///
    /// A reload materialises the whole filtered result set in one array,
    /// so two things have to hold or memory explodes:
    ///
    /// 1. **One query at a time.** Reloads are requested far faster than a
    ///    large session can be fetched, and a cancelled task's SQL still
    ///    runs and still builds its array. Left unserialised, a burst of
    ///    appends puts ~20 full-session arrays in flight at once — the
    ///    multiplier behind the 56 GB freeze.
    /// 2. **No JSON payloads.** The table renders level / message /
    ///    subsystem / category / time only; payloads are ~97% of the bytes.
    ///    The detail pane refetches the selected row's payloads by id.
    ///
    /// Returns once `page` reflects the newest reload requested by then —
    /// not merely once one has been queued. `jumpTo` resolves its row
    /// from `page` right after, and used to read a stale or just-emptied
    /// one, so the jump landed nowhere.
    private func reload() async {
        loadTask?.cancel()
        let previous = loadTask
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let snapshotFilter = filter
        let limit = maxEventsPerFetch
        let task = Task { [weak self, store, sessionId] in
            _ = await previous?.value
            guard let self, self.isCurrentReload(generation) else { return }
            do {
                // Rows and both counts in one read, newest rows first.
                let snapshot = try await store.feedSnapshot(
                    sessionId: sessionId,
                    filter: snapshotFilter,
                    limit: limit
                )
                guard self.isCurrentReload(generation) else { return }
                self.totalCount = snapshot.total
                self.unfilteredCount = snapshot.unfiltered
                self.feed.replace(with: snapshot.events)
                self.loadedFilter = snapshotFilter
                self.watermark = snapshot.watermark
                self.restoreSelection()
                // Appends announced while no watermark was set were
                // skipped; fetch whatever landed after the read.
                self.requestTail()
            } catch {
                // TODO: surface to UI as a banner.
                print("LogFeedViewModel.reload: \(error)")
            }
        }
        loadTask = task
        // A newer reload supersedes this one without setting `page`, so
        // wait on whichever is newest until none started meanwhile.
        var awaited: Task<Void, Never>?
        while let current = loadTask, current != awaited {
            await current.value
            awaited = current
        }
    }

    private func isCurrentReload(_ generation: UInt64) -> Bool {
        generation == reloadGeneration
    }

    /// Fetch the selected row again, this time with its JSON payloads.
    private func loadSelectedEvent() {
        selectionTask?.cancel()
        guard let id = selectedEventId else {
            selectedEvent = nil
            selectedData = nil
            selectedContext = nil
            return
        }
        selectionTask = Task { [weak self, store] in
            let full = try? await store.events(ids: [id]).first
            let (data, context) = await Task.detached(priority: .userInitiated) {
                (full?.dataJSON.flatMap { StorageRecord.parse($0) },
                 full?.contextJSON.flatMap { StorageRecord.parse($0) })
            }.value
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.selectedEventId == id else { return }
                self.selectedEvent = full
                self.selectedData = data
                self.selectedContext = context
            }
        }
    }

    /// Full rows (payloads included) for the given ids — used by the
    /// clipboard actions, which need the JSON the feed query skips.
    func fullEvents(ids: Set<EventRecord.ID>) async -> [EventRecord] {
        (try? await store.events(ids: ids)) ?? []
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
                    self.follow.resume()
                    self.requestReload()
                    if self.facetPopoverOpen > 0 { await self.reloadFacetValues() }
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
        // Throttled, not restarted: a steady stream must not starve a
        // refresh the filter already asked for.
        if facetTask == nil { scheduleFacetRefresh(after: .seconds(1)) }
        if isPaused {
            // Frozen view — don't pull the new events into `page`.
            // Just track the gap so the UI shows the user how much
            // is waiting for them when they resume.
            follow.appended(count)
            return
        }
        requestTail()
    }

    // MARK: - Live tail

    /// Fetch the rows past the watermark and merge them in. Appends that
    /// arrive while a fetch is in flight fold into one follow-up, so a
    /// fast stream costs one small query at a time, never a queue.
    private func requestTail() {
        guard watermark != nil, !isPaused else { return }
        guard tailTask == nil else {
            tailPending = true
            return
        }
        tailTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.tailPending = false
                await self.fetchTail()
                guard self.tailPending else { break }
            }
            self?.tailTask = nil
        }
    }

    private func fetchTail() async {
        guard let after = watermark else { return }
        let generation = reloadGeneration
        do {
            let tail = try await store.feedTail(sessionId: sessionId, filter: loadedFilter, after: after)
            // A snapshot replaced the rows meanwhile; it tails itself.
            guard generation == reloadGeneration, watermark == after else { return }
            watermark = tail.watermark
            unfilteredCount += tail.unfiltered
            guard !tail.events.isEmpty else { return }
            totalCount += tail.events.count
            if feed.events.count + tail.events.count > maxEventsPerFetch + maxEventsPerFetch / 10 {
                requestReload()
                return
            }
            feed.merge(tail.events)
            follow.appended(tail.events.count)
        } catch {
            print("LogFeedViewModel.fetchTail: \(error)")
        }
    }

    /// Resume the live feed. Identical to setting `isPaused = false`;
    /// kept as a named action so the UI (pill click) reads cleanly.
    func resume() {
        isPaused = false
        // didSet on isPaused handles following + catching up.
    }

    /// The "N new ↓" pill: unpause, follow, and go to the newest row.
    func jumpToLatest() {
        isPaused = false
        follow.resume()
        latestScrollToken = UUID()
    }

    /// Reported by the table on user scrolls. Reaching the bottom
    /// resumes following; leaving it stops. An explicit pause holds.
    func userScrolled(atBottom: Bool) {
        guard !isPaused, atBottom != follow.isFollowing else { return }
        follow.scrolled(atBottom: atBottom)
    }

    // MARK: - Selection across reloads

    /// Put back the selection from before a filter change, on whichever
    /// rows now show those events, and bring the first into view.
    private func restoreSelection() {
        guard let previous = selectionToRestore else { return }
        selectionToRestore = nil
        let kept = Set(previous.compactMap { feed.rowId(for: $0) })
        selectedEventIds = kept
        if let first = kept.compactMap({ feed.rowIndex(ofRow: $0) }).min() {
            follow.stop()
            scrollTarget = (feed.rows[first].id, UUID())
        }
    }

    /// Drop the filter and land on `eventId` among its neighbours. Clear
    /// stays in force unless it hides the event itself.
    func showInContext(_ eventId: EventRecord.ID) {
        var unfiltered = Filter.none
        if let hidden = filter.hiddenThroughEventId, eventId > hidden {
            unfiltered.hiddenThroughEventId = hidden
        }
        guard unfiltered != filter else {
            Task { await jumpTo(eventId: eventId) }
            return
        }
        selectedEventIds = [eventId]
        filter = unfiltered
    }

    // MARK: - Filter carried across sessions

    private static let rememberedFilterKey = "logFeed.lastFilter"

    /// The filter last used, for the first session after a launch.
    static func rememberedFilter() -> Filter {
        UserDefaults.standard.data(forKey: rememberedFilterKey).flatMap(Filter.restore) ?? .none
    }

    private static func remember(_ filter: Filter) {
        UserDefaults.standard.set(filter.carriedOver.stored, forKey: rememberedFilterKey)
    }

    // MARK: - Copy, search focus, Δ

    /// The rows as clipboard lines, in table order.
    func logLines(for rowIds: Set<EventRecord.ID>) -> String {
        rowIds.compactMap { feed.rowIndex(ofRow: $0) }
            .sorted()
            .map { feed.rows[$0].event.logLine }
            .joined(separator: "\n")
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    /// Milliseconds from the selected row to `row`, or with nothing
    /// selected from the row above it. `nil` for the first row.
    func timeDelta(for row: FeedRow) -> Int64? {
        let reference: FeedRow
        if let selected = selectedEventId, let index = feed.rowIndex(ofRow: selected) {
            reference = feed.rows[index]
        } else {
            guard let index = feed.rowIndex(ofRow: row.id), index > 0 else { return nil }
            reference = feed.rows[index - 1]
        }
        return Int64(row.event.timestampMillis) - Int64(reference.event.timestampMillis)
    }

    // MARK: - Clearing the view

    /// True while "Clear" is hiding a stretch of the session.
    var isViewCleared: Bool { filter.hiddenThroughEventId != nil }

    /// Hide everything currently in the session and start fresh from the
    /// next event. Nothing is deleted — the events keep their bookmarks
    /// and come back via `restoreClearedView()` or an Export with the
    /// filter cleared.
    func clearView() async {
        // `try?` flattens the double optional, which suits us: a throw
        // and an empty session both mean "nothing to hide".
        guard let latest = try? await store.latestEventId(sessionId: sessionId) else {
            return
        }
        selectedEventId = nil
        filter.hiddenThroughEventId = latest
    }

    func restoreClearedView() {
        filter.hiddenThroughEventId = nil
    }

    // MARK: - Keyboard row navigation

    /// `j` / `k` walk the rows as displayed, so a collapsed group counts
    /// once — the same unit the user is looking at.
    func selectNextRow() { moveSelection(by: 1) }
    func selectPreviousRow() { moveSelection(by: -1) }

    /// `e` / `⇧E`: the next / previous error row. Doesn't wrap.
    func selectNextError() { stepError(forward: true) }
    func selectPreviousError() { stepError(forward: false) }

    private func moveSelection(by delta: Int) {
        let rows = collapsedRows
        guard !rows.isEmpty else { return }
        guard let current = selectedEventId,
              let index = feed.rowIndex(ofRow: current)
        else {
            // Nothing selected yet: enter from the end you came from.
            select(rowAt: delta > 0 ? 0 : rows.count - 1)
            return
        }
        let next = index + delta
        guard rows.indices.contains(next) else { return }
        select(rowAt: next)
    }

    private func stepError(forward: Bool) {
        let current = selectedEventId.flatMap { feed.rowIndex(ofRow: $0) }
        guard let index = feed.rowIndex(after: current, forward: forward,
                                         where: { $0.event.level == .error })
        else { return }
        select(rowAt: index)
    }

    /// Select and reveal a row. Anywhere but the last row takes the view
    /// off the tail, so the next append doesn't scroll it away.
    private func select(rowAt index: Int) {
        let id = feed.rows[index].id
        if index != feed.rows.count - 1 { follow.stop() }
        selectedEventId = id
        scrollTarget = (id, UUID())
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

    /// Jump to the event whose **time-of-day** is closest to
    /// `target`'s time-of-day, respecting the active filter. The
    /// calendar date in `target` is ignored — the store query matches
    /// on `timestamp_ms % 86_400_000` so a typed `12:13:42` lands on
    /// any event near 12:13:42 regardless of which day it occurred
    /// (live session today, imported session from last month — same
    /// behavior). Wraps around midnight.
    ///
    /// Stops following the tail so the jump isn't immediately undone
    /// by tail-scroll. See D27.
    func jumpToTime(_ target: Date) {
        // Compute UTC milliseconds since UTC midnight. The user typed
        // a local time, the popover built a Date by combining that
        // with today's date in the local calendar, so the resulting
        // absolute UTC ms %% 86400000 = "what UTC time-of-day matches
        // the local time-of-day the user meant".
        let totalMs = Int64(target.timeIntervalSince1970 * 1000)
        let dayMs: Int64 = 86_400_000
        var targetMod = totalMs % dayMs
        if targetMod < 0 { targetMod += dayMs }  // tolerate pre-1970 Dates

        Task { [weak self, targetMod] in
            guard let self else { return }
            do {
                guard let id = try await store.nearestEventId(
                    sessionId: sessionId,
                    targetMillisSinceMidnight: targetMod,
                    filter: filter
                ) else { return }
                await jumpTo(eventId: id)
            } catch {
                print("jumpToTime: \(error)")
            }
        }
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
    // MARK: - Subsystem / category chips

    func values(for facet: Filter.Facet) -> [FacetCount] {
        switch facet {
        case .subsystem: availableSubsystems
        case .category:  availableCategories
        }
    }

    /// One click advances include → exclude → off; the `filter` didSet
    /// reloads the page.
    func cycleChip(_ value: String, in facet: Filter.Facet) {
        guard !value.isEmpty else { return }
        filter.cycle(value, in: facet)
    }

    func setChip(_ state: Filter.ChipState, for value: String, in facet: Filter.Facet) {
        guard !value.isEmpty else { return }
        filter.set(state, for: value, in: facet)
    }

    /// Called when a chip menu opens, so its counts are current.
    func refreshFacets() {
        scheduleFacetRefresh(after: .zero)
    }

    /// Debounced: typing and fast streams coalesce into one GROUP BY pass
    /// per facet, run off the main actor by the store. No-op while no
    /// popover is open to show the result — see `facetPopoverOpen`.
    private func scheduleFacetRefresh(after delay: Duration) {
        guard facetPopoverOpen > 0 else { return }
        facetTask?.cancel()
        facetGeneration &+= 1
        let generation = facetGeneration
        facetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.facetTask = nil
            await self.reloadFacetValues(generation: generation)
        }
    }

    /// `generation` is `nil` for the one direct, unthrottled caller
    /// (`.cleared`) — that always runs. A generation from
    /// `scheduleFacetRefresh` is checked *before* the queries are issued,
    /// not just after: a cancelled `Task` still runs its SQL to
    /// completion once GRDB's queue gets to it (same reasoning as
    /// `isCurrentReload`).
    private func reloadFacetValues(generation: UInt64? = nil) async {
        if let generation, generation != facetGeneration { return }
        let filter = self.filter
        do {
            async let subsystems = store.facetCounts(sessionId: sessionId, facet: .subsystem, filter: filter)
            async let categories = store.facetCounts(sessionId: sessionId, facet: .category, filter: filter)
            let (newSubsystems, newCategories) = try await (subsystems, categories)
            // A newer filter or a newer scheduled refresh has its own
            // pass queued; don't flash stale counts.
            if let generation, generation != facetGeneration { return }
            guard filter == self.filter else { return }
            availableSubsystems = newSubsystems
            availableCategories = newCategories
        } catch is CancellationError {
            // Expected when a newer refresh supersedes this one.
        } catch {
            print("reloadFacetValues: \(error)")
        }
    }

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

    /// Step to the next matching event (wraps). Stops following so the
    /// jump isn't immediately undone by tail-scroll.
    func nextMatch() { stepMatch(by: 1) }
    func previousMatch() { stepMatch(by: -1) }

    /// Move to the next match that has a row of its own.
    ///
    /// Collapse folds a run of identical events into a single row, so a
    /// long `×20` group can hold twenty matches that all resolve to the
    /// same row. Landing on each in turn leaves the table motionless and
    /// the button looking broken, so those are walked past. The counter
    /// still reports every match — it just skips ahead.
    private func stepMatch(by delta: Int) {
        guard !matchIds.isEmpty else { return }
        let count = matchIds.count
        let currentRow = selectedEventId
        var index = currentMatchIndex ?? (delta > 0 ? -1 : 0)

        for _ in 0..<count {
            index = ((index + delta) % count + count) % count
            let candidate = matchIds[index]
            // An indexed lookup — walking a ×1000 group of matches
            // used to rescan the page per candidate.
            guard displayedRowId(for: candidate) != currentRow else { continue }
            currentMatchIndex = index
            Task { await jumpTo(eventId: candidate) }
            return
        }
        // Every match folds into the row already selected.
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

    /// Select `eventId` and scroll the table to the row showing it.
    ///
    /// `page` already holds the whole filtered session, so there is
    /// normally nothing to fetch; it reloads only when the event isn't
    /// there yet (a filter change just emptied the page, or the event
    /// arrived while paused).
    private func jumpTo(eventId: Int64) async {
        // Off the tail first, so incoming events don't scroll us off the
        // match. (This used to pause; appends are cheap tails now and no
        // longer supersede the reload below.)
        follow.stop()
        if !feed.contains(eventId: eventId) {
            await reload()
        }
        // Resolved after the reload, because `page` has to hold the
        // target before its displaying row can be found.
        let rowId = displayedRowId(for: eventId)
        scrollTarget = (rowId, UUID())
        selectedEventId = rowId
    }
}
