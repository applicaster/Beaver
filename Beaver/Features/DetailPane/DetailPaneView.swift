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

    var body: some View {
        if let event {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(event)
                    Divider()
                    metadata(event)
                    if let data = event.dataJSON, let tree = StorageRecord.parse(data) {
                        sectionHeader("Data")
                        treeView(root: tree)
                    }
                    if let context = event.contextJSON, let tree = StorageRecord.parse(context) {
                        sectionHeader("Context")
                        treeView(root: tree)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            Text(event.message)
                .font(.title3)
                .textSelection(.enabled)
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

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func treeView(root: StorageRecord) -> some View {
        JSONTreeView(record: root)
    }
}
