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

    var body: some View {
        VStack(spacing: 0) {
            StoragesTopBar(
                vm: vm,
                onExport: { Task { await prepareExport() } }
            )
            Divider()
            StoragesSearchBar(vm: vm)
            Divider()
            HSplitView {
                StoragesTable(vm: vm)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                StoragesDetail(vm: vm)
                    .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    var body: some View {
        HStack(spacing: 10) {
            // Namespace chips — matches the original "session / local /
            // keychain" tab row. Selected one fills with its color.
            HStack(spacing: 6) {
                ForEach(StorageSnapshot.Namespace.allCases, id: \.self) { ns in
                    NamespaceChip(
                        namespace: ns,
                        isSelected: vm.selectedNamespace == ns,
                        count: vm.recordCount(in: ns),
                        action: { vm.selectedNamespace = ns }
                    )
                }
            }
            .fixedSize()

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

private struct NamespaceChip: View {
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

// MARK: - Table

private struct StoragesTable: View {
    @Bindable var vm: StoragesViewModel

    var body: some View {
        if vm.records.isEmpty {
            ContentUnavailableView(
                "No \(vm.selectedNamespace.displayName.lowercased()) data",
                systemImage: "tray",
                description: Text("Click Reload to fetch from the connected device.")
            )
        } else if vm.filteredRecords.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No keys or values match \"\(vm.searchTerm)\".")
            )
        } else {
            Table(vm.filteredRecords, selection: $vm.selectedRecordId) {
                TableColumn("Key") { row in
                    Text(row.key)
                        .font(.body.weight(.medium))
                }
                .width(min: 200, ideal: 300)

                TableColumn("Value") { row in
                    if let value = row.valueText {
                        Text(value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    } else if row.isContainer {
                        Text(row.itemCount == 1 ? "1 item" : "\(row.itemCount) items")
                            .font(.body)
                            .italic()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("")
                    }
                }
                .width(min: 200, ideal: 400)
            }
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
                        // Leaf record — wrap in StorageTreeRow so the
                        // user gets the same hover-copy affordance as
                        // any nested row.
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
                description: Text("Pick a key from the table to inspect its value.")
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
                Text(vm.selectedNamespace.displayName)
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
