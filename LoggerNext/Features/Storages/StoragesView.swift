//
//  StoragesView.swift
//  LoggerNext
//

import SwiftUI

/// Storages screen — three colored layer chips (Session / Local /
/// Keychain) at the top, then a flat list of the active layer's
/// namespaces. Each namespace row is expandable: click the chevron
/// (or anywhere on the row) to reveal its inner `key: value` pairs
/// inline. No right-side detail pane — everything's visible inline,
/// and deeper structures can be inspected via copy-as-JSON.
///
/// Per-row affordances (D31):
///   • Namespace (container) row: [copy-as-JSON] [add-key-inside]
///   • Top-level scalar row:      [copy-value]   [delete]
///   • Inner `key: value` row:    [copy-value]   [delete]
struct StoragesView: View {
    /// VM is owned by `MainWindow` (keyed by `viewingSessionId`)
    /// so per-tab state — selected layer, expanded namespaces,
    /// search term, auto-refresh toggle — survives tab switches.
    /// MainWindow renders `ConnectionPlaceholder` instead of this
    /// view when no session is active, so the VM is always
    /// concrete here.
    @Bindable var vm: StoragesViewModel

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        StoragesContent(vm: vm)
            // Refresh from the device whenever the user pops back
            // to this tab — the in-memory snapshot may have gone
            // stale while they were in the Log feed. No-op if no
            // client is connected; `WSServer.send` silently drops
            // in that case and the UI keeps showing whatever's
            // cached on disk.
            //
            // Note: MainWindow already fires the *initial*
            // storage.list when the session is created, so the
            // common "open the app + connect" flow doesn't depend
            // on this.
            .onAppear {
                vm.requestRefresh(via: env.server)
            }
    }
}

// MARK: - Content

private struct StoragesContent: View {
    @Bindable var vm: StoragesViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var showingExporter = false
    @State private var exportDocument: JSONExportDocument?

    // Add / delete sheet state. Each row in the outline owns its
    // namespace, so we carry that along — the action sheet picks the
    // right `storage.<ns>.set/delete` command.

    /// Top-level scalar delete — applies to a value sitting directly
    /// in the layer (no parent subscope). SDK command:
    /// `storage.<ns>.delete <key>`.
    struct DeleteTarget: Identifiable {
        let record: StorageRecord
        let namespace: StorageSnapshot.Namespace
        var id: String { "\(namespace.rawValue):\(record.id)" }
    }

    /// Inner-row delete uses (namespace, parentKey, childKey) — we
    /// don't have a `StorageRecord` reference for these because they
    /// come straight from the row view; only the strings are needed
    /// to build the `storage.<ns>.delete <key> <parentKey>` command.
    struct InnerDeleteTarget: Identifiable {
        let namespace: StorageSnapshot.Namespace
        let parentKey: String
        let childKey: String
        var id: String { "\(namespace.rawValue):\(parentKey):\(childKey)" }
    }

    /// Add-key flow. When pre-filled with `parentKey`, the sheet is
    /// in "add-inside" mode (the SDK's optional 3rd argument carries
    /// the parent's name as a subscope). When `parentKey` is nil,
    /// the sheet is in "add a top-level namespace" mode.
    struct AddKeyContext: Identifiable {
        let namespace: StorageSnapshot.Namespace
        let parentKey: String?
        var id: String { "\(namespace.rawValue):\(parentKey ?? "<root>")" }
    }

    @State private var pendingDelete: DeleteTarget?
    @State private var pendingInnerDelete: InnerDeleteTarget?
    @State private var pendingAdd: AddKeyContext?

