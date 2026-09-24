//
//  Watches.swift
//  Beaver
//
//  Design M29 (D69): a watch is a start id plus a filter. Counts come from
//  the store when asked; only `notify` needs a task.

import Foundation

public actor Watches {

    public struct Watch: Sendable {
        public let name: String
        public let filter: Filter
        public let filterText: String
        /// Omitted sessionId: also counts the device's later live sessions.
        public let follows: Bool
        public let sessionId: Int64
        public let startId: Int64
        public let startedAt: Date
        /// Tell the person at this many matches (`onFirst` = 1).
        public let notifyAt: Int?
        public var firedAt: Date?
    }

    private var watches: [String: Watch] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init() {}

    /// `true` when it replaced a watch with the same name.
    func add(_ watch: Watch) -> Bool {
        tasks.removeValue(forKey: watch.name)?.cancel()
        let replaced = watches[watch.name] != nil
        watches[watch.name] = watch
        return replaced
    }

    func get(_ name: String) -> Watch? { watches[name] }

    func all() -> [Watch] { watches.values.sorted { $0.startedAt < $1.startedAt || ($0.startedAt == $1.startedAt && $0.name < $1.name) } }

    func remove(_ name: String) -> Watch? {
        tasks.removeValue(forKey: name)?.cancel()
        return watches.removeValue(forKey: name)
    }

    func removeAll() -> [Watch] {
        let gone = all()
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        watches = [:]
        return gone
    }

    func setTask(_ task: Task<Void, Never>, for name: String) { tasks[name] = task }

    /// commands_send's disconnect watcher: one at a time, the latest command wins.
    private var disconnectWatcher: Task<Void, Never>?

    func setDisconnectWatcher(_ task: Task<Void, Never>) {
        disconnectWatcher?.cancel()
        disconnectWatcher = task
    }

    /// `false` when the watch is gone, was replaced (a different
    /// `startedAt` — the caller's stale copy lost the race to `add`), or
    /// already fired.
    func markFired(_ name: String, startedAt: Date, at date: Date) -> Bool {
        guard var watch = watches[name], watch.startedAt == startedAt, watch.firedAt == nil else { return false }
        watch.firedAt = date
        watches[name] = watch
        return true
    }
}

struct WatchStatus: Sendable {
    let watch: Watches.Watch
    let sessions: [Int64]
    let total: Int
    let first: EventRecord?
    let last: EventRecord?
    let levels: [LogLevel: Int]
    let subsystems: [FacetCount]
    let categories: [FacetCount]
}

extension ToolContext {

    static let watchPollInterval: Duration = .milliseconds(500)

    /// The start session after the start id, plus — for a following watch —
    /// every later live session from its first event (session ids grow).
    func segments(of w: Watches.Watch) async throws -> [(sessionId: Int64, afterId: Int64)] {
        var segments = [(sessionId: w.sessionId, afterId: w.startId)]
        if w.follows {
            let later = try await store.sessions().filter { $0.source == .live && $0.id > w.sessionId }
            segments += later.map(\.id).sorted().map { (sessionId: $0, afterId: Int64(0)) }
        }
        return segments
    }

