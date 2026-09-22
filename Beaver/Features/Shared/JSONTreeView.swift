import SwiftUI

/// Recursive JSON tree, shared by the log detail pane (DATA / CONTEXT)
/// and the storage inspector — the same arrangement the web viewer uses,
/// where one `<xray-json-tree>` serves both screens.
///
/// Indents children by `depth × indentStep` and gives every row a hover
/// copy action: the raw value on a leaf, the whole subtree as JSON on a
/// container.
///
/// Hand-rolled rather than `OutlineGroup`: its automatic indentation
/// doesn't show through outside a `List`, which rendered the tree
/// visually flat. This adds explicit leading padding per depth and draws
/// its own disclosure chevron, so nesting reads at a glance.
struct JSONTreeView: View {
    let record: StorageRecord
    var depth: Int = 0

    @State private var isExpanded: Bool = true

    private static let indentStep: CGFloat = 14

    private var hasChildren: Bool {
        !(record.children?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                disclosureChevron
                JSONTreeRow(record: record)
            }
            .padding(.leading, CGFloat(depth) * Self.indentStep)

            if isExpanded, let children = record.children, !children.isEmpty {
                ForEach(children) { child in
                    JSONTreeView(record: child, depth: depth + 1)
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
            // Reserve the gutter so leaf and container rows align.
            Color.clear.frame(width: 10, height: 10)
        }
    }
}

private struct JSONTreeRow: View {
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
        case .string(let raw): payload = raw
        case .number(let n):   payload = n
        case .bool(let b):     payload = b ? "true" : "false"
        case .null:            payload = "null"
        case .object, .array:  payload = StorageRecord.serializeJSON(record)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}
