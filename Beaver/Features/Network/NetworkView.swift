//
//  NetworkView.swift
//  Beaver
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NetworkView: View {
    @Bindable var vm: NetworkViewModel
    @Environment(ToastCenter.self) private var toasts
    /// The entry open in the large detail sheet.
    @State private var expanded: NetworkEntry?
    @State private var harDocument: JSONExportDocument?
    @State private var harDefaultFilename = ""
    @State private var showingHARExporter = false

    var body: some View {
        let rows = vm.filtered
        VStack(spacing: 0) {
            filterBar
            if vm.filter.hasFacets { chipsBar }
            resultsBar(rows)
            Divider()
            // HSplitView sizes to its ideal height unless every pane and the
            // split itself ask for the full height — same as LogFeedView.
            HSplitView {
                table(rows)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                NetworkDetailView(entry: vm.selected, isBookmarked: vm.selection.map(vm.isBookmarked) ?? false,
                                  onToggleBookmark: { vm.toggleBookmark($0.id) },
                                  onExpand: { expanded = $0 })
                    .frame(minWidth: 320, idealWidth: 360, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $expanded) { e in
            VStack(spacing: 0) {
                NetworkDetailView(entry: e, isBookmarked: vm.isBookmarked(e.id),
                                  onToggleBookmark: { vm.toggleBookmark($0.id) })
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { expanded = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(minWidth: 800, minHeight: 600)
            // The window's toast chip sits behind the sheet.
            .overlay(alignment: .top) { ToastPresenter() }
            .environment(toasts)
        }
        .fileExporter(
            isPresented: $showingHARExporter,
            document: harDocument,
            contentType: .har,
            defaultFilename: harDefaultFilename,
            onCompletion: { _ in harDocument = nil }
        )
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterPillField(systemImage: "magnifyingglass", placeholder: "Search URLs, headers, bodies…",
                            text: $vm.filter.search, regex: $vm.filter.searchIsRegex)
                .frame(maxWidth: 320)
            let base = vm.base
            FacetPicker(title: "Method", selection: $vm.filter.method,
                        options: vm.filter.availableMethods(in: base), tint: MethodBadge.tint)
            FacetPicker(title: "Status", selection: $vm.filter.status,
                        options: vm.filter.availableStatuses(in: base),
                        label: NetworkEntry.statusLabel(for:), tint: \.color)
            FacetPicker(title: "Host", selection: $vm.filter.host,
                        options: vm.filter.availableHosts(in: base))
            if !vm.filter.isEmpty || vm.filter.searchIsRegex {
                Button("Clear filters") { vm.filter = NetworkFilter() }
            }
            Spacer()
        }
        .padding(8)
    }

    // MARK: Chips

    /// What the facets narrow to, each removable on its own. Same look as
    /// the Log feed's ActiveChipsBar.
    private var chipsBar: some View {
        let f = vm.filter
        let classes = NetworkEntry.StatusClass.allCases
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if f.method != nil || f.status != nil || f.host != nil {
                    Text("Including:").font(.caption).foregroundStyle(.secondary)
                    if let m = f.method { NetworkChip(title: m, excluded: false) { vm.filter.method = nil } }
                    if let st = f.status {
                        NetworkChip(title: NetworkEntry.statusLabel(for: st), excluded: false) { vm.filter.status = nil }
                    }
                    if let h = f.host { NetworkChip(title: h, excluded: false) { vm.filter.host = nil } }
                }
                if !(f.excludedMethods.isEmpty && f.excludedStatusClasses.isEmpty && f.excludedHosts.isEmpty) {
                    Text("Excluding:").font(.caption).foregroundStyle(.secondary)
                    chips(f.excludedMethods.sorted(), excluded: true) { vm.filter.excludedMethods.remove($0) }
                    chips(classes.filter(f.excludedStatusClasses.contains), title: \.displayName, excluded: true) {
                        vm.filter.excludedStatusClasses.remove($0)
                    }
                    chips(f.excludedHosts.sorted(), excluded: true) { vm.filter.excludedHosts.remove($0) }
                }
                Button { vm.filter.clearFacets() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear every chip")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private func chips<T: Hashable>(
        _ values: [T], title: KeyPath<T, String>? = nil, excluded: Bool, remove: @escaping (T) -> Void
    ) -> some View {
        ForEach(values, id: \.self) { value in
            NetworkChip(title: title.map { value[keyPath: $0] } ?? "\(value)", excluded: excluded) { remove(value) }
        }
    }

    // MARK: Results bar

    /// `Results (754/754)  Success 96% (720/749)  Avg 413 ms` and the
    /// Bookmarks / Clear / Pause / Export HAR buttons, as in zapp-support.
    private func resultsBar(_ rows: [NetworkEntry]) -> some View {
        let s = NetworkStats(rows)
        return HStack(spacing: 12) {
            Text("Results (\(s.count)/\(vm.entries.count))").font(.headline)
            Group {
                if let rate = s.successRate {
                    Text("Success \(Int((rate * 100).rounded()))% (\(s.successCount)/\(s.httpCount))")
                }
                if let avg = s.averageDurationMillis { Text("Avg \(avg) ms") }
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            bookmarksButton
            Button { vm.clear() } label: { Label("Clear", systemImage: "xmark.circle") }
                .help("Hide the requests on screen and start fresh — nothing is deleted")
                .disabled(vm.entries.isEmpty)
            Button { vm.togglePause() } label: {
                Label(pauseTitle, systemImage: vm.isPaused ? "play.fill" : "pause.fill")
            }
            .help(vm.isPaused ? "Show the requests that arrived while paused"
                              : "Freeze the list; requests are still recorded")
            Button { exportHAR(rows) } label: { Label("Export HAR", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .help("Save the requests shown as a HAR file")
                .disabled(rows.isEmpty)
        }
        .monospacedDigit()
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var pauseTitle: String {
        guard vm.isPaused else { return "Pause" }
        return vm.pendingCount > 0 ? "Resume (\(vm.pendingCount) new)" : "Resume"
    }

    /// Highlighted while it narrows the list; disabled when there is
    /// nothing to narrow to, unless it is on (so it can be turned off).
    @ViewBuilder
    private var bookmarksButton: some View {
        let count = vm.entries.lazy.filter { vm.isBookmarked($0.id) }.count
        let button = Button { vm.showOnlyBookmarked.toggle() } label: {
            Label("Bookmarks (\(count))", systemImage: vm.showOnlyBookmarked ? "bookmark.fill" : "bookmark")
        }
        .help(vm.showOnlyBookmarked ? "Show every request" : "Show only bookmarked requests")
        .disabled(count == 0 && !vm.showOnlyBookmarked)
        if vm.showOnlyBookmarked {
            button.buttonStyle(.borderedProminent).tint(.orange)
        } else {
            button
        }
    }

    private func exportHAR(_ rows: [NetworkEntry]) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard let data = try? HARExport.encode(rows, creatorVersion: version) else {
            toasts.error("Couldn't build the HAR file")
            return
        }
        harDocument = JSONExportDocument(data: data)
        harDefaultFilename = Self.harFilename()
        showingHARExporter = true
    }

    static func harFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = .init(identifier: "en_US_POSIX")
        return "beaver_\(formatter.string(from: Date())).har"
    }

    // MARK: Table

    private func table(_ rows: [NetworkEntry]) -> some View {
        Table(rows, selection: $vm.selection) {
            TableColumn("Method") { e in
                HStack(spacing: 4) {
                    if vm.isBookmarked(e.id) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    MethodBadge(method: e.method)
                }
            }
            .width(min: 64, ideal: 76, max: 96)
            TableColumn("Status") { StatusBadge(entry: $0) }
                .width(min: 48, ideal: 56, max: 64)
            TableColumn("Host") { Text($0.host).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("Path") { Text($0.path).lineLimit(1).truncationMode(.middle) }
            TableColumn("Duration") { e in
                Text(e.durationMillis.map { "\($0) ms" } ?? "—")
                    .foregroundStyle(Self.durationColor(e.durationMillis)).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Size") { e in
                // The reported size when the SDK sent one (exact, no "+");
                // Content-Length is never used here — compressed, it would
                // read as a wrong body size.
                if let bytes = e.responseBodySize ?? e.responseBytes {
                    let pill = Pill(text: Self.size(e), tint: bytes < 50_000 ? .green : .orange)
                    if e.isResponseBodyTruncated && e.responseBodySize == nil {
                        pill.help(Self.sizeHelp(e))
                    } else {
                        pill
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 56, ideal: 70, max: 90)
            TableColumn("Time") { Text(Self.time($0.startMillis)).monospacedDigit() }
                .width(min: 90, ideal: 100, max: 110)
        }
        .contextMenu(forSelectionType: NetworkEntry.ID.self) { ids in
            if let id = ids.first, let e = vm.entries.first(where: { $0.id == id }) {
                Button(vm.isBookmarked(e.id) ? "Remove bookmark" : "Bookmark") { vm.toggleBookmark(e.id) }
                Divider()
                Button("Only \(e.host)") { vm.filter.host = e.host }
                Button("Hide \(e.host)") { vm.filter.excludedHosts.insert(e.host) }
                Button("Only \(e.method)") { vm.filter.method = e.method }
                Button("Hide \(e.method)") { vm.filter.excludedMethods.insert(e.method) }
                let pick = NetworkFilter.StatusPick(e.status)
                Button("Only \(NetworkEntry.statusLabel(for: pick))") { vm.filter.status = pick }
                let statusClass = e.statusClass
                Button("Hide \(statusClass.displayName)") { vm.filter.excludedStatusClasses.insert(statusClass) }
                Divider()
                Button("Copy URL") { toasts.copy(e.url, "Copied URL") }
                Button("Copy as cURL") { toasts.copy(e.curlCommand, "Copied cURL") }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No network requests", systemImage: "network",
                                       description: Text(vm.entries.isEmpty
                                           ? "Requests appear here as the app makes them (iOS X-Ray SDK)."
                                           : "Nothing matches the current filters."))
            }
        }
    }

    static func durationColor(_ ms: Int?) -> Color {
        guard let ms else { return .secondary }
        return ms < 100 ? .green : ms < 500 ? .orange : .red
    }

    /// The reported (real) size when the SDK sent one; otherwise the
    /// captured size, `100 KB+` when the SDK cut the body short.
    static func size(_ e: NetworkEntry) -> String {
        if let reported = e.responseBodySize { return NetworkEntry.compactSize(reported) }
        guard let bytes = e.responseBytes else { return "—" }
        return NetworkEntry.compactSize(bytes) + (e.isResponseBodyTruncated ? "+" : "")
    }

    static func sizeHelp(_ e: NetworkEntry) -> String {
        e.isResponseBodyTruncated ? "Body truncated by the SDK at 100 000 characters" : ""
    }

    static func time(_ ms: UInt64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    }
}

extension ToastCenter {
    /// Pasteboard write plus the usual green "Copied …" chip.
    func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        success(message)
    }
}

// MARK: - Badges

extension NetworkFilter.StatusPick {
    /// StatusBadge's colour for this code; "No status" is a failure.
    var color: Color {
        guard case .code(let code) = self else { return NetworkEntry.StatusClass.failed.color }
        return NetworkEntry.StatusClass(status: code).color
    }
}

extension NetworkEntry.StatusClass {
    var color: Color {
        switch self {
        case .success: .green
        case .redirect: .blue
        case .clientError: .orange
        case .serverError, .failed: .red
        case .other: .gray
        }
    }
}

/// Rounded tinted label, the zapp-support badge look.
struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// An active facet value with its own ×. Included values are green;
/// excluded ones red and struck through.
private struct NetworkChip: View {
    let title: String
    let excluded: Bool
    let onRemove: () -> Void

    private var tint: Color { excluded ? .red : .green }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: excluded ? "minus" : "checkmark")
                .font(.caption2.weight(.bold))
            Text(title)
                .strikethrough(excluded)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .help("Remove \"\(title)\"")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.18)))
        .foregroundStyle(tint)
    }
}

/// The one place method colours live.
struct MethodBadge: View {
    let method: String

    var body: some View { Pill(text: method, tint: Self.tint(method)) }

    static func tint(_ method: String) -> Color {
        switch method {
        case "GET": .blue
        case "POST": .green
        case "PUT": .orange
        case "PATCH": .purple
        case "DELETE": .red
        default: .gray
        }
    }
}

struct StatusBadge: View {
    let entry: NetworkEntry

    var body: some View {
        Pill(text: entry.status.map(String.init) ?? "—", tint: entry.statusClass.color)
    }
}

/// Single-choice facet dropdown, styled like the Log feed's level pill:
/// neutral on All, tinted once a value is picked. Options come from
/// `NetworkFilter.available…`, so they only list values that can match.
private struct FacetPicker<Value: Hashable & Sendable>: View {
    let title: String
    @Binding var selection: Value?
    let options: [FacetOption<Value>]
    var label: (Value) -> String = { "\($0)" }
    var tint: (Value) -> Color = { _ in .accentColor }
    @State private var isShown = false
    @State private var isHovered = false

    var body: some View {
        let color = selection.map(tint) ?? .secondary
        Button { isShown.toggle() } label: {
            HStack(spacing: 6) {
                Text(selection.map(label) ?? title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selection == nil ? Color.primary : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(isHovered ? color.opacity(0.12) : Color(.controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(color.opacity(selection == nil ? 0.3 : 0.5), lineWidth: 1))
            .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Show one \(title.lowercased()) only")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            // ponytail: scrolls past 14 rows; a search field if hosts get into the hundreds.
            if options.count > 14 {
                ScrollView { rows }.frame(height: 420)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            FacetPickerRow(text: "All", count: options.reduce(0) { $0 + $1.count },
                           isSelected: selection == nil, tint: .primary) { pick(nil) }
            Divider().padding(.vertical, 2)
            ForEach(options, id: \.value) { option in
                FacetPickerRow(text: label(option.value), count: option.count,
                               isSelected: option.value == selection, tint: tint(option.value)) { pick(option.value) }
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 180)
    }

    private func pick(_ value: Value?) {
        selection = value
        isShown = false
    }
}

/// Same look as the Log feed's LevelPopoverRow, plus a count.
private struct FacetPickerRow: View {
    let text: String
    let count: Int
    let isSelected: Bool
    let tint: Color
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .opacity(isSelected ? 1 : 0)
                .frame(width: 14)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovered ? tint.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovered = $0 }
    }
}
