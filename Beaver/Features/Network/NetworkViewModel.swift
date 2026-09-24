//
//  NetworkViewModel.swift
//  Beaver
//

import Foundation
import Observation

@MainActor
@Observable
final class NetworkViewModel {
    let sessionId: Int64
    private let store: LogStore

    private(set) var entries: [NetworkEntry] = [] {
        didSet { bookmarkCount = entries.count { bookmarkedIds.contains($0.id) } }
    }
    /// A search edit waits `searchDebounce` before re-filtering, so typing
    /// doesn't scan every body on each keystroke; other changes apply at once.
    var filter = NetworkFilter() {
        didSet {
            guard filter != oldValue else { return }
            var unsearched = filter; unsearched.search = oldValue.search
            if unsearched == oldValue { scheduleSearch() } else { recompute() }
        }
    }
    var selection: NetworkEntry.ID?

    /// While paused new requests are stored but not loaded; `pendingCount`
    /// is how many arrived meanwhile.
    private(set) var isPaused = false
    private(set) var pendingCount = 0

    private(set) var bookmarkedIds: Set<Int64> = [] {
        didSet {
            bookmarkCount = entries.count { bookmarkedIds.contains($0.id) }
            if showOnlyBookmarked { recompute() }
        }
    }
    private(set) var bookmarkCount = 0
    var showOnlyBookmarked = false { didSet { if showOnlyBookmarked != oldValue { recompute() } } }

    /// The table's column sort; empty keeps arrival order. In memory
    /// only: a `KeyPathComparator` isn't Codable for `@AppStorage`.
    var sortOrder: [KeyPathComparator<NetworkEntry>] = [] {
        didSet { if sortOrder != oldValue { recompute() } }
    }

    /// What the table shows (filtered, then sorted), and its results bar. Stored, not computed:
    /// rebuilt only when the filter, bookmarks or entries change, and on
    /// append only the new rows are filtered — never on a render.
    private(set) var filtered: [NetworkEntry] = []
    private(set) var stats = NetworkStats([])

    /// After Clear and bookmarks-only, before the filter: what the
    /// Method / Status / Host dropdowns count (only while one is open).
    var base: [NetworkEntry] {
        showOnlyBookmarked ? entries.filter { bookmarkedIds.contains($0.id) } : entries
    }
    /// The selected entry, but only while it is on screen: a filter, search
    /// or bookmarks-only that hides it also empties the detail pane, instead
    /// of showing a request the table no longer lists.
    var selected: NetworkEntry? {
        guard let id = selection else { return nil }
        return filtered.first { $0.id == id }
    }

    private static let searchDebounce = Duration.milliseconds(150)
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// See StoragesViewModel.subscription for why this is nonisolated(unsafe).
    private nonisolated(unsafe) var subscription: Task<Void, Never>?

    /// Highest `id` loaded so far. NOT `entries.last?.id`: the very
    /// first `loadNew()` from bootstrap can race the subscription's
    /// own `loadNew()` call, so the last element appended isn't
    /// necessarily the max id loaded. Tracking the max explicitly
    /// avoids that.
    @ObservationIgnored
    private var maxLoadedId: Int64 = 0

    init(store: LogStore, sessionId: Int64) {
        self.store = store
        self.sessionId = sessionId
    }

    deinit { subscription?.cancel() }

    /// Subscribe first, then load. Same race as StoragesViewModel.bootstrap().
    func bootstrap() async {
        let stream = await store.changes()
        subscription = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                switch change {
                case .networkAppended(let sid) where sid == self.sessionId:
                    // One broadcast per stored request, so this counts them.
                    if self.isPaused { self.pendingCount += 1 } else { await self.loadNew() }
                case .networkBookmarksChanged(let sid) where sid == self.sessionId:
                    await self.loadBookmarks()
                case .cleared(let sid) where sid == self.sessionId:
                    self.entries = []
                    self.recompute()
                    self.selection = nil
                    self.maxLoadedId = 0
                    self.pendingCount = 0
                    self.bookmarkedIds = []
                default:
                    break
                }
            }
        }
        await loadNew()
        await loadBookmarks()
    }

    /// Hides everything loaded so far, like the toolbar Clear: nothing is
    /// deleted, and requests that arrive later still show. `maxLoadedId`
    /// is the watermark — `loadNew()` only reads past it. Reopening the
    /// session (a new VM) shows everything again.
    func clear() {
        entries = []
        recompute()
        selection = nil
    }

    func togglePause() {
        isPaused.toggle()
        guard !isPaused else { return }
        pendingCount = 0
        Task { await loadNew() }
    }

    /// The payload as received, for Copy JSON; entries keep only the
    /// parsed fields.
    func payloadJSON(_ id: NetworkEntry.ID) async -> String? {
        try? await store.networkPayload(id: id)
    }

    func isBookmarked(_ id: NetworkEntry.ID) -> Bool { bookmarkedIds.contains(id) }

    /// The store broadcasts `.networkBookmarksChanged`, which reloads the set.
    func toggleBookmark(_ id: NetworkEntry.ID) {
        Task { try? await store.toggleNetworkBookmark(entryId: id, sessionId: sessionId) }
    }

    private func loadBookmarks() async {
        bookmarkedIds = (try? await store.networkBookmarkIds(sessionId: sessionId)) ?? []
    }

    /// Only rows after the last loaded id, so a burst of requests doesn't
    /// re-read the whole session each time.
    private func loadNew() async {
        let fresh = (try? await store.networkEntries(sessionId: sessionId,
                                                     afterId: maxLoadedId)) ?? []
        let newOnes = fresh.filter { $0.id > maxLoadedId }
        guard !newOnes.isEmpty else { return }
        entries.append(contentsOf: newOnes)
        maxLoadedId = max(maxLoadedId, newOnes.map(\.id).max() ?? 0)
        let shown = newOnes.filter(isShown)
        guard !shown.isEmpty else { return }
        filtered = sortOrder.isEmpty ? filtered + shown : NetworkEntry.sorted(filtered + shown, using: sortOrder)
        stats = NetworkStats(filtered)
    }

    private func isShown(_ e: NetworkEntry) -> Bool {
        (!showOnlyBookmarked || bookmarkedIds.contains(e.id)) && filter.matches(e)
    }

    private func recompute() {
        searchTask?.cancel()
        let shown = filter.isEmpty && !showOnlyBookmarked ? entries : entries.filter(isShown)
        filtered = NetworkEntry.sorted(shown, using: sortOrder)
        stats = NetworkStats(filtered)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }
}
