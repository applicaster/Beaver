//
//  SessionsViewModel.swift
//  LoggerNext
//

import Foundation
import SwiftUI

/// Drives the sessions sidebar. Loads all sessions on appear and refreshes
/// when the store broadcasts session lifecycle changes. Selection feeds
/// back into `AppEnvironment.viewingSessionId` so the LogFeed switches.
@Observable
@MainActor
final class SessionsViewModel {

    /// All sessions, newest first.
    private(set) var sessions: [SessionListItem] = []

    private let store: LogStore

    /// Marked `nonisolated(unsafe)` so the nonisolated `deinit` can
    /// cancel it. Task<Void, Never> is Sendable; the property is only
    /// written from `@MainActor` init/subscribe, and read once from
    /// deinit after all other references are gone — no concurrent
    /// access is possible.
    private nonisolated(unsafe) var subscription: Task<Void, Never>?

    init(store: LogStore) {
        self.store = store
        Task { await self.reload() }
        Task { await self.subscribe() }
    }

    deinit {
        subscription?.cancel()
    }

    func reload() async {
        do {
            let raw = try await store.sessions()
            var items: [SessionListItem] = []
            for s in raw {
                let count = try await store.eventCount(
                    sessionId: s.id,
                    filter: .none
                )
                items.append(SessionListItem(session: s, eventCount: count))
            }
            self.sessions = items
        } catch {
            print("SessionsViewModel.reload: \(error)")
        }
    }

    private func subscribe() async {
        let stream = await store.changes()
        subscription = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                switch change {
                case .sessionStarted, .sessionEnded:
                    await self.reload()
                case .appended, .cleared:
                    // Counts change; refresh in a debounced way later.
                    // For now, do nothing — counts are recomputed on
                    // next `reload()`.
                    break
                case .storageUpdated, .bookmarksChanged:
                    break
                }
            }
        }
    }
}

/// Row data for the sessions list.
struct SessionListItem: Identifiable, Hashable {
    let session: Session
    let eventCount: Int

    var id: Int64 { session.id }

    var title: String {
        if let label = session.clientLabel { return label }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: session.startedAt)
    }

    var subtitle: String {
        let countStr = eventCount == 1 ? "1 event" : "\(eventCount) events"
        switch session.source {
        case .live where session.endedAt == nil:
            return "Live · \(countStr)"
        case .live:
            return "Ended · \(countStr)"
        case .imported:
            return "Imported · \(countStr)"
        }
    }

    var iconName: String {
        switch session.source {
        case .live where session.endedAt == nil:
            return "wifi"
        case .live:
            return "wifi.slash"
        case .imported:
            return "doc.text"
        }
    }
}
