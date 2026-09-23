//
//  NetworkView.swift
//  Beaver
//

import SwiftUI
import AppKit

struct NetworkView: View {
    @Bindable var vm: NetworkViewModel
    @Environment(ToastCenter.self) private var toasts
    /// The entry open in the large detail sheet.
    @State private var expanded: NetworkEntry?

    var body: some View {
        let rows = vm.filtered
        VStack(spacing: 0) {
            filterBar(rows)
            Divider()
            // HSplitView sizes to its ideal height unless every pane and the
            // split itself ask for the full height — same as LogFeedView.
            HSplitView {
                table(rows)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                NetworkDetailView(entry: vm.selected, onExpand: { expanded = $0 })
                    .frame(minWidth: 320, idealWidth: 360, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $expanded) { e in
            VStack(spacing: 0) {
                NetworkDetailView(entry: e)
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
    }

    // MARK: Filter bar

    private func filterBar(_ rows: [NetworkEntry]) -> some View {
        HStack(spacing: 8) {
            TextField("Search URLs, headers, bodies…", text: $vm.filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            facetMenu("Method", all: vm.allMethods, selected: $vm.filter.methods)
            facetMenu("Status", all: NetworkEntry.StatusClass.allCases,
                      selected: $vm.filter.statusClasses, label: \.displayName)
            facetMenu("Host", all: vm.allHosts, selected: $vm.filter.hosts)
            if !vm.filter.isEmpty {
                Button("Clear") { vm.filter = NetworkFilter() }
            }
            Spacer()
            Text(statsLine(rows)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(8)
    }

    private func statsLine(_ rows: [NetworkEntry]) -> String {
        let s = NetworkStats(rows)
        var parts = ["\(s.count) of \(vm.entries.count)"]
        if let r = s.successRate { parts.append("\(Int((r * 100).rounded()))% 2xx") }
        if let d = s.averageDurationMillis { parts.append("avg \(d) ms") }
        return parts.joined(separator: " · ")
    }

    private func facetMenu<T: Hashable>(
        _ title: String, all: [T], selected: Binding<Set<T>>, label: KeyPath<T, String>? = nil
    ) -> some View {
        Menu(selected.wrappedValue.isEmpty ? title : "\(title) (\(selected.wrappedValue.count))") {
            ForEach(all, id: \.self) { value in
                Toggle(label.map { value[keyPath: $0] } ?? "\(value)", isOn: Binding(
                    get: { selected.wrappedValue.contains(value) },
                    set: { on in
                        if on { selected.wrappedValue.insert(value) }
                        else { selected.wrappedValue.remove(value) }
                    }
                ))
            }
        }
        .fixedSize()
    }

    // MARK: Table

    private func table(_ rows: [NetworkEntry]) -> some View {
        Table(rows, selection: $vm.selection) {
            TableColumn("Method") { MethodBadge(method: $0.method) }
                .width(min: 56, ideal: 64, max: 84)
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
                Text(Self.size(e))
                    .foregroundStyle(.secondary).monospacedDigit()
                    .help(Self.sizeHelp(e))
            }
            .width(min: 56, ideal: 70, max: 90)
            TableColumn("Time") { Text(Self.time($0.startMillis)).monospacedDigit() }
                .width(min: 90, ideal: 100, max: 110)
        }
        .contextMenu(forSelectionType: NetworkEntry.ID.self) { ids in
            if let id = ids.first, let e = vm.entries.first(where: { $0.id == id }) {
                Button("Only \(e.host)") { vm.filter.hosts = [e.host] }
                Button("Hide \(e.host)") { vm.filter.excludedHosts.insert(e.host) }
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

    /// `100 KB+` when the SDK cut the body short.
    static func size(_ e: NetworkEntry) -> String {
        guard let bytes = e.responseBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            + (e.isResponseBodyTruncated ? "+" : "")
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

/// The one place method colours live.
struct MethodBadge: View {
    let method: String

    var body: some View { Pill(text: method, tint: tint) }

    private var tint: Color {
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
