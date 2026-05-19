//
//  StoragesViewModel.swift
//  LoggerNext
//

import Foundation

/// Drives the Storages screen for a given session. Holds the latest
/// per-namespace snapshot, the user's selected namespace + record,
/// and orchestrates `storage.list` refreshes.
///
/// Data flow:
/// 1. On init / session switch: pull latest snapshots from the store.
/// 2. Subscribe to `.storageUpdated` change broadcasts; refresh when
///    one matches our session.
/// 3. "Reload" UI action sends `storage.list` to the connected client.
///    The SDK responds with a `storage` message; the existing
///    `handleInbound` path decodes it into the store; the store
///    broadcasts `.storageUpdated`; we re-fetch.
@Observable
@MainActor
final class StoragesViewModel {

    var selectedNamespace: StorageSnapshot.Namespace = .session {
        didSet { selectedRecordId = nil }
    }

    /// Latest snapshot per namespace. Refreshed from the store after
    /// any `.storageUpdated` broadcast for this session.
    private(set) var snapshots: [StorageSnapshot.Namespace: StorageSnapshot] = [:]

    var selectedRecordId: String?

    /// Substring filter applied to the visible records — matches the
    /// top-level row OR any nested descendant by key or value.
    var searchTerm: String = ""

    /// Periodic auto-refresh toggle. When on, the view fires a
    /// `storage.list` every `autoRefreshInterval` seconds via a
    /// `.task` loop that watches this property.
    var autoRefreshEnabled: Bool = false

    /// Seconds between auto-refreshes when enabled.
    var autoRefreshInterval: TimeInterval = 2.0

    let sessionId: Int64
    private let store: LogStore

    /// `nonisolated(unsafe)` so the nonisolated `deinit` can cancel
    /// it. Task<Void, Never> is Sendable; only written from the
    /// `@MainActor` init.
    private nonisolated(unsafe) var subscription: Task<Void, Never>?

    init(store: LogStore, sessionId: Int64) {
        self.store = store
        self.sessionId = sessionId
    }

    deinit {
        subscription?.cancel()
    }

    /// Two-phase init: must be `await`ed before the VM is published.
    ///
    /// The change-stream subscription has to be registered with the
    /// store BEFORE we ask the device for new data, otherwise the
    /// inbound `.storageUpdated` broadcast can race past the
    /// not-yet-listening continuation and leave the UI showing nothing
    /// even after a reload. Keeping `init` synchronous wasn't enough
    /// because `Task { await … }` is unstructured and Swift can
    /// schedule the request Task before the subscription Task ever
    /// reaches its `await store.changes()` call. See
    /// `StoragesView.task(id:)` for the call site.
    func bootstrap() async {
        await subscribeToChanges()
        await reloadFromStore()
    }

    // MARK: - Derived state

    /// Top-level records in the currently-selected namespace, sorted
    /// alphabetically. The table displays these; the detail pane
    /// drills into any one of them.
    var records: [StorageRecord] {
        guard let snap = snapshots[selectedNamespace] else { return [] }
        return StorageRecord.parseTopLevel(snap.dataJSON)
    }

    /// Records narrowed by `searchTerm`. A top-level record matches
    /// if any descendant key or value contains the term (case-
    /// insensitive). Empty search term returns all records.
    var filteredRecords: [StorageRecord] {
        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        let needle = trimmed.lowercased()
        return records.filter { record in
            record.allDescendants().contains { node in
                node.key.lowercased().contains(needle) ||
                (node.valueText?.lowercased().contains(needle) ?? false)
            }
        }
    }

    /// Record currently focused in the detail pane. Looks through
    /// every top-level record and its descendants — selection may
    /// point at any depth via the OutlineGroup in the detail view.
    var selectedRecord: StorageRecord? {
        guard let id = selectedRecordId else { return nil }
        for top in records {
            for record in top.allDescendants() where record.id == id {
                return record
            }
        }
        return nil
    }

    /// Total namespaces present in the latest snapshot set.
    func recordCount(in namespace: StorageSnapshot.Namespace) -> Int {
        guard let snap = snapshots[namespace] else { return 0 }
        return StorageRecord.parseTopLevel(snap.dataJSON).count
    }

    /// True if at least one namespace has data.
    var hasAnyData: Bool {
        !snapshots.isEmpty
    }

    // MARK: - Actions

