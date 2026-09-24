//
//  NetworkView.swift
//  Beaver
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NetworkView: View {
    @Bindable var vm: NetworkViewModel
    /// Switches to the Log feed at the request's start time.
    var onShowInLogFeed: (NetworkEntry) -> Void = { _ in }
    @Environment(ToastCenter.self) private var toasts
    /// The entry open in the large detail sheet.
    @State private var expanded: NetworkEntry?
    @State private var harDocument: JSONExportDocument?
    @State private var harDefaultFilename = ""
    @State private var showingHARExporter = false
    /// Column widths / order / visibility, remembered between launches —
    /// the Log feed's pattern (`TableColumnCustomization` is Codable).
    @AppStorage("network.columnLayout") private var storedColumnLayout = ""
    @State private var columnLayout = TableColumnCustomization<NetworkEntry>()

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
                                  payloadJSON: vm.payloadJSON,
                                  onToggleBookmark: { vm.toggleBookmark($0.id) },
                                  onShowInLogFeed: onShowInLogFeed,
                                  onExpand: { expanded = $0 })
                    .frame(minWidth: 320, idealWidth: 360, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $expanded) { e in
            VStack(spacing: 0) {
                NetworkDetailView(entry: e, isBookmarked: vm.isBookmarked(e.id),
                                  payloadJSON: vm.payloadJSON,
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
            FacetPicker(title: "Method", selection: $vm.filter.method,
                        options: { vm.filter.availableMethods(in: vm.base) }, tint: MethodBadge.tint)
            FacetPicker(title: "Status", selection: $vm.filter.status,
                        options: { vm.filter.availableStatuses(in: vm.base) },
                        label: NetworkEntry.statusLabel(for:), tint: \.color, summary: .errors)
            FacetPicker(title: "Host", selection: $vm.filter.host,
                        options: { vm.filter.availableHosts(in: vm.base) })
            if !vm.filter.isEmpty || vm.filter.searchIsRegex {
                Button("Clear filters") { vm.filter = NetworkFilter() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
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
            .padding(.bottom, 4)
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
        let s = vm.stats
        return HStack(spacing: 12) {
            Text("Results (\(s.count)/\(vm.entries.count))").font(.headline)
            let stats = [
                s.successRate.map { "Success \(Int(($0 * 100).rounded()))% (\(s.successCount)/\(s.httpCount))" },
                s.averageDurationMillis.map { "Avg \($0) ms" },
            ].compactMap { $0 }
            if !stats.isEmpty {
                Text(stats.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !vm.sortOrder.isEmpty {
                Button { vm.sortOrder = [] } label: { Label("Arrival order", systemImage: "arrow.up.arrow.down") }
                    .help("Drop the column sort and list requests as they arrived")
            }
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
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 2)
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
        let count = vm.bookmarkCount
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
        // HAR is a timeline: arrival order even when the table is sorted.
        guard let data = try? HARExport.encode(rows.sorted { $0.id < $1.id }, creatorVersion: version) else {
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

    /// One type style per row: 12 pt monospaced, numbers right-aligned,
    /// colour only where it means something (method, non-2xx status, slow,
    /// large or cut).
    private func table(_ rows: [NetworkEntry]) -> some View {
        ScrollViewReader { proxy in
            tableContent(rows)
                .background { ScrollWatcher(bottomSlack: 8) { vm.userScrolled(atBottom: $0) } }
                // Same as the Log feed's auto-scroll: instant, and deferred
                // one runloop so the Table commits its rows before scrolling.
                .onChange(of: rows.last?.id) { _, id in
                    guard let id, vm.isFollowing else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: vm.isFollowing) { _, following in
                    guard following, let id = vm.filtered.last?.id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
                }
                // An agent's ui_show or a journal link picked a row.
                .onChange(of: vm.scrollTarget?.token) { _, _ in
                    guard let id = vm.scrollTarget?.id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
                // Back on the tab: the tail while following, else the row
                // an agent or a link picked while the tab was hidden.
                .onAppear {
                    guard let id = vm.isFollowing ? rows.last?.id : vm.scrollTarget?.id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: vm.isFollowing ? .bottom : .center) }
                }
                .overlay(alignment: .bottom) {
                    if !vm.isFollowing && vm.sortOrder.isEmpty && vm.unseenCount > 0 {
                        Button { vm.isFollowing = true } label: {
                            Text("\(vm.unseenCount) new ↓")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                        .help("Scroll to the newest request and keep following")
                        .padding(.bottom, 12)
                    }
                }
        }
    }

    private func tableContent(_ rows: [NetworkEntry]) -> some View {
        Table(rows, selection: $vm.selection, sortOrder: $vm.sortOrder, columnCustomization: $columnLayout) {
            TableColumn("Method", value: \.method) { e in
                HStack(spacing: 4) {
                    if vm.isBookmarked(e.id) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Pill(text: e.method, tint: MethodBadge.tint(e.method), minWidth: 44, strong: true)
                }
            }
            .width(min: 64, ideal: 76, max: 96)
            .customizationID("method")
            // The status is the one pill column; the method beside it is plain text.
            TableColumn("Status", value: \.status, comparator: NilLastComparator()) { StatusBadge(entry: $0) }
            .width(min: 48, ideal: 56, max: 64)
            .customizationID("status")
            TableColumn("Host", value: \.host) { Text($0.host).font(Self.rowFont).lineLimit(1) }
                .width(min: 100, ideal: 170, max: 260)
                .customizationID("host")
            TableColumn("Path", value: \.path) { e in
                Text(e.path).font(Self.rowFont).lineLimit(1).truncationMode(.middle).help(e.path)
            }
            .customizationID("path")
            TableColumn("Duration", value: \.durationMillis, comparator: NilLastComparator()) { DurationCell(millis: $0.durationMillis) }
                .width(min: 60, ideal: 72, max: 90)
                .customizationID("duration")
                .alignment(.trailing)
            TableColumn("Size", value: \.tableSizeBytes, comparator: NilLastComparator()) { SizeCell(entry: $0) }
                .width(min: 56, ideal: 70, max: 90)
                .customizationID("size")
                .alignment(.trailing)
            TableColumn("Time", value: \.startMillis) { e in
                Text(Self.time(e.startMillis))
                    .font(Self.rowFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 96, ideal: 104, max: 120)
            .customizationID("time")
            .alignment(.trailing)
        }
        .onAppear {
            guard let data = storedColumnLayout.data(using: .utf8),
                  let saved = try? JSONDecoder().decode(TableColumnCustomization<NetworkEntry>.self, from: data)
            else { return }
            columnLayout = saved
        }
        .onChange(of: columnLayout) { _, layout in
            guard let data = try? JSONEncoder().encode(layout),
                  let text = String(data: data, encoding: .utf8)
            else { return }
            storedColumnLayout = text
        }
        .contextMenu(forSelectionType: NetworkEntry.ID.self) { ids in
            if let id = ids.first, let e = vm.entries.first(where: { $0.id == id }) {
                Button(vm.isBookmarked(e.id) ? "Remove bookmark" : "Bookmark") { vm.toggleBookmark(e.id) }
                Button("Show in Log feed") { onShowInLogFeed(e) }
                Divider()
                Button("Only \(e.host)") { vm.filter.host = e.host }
                Button("Hide \(e.host)") { vm.filter.excludedHosts.insert(e.host) }
                Button("Only \(e.method)") { vm.filter.method = e.method }
                Button("Hide \(e.method)") { vm.filter.excludedMethods.insert(e.method) }
                let pick = NetworkFilter.StatusPick(e.status)
                let statusMenuLabel = pick == .noStatus ? "entries without status" : NetworkEntry.statusLabel(for: pick)
                Button("Only \(statusMenuLabel)") { vm.filter.status = pick }
                if NetworkFilter.StatusPick.errors.matches(e) {
                    Button("Only errors") { vm.filter.status = .errors }
                }
                let statusClass = e.statusClass
                Button("Hide \(statusClass.displayName)") { vm.filter.excludedStatusClasses.insert(statusClass) }
                Divider()
                Button("Copy URL") { toasts.copy(e.url, "Copied URL") }
                Button("Copy as cURL") { toasts.copy(e.curlCommand, e.copyToast("cURL")) }
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

    /// The table's single row font.
    static let rowFont = Font.system(size: 12, design: .monospaced)

    /// Same grey / yellow / red scale as Size: under 1 s, 1–3 s, 3 s and up.
    static func durationColor(_ ms: Int?, _ scheme: ColorScheme) -> Color {
        switch NetworkEntry.DurationTier(millis: ms) {
        case .normal: Color.tier(.normal, scheme)
        case .slow: Color.tier(.attention, scheme)
        case .verySlow: Color.tier(.critical, scheme)
        }
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

/// Lets an optional column drive `Table(sortOrder:)`. The VM sorts with
/// `NetworkEntry.sorted`, which reads only the key path and order.
private struct NilLastComparator: SortComparator {
    var order = SortOrder.forward

    func compare(_ a: Int?, _ b: Int?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case let (a?, b?):
            a == b ? .orderedSame : (a < b) == (order == .forward) ? .orderedAscending : .orderedDescending
        }
    }
}

/// `512 ms`, right-aligned; orange from 1 s, red from 3 s, white on a
/// selected row.
private struct DurationCell: View {
    let millis: Int?
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(millis.map(NetworkEntry.compactDuration) ?? "—")
            .font(NetworkView.rowFont)
            .foregroundStyle(prominence == .increased ? .white : NetworkView.durationColor(millis, scheme))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The reported size when the SDK sent one (exact, no "+"), else the
/// captured bytes. Content-Length is never used here — compressed, it would
/// read as a wrong body size. Grey / yellow / red by `tableSizeTier`.
private struct SizeCell: View {
    let entry: NetworkEntry
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let text = Text(NetworkView.size(entry))
            .font(NetworkView.rowFont)
            .foregroundStyle(prominence == .increased ? .white
                             : Color.tier(entry.tableSizeTier, scheme))
            .frame(maxWidth: .infinity, alignment: .trailing)
        if entry.isResponseBodyTruncated && entry.responseBodySize == nil {
            text.help(NetworkView.sizeHelp(entry))
        } else {
            text
        }
    }
}

/// The table's method: bold coloured text, no fill. A pale fill at 11 pt on
/// every row smeared; text alone stays crisp and leaves the status as the
/// only pill column.
private struct MethodText: View {
    let method: String
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = MethodBadge.tint(method)
        Text(method)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(prominence == .increased ? .white
                             : scheme == .dark ? tint.mix(with: .white, by: 0.25) : tint.mix(with: .black, by: 0.35))
            .lineLimit(1)
            .frame(minWidth: 44, alignment: .leading)
    }
}

extension Color {
    /// Grey / yellow / red for the Size and Duration columns. System yellow
    /// is unreadable as text on white, so it is darkened in light mode.
    static func tier(_ tier: NetworkEntry.Tier, _ scheme: ColorScheme) -> Color {
        switch tier {
        case .normal: .secondary
        case .attention: scheme == .dark ? .yellow : Color.yellow.mix(with: .black, by: 0.4)
        case .critical: .red
        }
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
    /// StatusBadge's colour for this pick; Errors and "No status" are failures.
    var color: Color {
        switch self {
        case .errors, .noStatus: NetworkEntry.StatusClass.failed.color
        case .statusClass(let c): c.color
        case .code(let code): NetworkEntry.StatusClass(status: code).color
        }
    }
}

extension NetworkEntry.StatusClass {
    var color: Color {
        switch self {
        case .success: .green
        case .redirect: .blue
        case .clientError, .serverError, .failed: .red
        case .other: .gray
        }
    }
}

/// Rounded tinted label, the zapp-support badge look.
struct Pill: View {
    let text: String
    let tint: Color
    /// Keeps a column of pills one width (GET/POST/PUT), text centred.
    var minWidth: CGFloat?
    /// A denser fill and darker text, for the method column, so a full
    /// column of pills reads solid instead of washed out.
    var strong = false
    @Environment(\.colorScheme) private var scheme
    /// `.increased` inside a selected table row (blue background).
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: minWidth)
            .background(fill, in: RoundedRectangle(cornerRadius: 4))
    }

    // System .green/.orange are fill colours: as text on their own 15% tint
    // they sit near 2:1 contrast and read as blurry. Darken (light mode) or
    // lighten (dark mode) the text, and go white on a selected row.
    private var textColor: Color {
        if prominence == .increased { return .white }
        if strong { return scheme == .dark ? tint.mix(with: .white, by: 0.35) : tint.mix(with: .black, by: 0.55) }
        return tint.readableText(in: scheme)
    }

    private var fill: Color {
        if prominence == .increased { return .white.opacity(0.22) }
        if strong { return tint.opacity(scheme == .dark ? 0.38 : 0.30) }
        return tint.opacity(scheme == .dark ? 0.25 : 0.18)
    }
}

extension Color {
    /// This tint darkened (light mode) or lightened (dark mode) enough to
    /// read as text on its own pale fill.
    func readableText(in scheme: ColorScheme) -> Color {
        scheme == .dark ? mix(with: .white, by: 0.25) : mix(with: .black, by: 0.4)
    }
}

/// An active facet value with its own ×. Included values are green;
/// excluded ones red and struck through.
private struct NetworkChip: View {
    let title: String
    let excluded: Bool
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var scheme

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
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(scheme == .dark ? 0.25 : 0.15)))
        .foregroundStyle(tint.readableText(in: scheme))
    }
}

/// The one place method colours live.
struct MethodBadge: View {
    let method: String

    var body: some View { Pill(text: method, tint: Self.tint(method), minWidth: 44) }

    /// A muted colour per verb so GET and POST read apart at a glance;
    /// Pill darkens the text and keeps the fill light.
    static func tint(_ method: String) -> Color {
        switch method {
        case "GET": .blue
        case "POST": .teal
        case "PUT": .orange
        case "PATCH": .purple
        case "DELETE": .red
        default: .gray
        }
    }
}

struct StatusBadge: View {
    let entry: NetworkEntry
    static let minWidth: CGFloat = 34

    var body: some View {
        Pill(text: entry.status.map(String.init) ?? "—", tint: entry.statusClass.color, minWidth: Self.minWidth)
    }
}

/// Single-choice facet dropdown: a native bordered button as tall as the
/// search field, neutral on All, tinted once a value is picked. Options come from
/// `NetworkFilter.available…`, so they only list values that can match.
private struct FacetPicker<Value: Hashable & Sendable>: View {
    let title: String
    @Binding var selection: Value?
    /// Evaluated only while the popover is open — options can be an O(n)
    /// scan over the entries, so a hidden pill shouldn't pay for it on
    /// every render.
    let options: () -> [FacetOption<Value>]
    var label: (Value) -> String = { "\($0)" }
    var tint: (Value) -> Color = { _ in .accentColor }
    /// An aggregate row (Status's "Errors") that overlaps the others: a
    /// divider follows it and "All" doesn't count it.
    var summary: Value?
    @State private var isShown = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = selection.map(tint)
        Button { isShown.toggle() } label: {
            HStack(spacing: 6) {
                Text(selection.map(label) ?? title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .foregroundStyle(color.map { AnyShapeStyle($0.readableText(in: scheme)) } ?? AnyShapeStyle(.primary))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(color)
        .fixedSize()
        .help("Show one \(title.lowercased()) only")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            let opts = options()
            // Always a ScrollView (capped at 420pt) rather than switching
            // to a plain stack under 14 rows: an open popover's view
            // identity would otherwise flip as live counts cross that
            // threshold, and it visibly jumps.
            ScrollView { rows(opts) }
                .frame(maxHeight: 420)
        }
    }

    private func rows(_ options: [FacetOption<Value>]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let total = options.filter { $0.depth == 0 && $0.value != summary }.reduce(0) { $0 + $1.count }
            FacetPickerRow(text: "All", count: total, isSelected: selection == nil, tint: .primary) { pick(nil) }
            Divider().padding(.vertical, 2)
            ForEach(options, id: \.value) { option in
                FacetPickerRow(text: label(option.value), count: option.count, depth: option.depth,
                               isSelected: option.value == selection, tint: tint(option.value)) { pick(option.value) }
                if option.value == summary { Divider().padding(.vertical, 2) }
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
    var depth = 0
    let isSelected: Bool
    let tint: Color
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                    .padding(.leading, CGFloat(depth) * 16)
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
