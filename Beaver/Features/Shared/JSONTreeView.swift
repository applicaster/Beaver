import SwiftUI

/// Edit / delete for the fields of a stored JSON value. Set by the
/// storage screen around a decoded tree; `nil` everywhere else (log
/// detail, popover), so those trees stay copy-only.
struct StorageFieldEditor {
    /// False while the device is disconnected — buttons show disabled.
    let canWrite: Bool
    let edit: @MainActor (StorageRecord) -> Void
    let delete: @MainActor (StorageRecord) -> Void
}

extension EnvironmentValues {
    @Entry var storageFieldEditor: StorageFieldEditor? = nil
}

/// Recursive JSON tree, shared by the log detail pane (DATA / CONTEXT)
/// and the storage inspector — the same arrangement the web viewer uses,
/// where one `<xray-json-tree>` serves both screens.
///
/// Indents children by `depth × indentStep` and gives every row a hover
/// copy action: the raw value on a leaf, the whole subtree as JSON on a
/// container.
///
/// String leaves are decoded too, so a token nested inside a payload —
/// `{ "token": "eyJ…" }` — carries its own badge and validity chip and
/// opens into a readable tree, rather than being a wall of base64.
///
/// Hand-rolled rather than `OutlineGroup`: its automatic indentation
/// doesn't show through outside a `List`, which rendered the tree
/// visually flat. This adds explicit leading padding per depth and draws
/// its own disclosure chevron, so nesting reads at a glance.
struct JSONTreeView: View {
    let record: StorageRecord
    var depth: Int = 0
    /// Position among its siblings, for zebra striping.
    var rowIndex: Int = 0
    /// Opens this node on first show when it's a decodable leaf (Base64 /
    /// JWT / JSON text), which otherwise starts closed regardless of
    /// depth. A container at depth 0 already falls within the
    /// auto-expand budget below and needs no help. Not passed down to
    /// children.
    var expandsRoot: Bool = false

    /// `nil` until the user touches this node, then their choice.
    /// Containers start open (the structure is the point); a decodable
    /// leaf starts closed, so a payload full of tokens isn't unrolled.
    @State private var expandedOverride: Bool?

    private static let indentStep: CGFloat = 14

    /// How many levels open by themselves.
    ///
    /// The rows are a plain `VStack`, so everything expanded is
    /// materialised at once — and each row costs a `body` evaluation
    /// plus its attribute-graph nodes. A payload nested five deep used
    /// to render in full on sight; a profile caught exactly that,
    /// thousands of `JSONTreeRow.body` frames stacked inside each other.
    /// Two levels show the shape; the rest is one click away.
    private static let autoExpandDepth = 2

    private var hasChildren: Bool {
        !(record.children?.isEmpty ?? true)
    }

    /// Result is cached inside `LeafDecoder`, so re-evaluating `body`
    /// doesn't re-decode.
    private var decode: LeafDecode? {
        guard case .string(let raw) = record.kind else { return nil }
        return LeafDecoder.decode(raw)
    }

    private var decodedContent: LeafDecode? {
        guard let decode, decode.tree != nil || decode.text != nil else { return nil }
        return decode
    }

    private var canOpen: Bool {
        hasChildren || decodedContent != nil
    }

    private var isExpanded: Bool {
        expandedOverride ?? ((expandsRoot && canOpen) || (hasChildren && depth < Self.autoExpandDepth))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                disclosureChevron
                JSONTreeRow(record: record, decode: decode, rowIndex: rowIndex)
            }
            .padding(.leading, CGFloat(depth) * Self.indentStep)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canOpen else { return }
                expandedOverride = !isExpanded
            }

            if isExpanded {
                if let decoded = decodedContent {
                    decodedBody(decoded)
                        .padding(.leading, CGFloat(depth + 1) * Self.indentStep)
                        // A value decoded out of a field would need
                        // re-encoding to write back — copy-only.
                        .environment(\.storageFieldEditor, nil)
                } else if let children = record.children, !children.isEmpty {
                    JSONTreeList(children: children, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func decodedBody(_ decoded: LeafDecode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !decoded.note.isEmpty {
                Text(decoded.note)
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            if decoded.isJWT {
                JWTSummaryView(status: decoded.chip, claims: decoded.jwtClaims)
            }
            if let tree = decoded.tree, let children = tree.children, !children.isEmpty {
                // Carries the depth on: a decoded subtree is deeper than
                // its parent, not a fresh tree, so it neither restarts the
                // auto-expand budget nor the indent.
                JSONTreeList(children: children, depth: depth + 1)
            } else if let text = decoded.text {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var disclosureChevron: some View {
        if canOpen {
            Button {
                expandedOverride = !isExpanded
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // Reserve the gutter so leaf and container rows align.
            Color.clear.frame(width: 10, height: 10)
        }
    }
}

/// Sibling rows of one tree level, each told its position so the rows
/// can stripe.
struct JSONTreeList: View {
    let children: [StorageRecord]
    var depth: Int = 0

    var body: some View {
        ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
            JSONTreeView(record: child, depth: depth, rowIndex: index)
        }
    }
}

private struct JSONTreeRow: View {
    let record: StorageRecord
    let decode: LeafDecode?
    let rowIndex: Int

    @State private var isHovered = false
    @Environment(\.storageFieldEditor) private var editor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            JSONSyntax.row(
                key: record.key,
                isArrayIndex: record.key.looksLikeJSONArrayIndex,
                kind: record.kind
            )
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.tail)

            valueTags

            // Right after the value, not at the far edge: on a wide pane
            // the button drifted so far from short rows that it was
            // unclear which one it would copy.
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

            if let editor {
                HStack(spacing: 6) {
                    // Containers are removed whole; only leaves take a new value.
                    if !record.kind.isContainer {
                        treeButton("pencil", editor.canWrite ? "Edit this field" : "Reconnect the device to edit") {
                            editor.edit(record)
                        }
                    }
                    treeButton("trash", editor.canWrite ? "Delete this field" : "Reconnect the device to delete") {
                        editor.delete(record)
                    }
                }
                .disabled(!editor.canWrite)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }

            // Keeps the hover area the full row width.
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// Same tints as a storage key row. Hover marks the row the copy
    /// button belongs to; the faint stripes keep the eye on one line
    /// from key to value across a wide pane. Striping counts siblings,
    /// so where levels meet two neighbours can share a shade.
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

    /// Wrapper badge and token verdict, same rules as a storage row: the
    /// badge is dropped when a `jwt` chip already says it.
    @ViewBuilder
    private var valueTags: some View {
        if let decode {
            if let badge = decode.badgeKind, !(badge == .jwt && decode.chip != nil) {
                DecodeBadge(kind: badge)
            }
            if let status = decode.chip {
                JWTStatusChip(status: status)
            }
        }
    }

    private func treeButton(_ systemImage: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Copies what was stored, never the decoded view.
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
