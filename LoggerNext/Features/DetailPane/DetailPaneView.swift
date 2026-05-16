//
//  DetailPaneView.swift
//  LoggerNext
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
                    if let data = event.dataJSON, let tree = JSONTreeNode.parse(data) {
                        sectionHeader("Data")
                        treeView(root: tree)
                    }
                    if let context = event.contextJSON, let tree = JSONTreeNode.parse(context) {
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
    private func treeView(root: JSONTreeNode) -> some View {
        OutlineGroup(root, children: \.children) { node in
            JSONTreeRow(node: node)
        }
    }
}

// MARK: - JSON tree row

/// One row in the OutlineGroup. Owns its hover state so it can reveal
/// a copy icon on the right when the pointer is over it.
private struct JSONTreeRow: View {
    let node: JSONTreeNode
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(node.label)
                .foregroundStyle(.secondary)
                .frame(width: node.labelColumnWidth, alignment: .trailing)
                .help(node.label)

            if let value = node.valueText {
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            // Copy button: reserves space always (so layout is stable),
            // becomes visible + clickable only when the row is hovered.
            Button {
                copyToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(node.valueText == nil
                  ? "Copy as JSON"
                  : "Copy value")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .font(.system(.caption, design: .monospaced))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// Leaf rows copy the raw value (string without JSON quotes,
    /// numbers/bools/null as-is). Container rows copy the subtree
    /// as pretty-printed JSON.
    private func copyToPasteboard() {
        let payload: String
        if let value = node.valueText {
            // Strip the surrounding quotes that we added when
            // displaying strings (`"hello"` → `hello`).
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                payload = String(value.dropFirst().dropLast())
            } else {
                payload = value
            }
        } else {
            payload = JSONTreeNode.serializeJSON(node)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}

// MARK: - JSON tree

/// Recursive model for rendering arbitrary JSON in an `OutlineGroup`.
///
/// Replaces the old `DataModel` + `DataModelHelper.prepareDataSource…`
/// machinery (≈200 LOC) with about 60. Parse-once; no in-row recursion.
struct JSONTreeNode: Identifiable, Hashable {
    let id: String
    let label: String
    let valueText: String?
    let children: [JSONTreeNode]?

    /// Width of the label column for THIS node's row. Set by the parent
    /// so all siblings within the same group share the same column,
    /// making value columns line up.
    var labelColumnWidth: CGFloat = 90

    static func parse(_ json: String) -> JSONTreeNode? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        return build(label: "root", value: raw, path: "$")
    }

    private static func build(label: String, value: Any, path: String) -> JSONTreeNode {
        switch value {
        case let dict as [String: Any]:
            let sortedKeys = dict.keys.sorted()
            var children = sortedKeys.map { key in
                build(label: key, value: dict[key]!, path: "\(path).\(key)")
            }
            // All siblings get the same label column width = max width
            // among their labels. Width estimate is based on monospaced
            // .caption font (~6.7pt per char), with small padding.
            let column = estimatedColumnWidth(forLabels: children.map(\.label))
            for i in children.indices { children[i].labelColumnWidth = column }
            return JSONTreeNode(
                id: path,
                label: "\(label)  { \(children.count) }",
                valueText: nil,
                children: children.isEmpty ? nil : children
            )
        case let array as [Any]:
            var children = array.enumerated().map { (index, element) in
                build(label: "[\(index)]", value: element, path: "\(path)[\(index)]")
            }
            let column = estimatedColumnWidth(forLabels: children.map(\.label))
            for i in children.indices { children[i].labelColumnWidth = column }
            return JSONTreeNode(
                id: path,
                label: "\(label)  [ \(children.count) ]",
                valueText: nil,
                children: children.isEmpty ? nil : children
            )
        case is NSNull:
            return JSONTreeNode(id: path, label: label, valueText: "null", children: nil)
        case let bool as Bool:
            return JSONTreeNode(id: path, label: label, valueText: bool ? "true" : "false", children: nil)
        case let number as NSNumber:
            return JSONTreeNode(id: path, label: label, valueText: number.stringValue, children: nil)
        case let string as String:
            return JSONTreeNode(id: path, label: label, valueText: "\"\(string)\"", children: nil)
        default:
            return JSONTreeNode(id: path, label: label, valueText: String(describing: value), children: nil)
        }
    }

    /// Serialize a subtree as pretty-printed JSON for the copy action.
    /// Reconstructs the JSON shape from the tree representation: leaf
    /// `valueText` is already JSON-valid (`"str"`, `true`, `123`,
    /// `null`); containers become `{...}` (object) or `[...]` (array)
    /// depending on whether their children labels look like `[N]`
    /// indices.
    static func serializeJSON(_ node: JSONTreeNode, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)

        if let value = node.valueText {
            return value
        }
        guard let children = node.children, !children.isEmpty else {
            return "null"
        }
        let isArray = children.allSatisfy {
            $0.label.hasPrefix("[") && $0.label.hasSuffix("]")
        }
        if isArray {
            let parts = children.map { child in
                "\(innerPad)\(serializeJSON(child, indent: indent + 1))"
            }
            return "[\n" + parts.joined(separator: ",\n") + "\n\(pad)]"
        } else {
            let parts = children.map { child in
                let escapedKey = child.label
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\(innerPad)\"\(escapedKey)\": \(serializeJSON(child, indent: indent + 1))"
            }
            return "{\n" + parts.joined(separator: ",\n") + "\n\(pad)}"
        }
    }

    /// Approximate pixel width for the widest label in a sibling group.
    /// Tuned for `.system(.caption, design: .monospaced)`; the char
    /// width is ~6.7pt at typical caption size. Capped so a single
    /// pathological key doesn't blow out the whole detail pane.
    private static func estimatedColumnWidth(forLabels labels: [String]) -> CGFloat {
        let maxChars = labels.map(\.count).max() ?? 0
        let approx = CGFloat(maxChars) * 6.7 + 6
        return min(max(approx, 70), 300)   // floor 70, ceiling 300
    }
}
