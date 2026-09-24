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
/// request and the response as two titled sections under a divider each.
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
        requestBody = Self.body(e.requestBody, truncated: e.isRequestBodyTruncated)
        responseHeaders = Self.headers(e.responseHeaders)
        responseBody = Self.body(e.responseBody, truncated: e.isResponseBodyTruncated)
    }

    private static func headers(_ h: [String: String]) -> StorageRecord? {
        h.isEmpty ? nil : StorageRecord.make(key: "headers", value: h, path: "$")
    }

    /// A tree only for a non-empty object or array; anything else shows as
    /// text. A truncated JSON body gets a tree of its complete values.
    private static func body(_ text: String?, truncated: Bool) -> StorageRecord? {
        guard let text, !text.isEmpty,
              let tree = StorageRecord.parse(text, rootKey: "body")
                ?? (truncated ? TruncatedJSON.repair(text).flatMap { StorageRecord.parse($0, rootKey: "body") } : nil),
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
    /// The full URL under the short one; collapsed again for every entry.
    @State private var showsFullURL = false

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
        .onChange(of: entry.id, initial: true) {
            parsed = ParsedEntry(entry)
            showsFullURL = false
        }
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
            urlLine
            Text(entry.statusLine)
                .font(.title3.weight(.semibold))
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

    /// `https://host/path...` — a query can hold kilobytes of token. The
    /// chevron (or a click on the text) shows the whole URL as a block;
    /// the copy icon always copies all of it.
    @ViewBuilder
    private var urlLine: some View {
        let short = entry.shortURL
        let isCut = short != entry.url
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Not `.textSelection(.enabled)` here: it can conflict with the
            // tap gesture below on macOS. The copy button and the
            // expanded block (which stays selectable) cover selection.
            Text(short)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { if isCut { showsFullURL.toggle() } }
                .help(isCut ? "Show full URL" : "")
            copyIcon(help: "Copy URL") { toasts.copy(entry.url, "Copied URL") }
            if isCut {
                Button { showsFullURL.toggle() } label: {
                    Image(systemName: showsFullURL ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(showsFullURL ? "Hide full URL" : "Show full URL")
            }
        }
        if isCut && showsFullURL {
            // No tap gesture here, so the text stays selectable.
            Text(entry.url)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
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
            sizeRows(label: "Response size", size: entry.responseSize, capturedBytes: entry.responseBytes,
                     truncated: entry.isResponseBodyTruncated)
            if let requestSize = entry.requestSize {
                sizeRows(label: "Request size", size: requestSize, capturedBytes: entry.requestBody?.utf8.count,
                          truncated: entry.isRequestBodyTruncated)
            }
            // No "Error" row here — the red line under the status above
            // already shows it (see `header`).
        }
        .font(.system(size: 11))
    }

    /// The size row, plus a second "Captured" row when the shown size is
    /// exact (reported or Content-Length) but the body itself was cut —
    /// so it's clear the captured bytes on screen are only a prefix.
    @ViewBuilder
    private func sizeRows(label: String, size: NetworkEntry.BodySize?, capturedBytes: Int?, truncated: Bool) -> some View {
        if let size {
            let (text, isWarning) = Self.sizeText(size)
            row(label, text, color: isWarning ? .orange : nil)
            if truncated, Self.isCaptureNoteNeeded(size.source) {
                row("Captured", "\(NetworkEntry.compactSize(capturedBytes ?? 0)) (truncated)")
            }
        } else {
            row(label, "—")
        }
    }

    /// "312,450 bytes (312 KB)" — reported; with the source noted for
    /// Content-Length, or a real-size warning when only a truncated
    /// capture is known.
    private static func sizeText(_ size: NetworkEntry.BodySize) -> (text: String, isWarning: Bool) {
        let grouped = size.bytes.formatted(.number.locale(Locale(identifier: "en_US")))
        let compact = NetworkEntry.compactSize(size.bytes)
        switch size.source {
        case .reported:
            return ("\(grouped) bytes (\(compact))", false)
        case .contentLength(let encoding):
            let note = encoding.map { ", \($0)-compressed on the wire" } ?? ""
            return ("\(grouped) bytes (\(compact)) · Content-Length\(note)", false)
        case .captured where size.isLowerBound:
            return ("≥ \(grouped) bytes (\(compact)+) · real size unknown — the SDK cut the body", true)
        case .captured:
            return ("\(grouped) bytes (\(compact))", false)
        }
    }

    private static func isCaptureNoteNeeded(_ source: NetworkEntry.BodySize.Source) -> Bool {
        switch source {
        case .reported, .contentLength: true
        case .captured: false
        }
    }

    private func row(_ label: String, _ value: String, color: Color? = nil, help: String = "") -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if help.isEmpty {
                Text(value)
                    .foregroundStyle(color ?? .primary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .foregroundStyle(color ?? .primary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .help(help)
            }
        }
    }

    // MARK: Request / Response

    @ViewBuilder
    private func groups(_ trees: ParsedEntry) -> some View {
        // No cards: a divider and a headline per group, Xcode-inspector
        // style, so nothing grey sits on the grey pane.
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            group("Request", copy: { toasts.copy(entry.requestJSON, "Copied request") }) {
                // Not `rawQuery != nil`: a URL ending in a bare "?" has an
                // empty (non-nil) query component, which would otherwise
                // show an empty "(0) None" section.
                if !entry.queryItems.isEmpty {
                    Subsection(title: "Query parameters (\(entry.queryItems.count))", name: "query",
                               tree: trees.query, raw: entry.rawQuery ?? "")
                }
                headers(entry.requestHeaders, tree: trees.requestHeaders, name: "request headers")
                bodySection(entry.requestBody, tree: trees.requestBody, truncated: entry.isRequestBodyTruncated,
                            name: "request body", reportedSize: entry.requestBodySize)
            }
            Divider()
            group("Response", copy: { toasts.copy(entry.responseJSON, "Copied response") }) {
                headers(entry.responseHeaders, tree: trees.responseHeaders, name: "response headers")
                bodySection(entry.responseBody, tree: trees.responseBody, truncated: entry.isResponseBodyTruncated,
                            name: "response body", reportedSize: entry.responseBodySize)
            }
        }
    }

    /// A section with a title whose copy icon shows on hover.
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headers(_ h: [String: String], tree: StorageRecord?, name: String) -> some View {
        Subsection(title: "Headers (\(h.count))", name: name, tree: tree,
                   raw: h.keys.sorted().map { "\($0): \(h[$0]!)" }.joined(separator: "\n"))
    }

    @ViewBuilder
    private func bodySection(_ text: String?, tree: StorageRecord?, truncated: Bool, name: String,
                              reportedSize: Int?) -> some View {
        if let text, !text.isEmpty {
            // A truncated JSON body that won't repair is still JSON.
            let isJSON = tree != nil || text.first == "{" || text.first == "["
            let sizeBytes = reportedSize ?? text.utf8.count
            let size = truncated
                ? "\(NetworkEntry.compactSize(sizeBytes)) (showing first 100 KB)"
                : NetworkEntry.compactSize(sizeBytes)
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
/// a tree (text, an unrepairable truncated body, no headers) only the raw
/// form shows.
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
                    ParsedRawToggle(showRaw: $showRaw)
                }
            }
            if let tree, showsTree {
                JSONTreeView(record: tree, expandsRoot: true)
                if truncated {
                    Text("Partial — the SDK cut this body at 100 000 characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

/// `Parsed | Raw` as two small borderless words — lighter than a blue
/// segmented control repeated in every subsection.
private struct ParsedRawToggle: View {
    @Binding var showRaw: Bool

    var body: some View {
        HStack(spacing: 4) {
            option("Parsed", raw: false)
            Text("|").foregroundStyle(.tertiary)
            option("Raw", raw: true)
        }
        .font(.caption)
        .fixedSize()
    }

    private func option(_ title: String, raw: Bool) -> some View {
        let isOn = showRaw == raw
        return Button { showRaw = raw } label: {
            Text(title).foregroundStyle(isOn ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(raw ? "Show as received" : "Show parsed")
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
