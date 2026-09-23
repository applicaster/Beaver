//
//  NetworkDetailView.swift
//  Beaver
//

import SwiftUI
import AppKit

/// Right-hand pane of the Network tab. Same layout as the Log feed's
/// `DetailPaneView` — header, divider, metadata grid, then uppercase
/// sections with `JSONTreeView` — with the zapp-support header on top:
/// method and status badges, duration, time, and copy buttons, then the
/// request and the response as two separate panels.
struct NetworkDetailView: View {
    let entry: NetworkEntry?
    var isBookmarked = false
    var onToggleBookmark: ((NetworkEntry) -> Void)?
    /// Opens the entry in the large sheet. `nil` inside the sheet itself.
    var onExpand: ((NetworkEntry) -> Void)?

    var body: some View {
        if let entry {
            NetworkDetailContent(entry: entry, isBookmarked: isBookmarked,
                                 onToggleBookmark: onToggleBookmark, onExpand: onExpand)
        } else {
            ContentUnavailableView("No request selected", systemImage: "network")
        }
    }
}

/// Query, header and body trees, built once per entry (bodies run to 100 KB).
private struct ParsedEntry {
    let id: NetworkEntry.ID
    let query: StorageRecord?
    let requestHeaders: StorageRecord?
    let requestBody: StorageRecord?
    let responseHeaders: StorageRecord?
    let responseBody: StorageRecord?

    init(_ e: NetworkEntry) {
        id = e.id
        query = e.queryJSON.flatMap { StorageRecord.parse($0, rootKey: "query") }
        requestHeaders = Self.headers(e.requestHeaders)
        requestBody = Self.body(e.requestBody)
        responseHeaders = Self.headers(e.responseHeaders)
        responseBody = Self.body(e.responseBody)
    }

    private static func headers(_ h: [String: String]) -> StorageRecord? {
        h.isEmpty ? nil : StorageRecord.make(key: "headers", value: h, path: "$")
    }

    /// A tree only for a non-empty object or array; anything else shows as
    /// text. A truncated JSON body fails to parse and lands here too.
    private static func body(_ text: String?) -> StorageRecord? {
        guard let text, !text.isEmpty, let tree = StorageRecord.parse(text, rootKey: "body"),
              tree.children != nil else { return nil }
        return tree
    }
}

private struct NetworkDetailContent: View {
    let entry: NetworkEntry
    let isBookmarked: Bool
    let onToggleBookmark: ((NetworkEntry) -> Void)?
    let onExpand: ((NetworkEntry) -> Void)?

