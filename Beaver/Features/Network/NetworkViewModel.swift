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

    private(set) var entries: [NetworkEntry] = []
    var filter = NetworkFilter()
    var selection: NetworkEntry.ID?

    // ponytail: filters the whole array on every change. Fine for a few
    // thousand requests per session; move to SQL / incremental if a
    // session ever gets much bigger.
    var filtered: [NetworkEntry] { filter.isEmpty ? entries : entries.filter(filter.matches) }
    var selected: NetworkEntry? { selection.flatMap { id in entries.first { $0.id == id } } }
    var allMethods: [String] { Array(Set(entries.map(\.method))).sorted() }
    var allHosts: [String] { Array(Set(entries.map(\.host))).sorted() }

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
                    await self.loadNew()
                case .cleared(let sid) where sid == self.sessionId:
                    self.entries = []
                    self.selection = nil
                    self.maxLoadedId = 0
                default:
                    break
                }
            }
        }
        await loadNew()
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
    }
}
