//
//  NetworkView.swift
//  Beaver
//

import SwiftUI
import AppKit

struct NetworkView: View {
    @Bindable var vm: NetworkViewModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            HSplitView {
                table.frame(minWidth: 420)
                NetworkDetailView(entry: vm.selected).frame(minWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Filter bar

    private var filterBar: some View {
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
            Text(statsLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(8)
    }

    private var statsLine: String {
        let s = vm.stats
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

    private var table: some View {
        Table(vm.filtered, selection: $vm.selection) {
            TableColumn("Method") { Text($0.method).font(.caption.monospaced().bold()) }
                .width(min: 50, ideal: 60, max: 80)
            TableColumn("Status") { e in
                Text(e.status.map(String.init) ?? "—")
                    .foregroundStyle(color(e.statusClass)).monospacedDigit()
            }
            .width(min: 44, ideal: 50, max: 60)
            TableColumn("Host") { Text($0.host).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("Path") { Text($0.path).lineLimit(1).truncationMode(.middle) }
            TableColumn("Duration") { e in
                Text(e.durationMillis.map { "\($0) ms" } ?? "—")
                    .foregroundStyle(durationColor(e.durationMillis)).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Time") { Text(Self.time($0.startMillis)).monospacedDigit() }
                .width(min: 90, ideal: 100, max: 110)
        }
        .contextMenu(forSelectionType: NetworkEntry.ID.self) { ids in
            if let id = ids.first, let e = vm.entries.first(where: { $0.id == id }) {
                Button("Only \(e.host)") { vm.filter.hosts = [e.host] }
                Button("Hide \(e.host)") { vm.filter.excludedHosts.insert(e.host) }
                Divider()
                Button("Copy URL") { copy(e.url) }
            }
        }
        .overlay {
            if vm.filtered.isEmpty {
                ContentUnavailableView("No network requests", systemImage: "network",
                                       description: Text(vm.entries.isEmpty
                                           ? "Requests appear here as the app makes them (iOS X-Ray SDK)."
                                           : "Nothing matches the current filters."))
            }
        }
    }

    private func color(_ c: NetworkEntry.StatusClass) -> Color {
        switch c {
        case .success: .green
        case .redirect: .blue
        case .clientError: .orange
        case .serverError, .failed: .red
        case .other: .secondary
        }
    }

    private func durationColor(_ ms: Int?) -> Color {
        guard let ms else { return .secondary }
        return ms < 100 ? .green : ms < 500 ? .orange : .red
    }

    static func time(_ ms: UInt64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Detail

struct NetworkDetailView: View {
    let entry: NetworkEntry?

    var body: some View {
        if let e = entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Request") {
                        row("URL", e.url, copyable: true)
                        row("Method", e.method)
                        headers(e.requestHeaders)
                        bodyView(e.requestBody)
                    }
                    section("Response") {
                        row("Status", [e.status.map(String.init), e.statusText].compactMap { $0 }.joined(separator: " "))
                        if let err = e.error {
                            Text(err).foregroundStyle(.red).textSelection(.enabled)
                        }
                        headers(e.responseHeaders)
                        bodyView(e.responseBody)
                    }
                    section("Timing") {
                        row("Started", NetworkView.time(e.startMillis))
                        row("Duration", e.durationMillis.map { "\($0) ms" } ?? "—")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No request selected", systemImage: "network")
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ k: String, _ v: String, copyable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(v).textSelection(.enabled).font(.body.monospaced())
            if copyable { Button { copy(v) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless) }
        }
    }

    @ViewBuilder
    private func headers(_ h: [String: String]) -> some View {
        if !h.isEmpty {
            DisclosureGroup("Headers (\(h.count))") {
                ForEach(h.keys.sorted(), id: \.self) { k in row(k, h[k] ?? "") }
            }
        }
    }

    /// JSON bodies render as a tree (same component as the Log feed detail);
    /// anything else as selectable monospaced text.
    @ViewBuilder
    private func bodyView(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            DisclosureGroup("Body") {
                HStack { Spacer(); Button("Copy") { copy(text) } }
                if let tree = StorageRecord.parse(text, rootKey: "body"), tree.children != nil {
                    JSONTreeView(record: tree)
                } else {
                    Text(text).font(.body.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}