    /// Send `storage.list` to the device. The response will come back
    /// as a `storage` message and refresh `snapshots` via the change
    /// subscription. No-op if no client is connected (WSServer.send
    /// silently drops in that case).
    ///
    /// Belt-and-braces: in addition to relying on the subscription,
    /// we also reload from the store ourselves a short delay after
    /// sending. The subscription is the primary path (it picks up
    /// updates from ANY source, including auto-refresh from other VMs);
    /// this delayed reload covers the edge case where the broadcast
    /// arrives before the consumer Task has woken up.
    /// Push a new value into the device's storage for the currently
    /// selected namespace. SDK contract (CommandRegistry):
    ///   storage.<wireKey>.set <key> <value> [namespace]
    /// We omit the optional trailing `[namespace]` — it's an
    /// SDK-internal subscope rarely needed during debugging.
    ///
    /// After the SDK applies the write it emits a log event back; we
    /// also fire a `storage.list` refresh so the table picks up the
    /// new state without the user clicking Reload.
    func setValue(
        in namespace: StorageSnapshot.Namespace,
        key: String,
        value: String,
        via server: WSServer
    ) {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        // The SDK's parser is space-separated. Spaces inside `value`
        // would be lost unless we quote — but the SDK doesn't document
        // any quoting rule. Document this limitation in the UI.
        let cmd = "storage.\(namespace.wireKey).set \(trimmedKey) \(value)"
        Task { [weak self] in
            await server.send(command: cmd)
            try? await Task.sleep(for: .milliseconds(400))
            self?.requestRefresh(via: server)
        }
    }

    /// Remove a key from the device's storage for the given namespace.
    /// SDK contract: `storage.<wireKey>.delete <key> [namespace]`.
    /// Refreshes after the command completes (same belt-and-braces
    /// pattern as setValue).
    func deleteValue(
        in namespace: StorageSnapshot.Namespace,
        key: String,
        via server: WSServer
    ) {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        let cmd = "storage.\(namespace.wireKey).delete \(trimmedKey)"
        Task { [weak self] in
            await server.send(command: cmd)
            try? await Task.sleep(for: .milliseconds(400))
            self?.requestRefresh(via: server)
        }
    }

    func requestRefresh(via server: WSServer) {
        Task { [weak self] in
            await server.send(command: "storage.list")
            // 400 ms is a typical SDK round-trip for storage.list;
            // small enough that the user doesn't see staleness, big
            // enough that the SDK has almost certainly answered.
            try? await Task.sleep(for: .milliseconds(400))
            await self?.reloadFromStore()
        }
    }

    /// Wipe local snapshot cache. Doesn't touch the device's actual
    /// storage; just clears what LoggerNext is displaying.
    func clearLocalCache() {
        snapshots.removeAll()
        selectedRecordId = nil
    }

    /// Produce the file payload for the Export button. Includes all
    /// three namespaces in one JSON document, matching the wire
    /// format the SDK sends in a `storage` message — so the file is
    /// re-ingestible later if we add storage import.
    func exportAllAsJSON(pretty: Bool = true) -> Data? {
        var combined: [String: Any] = [:]
        for ns in StorageSnapshot.Namespace.allCases {
            if let snap = snapshots[ns],
               let data = snap.dataJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: []) {
                combined[ns.wireKey] = parsed
            }
        }
        guard !combined.isEmpty else { return nil }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try? JSONSerialization.data(withJSONObject: combined, options: options)
    }

    // MARK: - Loading

    private func reloadFromStore() async {
        var fresh: [StorageSnapshot.Namespace: StorageSnapshot] = [:]
        for ns in StorageSnapshot.Namespace.allCases {
            if let snap = try? await store.latestStorageSnapshot(
                sessionId: sessionId,
                namespace: ns
            ) {
                fresh[ns] = snap
            }
        }
        snapshots = fresh
    }

    private func subscribeToChanges() async {
        let stream = await store.changes()
        subscription = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                switch change {
                case .storageUpdated(let sid, _) where sid == self.sessionId:
                    await self.reloadFromStore()
                case .cleared(let sid) where sid == self.sessionId:
                    // clearEvents() also deletes bookmarks; storage
                    // snapshots survive intentionally so the user can
                    // still inspect device state after a clear.
                    break
                default:
                    break
                }
            }
        }
    }
}
