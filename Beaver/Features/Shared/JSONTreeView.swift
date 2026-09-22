import SwiftUI

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

    /// `nil` until the user touches this node, then their choice.
    /// Containers start open (the structure is the point); a decodable
    /// leaf starts closed, so a payload full of tokens isn't unrolled.
    @State private var expandedOverride: Bool?

    private static let indentStep: CGFloat = 14

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
        expandedOverride ?? hasChildren
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                disclosureChevron
                JSONTreeRow(record: record, decode: decode)
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
                } else if let children = record.children, !children.isEmpty {
                    ForEach(children) { child in
                        JSONTreeView(record: child, depth: depth + 1)
                    }
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
                ForEach(children) { child in
                    JSONTreeView(record: child)
                }
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
            .help(isExpanded ? "Collapse" : "Expand")
        } else {
            // Reserve the gutter so leaf and container rows align.
            Color.clear.frame(width: 10, height: 10)
        }
    }
}

private struct JSONTreeRow: View {
    let record: StorageRecord
    let decode: LeafDecode?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            JSONSyntax.row(
                key: record.key,
                isArrayIndex: record.key.looksLikeJSONArrayIndex,
                kind: record.kind
            )
            .textSelection(.enabled)
            .help(record.key)
            .lineLimit(1)
            .truncationMode(.tail)

            valueTags

            Spacer(minLength: 6)

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
