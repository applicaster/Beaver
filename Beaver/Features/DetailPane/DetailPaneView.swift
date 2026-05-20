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
        // Manual recursive tree — OutlineGroup's automatic
        // indentation doesn't show through outside of a List, which
        // made the tree visually flat. `JSONTree` adds explicit
        // leading padding per depth and renders its own disclosure
        // chevron, so nesting reads at a glance.
        JSONTree(node: root, depth: 0)
    }
}

// MARK: - JSON tree

/// Recursive tree renderer. Indents children by `depth × indentStep`
/// so the JSON structure reads visually as a tree, and owns its
/// expand/collapse state per node. Each row is a `JSONTreeRow`.
private struct JSONTree: View {
    let node: JSONTreeNode
    let depth: Int

    @State private var isExpanded: Bool = true

    /// Visual indent applied per nesting level.
    private static let indentStep: CGFloat = 14

    private var hasChildren: Bool {
        !(node.children?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                disclosureChevron
                JSONTreeRow(node: node)
            }
            .padding(.leading, CGFloat(depth) * Self.indentStep)

            if isExpanded, let children = node.children, !children.isEmpty {
                ForEach(children) { child in
                    JSONTree(node: child, depth: depth + 1)
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
            // Leaf rows still reserve the same gutter so keys + values
            // line up under their container's content column.
            Color.clear.frame(width: 10, height: 10)
        }
    }
}

// MARK: - JSON tree row

/// One row in the tree. Renders `"key": value` (or `[N]:` for array
/// elements) as a single syntax-coloured Text, with a hover-revealed
/// copy icon on the right.
private struct JSONTreeRow: View {
    let node: JSONTreeNode
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            JSONSyntax.row(
                key: node.label,
                isArrayIndex: node.label.looksLikeJSONArrayIndex,
                kind: node.kind
            )
            .textSelection(.enabled)
            .help(node.label)
            .frame(maxWidth: .infinity, alignment: .leading)

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
            .help(node.kind.isContainer ? "Copy as JSON" : "Copy value")
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
        switch node.kind {
        case .string(let raw):  payload = raw
        case .number(let n):    payload = n
        case .bool(let b):      payload = b ? "true" : "false"
        case .null:             payload = "null"
        case .object, .array:   payload = JSONTreeNode.serializeJSON(node)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}

// MARK: - JSON tree model

/// Recursive model used by `JSONTree`. Parse-once; no in-row
/// recursion. Replaces the old `DataModel` +
/// `DataModelHelper.prepareDataSource…` machinery (≈200 LOC) with
/// about 60.
///
/// `label` is the bare key — no `{ N }` / `[ N ]` summary appended,
/// since `JSONSyntax` renders the summary as its own coloured Text
/// segment.
struct JSONTreeNode: Identifiable, Hashable {
    let id: String
    let label: String
    let kind: JSONKind
    let children: [JSONTreeNode]?

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
            let children = sortedKeys.map { key in
                build(label: key, value: dict[key]!, path: "\(path).\(key)")
            }
            return JSONTreeNode(
                id: path,
                label: label,
                kind: .object(count: children.count),
                children: children.isEmpty ? nil : children
            )
        case let array as [Any]:
            let children = array.enumerated().map { (index, element) in
                build(label: "[\(index)]", value: element, path: "\(path)[\(index)]")
            }
            return JSONTreeNode(
                id: path,
                label: label,
                kind: .array(count: children.count),
                children: children.isEmpty ? nil : children
            )
        case is NSNull:
            return JSONTreeNode(id: path, label: label, kind: .null, children: nil)
        case let bool as Bool:
            return JSONTreeNode(id: path, label: label, kind: .bool(bool), children: nil)
        case let number as NSNumber:
            // Bool was matched above; this branch is real numbers only.
            return JSONTreeNode(
                id: path,
                label: label,
                kind: .number(number.stringValue),
                children: nil
            )
        case let string as String:
            return JSONTreeNode(id: path, label: label, kind: .string(string), children: nil)
        default:
            return JSONTreeNode(
                id: path,
                label: label,
                kind: .string(String(describing: value)),
                children: nil
            )
        }
    }

    /// Serialize a subtree as pretty-printed JSON for the copy action.
    /// Walks `kind` directly — no string-parsing guesswork.
    static func serializeJSON(_ node: JSONTreeNode, indent: Int = 0) -> String {
        let pad      = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)

        switch node.kind {
        case .null:           return "null"
        case .bool(let b):    return b ? "true" : "false"
        case .number(let n):  return n
        case .string(let s):
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .object:
            guard let children = node.children, !children.isEmpty else { return "{}" }
            let parts = children.map { child in
                let escapedKey = child.label
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\(innerPad)\"\(escapedKey)\": \(serializeJSON(child, indent: indent + 1))"
            }
            return "{\n" + parts.joined(separator: ",\n") + "\n\(pad)}"
        case .array:
            guard let children = node.children, !children.isEmpty else { return "[]" }
            let parts = children.map { child in
                "\(innerPad)\(serializeJSON(child, indent: indent + 1))"
            }
            return "[\n" + parts.joined(separator: ",\n") + "\n\(pad)]"
        }
    }
}