    @Environment(ToastCenter.self) private var toasts
    /// Never parse in `body`: rebuilt only when the selected entry changes.
    @State private var parsed: ParsedEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                metadata
                // nil for the one frame before onChange parses a new entry.
                if let trees = parsed?.id == entry.id ? parsed : nil {
                    groups(trees)
                        // Fresh toggles and tree expansion for every entry.
                        .id(trees.id)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: entry.id, initial: true) { parsed = ParsedEntry(entry) }
    }

    // MARK: Header

    private var duration: String { entry.durationMillis.map { "\($0) ms" } ?? "—" }

    /// `[GET] [403] 274 ms 13:08:24.743 … [⤢] [Copy JSON] [cURL] [fetch]`,
    /// then the URL and the status in large type.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Buttons drop under the badges when the pane is too narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { summary; Spacer(minLength: 8); buttons }
                VStack(alignment: .leading, spacing: 6) { summary; HStack(spacing: 6) { buttons } }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.url)
                    .font(.title3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                copyIcon(help: "Copy URL") { toasts.copy(entry.url, "Copied URL") }
            }
            Text(entry.statusLine)
                .font(.title2.weight(.semibold))
                .foregroundStyle(entry.statusClass.color)
                .textSelection(.enabled)
            // statusLine already carries the error when there is no HTTP status.
            if let error = entry.error, !entry.statusLine.contains(error) {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            MethodBadge(method: entry.method)
            StatusBadge(entry: entry)
            Text(duration)
                .font(.caption.monospaced())
                .foregroundStyle(NetworkView.durationColor(entry.durationMillis))
            Text(NetworkView.time(entry.startMillis))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var buttons: some View {
        Group {
            if let onToggleBookmark {
                Button { onToggleBookmark(entry) } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(isBookmarked ? .yellow : .primary)
                }
                .help(isBookmarked ? "Remove bookmark" : "Bookmark this request")
            }
            if let onExpand {
                Button { onExpand(entry) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Open in a larger window")
            }
            Button("Copy JSON") { toasts.copy(entry.prettyPayloadJSON, "Copied JSON") }
                .help("Copy the whole payload as received")
            Button("cURL") { toasts.copy(entry.curlCommand, "Copied cURL") }
                .help("Copy as a cURL command")
            Button("fetch") { toasts.copy(entry.fetchSnippet, "Copied fetch") }
                .help("Copy as a JavaScript fetch call")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Metadata

    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Host", entry.host.isEmpty ? "—" : entry.host)
            row("Method", entry.method)
            row("Duration", duration)
            row("Started", NetworkView.time(entry.startMillis))
            row("Ended", entry.durationMillis.map {
                NetworkView.time(entry.startMillis + UInt64(max($0, 0)))
            } ?? "—")
            row("Size", NetworkView.size(entry), help: NetworkView.sizeHelp(entry))
            if let error = entry.error {
                row("Error", error, color: .red)
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String, color: Color? = nil, help: String = "") -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Text(value)
                .foregroundStyle(color ?? .primary)
                .textSelection(.enabled)
                .help(help)
        }
    }

    // MARK: Request / Response

    @ViewBuilder
    private func groups(_ trees: ParsedEntry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Request", copy: { toasts.copy(entry.requestJSON, "Copied request") }) {
                if let rawQuery = entry.rawQuery {
                    Subsection(title: "Query parameters (\(entry.queryItems.count))", name: "query",
                               tree: trees.query, raw: rawQuery)
                }
                headers(entry.requestHeaders, tree: trees.requestHeaders, name: "request headers")
                bodySection(entry.requestBody, tree: trees.requestBody, truncated: false, name: "request body")
            }
            group("Response", copy: { toasts.copy(entry.responseJSON, "Copied response") }) {
                headers(entry.responseHeaders, tree: trees.responseHeaders, name: "response headers")
                bodySection(entry.responseBody, tree: trees.responseBody,
                     truncated: entry.isResponseBodyTruncated, name: "response body")
            }
        }
    }

    /// A rounded panel with a title whose copy icon shows on hover.
    private func group(
        _ title: String, copy: @escaping () -> Void, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HoverCopyHeader(help: "Copy \(title.lowercased()) as JSON", copy: copy) {
                Text(title).font(.headline)
            } trailing: {
                EmptyView()
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func headers(_ h: [String: String], tree: StorageRecord?, name: String) -> some View {
        Subsection(title: "Headers (\(h.count))", name: name, tree: tree,
                   raw: h.keys.sorted().map { "\($0): \(h[$0]!)" }.joined(separator: "\n"))
    }

    @ViewBuilder
    private func bodySection(_ text: String?, tree: StorageRecord?, truncated: Bool, name: String) -> some View {
        if let text, !text.isEmpty {
            // A truncated JSON body doesn't parse, but it is still JSON.
            let isJSON = tree != nil || text.first == "{" || text.first == "["
            let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
            Subsection(title: "Body · \(isJSON ? "JSON" : "Text") · \(size)", name: name,
                       tree: tree, raw: text, truncated: truncated)
        }
    }

    /// Same icon and weight as JSONTreeView's row copy button.
    private func copyIcon(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// One part of a request or response: a caption header with a hover copy
/// icon and a Parsed / Raw toggle, then the tree or the raw text. Without
/// a tree (text or truncated body, no headers) only the raw form shows.
private struct Subsection: View {
    let title: String
    /// For the tooltip and toast, e.g. "request headers".
    let name: String
    let tree: StorageRecord?
    let raw: String
    var truncated = false

    @Environment(ToastCenter.self) private var toasts
    @State private var showRaw = false

    private var showsTree: Bool { tree != nil && !showRaw }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HoverCopyHeader(help: "Copy \(name)", copy: raw.isEmpty ? nil : copy) {
                HStack(spacing: 0) {
                    Text(title.uppercased())
                    if truncated {
                        Text(" · truncated")
                            .foregroundStyle(.orange)
                            .help("Body truncated by the SDK at 100 000 characters")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            } trailing: {
                if tree != nil {
                    Picker("View", selection: $showRaw) {
                        Text("Parsed").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if let tree, showsTree {
                JSONTreeView(record: tree, expandsRoot: true)
            } else if raw.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(raw)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Copies what is on screen: the tree as JSON, or the raw text.
    private func copy() {
        toasts.copy(tree.flatMap { showsTree ? StorageRecord.serializeJSON($0) : nil } ?? raw, "Copied \(name)")
    }
}

/// A header row whose `doc.on.doc` copy icon appears only while hovered —
/// the JSONTreeView row idiom.
private struct HoverCopyHeader<Label: View, Trailing: View>: View {
    let help: String
    let copy: (() -> Void)?
    @ViewBuilder let label: Label
    @ViewBuilder let trailing: Trailing

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            label
            if let copy {
                Button(action: copy) {
                    Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(help)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
