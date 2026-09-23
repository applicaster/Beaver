//
//  NetworkDetailView.swift
//  Beaver
//

import SwiftUI
import AppKit

/// Right-hand pane of the Network tab. Same layout as the Log feed's
/// `DetailPaneView` — header, divider, metadata grid, then uppercase
/// sections with `JSONTreeView` — with the zapp-support header on top:
/// method and status badges, duration, time, and copy buttons.
struct NetworkDetailView: View {
    let entry: NetworkEntry?
    /// Opens the entry in the large sheet. `nil` inside the sheet itself.
    var onExpand: ((NetworkEntry) -> Void)?

    var body: some View {
        if let entry {
            NetworkDetailContent(entry: entry, onExpand: onExpand)
        } else {
            ContentUnavailableView("No request selected", systemImage: "network")
        }
    }
}

/// Header and body trees, built once per entry (bodies run to 100 KB).
private struct ParsedEntry {
    let id: NetworkEntry.ID
    let requestHeaders: StorageRecord?
    let requestBody: StorageRecord?
    let responseHeaders: StorageRecord?
    let responseBody: StorageRecord?

    init(_ e: NetworkEntry) {
        id = e.id
        requestHeaders = Self.headers(e.requestHeaders)
        requestBody = Self.body(e.requestBody)
        responseHeaders = Self.headers(e.responseHeaders)
        responseBody = Self.body(e.responseBody)
    }

    private static func headers(_ h: [String: String]) -> StorageRecord? {
        h.isEmpty ? nil : StorageRecord.make(key: "headers", value: h, path: "$")
    }

    /// A tree only for a non-empty object or array; anything else shows as text.
    private static func body(_ text: String?) -> StorageRecord? {
        guard let text, !text.isEmpty, let tree = StorageRecord.parse(text, rootKey: "body"),
              tree.children != nil else { return nil }
        return tree
    }
}

private struct NetworkDetailContent: View {
    let entry: NetworkEntry
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
                    sections(trees)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: entry.id, initial: true) { parsed = ParsedEntry(entry) }
    }

    // MARK: Header

    private var duration: String { entry.durationMillis.map { "\($0) ms" } ?? "—" }

    /// `[GET] [403] 274 ms 13:08:24.743 … [⤢] [Copy JSON] [cURL]`, then the URL.
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
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Metadata

    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Status", entry.statusLine, color: entry.statusClass.color)
            row("Host", entry.host.isEmpty ? "—" : entry.host)
            row("Method", entry.method)
            row("Duration", duration)
            row("Started", NetworkView.time(entry.startMillis))
            row("Ended", entry.durationMillis.map {
                NetworkView.time(entry.startMillis + UInt64(max($0, 0)))
            } ?? "—")
            row("Size", NetworkView.size(entry))
            if let error = entry.error {
                row("Error", error, color: .red)
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String, color: Color? = nil) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Text(value)
                .foregroundStyle(color ?? .primary)
                .textSelection(.enabled)
        }
    }

    // MARK: Sections

    /// Headers sections always show, so "Copy request" / "Copy response"
    /// are always there; body sections only when there is a body.
    @ViewBuilder
    private func sections(_ trees: ParsedEntry) -> some View {
        sectionHeader("Request headers", button: "Copy request") {
            toasts.copy(entry.requestJSON, "Copied request")
        }
        tree(trees.requestHeaders)
        bodySection("Request body", tree: trees.requestBody, text: entry.requestBody)

        sectionHeader("Response headers", button: "Copy response") {
            toasts.copy(entry.responseJSON, "Copied response")
        }
        tree(trees.responseHeaders)
        bodySection("Response body", tree: trees.responseBody, text: entry.responseBody)
    }

    @ViewBuilder
    private func tree(_ record: StorageRecord?) -> some View {
        if let record {
            JSONTreeView(record: record)
        } else {
            Text("None").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bodySection(_ title: String, tree: StorageRecord?, text: String?) -> some View {
        if let text, !text.isEmpty {
            sectionHeader(title, button: "Copy body") { toasts.copy(text, "Copied body") }
            if let tree {
                JSONTreeView(record: tree)
            } else {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// DetailPaneView's section header, plus a trailing small copy button.
    private func sectionHeader(_ title: String, button: String, copy: @escaping () -> Void) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(button, action: copy)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.top, 4)
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
