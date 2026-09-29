//
//  IssuesViewModel.swift
//  Beaver
//

import Foundation
import Observation

/// The viewed session's issues (D95). Owned by `MainWindow` like the other
/// per-session models, so the sidebar badge and the Log feed's ⚠ chip
/// read it whichever tab shows. While the session is live it re-reads at
/// most once a second — longer if the query itself takes long.
@Observable
@MainActor
final class IssuesViewModel {
    let store: LogStore
    let sessionId: Int64

    private(set) var report: Issues.Report = .empty
    private(set) var loaded = false
    /// Signatures that appeared since the first load, highlighted briefly.
    private(set) var fresh: Set<String> = []

    /// Error only, else warnings and errors. Remembered across sessions.
    var errorsOnly = UserDefaults.standard.bool(forKey: "issues.errorsOnly") {
        didSet {
            UserDefaults.standard.set(errorsOnly, forKey: "issues.errorsOnly")
            fresh = []
            loaded = false
            // Now, not throttled: the person is waiting on it.
            Task { await refreshNow() }
        }
    }
    var sort: Issues.Sort = .newest
    var showIgnored = false

    var minLevel: LogLevel { errorsOnly ? .error : .warning }
    var rows: [Issues.Group] { sort.sorted(showIgnored ? report.groups : report.shown) }
    var ignoredCount: Int { report.groups.count - report.shown.count }

    private nonisolated(unsafe) var subscription: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var lastQuery: Duration = .zero

    init(store: LogStore, sessionId: Int64) {
        self.store = store
        self.sessionId = sessionId
        subscription = Task { [weak self, store] in
            let stream = await store.changes()
            await self?.refreshNow()
            for await change in stream {
                guard let self else { return }
                switch change {
                case .appended(let sid, _) where sid == self.sessionId: self.refresh()
                case .cleared(let sid) where sid == self.sessionId: self.refresh()
                // The app's name can arrive after the events; ignores follow it.
                case .sessionUpdated(let s) where s.id == self.sessionId: self.refresh()
                case .ignoredIssuesChanged: self.refresh()
                default: break
                }
            }
        }
    }

    deinit { subscription?.cancel() }

    /// Throttled, not debounced: a steady stream still updates each second.
    func refresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.refreshPending = false
                await self.refreshNow()
                try? await Task.sleep(for: max(.seconds(1), self.lastQuery * 4))
                guard self.refreshPending else { break }
            }
            self?.refreshTask = nil
        }
    }

    private func refreshNow() async {
        let level = minLevel
        let start = ContinuousClock.now
        guard let new = try? await store.issues(sessionId: sessionId, minLevel: level), level == minLevel else { return }
        lastQuery = ContinuousClock.now - start
        if loaded {
            let known = Set(report.groups.map(\.signature))
            let added = Set(new.groups.map(\.signature)).subtracting(known)
            if !added.isEmpty {
                fresh.formUnion(added)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.fresh.subtract(added)
                }
            }
        }
        report = new
        loaded = true
    }

    func setIgnored(_ ignored: Bool, _ group: Issues.Group) async throws {
        try await store.setIssueIgnored(ignored, subsystem: group.subsystem, pattern: group.pattern, sessionId: sessionId)
    }
}
