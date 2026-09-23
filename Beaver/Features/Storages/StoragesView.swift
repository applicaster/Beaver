//
//  StoragesView.swift
//  Beaver
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
///   • Namespace (container) row: [add-key-inside] [copy-as-JSON]
///   • Top-level scalar row:      [copy-key] [copy-value] [edit] [delete]
///   • Inner `key: value` row:    [copy-key] [copy-value] [edit] [delete]
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
    /// `editKey` switches the sheet to edit mode: key locked, value
    /// prefilled, same `storage.<ns>.set` command on save.
    struct AddKeyContext: Identifiable {
        let namespace: StorageSnapshot.Namespace
        let parentKey: String?
        var editKey: String? = nil
        var editValue: String = ""
        /// Set when editing one field of a stored JSON value.
        var field: StorageFieldTarget? = nil
        var id: String { "\(namespace.rawValue):\(parentKey ?? "<root>"):\(editKey ?? ""):\(field?.id ?? "")" }
    }

    @State private var pendingDelete: DeleteTarget?
    @State private var pendingInnerDelete: InnerDeleteTarget?
    @State private var pendingAdd: AddKeyContext?
    @State private var pendingFieldDelete: StorageFieldTarget?

    var body: some View {
        VStack(spacing: 0) {
            // Device/app context now lives in the sidebar's top
            // card (see SidebarDeviceCard in MainWindow) so it's
            // visible across every tab instead of just here.

            StoragesTopBar(
                vm: vm,
                onExport: { scope in Task { await prepareExport(scope: scope) } },
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
                },
                onEdit: { namespace, parentKey, key, value in
                    vm.selectedNamespace = namespace
                    pendingAdd = AddKeyContext(
                        namespace: namespace,
                        parentKey: parentKey,
                        editKey: key,
                        editValue: value
                    )
                },
                onField: { target, delete in
                    vm.selectedNamespace = target.namespace
                    if delete {
                        pendingFieldDelete = target
                    } else {
                        pendingAdd = AddKeyContext(
                            namespace: target.namespace,
                            parentKey: target.parentKey,
                            editKey: target.key,
                            editValue: target.field.valueText ?? "",
                            field: target
                        )
                    }
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
        // Field delete: the SDK can't remove part of a value, so this
        // rewrites the whole stored JSON without the field.
        .confirmationDialog(
            "Delete \"\(pendingFieldDelete?.fieldLabel ?? "")\" from \(pendingFieldDelete?.key ?? "")?",
            isPresented: Binding(
                get: { pendingFieldDelete != nil },
                set: { if !$0 { pendingFieldDelete = nil } }
            ),
            presenting: pendingFieldDelete
        ) { target in
            Button("Delete", role: .destructive) {
                pendingFieldDelete = nil
                guard let json = JSONFieldPatch.removing(target.field.id, in: target.storedJSON) else { return }
                vm.setValue(in: target.namespace, parent: target.parentKey,
                            key: target.key, value: json, via: env.server)
            }
            Button("Cancel", role: .cancel) { pendingFieldDelete = nil }
        } message: { target in
            let json = JSONFieldPatch.removing(target.field.id, in: target.storedJSON) ?? ""
            Text(json.contains(where: \.isWhitespace)
                 ? "Rewrites \(target.key) on the device without this field. The new value contains spaces, which the device splits on — it may store only part of it."
                 : "Rewrites \(target.key) on the device without this field.")
        }
        // Add-key sheet. Identifiable trigger so the same view powers
        // both top-bar "+ Add key" (parentKey = nil → top-level) and
        // per-row "+ inside namespace" (parentKey = the namespace).
        .sheet(item: $pendingAdd) { ctx in
            AddStorageKeySheet(
                initialNamespace: ctx.namespace,
                initialParent: ctx.parentKey,
                editKey: ctx.editKey,
                initialValue: ctx.editValue,
                fieldLabel: ctx.field?.fieldLabel,
                transform: ctx.field.map { f in
                    { JSONFieldPatch.setting(f.field.id, to: $0, in: f.storedJSON) }
                },
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

    private func prepareExport(scope: SessionExport.Scope) async {
        guard let data = await SessionExport.make(
            store: env.store,
            sessionId: vm.sessionId,
            scope: scope
        ) else { return }
        exportDocument = JSONExportDocument(data: data)
        showingExporter = true
    }
}

// MARK: - Top bar

private struct StoragesTopBar: View {
    @Bindable var vm: StoragesViewModel
    @Environment(AppEnvironment.self) private var env
    let onExport: (SessionExport.Scope) -> Void
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
                // Green ➕ tile — adds a top-level key in the current layer.
                Button(action: onAddKey) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add key")
                .opacity(isClientConnected ? 1 : 0.4)
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

            // Same two choices as the Log feed's Export, writing the
            // same file. "Filtered" refers to the log filter — storage
            // is never partial, since there is nothing on this screen
            // for a partial snapshot to correspond to.
            Menu {
                Button("Export filtered") {
                    onExport(.filtered(env.activeFilter))
                }
                .disabled(env.activeFilter.isEmpty)
                Button("Export all") {
                    onExport(.everything)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!vm.hasAnyData)
            .help("Save the session to a JSON file — the device storage plus its events")

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

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            searchField
            if !vm.groupNames.isEmpty {
                groupPicker
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Discover keys and values…", text: $vm.searchTerm)
                .textFieldStyle(.plain)
                .focused($isFocused)
                // Enter walks matches without leaving the box, so a
                // search and a jump are one gesture.
                .onSubmit { vm.nextMatch() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    vm.previousMatch()
                    return .handled
                }

            if !vm.searchTerm.isEmpty {
                MatchNavigatorCompact(vm: vm)
            }

            RegexToggle(isOn: $vm.searchIsRegex, isInvalid: vm.patternIsInvalid)

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
                .strokeBorder(
                    vm.patternIsInvalid ? Color.red : Color(.separatorColor),
                    lineWidth: 1
                )
        )
        .help(vm.patternIsInvalid
              ? "That regular expression doesn't compile"
              : "Matches groups, keys and values")
    }

    private var groupPicker: some View {
        Picker("", selection: $vm.groupFilter) {
            Text("All groups").tag(String?.none)
            Divider()
            ForEach(vm.groupNames, id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .help("Show only one group")
    }
}

/// `.*` switch. Turns red rather than empty when the pattern is broken,
/// so a half-typed expression reads as "not finished" and not "no hits".
private struct RegexToggle: View {
    @Binding var isOn: Bool
    let isInvalid: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(".*")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(isOn ? 0.20 : 0))
                )
                .foregroundStyle(isOn ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Regex: ON" : "Match with a regular expression")
    }

    private var tint: Color { isInvalid ? .red : .accentColor }
}

/// `current/total` with ▲ ▼, sized to sit inside the search field.
private struct MatchNavigatorCompact: View {
    @Bindable var vm: StoragesViewModel

    var body: some View {
        HStack(spacing: 2) {
            Text(counterText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.matchCount > 0 ? .primary : .secondary)

            Button { vm.previousMatch() } label: {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(vm.matchCount == 0)
            .help("Previous match (⇧↩)")

            Button { vm.nextMatch() } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(vm.matchCount == 0)
            .help("Next match (↩)")
        }
        .fixedSize()
    }

    private var counterText: String {
        guard vm.matchCount > 0 else { return "0/0" }
        return "\((vm.currentMatchIndex ?? 0) + 1)/\(vm.matchCount)"
    }
}


// MARK: - Outline (single layer, expandable namespaces)

/// One field inside a stored JSON value, picked in the decoded tree.
/// `field` is the tree node; the placeholder passed when building the
/// editor is swapped for the clicked node in `storageFieldEditor`.
struct StorageFieldTarget: Identifiable {
    let namespace: StorageSnapshot.Namespace
    /// The storage subscope (nil = top level), as for a key edit.
    let parentKey: String?
    let key: String
    /// The key's stored text — the document being patched.
    let storedJSON: String
    var field: StorageRecord

    var id: String { "\(namespace.rawValue):\(parentKey ?? ""):\(key):\(field.id)" }

    /// `volume`, `list[2].on` — the tree id minus its leading dot.
    var fieldLabel: String {
        field.id.hasPrefix(".") ? String(field.id.dropFirst()) : field.id
    }
}

/// (field, true = delete / false = edit)
private typealias StorageFieldAction = (_ target: StorageFieldTarget, _ delete: Bool) -> Void

/// Field edit / delete for a decoded value, or nil when it can't be
/// written back: only plain JSON text is patched — Base64 would need
/// re-encoding and a JWT's signature would break. Past sessions get nil.
@MainActor
private func storageFieldEditor(
    decode: LeafDecode?,
    target: StorageFieldTarget,
    live: Bool,
    connected: Bool,
    onField: @escaping StorageFieldAction
) -> StorageFieldEditor? {
    guard live, decode?.kinds == [.json] else { return nil }
    func at(_ node: StorageRecord) -> StorageFieldTarget {
        var t = target
        t.field = node
        return t
    }
    return StorageFieldEditor(
        canWrite: connected,
        edit: { onField(at($0), false) },
        delete: { onField(at($0), true) }
    )
}

/// (layer, parent subscope or nil for top level, key, current raw value)
private typealias StorageEditAction = (
    _ namespace: StorageSnapshot.Namespace,
    _ parentKey: String?,
    _ key: String,
    _ value: String
) -> Void

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
    let onEdit: StorageEditAction
    let onField: StorageFieldAction

    private var records: [StorageRecord] {
        vm.filteredRecords(in: vm.selectedNamespace)
    }

    var body: some View {
        // Filtering walks every node (7–22 ms on a real layer) — once per
        // render, not once per use.
        let records = self.records
        ScrollViewReader { proxy in
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
                                onDeleteInside: onDeleteInside,
                                onEdit: onEdit,
                                onField: onField
                            )
                            .id(record.id)
                            Divider().opacity(0.3)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            // Jumping between Discover matches scrolls the group holding
            // the match into view. The token changes on every jump, so
            // landing on the same group twice still scrolls.
            .onChange(of: vm.scrollTarget?.token) { _, _ in
                guard let target = vm.scrollTarget else { return }
                // The group first: it may be off screen and so not yet
                // built by the lazy stack, and a row inside an unbuilt
                // group has no position to scroll to.
                proxy.scrollTo(target.ownerId, anchor: .top)
                guard target.rowId != target.ownerId else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target.rowId, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmed = vm.searchTerm.trimmingCharacters(in: .whitespaces)
        ContentUnavailableView(
            "Nothing to show",
            systemImage: trimmed.isEmpty ? "tray" : "magnifyingglass",
            description: Text(emptyStateMessage(searchTerm: trimmed))
        )
        // Parent LazyVStack uses `.leading` alignment which would
        // pin this content to the left. `.frame(maxWidth: .infinity)`
        // restores the center alignment ContentUnavailableView
        // assumes.
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    /// Pure string-returning helper so the ViewBuilder above stays
    /// happy — SwiftUI's `@ViewBuilder` doesn't accept if/else
    /// statements that assign to a `var`. Branches between three
    /// cases:
    ///   • non-empty search term → "no matches"
    ///   • live session, no data → "click Reload"
    ///   • past session, no data → "wasn't captured during this session"
    private func emptyStateMessage(searchTerm trimmed: String) -> String {
        if !trimmed.isEmpty {
            return "No keys or values match \"\(trimmed)\"."
        }
        let layer = vm.selectedNamespace.displayName.lowercased()
        if env.currentSessionId == vm.sessionId {
            return "No \(layer) data. Click Reload to fetch from the device."
        }
        return "No \(layer) data was captured during this session."
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

    private var icon: String {
        switch namespace {
        case .session:  "clock"
        case .local:    "cylinder.split.1x2"
        case .keychain: "lock"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(namespace.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected
                                       ? Color.white.opacity(0.25)
                                       : color.opacity(0.15))
                    )
            }
            .padding(.horizontal, 12)
            // Same 30pt as the green ＋ tile beside the tabs.
            .frame(height: 30)
            .foregroundStyle(isSelected ? Color.white : color)
            .opacity(count == 0 && !isSelected ? 0.6 : 1)
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
        .help("\(count) \(count == 1 ? "namespace" : "namespaces") in \(namespace.displayName) storage")
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
    let onEdit: StorageEditAction
    let onField: StorageFieldAction

    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var isHovered = false

    private var isExpanded: Bool {
        vm.isExpanded(record: record, in: namespace)
    }

    /// A device may report a layer flat — `{"featureFlags": "{...}"}` —
    /// so a top-level entry is not always a namespace. Decoding it here
    /// keeps a stringified value readable instead of stranding it as an
    /// unexpandable one-line summary.
    private var decode: LeafDecode? {
        guard case .string(let raw) = record.kind else { return nil }
        return LeafDecoder.decode(raw)
    }

    private var decodedSubtree: StorageRecord? {
        guard let tree = decode?.tree, !(tree.children?.isEmpty ?? true) else { return nil }
        return tree
    }

    /// Expandable when it holds keys, or when its value decodes into
    /// something worth showing.
    private var canExpand: Bool {
        if record.isContainer, !(record.children?.isEmpty ?? true) { return true }
        guard let decode else { return false }
        return decode.tree != nil || decode.text != nil
    }

    private var showingRaw: Binding<Bool> {
        Binding(
            get: { vm.isShowingRaw(record: record, in: namespace) },
            set: { vm.setShowingRaw($0, record: record, in: namespace) }
        )
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
                        vm: vm,
                        namespace: namespace,
                        parent: record,
                        child: child,
                        isClientConnected: isClientConnected,
                        isLiveSession: isViewingLiveSession,
                        rowIndex: idx,
                        onCopy: { copyValue(of: child) },
                        onDelete: {
                            onDeleteInside(namespace, record.key, child.key)
                        },
                        onEdit: { value in
                            onEdit(namespace, record.key, child.key, value)
                        },
                        onField: onField
                    )
                    .id(child.id)  // Discover scrolls to it
                }
            } else if isExpanded, decode != nil {
                decodedContent
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Same Formatted / Raw treatment an inner row gets, for the case
    /// where the entry is a value rather than a namespace.
    @ViewBuilder
    private var decodedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            DecodeTabBar(showingRaw: showingRaw, note: decode?.note ?? "")

            if showingRaw.wrappedValue {
                RawValueBlock(text: record.valueText ?? "")
            } else if let decode {
                if decode.isJWT {
                    JWTSummaryView(status: decode.chip, claims: decode.jwtClaims)
                }
                if let tree = decodedSubtree, let children = tree.children {
                    VStack(alignment: .leading, spacing: 2) {
                        JSONTreeList(children: children)
                    }
                    .environment(\.storageFieldEditor, storageFieldEditor(
                        decode: decode,
                        target: StorageFieldTarget(namespace: namespace, parentKey: nil,
                                                   key: record.key, storedJSON: record.valueText ?? "",
                                                   field: tree),
                        live: isViewingLiveSession, connected: isClientConnected, onField: onField
                    ))
                } else if let text = decode.text {
                    RawValueBlock(text: text)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            chevron
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(highlighted(record.key))
                        .font(.body.weight(.medium))
                    valueTags
                    // Beside the key it acts on, not at the far edge,
                    // where on a wide window it was unclear which row
                    // it belonged to.
                    actions
                }
                Text(highlighted(summaryLine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        // An expanded namespace flashes its changed keys instead.
        .modifier(ChangeFlash(
            isChanged: vm.isChanged(record: record, in: namespace)
                && !(isExpanded && record.isContainer),
            generation: vm.changeGeneration
        ))
        .overlay(currentMatchOutline)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Whole row toggles expansion on container rows; scalars
        // can't expand, so the tap is a no-op there.
        .onTapGesture {
            if canExpand {
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

    private func highlighted(_ text: String) -> AttributedString {
        Highlighting.highlight(
            text,
            term: vm.searchTerm.isEmpty ? nil : vm.searchTerm,
            isRegex: vm.searchIsRegex
        )
    }

    /// Marks the match the user jumped to, so ▲ ▼ has somewhere to land.
    @ViewBuilder
    private var currentMatchOutline: some View {
        if vm.currentMatchId == record.id {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        }
    }

    @ViewBuilder
    private var valueTags: some View {
        let jwt = decode?.chip ?? nestedStatus
        if let badge = decode?.badgeKind, !(badge == .jwt && jwt != nil) {
            DecodeBadge(kind: badge)
        }
        if let jwt {
            JWTStatusChip(status: jwt, isNested: decode?.chip == nil)
        }
    }

    private var nestedStatus: JWTStatus? {
        if let tree = decode?.tree {
            return LeafDecoder.nestedJWTStatus(in: tree)
        }
        if record.isContainer {
            return LeafDecoder.nestedJWTStatus(in: record)
        }
        return nil
    }

    @ViewBuilder
    private var chevron: some View {
        if canExpand {
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
            return JSONSyntax.oneLine(valueText)
        }
        if record.isContainer {
            return record.itemCount == 1 ? "1 key" : "\(record.itemCount) keys"
        }
        return ""
    }

    @ViewBuilder
    private var actions: some View {
        // Editing affordances hidden for past sessions — the device
        // that recorded the session is gone, so writes would silently
        // fail. Copy always works, device or not.
        let canWrite = isViewingLiveSession
        HStack(spacing: 4) {
            if record.isContainer {
                // Namespace: [+] [copy as JSON]. No delete — the SDK
                // has no command to remove a whole namespace.
                if canWrite {
                    RowIconButton(
                        systemImage: "plus",
                        help: isClientConnected
                            ? "Add a key inside \(record.key)"
                            : "Reconnect the device to add a key"
                    ) { onAddInside(record, namespace) }
                    .disabled(!isClientConnected)
                }
                RowIconButton(systemImage: "doc.on.doc",
                              help: "Copy all keys inside as JSON",
                              action: copyNamespaceContents)
            } else {
                // Scalar top-level key: [key] [copy] [edit] [delete],
                // no subscope. SDK: `storage.<ns>.set|delete <key>`.
                RowIconButton(systemImage: "key",
                              help: "Copy key name",
                              action: copyKeyName)
                RowIconButton(systemImage: "doc.on.doc",
                              help: "Copy this value",
                              action: copyNamespaceContents)
                if canWrite {
                    RowIconButton(
                        systemImage: "pencil",
                        help: isClientConnected ? "Edit this value" : "Reconnect the device to edit"
                    ) { onEdit(namespace, nil, record.key, record.valueText ?? "") }
                    .disabled(!isClientConnected)
                    RowIconButton(
                        systemImage: "trash",
                        help: isClientConnected ? "Delete this top-level key" : "Reconnect the device to delete"
                    ) { onDelete(record, namespace) }
                    .disabled(!isClientConnected)
                }
            }
        }
        .opacity(isHovered ? 1 : 0)
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
    @Bindable var vm: StoragesViewModel
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
    /// Receives the raw stored string to prefill the edit sheet.
    let onEdit: (String) -> Void
    let onField: StorageFieldAction

    @State private var isHovered = false
    @State private var showingFullValue = false
    @Environment(ToastCenter.self) private var toasts

    // MARK: Decoding

    /// A device stores nearly everything as text, so most leaves are
    /// really JSON, Base64 or a token. Result is cached inside
    /// `LeafDecoder`, so re-evaluating `body` is cheap.
    private var decode: LeafDecode? {
        guard case .string(let raw) = child.kind else { return nil }
        return LeafDecoder.decode(raw)
    }

    /// The exact stored string — what copy and edit act on, and what the
    /// Raw tab shows. Native containers have no stored string of their
    /// own, so they fall back to pretty-printed JSON.
    private var rawText: String {
        switch child.kind {
        case .string(let s):  return s
        case .number(let n):  return n
        case .bool(let b):    return b ? "true" : "false"
        case .null:           return "null"
        case .object, .array: return StorageRecord.serializeJSON(child)
        }
    }

    /// The token's own verdict, when the value *is* a token.
    private var jwtSelf: JWTStatus? { decode?.chip }

    /// A verdict for a token buried inside the value — so a Base64 blob
    /// holding a stale token reads `JWT-EXPIRED` un-expanded. The scan is
    /// depth-bounded, and every string leaf it touches hits the decode
    /// cache, so this stays cheap on re-render.
    private var jwtNested: JWTStatus? {
        guard jwtSelf == nil else { return nil }
        if let tree = decode?.tree {
            return LeafDecoder.nestedJWTStatus(in: tree)
        }
        if child.isContainer {
            return LeafDecoder.nestedJWTStatus(in: child)
        }
        return nil
    }

    // MARK: Expansion

    private var isExpanded: Bool {
        vm.isExpanded(record: child, in: namespace)
    }

    private var showingRaw: Binding<Bool> {
        Binding(
            get: { vm.isShowingRaw(record: child, in: namespace) },
            set: { vm.setShowingRaw($0, record: child, in: namespace) }
        )
    }

    /// Anything with a Formatted view opens in place: a native container,
    /// or a string that decoded to a tree or to readable text.
    private var canExpandInline: Bool {
        if child.isContainer, !(child.children?.isEmpty ?? true) { return true }
        guard let decode else { return false }
        return decode.tree != nil || decode.text != nil
    }

    /// The popover is for reading a value end-to-end. Short scalars fit
    /// on the row and don't need it.
    private var canOpenPopover: Bool {
        if canExpandInline { return true }
        if case .string(let s) = child.kind { return s.count > 60 }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded, canExpandInline {
                expandedContent
                    // Line the subtree up under this row's value column.
                    .padding(.leading, 44)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: Row

    private var row: some View {
        HStack(spacing: 6) {
            // Indent past the parent's chevron gutter so the inner
            // key:value column aligns visually under the namespace
            // row's key label.
            Color.clear.frame(width: 16)
            inlineChevron

            JSONSyntax.row(
                key: child.key,
                isArrayIndex: child.key.looksLikeJSONArrayIndex,
                kind: child.kind,
                highlight: vm.searchTerm.isEmpty ? nil : vm.searchTerm,
                isRegex: vm.searchIsRegex
            )
            // .callout monospaced (13pt) — readable at standard
            // zoom without dominating the layout. Was .caption
            // (12pt) which felt cramped over long lists.
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.tail)

            valueTags

            // Right after the value, same as the JSON tree: at the far
            // edge it was unclear which row the buttons acted on.
            HStack(spacing: 4) {
                if canOpenPopover {
                    RowIconButton(
                        systemImage: "rectangle.expand.vertical",
                        help: canExpandInline ? "View formatted / raw" : "Show full value"
                    ) { showingFullValue = true }
                    .popover(isPresented: $showingFullValue,
                             arrowEdge: .leading) {
                        StorageValuePopover(
                            record: child,
                            onCopyKey: copyKeyName,
                            onEdit: isLiveSession && !child.isContainer
                                ? { showingFullValue = false; onEdit(rawText) } : nil,
                            onDelete: isLiveSession
                                ? { showingFullValue = false; onDelete() } : nil,
                            canWrite: isClientConnected
                        )
                    }
                }

                RowIconButton(systemImage: "key", help: "Copy key name", action: copyKeyName)
                RowIconButton(systemImage: "doc.on.doc", help: "Copy this value", action: onCopy)

                // Hidden entirely for past sessions — see comments
                // above on isLiveSession.
                if isLiveSession {
                    // Native objects/arrays have no single stored string
                    // to edit; edit their leaves instead.
                    if !child.isContainer {
                        RowIconButton(
                            systemImage: "pencil",
                            help: isClientConnected ? "Edit this value" : "Reconnect the device to edit"
                        ) { onEdit(rawText) }
                        .disabled(!isClientConnected)
                    }
                    RowIconButton(
                        systemImage: "trash",
                        help: isClientConnected
                            ? "Delete this key inside \(parent.key)"
                            : "Reconnect the device to delete",
                        action: onDelete
                    )
                    .disabled(!isClientConnected)
                }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // Vertical breathing room: was 3, now 6. Long namespaces
        // (50+ keys) read as a comfortable list instead of a wall.
        .padding(.vertical, 6)
        .background(rowBackground)
        .modifier(ChangeFlash(
            isChanged: vm.isChanged(record: child, in: namespace),
            generation: vm.changeGeneration
        ))
        .overlay {
            if vm.currentMatchId == child.id {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard canExpandInline else { return }
            vm.toggleExpansion(record: child, in: namespace)
        }
        // Right-click → copy options. Mirrors NamespaceRow's
        // pattern so the muscle memory is the same on both levels.
        .contextMenu {
            Button(action: copyKeyName) {
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

    /// The wrapper badge and the token verdict. The badge is dropped when
    /// a `jwt` chip is already saying the same thing.
    @ViewBuilder
    private var valueTags: some View {
        let jwt = jwtSelf ?? jwtNested
        if let badge = decode?.badgeKind, !(badge == .jwt && jwt != nil) {
            DecodeBadge(kind: badge)
        }
        if let jwt {
            JWTStatusChip(status: jwt, isNested: jwtSelf == nil)
        }
    }

    // MARK: Expanded body

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            DecodeTabBar(
                showingRaw: showingRaw,
                note: decode?.note ?? ""
            )

            if showingRaw.wrappedValue {
                RawValueBlock(text: rawText)
            } else if let decode {
                if decode.isJWT {
                    JWTSummaryView(status: decode.chip, claims: decode.jwtClaims)
                }
                if let tree = decode.tree {
                    subtree(of: tree)
                        .environment(\.storageFieldEditor, storageFieldEditor(
                            decode: decode,
                            target: StorageFieldTarget(namespace: namespace, parentKey: parent.key,
                                                       key: child.key, storedJSON: rawText,
                                                       field: tree),
                            live: isLiveSession, connected: isClientConnected, onField: onField
                        ))
                } else if let text = decode.text {
                    RawValueBlock(text: text)
                }
            } else {
                subtree(of: child)
            }
        }
    }

    @ViewBuilder
    private func subtree(of record: StorageRecord) -> some View {
        if let children = record.children, !children.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                JSONTreeList(children: children)
            }
        }
    }

    private func copyKeyName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(child.key, forType: .string)
        toasts.success("Copied key name")
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

    @ViewBuilder
    private var inlineChevron: some View {
        if canExpandInline {
            Button {
                vm.toggleExpansion(record: child, in: namespace)
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
            // Reserve the gutter so scalar and container rows align.
            Color.clear.frame(width: 10, height: 10)
        }
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
            Color.secondary.opacity(0.07)
        }
    }
}


// MARK: - Space warning

private extension View {
    /// Red outline + a one-line note under a field when `isOn`.
    func spaceWarning(_ isOn: Bool, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.red, lineWidth: 1)
                    .opacity(isOn ? 1 : 0)
            )
            if isOn {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Change flash

/// Briefly tints a row whose value just appeared or changed on the
/// device, then fades out.
private struct ChangeFlash: ViewModifier {
    let isChanged: Bool
    let generation: Int

    @State private var intensity = 0.0

    func body(content: Content) -> some View {
        content
            .background(Color.yellow.opacity(0.3 * intensity))
            // Runs on appear too, so a freshly added row flashes.
            .task(id: generation) {
                guard isChanged else { return }
                intensity = 1
                // Let the full tint render before fading it.
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeOut(duration: 1.2)) { intensity = 0 }
            }
    }
}

// MARK: - Row icon button

/// Small bordered square icon — the copy / edit / delete / add tail on
/// storage rows.
private struct RowIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
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
    let onCopyKey: () -> Void
    /// nil hides the button (past session, or nothing to edit).
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let canWrite: Bool

    @Environment(ToastCenter.self) private var toasts
    @State private var showingRaw = false

    private var decode: LeafDecode? {
        guard case .string(let raw) = record.kind else { return nil }
        return LeafDecoder.decode(raw)
    }

    /// True when there is something to show other than the stored
    /// string — a decoded tree, decoded text, or a native container.
    private var hasFormattedView: Bool {
        if record.kind.isContainer { return true }
        guard let decode else { return false }
        return decode.tree != nil || decode.text != nil
    }

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

    /// The Formatted view as text — only when it differs from the stored
    /// string (a JSON string, Base64 or a token).
    private var decodedPretty: String? {
        guard let decode else { return nil }
        if let tree = decode.tree { return StorageRecord.serializeJSON(tree) }
        return decode.text
    }

    private func copy(_ text: String, _ toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toasts.success(toast)
    }

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
                if let badge = decode?.badgeKind,
                   !(badge == .jwt && decode?.chip != nil) {
                    DecodeBadge(kind: badge)
                }
                if let status = decode?.chip {
                    JWTStatusChip(status: status)
                }
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
                // Same tail as the row, plus the decoded value pretty-printed.
                RowIconButton(systemImage: "key", help: "Copy key name", action: onCopyKey)
                RowIconButton(systemImage: "doc.on.doc",
                              help: record.kind.isContainer ? "Copy pretty-printed JSON" : "Copy value") {
                    copy(bodyText, record.kind.isContainer ? "Copied JSON" : "Copied value")
                }
                if let pretty = decodedPretty {
                    RowIconButton(systemImage: "curlybraces", help: "Copy decoded value, pretty-printed") {
                        copy(pretty, "Copied decoded value")
                    }
                }
                if let onEdit {
                    RowIconButton(systemImage: "pencil",
                                  help: canWrite ? "Edit this value" : "Reconnect the device to edit",
                                  action: onEdit)
                    .disabled(!canWrite)
                }
                if let onDelete {
                    RowIconButton(systemImage: "trash",
                                  help: canWrite ? "Delete this key" : "Reconnect the device to delete",
                                  action: onDelete)
                    .disabled(!canWrite)
                }
            }

            Divider()

            if hasFormattedView {
                DecodeTabBar(showingRaw: $showingRaw, note: decode?.note ?? "")
            }

            ScrollView {
                if showingRaw || !hasFormattedView {
                    // The exact stored string, escaping and all.
                    Text(bodyText)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    formattedBody
                }
            }
        }
        .padding(14)
        .frame(width: 540, height: 380)
    }

    @ViewBuilder
    private var formattedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decode {
                if decode.isJWT {
                    JWTSummaryView(status: decode.chip, claims: decode.jwtClaims)
                }
                if let tree = decode.tree {
                    subtree(of: tree)
                } else if let text = decode.text {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                subtree(of: record)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func subtree(of node: StorageRecord) -> some View {
        if let children = node.children, !children.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                JSONTreeList(children: children)
            }
        }
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
    /// Non-nil = edit mode: this key is fixed, only the value changes.
    let editKey: String?
    /// Field mode: the value typed is one field's; `transform` turns it
    /// into the whole stored value (nil = can't).
    let fieldLabel: String?
    let transform: ((String) -> String?)?

    /// What actually gets sent as the key's value.
    private var outgoingValue: String? {
        guard let transform else { return value }
        return transform(value)
    }
    let onSave: (StorageSnapshot.Namespace, String?, String, String) -> Void
    let onCancel: () -> Void

    @State private var key: String
    @State private var value: String

    init(initialNamespace: StorageSnapshot.Namespace,
         initialParent: String?,
         editKey: String? = nil,
         initialValue: String = "",
         fieldLabel: String? = nil,
         transform: ((String) -> String?)? = nil,
         onSave: @escaping (StorageSnapshot.Namespace, String?, String, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialNamespace = initialNamespace
        self.initialParent = initialParent
        self.editKey = editKey
        self.fieldLabel = fieldLabel
        self.transform = transform
        self.onSave = onSave
        self.onCancel = onCancel
        _key = State(initialValue: editKey ?? "")
        _value = State(initialValue: initialValue)
    }
    /// User-typed subscope for top-level mode. Trimmed and folded
    /// to `nil` on save when empty.
    @State private var manualParent: String = ""

    // The SDK splits commands on spaces with no quoting. A space in the
    // key or namespace shifts every argument and writes the wrong key,
    // so it blocks Save; a space in the value only truncates it, so
    // that one just warns.
    private static func hasInnerSpace(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace)
    }
    private var keyHasSpaces: Bool { Self.hasInnerSpace(key) }
    private var parentHasSpaces: Bool { Self.hasInnerSpace(manualParent) }
    private var valueHasSpaces: Bool { (outgoingValue ?? value).contains(where: \.isWhitespace) }

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyHasSpaces && !parentHasSpaces && outgoingValue != nil
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
        var cmd = "storage.\(initialNamespace.wireKey).set \(key) \(outgoingValue ?? "…")"
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
                Text(editKey.map { key in fieldLabel.map { "Edit \(key) › \($0)" } ?? "Edit \(key)" }
                     ?? (isInside ? "Add key inside \(initialParent!)" : "Add key"))
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

            if editKey == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Key").font(.caption).foregroundStyle(.secondary)
                    TextField(
                        isInside ? "e.g. premium" : "e.g. featureFlag.premium",
                        text: $key
                    )
                    .textFieldStyle(.roundedBorder)
                    .spaceWarning(keyHasSpaces, "Key can't contain spaces.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. true", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .spaceWarning(valueHasSpaces,
                                  "The device splits on spaces — only the first word may be stored.")
            }

            // Optional subscope — only shown in top-level mode.
            // Leave blank to write at the layer's root; type a
            // name to put the pair inside that subscope.
            if !isInside && editKey == nil {
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
                        .spaceWarning(parentHasSpaces, "Namespace can't contain spaces.")
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
                        outgoingValue ?? value
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
