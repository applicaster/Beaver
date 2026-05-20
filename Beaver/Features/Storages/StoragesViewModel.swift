//
//  StoragesViewModel.swift
//  Beaver
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

    /// The currently-active storage layer tab (Session / Local /
    /// Keychain). Drives which set of records the outline displays.
    var selectedNamespace: StorageSnapshot.Namespace = .session

    /// Latest snapshot per namespace. Refreshed from the store after
    /// any `.storageUpdated` broadcast for this session.
    private(set) var snapshots: [StorageSnapshot.Namespace: StorageSnapshot] = [:]

    /// Per-record expansion state inside the current storage layer.
    /// Keyed by `"<wireKey>:<recordId>"` so the set survives tab
    /// switches without leaking expand state across layers.
    var expandedRecordKeys: Set<String> = []

    func isExpanded(record: StorageRecord,
                    in namespace: StorageSnapshot.Namespace) -> Bool {
        expandedRecordKeys.contains(expansionKey(record, namespace))
    }

    func toggleExpansion(record: StorageRecord,
                         in namespace: StorageSnapshot.Namespace) {
        let key = expansionKey(record, namespace)
        if expandedRecordKeys.contains(key) {
            expandedRecordKeys.remove(key)
        } else {
            expandedRecordKeys.insert(key)
        }
    }

    private func expansionKey(_ r: StorageRecord,
                              _ ns: StorageSnapshot.Namespace) -> String {
        "\(ns.wireKey):\(r.id)"
    }

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

    /// Marked `nonisolated(unsafe)` so the nonisolated `deinit` can
    /// cancel it. `Task<Void, Never>` is Sendable; written only
    /// from `@MainActor` init/subscribe and read once from deinit
    /// after all other references are gone — the "unsafe" is
    /// notational.
    ///
    /// Xcode 26 emits a "'nonisolated(unsafe)' has no effect,
    /// consider using 'nonisolated'" warning here. Suggestion is
    /// wrong: plain `nonisolated` is rejected on mutable stored
    /// properties. Known compiler false positive; ignore it.
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

    /// Top-level records in a given namespace, sorted alphabetically
    /// by key (NOCASE).
    func records(in namespace: StorageSnapshot.Namespace) -> [StorageRecord] {
        guard let snap = snapshots[namespace] else { return [] }
        return StorageRecord.parseTopLevel(snap.dataJSON)
    }

    /// Records in a namespace narrowed by `searchTerm`. A top-level
    /// record matches if any descendant key or value contains the
    /// term (case-insensitive). Empty search term returns all.
    func filteredRecords(in namespace: StorageSnapshot.Namespace) -> [StorageRecord] {
        let all = records(in: namespace)
        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.lowercased()
        return all.filter { record in
            record.allDescendants().contains { node in
                node.key.lowercased().contains(needle) ||
                (node.valueText?.lowercased().contains(needle) ?? false)
            }
        }
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

    /// Snapshot of "what device + app am I looking at" pulled from
    /// the SDK's well-known metadata namespace. Surfaced as a slim
    /// header at the top of the Storages view so the user can tell
    /// at a glance which build of which app is on the wire.
    ///
    /// All fields are optional — apps that don't write the standard
    /// `applicaster.v2` namespace just don't get a header. Both
    /// camelCase and snake_case variants of the device keys are
    /// checked because the SDK has historically written both.
    struct AppContext: Equatable, Sendable {
        let appName: String?
        let appVersion: String?
        let deviceModel: String?
        let platform: String?
        let osVersion: String?

        /// True if there's anything worth rendering — keeps the
        /// header from showing as an empty bar when the standard
        /// metadata namespace is missing.
        var isNonEmpty: Bool {
            appName != nil || deviceModel != nil ||
                platform != nil || osVersion != nil
        }
    }

    var appContext: AppContext? {
        // Live SDK convention: `applicaster.v2` lives in session
        // storage. If a future SDK moves it, fall back to local or
        // keychain so we still show *something*.
        let order: [StorageSnapshot.Namespace] = [.session, .local, .keychain]
        for layer in order {
            if let ctx = appContext(in: layer), ctx.isNonEmpty {
                return ctx
            }
        }
        return nil
    }

    private func appContext(in layer: StorageSnapshot.Namespace) -> AppContext? {
        guard let snap = snapshots[layer] else { return nil }
        let tops = StorageRecord.parseTopLevel(snap.dataJSON)
        guard let v2 = tops.first(where: { $0.key == "applicaster.v2" }),
              let children = v2.children else { return nil }

        // Tiny closure that resolves a key inside applicaster.v2 to
        // its `valueText`, with multi-key fallback for the device
        // family (camelCase + snake_case).
        func value(_ keys: String...) -> String? {
            for k in keys {
                if let v = children.first(where: { $0.key == k })?.valueText,
                   !v.isEmpty {
                    return v
                }
            }
            return nil
        }

        return AppContext(
            appName:     value("app_name"),
            appVersion:  value("version_name"),
            deviceModel: value("deviceModel", "device_model", "deviceName"),
            platform:    value("platform"),
            osVersion:   value("osVersion")
        )
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
    /// Push a new value into the device's storage. SDK contract
    /// (CommandRegistry):
    ///   storage.<wireKey>.set <key> <value> [namespace]
    /// The trailing `[namespace]` is the SDK's per-storage SUBSCOPE —
    /// e.g., `storage.local.set foo bar applicaster.v2` writes
    /// `foo: bar` inside the `applicaster.v2` subscope. Passing
    /// `parent = nil` writes at the top level.
    ///
    /// After the SDK applies the write it emits a log event back; we
    /// also fire a `storage.list` refresh so the UI picks up the new
    /// state without the user clicking Reload.
    func setValue(
        in namespace: StorageSnapshot.Namespace,
        parent: String? = nil,
        key: String,
        value: String,
        via server: WSServer
    ) {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        let trimmedParentRaw = parent?.trimmingCharacters(in: .whitespaces) ?? ""
        let trimmedParent: String? = trimmedParentRaw.isEmpty ? nil : trimmedParentRaw
        // The SDK's parser is space-separated. Spaces inside `value`
        // get split apart with no quoting — UI surfaces a warning.
        var cmd = "storage.\(namespace.wireKey).set \(trimmedKey) \(value)"
        if let trimmedParent {
            cmd += " \(trimmedParent)"
        }
        Task { [weak self] in
            await server.send(command: cmd)
            try? await Task.sleep(for: .milliseconds(400))
            self?.requestRefresh(via: server)
        }
    }

    /// Remove a key from the device's storage. SDK contract:
    /// `storage.<wireKey>.delete <key> [namespace]`. `parent` maps
    /// to the trailing subscope (nil = top-level).
    func deleteValue(
        in namespace: StorageSnapshot.Namespace,
        parent: String? = nil,
        key: String,
        via server: WSServer
    ) {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return }
        let trimmedParentRaw = parent?.trimmingCharacters(in: .whitespaces) ?? ""
        let trimmedParent: String? = trimmedParentRaw.isEmpty ? nil : trimmedParentRaw
        var cmd = "storage.\(namespace.wireKey).delete \(trimmedKey)"
        if let trimmedParent {
            cmd += " \(trimmedParent)"
        }
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
    /// storage; just clears what Beaver is displaying.
    func clearLocalCache() {
        snapshots.removeAll()
        expandedRecordKeys.removeAll()
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
