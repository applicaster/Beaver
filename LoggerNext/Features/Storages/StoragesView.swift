//
//  StoragesView.swift
//  LoggerNext
//

import SwiftUI

/// Storages screen — three colored namespace chips (Session / Local /
/// Keychain), a table of top-level keys, and a detail tree for the
/// selected key. Matches the layout of the original Logger app's
/// Storages screen, adapted to LoggerNext's session-aware data
/// model.
struct StoragesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm: StoragesViewModel?

    var body: some View {
        Group {
            if let sessionId = env.viewingSessionId {
                if let vm {
                    StoragesContent(vm: vm)
                } else {
                    ProgressView("Loading session…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "No session selected",
                    systemImage: "externaldrive",
                    description: Text("Connect a device or pick a past session from the sidebar.")
                )
            }
        }
        .task(id: env.viewingSessionId) {
            // .task(id:) re-fires on every appearance AND on session
            // change, so this gives us both "fresh data on tab open"
            // and "fresh data on session switch" in one place.
            guard let sessionId = env.viewingSessionId else {
                vm = nil
                return
            }
            if vm?.sessionId != sessionId {
                let fresh = StoragesViewModel(store: env.store, sessionId: sessionId)
                // Critical: subscribe + load cached data BEFORE asking
                // the device for fresh data. Otherwise the inbound
                // `.storageUpdated` broadcast can race past the
                // not-yet-registered continuation and leave the UI
                // blank even after Reload.
                await fresh.bootstrap()
                vm = fresh
            }
            // Auto-refresh from the device. No-op if no client is
            // connected — WSServer.send silently drops in that case
            // and the UI keeps showing whatever's cached on disk.
            vm?.requestRefresh(via: env.server)
        }
    }
}

// MARK: - Content

private struct StoragesContent: View {
    @Bindable var vm: StoragesViewModel
    @Environment(AppEnvironment.self) private var env
    @State private var showingExporter = false
    @State private var exportDocument: JSONExportDocument?

    // Edit / add / delete sheet state. Each row in the outline owns
    // its namespace, so we carry that along — the action sheet picks
    // the right `storage.<ns>.set/delete` command.
    struct EditTarget: Identifiable {
        let record: StorageRecord
        let namespace: StorageSnapshot.Namespace
        var id: String { "\(namespace.rawValue):\(record.id)" }
    }

    /// Inner-row delete uses (namespace, parentKey, childKey) — we
    /// don't have a `StorageRecord` reference for these because they
    /// come straight from the row view; only the strings are needed
    /// to build the `storage.<ns>.delete <key> <namespace>` command.
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

    @State private var pendingEdit: EditTarget?
    @State private var pendingDelete: EditTarget?
    @State private var pendingInnerDelete: InnerDeleteTarget?
    @State private var pendingAdd: AddKeyContext?