    var body: some View {
        VStack(spacing: 0) {
            // Device/app context now lives in the sidebar's top
            // card (see SidebarDeviceCard in MainWindow) so it's
            // visible across every tab instead of just here.

            StoragesTopBar(
                vm: vm,
                onExport: { Task { await prepareExport() } },
                onAddKey: {
                    pendingAdd = AddKeyContext(
                        namespace: vm.selectedNamespace,
                        parentKey: nil
                    )
                }
            )
            Divider()
            StoragesSearchBar(vm: vm)
            Divider()
            // D31: no more right-side detail pane. Every value is
            // visible by expanding the namespace row inline; deeper
            // structures can be inspected by the row's copy-as-JSON
            // button.
            StoragesOutline(
                vm: vm,
                onDelete: { record, namespace in
                    vm.selectedNamespace = namespace
                    pendingDelete = DeleteTarget(record: record, namespace: namespace)
                },
                onAddInside: { record, namespace in
                    vm.selectedNamespace = namespace
                    pendingAdd = AddKeyContext(
                        namespace: namespace,
                        parentKey: record.key
                    )
                },
                onDeleteInside: { namespace, parentKey, childKey in
                    vm.selectedNamespace = namespace
                    pendingInnerDelete = InnerDeleteTarget(
                        namespace: namespace,
                        parentKey: parentKey,
                        childKey: childKey
                    )
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Top-level scalar delete — removes a key sitting directly
        // in the active layer (no subscope). Container namespace
        // rows don't surface a delete at all (the SDK has no way to
        // wipe a whole namespace in one call).
        .confirmationDialog(
            "Delete \"\(pendingDelete?.record.key ?? "")\" from \(pendingDelete?.namespace.displayName ?? "")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { target in
            Button("Delete", role: .destructive) {
                let key = target.record.key
                let ns  = target.namespace
                pendingDelete = nil
                vm.deleteValue(in: ns, key: key, via: env.server)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("The value is removed on the device immediately. Other devices won't see the change until they reconnect.")
        }
        // Inner-row delete confirmation. SDK contract:
        //   storage.<wireKey>.delete <childKey> <parentKey>
        // The trailing `parentKey` is the SDK's subscope, so the
        // delete is scoped to the namespace we expanded.
        .confirmationDialog(
            "Delete \"\(pendingInnerDelete?.childKey ?? "")\" from \(pendingInnerDelete?.parentKey ?? "")?",
            isPresented: Binding(
                get: { pendingInnerDelete != nil },
                set: { if !$0 { pendingInnerDelete = nil } }
            ),
            presenting: pendingInnerDelete
        ) { target in
            Button("Delete", role: .destructive) {
                let ns      = target.namespace
                let parent  = target.parentKey
                let child   = target.childKey
                pendingInnerDelete = nil
                vm.deleteValue(
                    in: ns,
                    parent: parent,
                    key: child,
                    via: env.server
                )
            }
            Button("Cancel", role: .cancel) { pendingInnerDelete = nil }
        } message: { _ in
            Text("Removes one key inside the namespace on the device. The namespace itself stays.")
        }
        // Add-key sheet. Identifiable trigger so the same view powers
        // both top-bar "+ Add key" (parentKey = nil → top-level) and
        // per-row "+ inside namespace" (parentKey = the namespace).
        .sheet(item: $pendingAdd) { ctx in
            AddStorageKeySheet(
                initialNamespace: ctx.namespace,
                initialParent: ctx.parentKey,
                onSave: { namespace, parent, key, value in
                    vm.setValue(
                        in: namespace,
                        parent: parent,
                        key: key,
                        value: value,
                        via: env.server
                    )
                    pendingAdd = nil
                },
                onCancel: { pendingAdd = nil }
            )
        }
        // Periodic auto-refresh loop. Re-fires when the toggle flips
        // or when the user pauses (id covers both transitions).
        .task(id: vm.autoRefreshEnabled) {
            while vm.autoRefreshEnabled {
                try? await Task.sleep(for: .seconds(vm.autoRefreshInterval))
                if Task.isCancelled || !vm.autoRefreshEnabled { return }
                vm.requestRefresh(via: env.server)
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: defaultExportName,
            onCompletion: { _ in exportDocument = nil }
        )
    }

    private var defaultExportName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = .init(identifier: "en_US_POSIX")
        return "loggernext_storages_\(formatter.string(from: Date()))"
    }

    private func prepareExport() async {
        guard let data = vm.exportAllAsJSON() else { return }
        exportDocument = JSONExportDocument(data: data)
        showingExporter = true
    }
}

// MARK: - Top bar

private struct StoragesTopBar: View {
    @Bindable var vm: StoragesViewModel
    @Environment(AppEnvironment.self) private var env
    let onExport: () -> Void
    let onAddKey: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Storage-layer tabs (D30 brings these back). Tapping a
            // chip switches the layer below. The outline that follows
            // shows only this layer's top-level keys ("namespaces").
            HStack(spacing: 6) {
                ForEach(StorageSnapshot.Namespace.allCases, id: \.self) { ns in
                    NamespaceTab(
                        namespace: ns,
                        isSelected: vm.selectedNamespace == ns,
                        count: vm.recordCount(in: ns)
                    ) {
                        vm.selectedNamespace = ns
                    }
                }
            }
            .fixedSize()

            // Editing affordances only make sense when the viewed
            // session IS the live session — for a past session the
            // device that recorded it is gone, so add / reload /
            // auto-refresh are no-ops. Hide them entirely rather
            // than presenting them as disabled-tease.
            if isViewingLiveSession {
                // "+ Add key" — adds a top-level key in the current layer.
                Button(action: onAddKey) {
                    Label("Add key", systemImage: "plus.circle")
                }
                .disabled(!isClientConnected)
                .help(isClientConnected
                      ? "Add a top-level key in the current layer"
                      : "Reconnect the device to add a key")
            }

            Spacer()

            if isViewingLiveSession {
                Toggle(isOn: $vm.autoRefreshEnabled) {
                    Label("Auto-refresh", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .disabled(!isClientConnected)
                .help(isClientConnected
                      ? "Re-fetch every \(Int(vm.autoRefreshInterval))s"
                      : "Reconnect the device to enable auto-refresh")

                Button {
                    vm.requestRefresh(via: env.server)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(!isClientConnected)
                .help(isClientConnected
                      ? "Re-fetch the device's storage snapshot now"
                      : "Reconnect the device to refresh")
            }

            Button {
                onExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!vm.hasAnyData)
            .help("Save all three namespaces to a JSON file")

            Button(role: .destructive) {
                vm.clearLocalCache()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .disabled(!vm.hasAnyData)
            .help("Clear the local snapshot cache (doesn't touch the device)")
        }
        .padding(.horizontal, 12)
        // Explicit 48pt so this bar lines up with LogFeedFilterBar.
        // The bigger namespace tabs (D32 polish) still fit
        // comfortably; shorter controls sit centered in the frame.
        .frame(height: 48)
    }

    private var isClientConnected: Bool {
        if case .clientConnected = env.serverState { return true }
        return false
    }

    /// True only when the session this view is bound to is the same
    /// session the WebSocket is currently feeding live. False for
    /// past sessions even if a new device has connected since.
    /// Drives whether device-editing affordances render at all.
    private var isViewingLiveSession: Bool {
        env.currentSessionId == vm.sessionId
    }
}

/// Search bar above the table. Matches a top-level row if any
/// descendant key or value contains the term.
private struct StoragesSearchBar: View {
    @Bindable var vm: StoragesViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search keys and values…", text: $vm.searchTerm)
                .textFieldStyle(.plain)
            if !vm.searchTerm.isEmpty {
                Button {
                    vm.searchTerm = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separatorColor), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Outline (single layer, expandable namespaces)

/// Shows the top-level "namespace" rows for the currently-selected
/// storage layer (Session / Local / Keychain). Each row is
/// expandable: click the chevron to reveal the namespace's one-level
/// children as inline `key: value` rows.
///
/// Per-row actions (D31):
///   • Namespace (container) row: copy-all-as-JSON + add-key-inside
///     — no delete (SDK can't wipe an entire namespace in one call)
///   • Namespace (scalar)    row: copy-value + delete
///   • Inner key/value row:        copy-value + delete-inside-namespace
private struct StoragesOutline: View {
    @Bindable var vm: StoragesViewModel
    @Environment(AppEnvironment.self) private var env
    let onDelete: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onAddInside: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onDeleteInside: (
        _ namespace: StorageSnapshot.Namespace,
        _ parentKey: String,
        _ childKey: String
    ) -> Void

    private var records: [StorageRecord] {
        vm.filteredRecords(in: vm.selectedNamespace)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if records.isEmpty {
                    emptyState
                } else {
                    ForEach(records) { record in
                        NamespaceRow(
                            vm: vm,
                            namespace: vm.selectedNamespace,
                            record: record,
                            onDelete: onDelete,
                            onAddInside: onAddInside,
                            onDeleteInside: onDeleteInside
                        )
                        Divider().opacity(0.3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmed = vm.searchTerm.trimmingCharacters(in: .whitespaces)
        let message: String
        if !trimmed.isEmpty {
            message = "No keys or values match \"\(trimmed)\"."
        } else if env.currentSessionId == vm.sessionId {
            // Live session, no snapshot yet → user can fetch.
            message = "No \(vm.selectedNamespace.displayName.lowercased()) data. Click Reload to fetch from the device."
        } else {
            // Past session with no captured snapshot for this
            // layer. Reload won't do anything (the device that
            // recorded this session is gone), so don't promise it.
            message = "No \(vm.selectedNamespace.displayName.lowercased()) data was captured during this session."
        }
        ContentUnavailableView(
            "Nothing to show",
            systemImage: trimmed.isEmpty ? "tray" : "magnifyingglass",
            description: Text(message)
        )
        // Parent LazyVStack uses `.leading` alignment which would
        // pin this content to the left. `.frame(maxWidth: .infinity)`
        // restores the center alignment ContentUnavailableView
        // assumes.
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}

// MARK: - Layer tab chip (Session / Local / Keychain)

private struct NamespaceTab: View {
    let namespace: StorageSnapshot.Namespace
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    @State private var isHovered = false

    private var color: Color {
        switch namespace {
        case .session:  .blue
        case .local:    .purple
        case .keychain: .green
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(namespace.displayName.uppercased())
                    .font(.subheadline.weight(.semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSelected
                                           ? Color.white.opacity(0.25)
                                           : color.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : color)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? color
                          : (isHovered ? color.opacity(0.12) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color.opacity(isSelected ? 0 : 0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Namespace row (top-level key in the current layer)

/// One row in the outline. Renders the namespace's name + a tail of
/// action icons; if it's expanded, its one-level inner key/value
/// children render directly underneath, indented.
private struct NamespaceRow: View {
    @Bindable var vm: StoragesViewModel
    let namespace: StorageSnapshot.Namespace
    let record: StorageRecord
    let onDelete: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onAddInside: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onDeleteInside: (
        _ namespace: StorageSnapshot.Namespace,
        _ parentKey: String,
        _ childKey: String
    ) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var isHovered = false

    private var isExpanded: Bool {
        vm.isExpanded(record: record, in: namespace)
    }

    private var isClientConnected: Bool {
        if case .clientConnected = env.serverState { return true }
        return false
    }

    /// Editing affordances only render when the viewed session is
    /// the same one the device is currently streaming — for past
    /// sessions, add / delete have no live target so we hide them
    /// rather than show non-functional buttons.
    private var isViewingLiveSession: Bool {
        env.currentSessionId == vm.sessionId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, let children = record.children, !children.isEmpty {
                // Index is threaded through for zebra striping —
                // every other row gets a subtle background so the
                // eye can lock onto key:value pairs in long lists.
                ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                    InnerKeyRow(
                        namespace: namespace,
                        parent: record,
                        child: child,
                        isClientConnected: isClientConnected,
                        isLiveSession: isViewingLiveSession,
                        rowIndex: idx,
                        onCopy: { copyValue(of: child) },
                        onDelete: {
                            onDeleteInside(namespace, record.key, child.key)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            chevron
            VStack(alignment: .leading, spacing: 1) {
                Text(record.key)
                    .font(.body.weight(.medium))
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Whole row toggles expansion on container rows; scalars
        // can't expand, so the tap is a no-op there.
        .onTapGesture {
            if record.isContainer {
                vm.toggleExpansion(record: record, in: namespace)
            }
        }
        // Right-click: power-user shortcuts. The toolbar copy
        // icon copies the *contents*; this menu surfaces the
        // less-common "I just want the key name" path.
        .contextMenu {
            Button {
                copyKeyName()
            } label: {
                Label("Copy name", systemImage: "textformat")
            }
            if record.isContainer {
                Button {
                    copyNamespaceContents()
                } label: {
                    Label("Copy as JSON", systemImage: "curlybraces")
                }
            } else {
                Button {
                    copyScalarValue()
                } label: {
                    Label("Copy value", systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if record.isContainer {
            Button {
                vm.toggleExpansion(record: record, in: namespace)
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // Reserve the same gutter so scalar / container rows align.
            Color.clear.frame(width: 14, height: 14)
        }
    }

    private var summaryLine: String {
        if let valueText = record.valueText {
            return valueText
        }
        if record.isContainer {
            return record.itemCount == 1 ? "1 key" : "\(record.itemCount) keys"
        }
        return ""
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            // Copy is always available — works without a device.
            // Container rows copy the full subtree as JSON; scalar
            // rows copy the raw value.
            Button(action: { copyNamespaceContents() }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(record.isContainer
                  ? "Copy all keys inside as JSON"
                  : "Copy this value")

            // Editing affordances (add / delete) hidden for past
            // sessions — the device that recorded the session is
            // gone, so writes would silently fail.
            if isViewingLiveSession {
                if record.isContainer {
                    // Containers (namespaces) — only [add]. No delete
                    // because the SDK has no command to remove an
                    // entire namespace; the user has to delete its
                    // inner keys one by one via the InnerKeyRow trash.
                    Button {
                        onAddInside(record, namespace)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isClientConnected)
                    .help(isClientConnected
                          ? "Add a key inside \(record.key)"
                          : "Reconnect the device to add a key")
                } else {
                    // Scalar top-level key — straight delete, no
                    // subscope. SDK: `storage.<ns>.delete <key>`.
                    Button(role: .destructive) {
                        onDelete(record, namespace)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isClientConnected)
                    .help(isClientConnected
                          ? "Delete this top-level key"
                          : "Reconnect the device to delete")
                }
            }
        }
        .opacity(isHovered ? 1 : 0.55)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isHovered {
            Color.secondary.opacity(0.08)
        } else {
            Color.clear
        }
    }

    private func copyNamespaceContents() {
        let payload = StorageRecord.serializeJSON(record)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        toasts.success(record.isContainer
                       ? "Copied \(record.key) as JSON"
                       : "Copied value")
    }

    private func copyValue(of child: StorageRecord) {
        let payload: String
        switch child.kind {
        case .string(let s): payload = s
        case .number(let n): payload = n
        case .bool(let b):   payload = b ? "true" : "false"
        case .null:          payload = "null"
        case .object, .array:
            payload = StorageRecord.serializeJSON(child)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        toasts.success("Copied \(child.key)")
    }

    /// Just the namespace's key text — `"applicaster.v2"`, no
    /// surrounding JSON. Used by the right-click "Copy name" menu
    /// so the user can paste the namespace name into a query, a
    /// bug report, an SDK command, etc.
    private func copyKeyName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.key, forType: .string)
        toasts.success("Copied name")
    }

    /// Raw scalar payload (no JSON quoting). Mirrors `copyValue` but
    /// for the namespace row itself when it happens to be a scalar.
    private func copyScalarValue() {
        let payload: String
        switch record.kind {
        case .string(let s): payload = s
        case .number(let n): payload = n
        case .bool(let b):   payload = b ? "true" : "false"
        case .null:          payload = "null"
        case .object, .array:
            payload = StorageRecord.serializeJSON(record)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        toasts.success("Copied value")
    }
}

// MARK: - Inner key/value row (one level inside a namespace)

private struct InnerKeyRow: View {
    let namespace: StorageSnapshot.Namespace
    let parent: StorageRecord
    let child: StorageRecord
    let isClientConnected: Bool
    /// True only when the session being viewed is the live one.
    /// Hides the delete button for past sessions where writes
    /// to the device aren't possible.
    let isLiveSession: Bool
    /// 0-based index inside the parent's children, used to draw
    /// zebra-stripe backgrounds. Doesn't affect functionality.
    let rowIndex: Int
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showingFullValue = false
    @Environment(ToastCenter.self) private var toasts

    /// True when the row content is likely to be truncated and
    /// worth surfacing an expand affordance for. Short scalars
    /// (numbers, bools, null, short strings) fit comfortably and
    /// don't need it; long strings and any container do.
    private var canExpand: Bool {
        switch child.kind {
        case .string(let s): return s.count > 60
        case .object, .array: return true
        default:              return false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Indent past the parent's chevron gutter so the inner
            // key:value column aligns visually under the namespace
            // row's key label.
            Color.clear.frame(width: 30)

            JSONSyntax.row(
                key: child.key,
                isArrayIndex: child.key.looksLikeJSONArrayIndex,
                kind: child.kind
            )
            // .callout monospaced (13pt) — readable at standard
            // zoom without dominating the layout. Was .caption
            // (12pt) which felt cramped over long lists.
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                if canExpand {
                    Button {
                        showingFullValue = true
                    } label: {
                        Image(systemName: "rectangle.expand.vertical")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(child.kind.isContainer
                          ? "Show pretty-printed JSON"
                          : "Show full value")
                    .popover(isPresented: $showingFullValue,
                             arrowEdge: .leading) {
                        StorageValuePopover(record: child)
                    }
                }

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Copy this value")

                // Hidden entirely for past sessions — see comments
                // above on isLiveSession.
                if isLiveSession {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isClientConnected)
                    .help(isClientConnected
                          ? "Delete this key inside \(parent.key)"
                          : "Reconnect the device to delete")
                }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 12)
        // Vertical breathing room: was 3, now 6. Long namespaces
        // (50+ keys) read as a comfortable list instead of a wall.
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Right-click → copy options. Mirrors NamespaceRow's
        // pattern so the muscle memory is the same on both levels.
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(child.key, forType: .string)
                toasts.success("Copied key name")
            } label: {
                Label("Copy key name", systemImage: "textformat")
            }
            Button(action: onCopy) {
                Label("Copy value", systemImage: "doc.on.doc")
            }
            Button {
                copyKeyValueLine()
            } label: {
                Label("Copy \"key\": value", systemImage: "text.alignleft")
            }
        }
    }

    /// Pastes a single line ready to drop into JSON or a config:
    ///   `"foo": "bar"`. Convenient for "show me this key from
    /// the device" Slack messages.
    private func copyKeyValueLine() {
        let valuePart: String
        switch child.kind {
        case .string(let s):
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            valuePart = "\"\(escaped)\""
        case .number(let n): valuePart = n
        case .bool(let b):   valuePart = b ? "true" : "false"
        case .null:          valuePart = "null"
        case .object, .array:
            valuePart = StorageRecord.serializeJSON(child)
        }
        let line = "\"\(child.key)\": \(valuePart)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        toasts.success("Copied as JSON line")
    }

    /// Hover wins over zebra (hover band needs to be visible);
    /// otherwise alternate rows get a subtle tint so the eye can
    /// scan key:value pairs without counting lines.
    @ViewBuilder
    private var rowBackground: some View {
        if isHovered {
            Color.secondary.opacity(0.10)
        } else if rowIndex.isMultiple(of: 2) {
            Color.clear
        } else {
            Color.secondary.opacity(0.04)
        }
    }
}

// MARK: - Full-value popover

/// Shown when the user clicks the expand affordance on a long
/// inner row. Renders the full value in a scrollable monospaced
/// view so base64 blobs, JWT payloads, stringified JSON, etc.
/// can be read end-to-end. For container values (objects /
/// arrays) the body is pretty-printed JSON.
private struct StorageValuePopover: View {
    let record: StorageRecord
    @Environment(ToastCenter.self) private var toasts

    /// What goes in the scrollable body — raw string for scalars,
    /// pretty JSON for containers.
    private var bodyText: String {
        switch record.kind {
        case .string(let s):  return s
        case .number(let n):  return n
        case .bool(let b):    return b ? "true" : "false"
        case .null:           return "null"
        case .object, .array: return StorageRecord.serializeJSON(record)
        }
    }

    private var charCount: Int { bodyText.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("\"\(record.key)\"")
                    .font(.headline.monospaced())
                    .foregroundStyle(JSONSyntax.keyColor)
                    .textSelection(.enabled)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(kindLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if record.kind.isContainer {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(record.itemCount == 1 ? "1 key" : "\(record.itemCount) keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(charCount == 1 ? "1 char" : "\(charCount) chars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bodyText, forType: .string)
                    toasts.success(record.kind.isContainer
                                   ? "Copied JSON"
                                   : "Copied value")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(record.kind.isContainer
                      ? "Copy pretty-printed JSON"
                      : "Copy value")
            }

            Divider()

            ScrollView {
                Text(bodyText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(width: 540, height: 380)
    }

    /// One-word kind label for the header chip — "string",
    /// "object", "array", "number", "bool", "null".
    private var kindLabel: String {
        switch record.kind {
        case .string: return "string"
        case .number: return "number"
        case .bool:   return "bool"
        case .null:   return "null"
        case .object: return "object"
        case .array:  return "array"
        }
    }
}

// MARK: - Add-key sheet

/// Sheet for adding a new key. The storage layer (Session / Local
/// / Keychain) is *not* picked here — it's inherited from
/// whichever tab the user already has selected on the main
/// screen. The sheet has two modes:
///
/// • Top-level (`initialParent == nil`): the user types a key +
///   value and may *optionally* type a namespace (subscope). If
///   the namespace field is empty, the SDK writes the pair at the
///   layer's root; if filled, the pair lands inside that subscope
///   (creating it if it doesn't already exist).
/// • Add-inside (`initialParent == "applicaster.v2"`): the
///   namespace is pre-filled and locked. The user only types the
///   inner key + value.
///
/// The save callback receives (layer, namespace, key, value); the
/// namespace is `nil` if the optional field was empty. The caller
/// hands those straight to
/// `vm.setValue(in:parent:key:value:via:)`.
private struct AddStorageKeySheet: View {
    let initialNamespace: StorageSnapshot.Namespace
    let initialParent: String?
    let onSave: (StorageSnapshot.Namespace, String?, String, String) -> Void
    let onCancel: () -> Void

    @State private var key: String = ""
    @State private var value: String = ""
    /// User-typed subscope for top-level mode. Trimmed and folded
    /// to `nil` on save when empty.
    @State private var manualParent: String = ""

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isInside: Bool { initialParent != nil }

    /// Active subscope considering both modes:
    ///   • add-inside: always `initialParent`
    ///   • top-level:  trimmed `manualParent`, nil if empty
    private var resolvedParent: String? {
        if let initialParent { return initialParent }
        let trimmed = manualParent.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var commandPreview: String {
        var cmd = "storage.\(initialNamespace.wireKey).set \(key) \(value)"
        if let parent = resolvedParent {
            cmd += " \(parent)"
        }
        return cmd
    }

    /// Colour cue per storage layer — matches the NamespaceTab
    /// chips on the main screen so the sheet feels anchored to
    /// the tab the user clicked Add-key from.
    private var layerColor: Color {
        switch initialNamespace {
        case .session:  .blue
        case .local:    .purple
        case .keychain: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title + a small chip naming the active layer (read-only).
            // Removes the segmented picker since the user already
            // chose a layer by clicking its tab on the main screen.
            HStack(spacing: 10) {
                Text(isInside ? "Add key inside \(initialParent!)" : "Add key")
                    .font(.headline)
                Spacer()
                Text(initialNamespace.displayName.uppercased())
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(layerColor)
                    .background(
                        Capsule()
                            .fill(layerColor.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(layerColor.opacity(0.45), lineWidth: 1)
                    )
                    .help("Adding to the \(initialNamespace.displayName) storage. To use a different storage, close this sheet and switch tabs.")
            }

            if isInside {
                // Add-inside mode: namespace is fixed.
                HStack(spacing: 6) {
                    Text("Namespace").font(.caption).foregroundStyle(.secondary)
                    Text(initialParent ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Key").font(.caption).foregroundStyle(.secondary)
                TextField(
                    isInside ? "e.g. premium" : "e.g. featureFlag.premium",
                    text: $key
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. true", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            // Optional subscope — only shown in top-level mode.
            // Leave blank to write at the layer's root; type a
            // name to put the pair inside that subscope.
            if !isInside {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Namespace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("(optional)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    TextField("e.g. applicaster.v2 — leave empty for root",
                              text: $manualParent)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Live preview of the exact command we'll send so the
            // power user can sanity-check before pressing Save.
            Text("Sends: \(commandPreview)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(
                        initialNamespace,
                        resolvedParent,
                        key.trimmingCharacters(in: .whitespaces),
                        value
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