    func status(of w: Watches.Watch) async throws -> WatchStatus {
        let segments = try await segments(of: w)
        var total = 0
        var first: EventRecord?
        var last: EventRecord?
        var levels: [LogLevel: Int] = [:]
        var subsystems: [String: Int] = [:]
        var categories: [String: Int] = [:]
        func counted(_ c: FacetCount, _ facet: Filter.Facet) -> Bool {
            let included = w.filter.included(facet)
            return c.count > 0 && (included.isEmpty || included.contains(c.value))
                && !w.filter.excluded(facet).contains(c.value)
        }
        for s in segments {
            let head = try await store.eventPage(sessionId: s.sessionId, filter: w.filter, afterId: s.afterId,
                                                 limit: 1, newestFirst: false)
            guard head.total > 0 else { continue }
            total += head.total
            if first == nil { first = head.events.first }
            last = try await store.eventPage(sessionId: s.sessionId, filter: w.filter, afterId: s.afterId,
                                             limit: 1, newestFirst: true).events.first
            for (level, n) in try await store.levelCounts(sessionId: s.sessionId, filter: w.filter, afterId: s.afterId)
            where level.severity >= w.filter.minLevel.severity {
                levels[level, default: 0] += n
            }
            for c in try await store.facetCounts(sessionId: s.sessionId, facet: .subsystem, filter: w.filter,
                                                 afterId: s.afterId) where counted(c, .subsystem) {
                subsystems[c.value, default: 0] += c.count
            }
            for c in try await store.facetCounts(sessionId: s.sessionId, facet: .category, filter: w.filter,
                                                 afterId: s.afterId) where counted(c, .category) {
                categories[c.value, default: 0] += c.count
            }
        }
        func sorted(_ d: [String: Int]) -> [FacetCount] {
            d.map { FacetCount(value: $0.key, count: $0.value) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.value < $1.value) }
        }
        return WatchStatus(watch: w, sessions: segments.map(\.sessionId), total: total, first: first, last: last,
                           levels: levels, subsystems: sorted(subsystems), categories: sorted(categories))
    }

    /// Polls until the watch reaches its count, then tells the person: an
    /// attention note in the journal and a notification (design §5.10).
    /// Beaver can't wake the agent (M2); it sees it in watch_status.
    ///
    /// Incremental, since it shares the store's queue with live ingest for
    /// hours: each poll counts only the matches after a per-segment cursor,
    /// and a following watch picks up the device's new live session from the
    /// UI snapshot, not the session list.
    func startNotifyTask(for w: Watches.Watch) -> Task<Void, Never> {
        Task { [self] in
            guard let threshold = w.notifyAt else { return }
            var segments = [WaitSegment(sessionId: w.sessionId, afterId: w.startId)]
            var total = 0
            var first: EventRecord?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchPollInterval)
                guard let current = await watches.get(w.name), current.startedAt == w.startedAt,
                      current.firedAt == nil else { return }
                if w.follows, let live = await ui.snapshot().liveSessionId, live > w.sessionId,
                   !segments.contains(where: { $0.sessionId == live }) {
                    segments.append(WaitSegment(sessionId: live, afterId: 0))
                }
                for (i, s) in segments.enumerated() {
                    // The newest match after the cursor, and how many there are.
                    guard let page = try? await store.eventPage(sessionId: s.sessionId, filter: w.filter,
                                                                afterId: s.afterId, limit: 1, newestFirst: true),
                          let newest = page.events.first else { continue }
                    if first == nil {
                        first = try? await store.eventPage(sessionId: s.sessionId, filter: w.filter,
                                                           afterId: s.afterId, limit: 1, newestFirst: false).events.first
                    }
                    total += page.total
                    segments[i] = WaitSegment(sessionId: s.sessionId, afterId: newest.id)
                }
                guard total >= threshold else { continue }
                // The count awaited the store; a replacing watch_start
                // (or watch_stop) could have landed while it did. `cancel()`
                // doesn't interrupt that await, so re-check both explicitly
                // before publishing what could otherwise be the old watch's
                // count under the new watch's name.
                guard !Task.isCancelled, await watches.markFired(w.name, startedAt: w.startedAt, at: now()) else { return }
                let text = "Watch “\(w.name)”: \(total) match\(total == 1 ? "" : "es") (\(w.filterText))."
                let links = first.map { [JournalLink.event($0.id)] } ?? []
                let outcome = await ui.notify(AgentNote(text: text, links: links))
                await AgentJournal(store: store).post(
                    .note, text, tool: "watch_start", level: AgentActivity.attention, links: links,
                    notice: outcome.notified ? nil : "Not notified: \(outcome.reason ?? "")",
                    sessionId: first?.sessionId)
                return
            }
        }
    }
}