    var body: some View {
        VStack(spacing: 0) {
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
            HSplitView {
                StoragesOutline(
                    vm: vm,
                    onEdit: { record, namespace in
                        vm.selectedNamespace = namespace
                        pendingEdit = EditTarget(record: record, namespace: namespace)
                    },
                    onDelete: { record, namespace in
                        vm.selectedNamespace = namespace
                        pendingDelete = EditTarget(record: record, namespace: namespace)
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
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                StoragesDetail(vm: vm)
                    .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Edit sheet — uses the namespace from the row that triggered it.
        .sheet(item: $pendingEdit) { target in
            EditStorageValueSheet(
                namespace: target.namespace,
                key: target.record.key,
                initialValue: target.record.valueText ?? "",
                onSave: { newValue in
                    vm.setValue(
                        in: target.namespace,
                        key: target.record.key,
                        value: newValue,
                        via: env.server
                    )
                    pendingEdit = nil
                },
                onCancel: { pendingEdit = nil }
            )
        }
        // Top-level delete confirmation — wipes a whole namespace
        // entry. The SDK leaves any nested subscope behind, but the
        // outer key is gone immediately.
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
                        vm.selection = nil
                    }
                }
            }
            .fixedSize()

            // "+ Add key" — adds a top-level key in the current layer.
            Button(action: onAddKey) {
                Label("Add key", systemImage: "plus.circle")
            }
            .disabled(!isClientConnected)
            .help(isClientConnected
                  ? "Add a top-level key in the current layer"
                  : "Connect a device to add a key")

            Spacer()

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
                  : "Connect a device to enable auto-refresh")

            Button {
                vm.requestRefresh(via: env.server)
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(!isClientConnected)
            .help(isClientConnected
                  ? "Re-fetch the device's storage snapshot now"
                  : "Connect a device to refresh")

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
        .padding(.vertical, 10)
    }

    private var isClientConnected: Bool {
        if case .clientConnected = env.serverState { return true }
        return false
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

// NamespaceChip removed when the outline view (D29) replaced the
// tab-style chip row in the top bar. Section headers in
// `NamespaceSection` now carry the same color cue.

// MARK: - Outline (single layer, expandable namespaces)

/// Shows the top-level "namespace" rows for the currently-selected
/// storage layer (Session / Local / Keychain). Each row is
/// expandable: click the chevron to reveal the namespace's one-level
/// children as inline `key: value` rows. The right-side detail pane
/// still drives full-depth browsing for arbitrarily nested values.
///
/// Per-row actions:
///   • Namespace (container) row: copy-as-JSON + add-key-inside + delete
///   • Namespace (scalar)    row: copy-value + delete
///   • Inner key/value row:        copy-value + delete-inside-namespace
private struct StoragesOutline: View {
    @Bindable var vm: StoragesViewModel
    @Environment(AppEnvironment.self) private var env
    let onEdit: (StorageRecord, StorageSnapshot.Namespace) -> Void
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
                            onEdit: onEdit,
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
        let message: String = trimmed.isEmpty
            ? "No \(vm.selectedNamespace.displayName.lowercased()) data. Click Reload to fetch from the device."
            : "No keys or values match \"\(trimmed)\"."
        ContentUnavailableView(
            "Nothing to show",
            systemImage: trimmed.isEmpty ? "tray" : "magnifyingglass",
            description: Text(message)
        )
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
            HStack(spacing: 6) {
                Text(namespace.displayName.uppercased())
                    .font(.caption.weight(.semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isSelected
                                           ? Color.white.opacity(0.25)
                                           : color.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.white : color)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? color
                          : (isHovered ? color.opacity(0.12) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
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
    let onEdit: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onDelete: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onAddInside: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onDeleteInside: (
        _ namespace: StorageSnapshot.Namespace,
        _ parentKey: String,
        _ childKey: String
    ) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var isHovered = false

    private var isExpanded: Bool {
        vm.isExpanded(record: record, in: namespace)
    }

    private var isSelected: Bool {
        vm.selection?.namespace == namespace &&
        vm.selection?.recordId  == record.id
    }

    private var isClientConnected: Bool {
        if case .clientConnected = env.serverState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, let children = record.children, !children.isEmpty {
                ForEach(children) { child in
                    InnerKeyRow(
                        namespace: namespace,
                        parent: record,
                        child: child,
                        isClientConnected: isClientConnected,
                        onCopy: { copyValue(of: child) },
                        onDelete: {
                            onDeleteInside(namespace, record.key, child.key)
                        }
                    )
                }
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
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
        .onTapGesture {
            vm.selection = .init(namespace: namespace, recordId: record.id)
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
            return record.itemCount == 1 ? "1 item" : "\(record.itemCount) items"
        }
        return ""
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
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

            if record.isContainer {
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
                      : "Connect a device to add a key")
            } else {
                Button {
                    onEdit(record, namespace)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!isClientConnected)
                .help(isClientConnected
                      ? "Edit this value on the device"
                      : "Connect a device to edit")
            }

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
                  : "Connect a device to delete")
        }
        .opacity(isHovered ? 1 : 0.55)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.18)
        } else if isHovered {
            Color.secondary.opacity(0.08)
        } else {
            Color.clear
        }
    }

    private func copyNamespaceContents() {
        let payload = StorageRecord.serializeJSON(record)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
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
    }
}

// MARK: - Inner key/value row (one level inside a namespace)

private struct InnerKeyRow: View {
    let namespace: StorageSnapshot.Namespace
    let parent: StorageRecord
    let child: StorageRecord
    let isClientConnected: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Indent past the parent's chevron gutter.
            Color.clear.frame(width: 30)

            JSONSyntax.row(
                key: child.key,
                isArrayIndex: child.key.looksLikeJSONArrayIndex,
                kind: child.kind
            )
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Copy this value")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!isClientConnected)
                .help(isClientConnected
                      ? "Delete this key inside \(parent.key)"
                      : "Connect a device to delete")
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(isHovered ? Color.secondary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Detail

private struct StoragesDetail: View {
    @Bindable var vm: StoragesViewModel

    var body: some View {
        if let record = vm.selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(record)
                    Divider()
                    if record.valueText != nil {
                        StorageTreeRow(record: record)
                    } else if let children = record.children, !children.isEmpty {
                        tree(children: children)
                    } else {
                        Text("(empty)").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(
                "No record selected",
                systemImage: "rectangle.inset.filled",
                description: Text("Pick a key from the outline to inspect its value.")
            )
        }
    }

    @ViewBuilder
    private func header(_ record: StorageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.key)
                .font(.title3)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(vm.selectedRecordNamespace.displayName)
                    .font(.caption.weight(.semibold))
                if record.isContainer {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(record.itemCount == 1 ? "1 item" : "\(record.itemCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tree(children: [StorageRecord]) -> some View {
        // Manual recursion — see DetailPaneView.JSONTree for the
        // same pattern. OutlineGroup's automatic indentation isn't
        // visible outside of a List, so we lay out depth padding +
        // disclosure chevrons ourselves.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(children) { child in
                StorageTree(record: child, depth: 0)
            }
        }
    }
}

// MARK: - Storage tree

/// Recursive tree renderer for storage records. Indents children per
/// nesting level so the structure reads as a tree, and renders its
/// own disclosure chevron beside each container row.
private struct StorageTree: View {
    let record: StorageRecord
    let depth: Int

    @State private var isExpanded: Bool = true

    private static let indentStep: CGFloat = 14

    private var hasChildren: Bool {
        !(record.children?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                disclosureChevron
                StorageTreeRow(record: record)
            }
            .padding(.leading, CGFloat(depth) * Self.indentStep)

            if isExpanded, let children = record.children, !children.isEmpty {
                ForEach(children) { child in
                    StorageTree(record: child, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private var disclosureChevron: some View {
        if hasChildren {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }
}

// MARK: - Storage tree row

/// One row in the storages OutlineGroup. Mirrors the
/// `JSONTreeRow` from the log-feed DetailPaneView: hover reveals a
/// copy button on the right. Leaf rows copy the raw value; container
/// rows copy the subtree as pretty-printed JSON.
///
/// Renders `"key": value` (or `[N]: value` for array elements) using
/// `JSONSyntax` so colours match the log-event detail pane.
private struct StorageTreeRow: View {
    let record: StorageRecord
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            JSONSyntax.row(
                key: record.key,
                isArrayIndex: record.key.looksLikeJSONArrayIndex,
                kind: record.kind
            )
            .textSelection(.enabled)
            .help(record.key)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Copy button: reserves space always so the row doesn't
            // jiggle when the pointer enters; only visible + clickable
            // while hovered.
            Button {
                copyToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(record.kind.isContainer ? "Copy as JSON" : "Copy value")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .font(.system(.caption, design: .monospaced))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func copyToPasteboard() {
        let payload: String
        switch record.kind {
        case .string(let raw):  payload = raw
        case .number(let n):    payload = n
        case .bool(let b):      payload = b ? "true" : "false"
        case .null:             payload = "null"
        case .object, .array:   payload = StorageRecord.serializeJSON(record)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}

// MARK: - Edit / Add value sheets

/// Sheet for changing the value of an existing top-level storage key.
/// The SDK's `storage.<ns>.set` command takes a space-separated
/// `<key> <value>`, so values containing spaces will be truncated —
/// surfaced as an inline warning when the user types one.
private struct EditStorageValueSheet: View {
    let namespace: StorageSnapshot.Namespace
    let key: String
    let initialValue: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String = ""

    private var hasSpace: Bool { value.contains(" ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit value")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(namespace.displayName + " · " + key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Sends: storage.\(namespace.wireKey).set \(key) <value>")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("New value", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onSave(value) }
                if hasSpace {
                    Text("⚠️ Spaces in the value may be lost — the SDK splits arguments on whitespace.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { value = initialValue }
    }
}

/// Sheet for adding a new key. Operates in two modes:
///
/// • Top-level (`initialParent == nil`): user picks a layer and a
///   key/value. The SDK creates a brand-new namespace if needed.
/// • Add-inside (`initialParent == "applicaster.v2"`): namespace +
///   layer are locked and shown as a header; the user only types
///   the inner key + value. The SDK puts the new pair inside that
///   parent namespace via its 3rd-arg subscope.
///
/// The save callback receives (namespace, parent, key, value); the
/// parent is `nil` for top-level adds and the parent key for
/// add-inside adds. The caller hands those straight to
/// `vm.setValue(in:parent:key:value:via:)`.
private struct AddStorageKeySheet: View {
    let initialNamespace: StorageSnapshot.Namespace
    let initialParent: String?
    let onSave: (StorageSnapshot.Namespace, String?, String, String) -> Void
    let onCancel: () -> Void

    @State private var namespace: StorageSnapshot.Namespace = .local
    @State private var key: String = ""
    @State private var value: String = ""

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isInside: Bool { initialParent != nil }

    private var commandPreview: String {
        var cmd = "storage.\(namespace.wireKey).set \(key) \(value)"
        if let parent = initialParent, !parent.isEmpty {
            cmd += " \(parent)"
        }
        return cmd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isInside ? "Add key inside \(initialParent!)" : "Add key")
                .font(.headline)

            if isInside {
                // Add-inside mode: namespace + parent are fixed.
                HStack(spacing: 8) {
                    Text(namespace.displayName.uppercased())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15))
                        )
                    Text("·").foregroundStyle(.secondary)
                    Text(initialParent ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                // Top-level mode: user picks the layer.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Namespace").font(.caption).foregroundStyle(.secondary)
                    Picker("Namespace", selection: $namespace) {
                        ForEach(StorageSnapshot.Namespace.allCases, id: \.self) { ns in
                            Text(ns.displayName).tag(ns)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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
                        namespace,
                        initialParent,
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
        .onAppear { namespace = initialNamespace }
    }
}
