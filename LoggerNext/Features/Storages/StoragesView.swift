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
    @State private var pendingEdit: EditTarget?
    @State private var pendingDelete: EditTarget?
    @State private var showingAddKey = false

    var body: some View {
        VStack(spacing: 0) {
            StoragesTopBar(
                vm: vm,
                onExport: { Task { await prepareExport() } },
                onAddKey: { showingAddKey = true }
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
        // Delete confirmation — also keyed off the row's namespace.
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
        // Add key sheet
        .sheet(isPresented: $showingAddKey) {
            AddStorageKeySheet(
                initialNamespace: vm.selectedNamespace,
                onSave: { namespace, key, value in
                    vm.setValue(
                        in: namespace,
                        key: key,
                        value: value,
                        via: env.server
                    )
                    showingAddKey = false
                },
                onCancel: { showingAddKey = false }
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
            // Namespaces are now the outline section headers, so the
            // chip row is gone. The only thing left on the leading
            // edge is the global "Add key" action.
            Button(action: onAddKey) {
                Label("Add key", systemImage: "plus.circle")
            }
            .disabled(!isClientConnected)
            .help(isClientConnected
                  ? "Add a new key/value to the device's storage"
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

// MARK: - Outline (sections per namespace)

/// Replaces the old single-namespace Table with a sectioned list:
/// each of the three namespaces is a collapsible section whose
/// rows are its top-level keys. Hovering a row reveals Edit + Delete
/// icons on the right — same affordance pattern as the Sessions
/// list — and clicking the row's body sets the detail-pane selection.
///
/// All three sections start expanded; the user can collapse the
/// ones they're not looking at via the chevron in each header.
private struct StoragesOutline: View {
    @Bindable var vm: StoragesViewModel
    @Environment(AppEnvironment.self) private var env
    let onEdit: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onDelete: (StorageRecord, StorageSnapshot.Namespace) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(StorageSnapshot.Namespace.allCases, id: \.self) { ns in
                    NamespaceSection(
                        vm: vm,
                        namespace: ns,
                        onEdit: onEdit,
                        onDelete: onDelete
                    )
                    Divider()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// One collapsible section (header + rows) for a namespace.
private struct NamespaceSection: View {
    @Bindable var vm: StoragesViewModel
    let namespace: StorageSnapshot.Namespace
    let onEdit: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onDelete: (StorageRecord, StorageSnapshot.Namespace) -> Void

    private var isExpanded: Bool { vm.expandedNamespaces.contains(namespace) }
    private var records: [StorageRecord] { vm.filteredRecords(in: namespace) }
    private var totalCount: Int { vm.recordCount(in: namespace) }

    private var color: Color {
        switch namespace {
        case .session:  .blue
        case .local:    .purple
        case .keychain: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if records.isEmpty {
                    emptyState
                } else {
                    ForEach(records) { record in
                        StorageOutlineRow(
                            vm: vm,
                            namespace: namespace,
                            record: record,
                            onEdit: onEdit,
                            onDelete: onDelete
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        Button {
            if isExpanded {
                vm.expandedNamespaces.remove(namespace)
            } else {
                vm.expandedNamespaces.insert(namespace)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(namespace.displayName.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text("\(totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(0.15)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(color.opacity(0.04))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(vm.searchTerm.trimmingCharacters(in: .whitespaces).isEmpty
             ? "No keys in this namespace."
             : "No keys match \"\(vm.searchTerm)\".")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 36)
            .padding(.vertical, 8)
    }
}

/// One row in an outline section.
private struct StorageOutlineRow: View {
    @Bindable var vm: StoragesViewModel
    let namespace: StorageSnapshot.Namespace
    let record: StorageRecord
    let onEdit: (StorageRecord, StorageSnapshot.Namespace) -> Void
    let onDelete: (StorageRecord, StorageSnapshot.Namespace) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var isHovered = false

    private var isSelected: Bool {
        vm.selection?.namespace == namespace &&
        vm.selection?.recordId  == record.id
    }

    private var isClientConnected: Bool {
        if case .clientConnected = env.serverState { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            // 36pt of leading indent so rows align past the chevron
            // gutter in the section header.
            Spacer().frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.key)
                    .font(.body)
                    .foregroundStyle(.primary)
                valueSummary
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hover-revealed Edit + Delete. Edit is scalar-only;
            // containers (object/array) show Delete only.
            HStack(spacing: 4) {
                if !record.isContainer {
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
                      ? "Delete this key from the device"
                      : "Connect a device to delete")
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            vm.selection = .init(namespace: namespace, recordId: record.id)
            vm.selectedNamespace = namespace
        }
    }

    @ViewBuilder
    private var valueSummary: some View {
        if let text = record.valueText {
            Text(text)
        } else if record.isContainer {
            Text(record.itemCount == 1
                 ? "1 item"
                 : "\(record.itemCount) items")
        } else {
            Text("")
        }
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

/// Sheet for adding a brand-new key. Namespace defaults to whichever
/// chip is currently selected so the common flow ("add a key here")
/// is one click.
private struct AddStorageKeySheet: View {
    let initialNamespace: StorageSnapshot.Namespace
    let onSave: (StorageSnapshot.Namespace, String, String) -> Void
    let onCancel: () -> Void

    @State private var namespace: StorageSnapshot.Namespace = .local
    @State private var key: String = ""
    @State private var value: String = ""

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add key").font(.headline)

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

            VStack(alignment: .leading, spacing: 6) {
                Text("Key").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. featureFlag.premium", text: $key)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. true", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            // Live preview of the command we'll send so the power
            // user knows exactly what's about to fly over the wire.
            Text("Sends: storage.\(namespace.wireKey).set \(key) \(value)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(namespace, key.trimmingCharacters(in: .whitespaces), value)
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
