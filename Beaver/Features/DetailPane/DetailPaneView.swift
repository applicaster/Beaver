//
//  DetailPaneView.swift
//  Beaver
//

import SwiftUI

/// Right-hand pane in the log feed — shows the full payload for the
/// selected event, including `data` and `context` rendered as a
/// recursive JSON tree via `OutlineGroup`. Replaces the old
/// hand-rolled `DataModel` walker (see ARCHITECTURE.md §13).
struct DetailPaneView: View {
    let event: EventRecord?
    /// Already parsed by the caller — never parse in `body`.
    var data: StorageRecord?
    var context: StorageRecord?
    /// Rows selected in the table; the pane details exactly one.
    var selectionCount = 0

    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        if let event {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(event)
                    Divider()
                    metadata(event)
                    if let data {
                        sectionHeader("Data", copy: event.dataJSON)
                        treeView(root: data)
                    }
                    if let context {
                        sectionHeader("Context", copy: event.contextJSON)
                        treeView(root: context)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if selectionCount > 1 {
            ContentUnavailableView(
                "\(selectionCount) events selected",
                systemImage: "rectangle.stack",
                description: Text("⌘C copies them as log lines.")
            )
        } else {
            ContentUnavailableView(
                "No event selected",
                systemImage: "rectangle.inset.filled"
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header(_ event: EventRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(event.level.displayColor)
                    .frame(width: 10, height: 10)
                Text(event.level.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(event.level.displayColor)
            }
            // Monospaced so stack traces and pretty-printed JSON line
            // up; capped and scrollable so a long one doesn't push the
            // metadata and payload out of reach.
            ScrollView {
                Text(event.message)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(.separatorColor), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func metadata(_ event: EventRecord) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Subsystem", event.subsystem)
            row("Category",  event.category.isEmpty ? "—" : event.category)
            row("Time",      event.fullTimestamp)
            row("Session",   String(event.sessionId))
        }
        .font(.caption)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    /// `raw` is the stored JSON, copied verbatim.
    @ViewBuilder
    private func sectionHeader(_ title: String, copy raw: String?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let raw {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                    toasts.success("Copied \(title.lowercased())")
                } label: {
                    Label("Copy \(title.lowercased())", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy the whole \(title.lowercased()) payload as JSON")
            }
        }
        .padding(.top, 4)
    }

    /// Paged: a payload with thousands of siblings at one level used to
    /// lay every row out at once and freeze the pane.
    @ViewBuilder
    private func treeView(root: StorageRecord) -> some View {
        JSONTreeView(record: root)
            .environment(\.jsonTreePageSize, 200)
    }
}
