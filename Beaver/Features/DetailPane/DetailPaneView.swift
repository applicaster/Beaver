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

    // Find (D84). The term stays as the selection moves, like a browser's
    // find bar; the matches belong to one event.
    @State private var isFinding = false
    @State private var findTerm = ""
    @State private var findIsRegex = false
    @State private var found: FindResult?
    @State private var current = 0
    /// Bumped on every jump, so landing on the same match again still scrolls.
    @State private var jumps = 0
    @FocusState private var findFocused: Bool

    private struct FindResult {
        let term: String
        let isRegex: Bool
        let matches: [DetailFind.Match]
    }

    var body: some View {
        if let event {
            VStack(spacing: 0) {
                if isFinding {
                    findBar
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header(event)
                            Divider()
                            metadata(event)
                            if let data {
                                sectionHeader("Data", copy: event.dataJSON)
                                treeView(root: data)
                                    .environment(\.jsonTreeFind, treeFind(.data))
                            }
                            if let context {
                                sectionHeader("Context", copy: event.contextJSON)
                                treeView(root: context)
                                    .environment(\.jsonTreeFind, treeFind(.context))
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Fresh per event: "Show more" pages and expansion
                        // state belong to the payload they were opened on.
                        .id(event.id)
                    }
                    .onChange(of: jumps) {
                        // After the update that opens the path to the match.
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(JSONTreeFind.anchor, anchor: .center)
                            }
                        }
                    }
                }
            }
            .onChange(of: event.id) { found = nil }
            .task(id: "\(event.id)|\(isFinding)|\(findIsRegex)|\(findTerm)") {
                await search(event)
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
                Spacer()
                // ⌥⌘F, not ⌘F: ⌘F stays the feed's filter wherever focus is (D84).
                Button {
                    isFinding = true
                    findFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("f", modifiers: [.command, .option])
                .help("Find in this event (⌥⌘F)")
            }
            // Monospaced so stack traces and pretty-printed JSON line
            // up; capped and scrollable so a long one doesn't push the
            // metadata and payload out of reach.
            ScrollView {
                Text(Highlighting.highlight(event.message, term: found?.term, isRegex: found?.isRegex ?? false))
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
                    .strokeBorder(currentMatch?.section == .message ? Color.accentColor : Color(.separatorColor),
                                  lineWidth: currentMatch?.section == .message ? 2 : 1)
            )
            .id(currentMatch?.section == .message ? JSONTreeFind.anchor : "message")
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

    // MARK: - Find

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in this event", text: $findTerm)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onAppear { findFocused = true }
                // Return walks matches without leaving the field.
                .onSubmit { step(by: 1) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    step(by: -1)
                    return .handled
                }
                .onExitCommand { closeFind() }

            if let found {
                Text(found.matches.isEmpty ? "0 of 0" : "\(current + 1) of \(found.matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(found.matches.isEmpty ? .secondary : .primary)
            }
            Button { step(by: -1) } label: {
                Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(found?.matches.isEmpty ?? true)
            .help("Previous match (⇧↩)")
            Button { step(by: 1) } label: {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(found?.matches.isEmpty ?? true)
            .help("Next match (↩)")

            RegexToggle(isOn: $findIsRegex,
                        isInvalid: StorageSearch.matcher(term: findTerm, isRegex: findIsRegex).isInvalid)
            Button { closeFind() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var currentMatch: DetailFind.Match? {
        guard let matches = found?.matches, matches.indices.contains(current) else { return nil }
        return matches[current]
    }

    /// What a tree highlights, opens and outlines; `nil` when not finding.
    private func treeFind(_ section: DetailFind.Section) -> JSONTreeFind? {
        guard let found, !found.matches.isEmpty else { return nil }
        let match = currentMatch?.section == section ? currentMatch : nil
        return JSONTreeFind(term: found.term, isRegex: found.isRegex,
                            currentId: match?.id, reveal: match?.reveal ?? [:])
    }

    private func step(by delta: Int) {
        guard let count = found?.matches.count, count > 0 else { return }
        current = ((current + delta) % count + count) % count
        jumps += 1
    }

    private func closeFind() {
        isFinding = false
        found = nil
    }

    /// Walks the parsed trees off the main thread, after a pause in typing:
    /// a payload can hold thousands of rows. Nothing is decoded again.
    private func search(_ event: EventRecord) async {
        let term = findTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFinding, !term.isEmpty else {
            found = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        let (message, data, context, isRegex) = (event.message, self.data, self.context, findIsRegex)
        let matches = await Task.detached(priority: .userInitiated) {
            DetailFind.matches(message: message, data: data, context: context, term: term, isRegex: isRegex)
        }.value
        guard !Task.isCancelled else { return }
        found = FindResult(term: term, isRegex: isRegex, matches: matches)
        current = 0
        if !matches.isEmpty { jumps += 1 }
    }

    /// Paged: a payload with thousands of siblings at one level used to
    /// lay every row out at once and freeze the pane.
    @ViewBuilder
    private func treeView(root: StorageRecord) -> some View {
        JSONTreeView(record: root)
            .environment(\.jsonTreePageSize, 200)
    }
}
