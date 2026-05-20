//
//  SessionsViewModel.swift
//  Beaver
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
    /// cancel it — `@MainActor` stored properties are unreachable
    /// from deinit's nonisolated context without an escape hatch.
    /// `Task<Void, Never>` is Sendable and the property is only
    /// written from `@MainActor` init/subscribe + read once from
    /// deinit after all other references are gone, so the "unsafe"
    /// is a notational concession, not an actual data race.
    ///
    /// Xcode 26 emits a "'nonisolated(unsafe)' has no effect, consider
    /// using 'nonisolated'" warning here — that suggestion is wrong:
    /// plain `nonisolated` is rejected on mutable stored properties.
    /// The warning is a known compiler false positive; ignore it.
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
                case .sessionStarted, .sessionEnded,
                     .sessionDeleted, .sessionsCleared,
                     .sessionUpdated:
                    // sessionUpdated covers device-info backfills
                    // (see LogStore.harvestDeviceInfo) — refreshing
                    // the list picks up the new app / device labels.
                    await self.reload()
                case .appended, .cleared:
                    // Counts change; refresh in a debounced way later.
                    // For now, do nothing — counts are recomputed on
                    // next `reload()`.
                    break
                case .storageUpdated, .bookmarksChanged, .savedFiltersChanged:
                    break
                }
            }
        }
    }

    // MARK: - Actions

    /// Delete one session. Cascades through events / snapshots /
    /// bookmarks via FK constraints. The subscription path picks up
    /// the broadcast and reloads the list.
    func deleteSession(id: Int64) async {
        do {
            try await store.deleteSession(id: id)
        } catch {
            print("SessionsViewModel.deleteSession(\(id)): \(error)")
        }
    }

    /// Wipe every session. Same cascade story. Used by the
    /// "Delete all sessions" toolbar button.
    func deleteAllSessions() async {
        do {
            try await store.deleteAllSessions()
        } catch {
            print("SessionsViewModel.deleteAllSessions: \(error)")
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

    /// Optional inline "app name + version" used on the top line of
    /// the row when the session has device fingerprint data
    /// captured (see Schema.v3_session_device_info). Returns nil
    /// for older sessions and imports that never logged an
    /// `applicaster.v2` snapshot so the row falls back to the
    /// existing date/label layout.
    var appLabel: String? {
        guard let name = session.appName else { return nil }
        if let v = session.appVersion { return "\(name) \(v)" }
        return name
    }

    /// Optional second muted subtitle line: device + OS.
    var deviceLabel: String? {
        var parts: [String] = []
        if let d = session.deviceModel { parts.append(d) }
        if let os = session.osVersion {
            parts.append((session.platform ?? "OS") + " " + os)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
