//
//  SessionCompareView.swift
//  Beaver
//

import SwiftUI

/// Two sessions side by side (D81), from Sessions → Compare with. A is the
/// one that works, B the one that doesn't. Every line opens its event or
/// request, like a journal link.
struct SessionCompareView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    let sessions: [SessionListItem]
    @State var a: Int64
    @State var b: Int64
    @State private var result: SessionCompare.Result?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                picker("Works (A)", $a)
                Button { (a, b) = (b, a) } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap A and B")
                picker("Fails (B)", $b)
            }
            .padding(12)
            Divider()
            content
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 560)
        .task(id: [a, b]) {
            result = nil
            failure = nil
            do {
                result = try await SessionCompare.run(store: env.store, a: a, b: b, zapp: .live)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func picker(_ title: String, _ selection: Binding<Int64>) -> some View {
        Picker(title, selection: selection) {
            ForEach(sessions) { s in
                Text("#\(s.id) \(s.title)" + (s.appLabel.map { " · \($0)" } ?? "")).tag(s.id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            ContentUnavailableView("Can't compare", systemImage: "exclamationmark.triangle", description: Text(failure))
                .frame(maxHeight: .infinity)
        } else if let r = result {
            // A plain scroll, not a List: List's section headers stay pinned
            // and on macOS 26 are see-through, so rows showed under them.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let logs = r.logs { logSections(logs) }
                    if let net = r.network { networkSections(net) }
                    if let info = r.appInfo { appInfoSections(info) }
                    if let storage = r.storage { storageSections(storage) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - App Info

    @ViewBuilder
    private func appInfoSections(_ info: SessionCompare.AppInfoDiff) -> some View {
        if !info.values.isEmpty {
            CompareSection(title: "App Info, A → B", count: info.values.count) {
                ForEach(info.values, id: \.self) { v in
                    HStack(alignment: .firstTextBaseline) {
                        Text(v.label).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
                        Text(v.a ?? "—").textSelection(.enabled)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                        Text(v.b ?? "—").textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        if !info.plugins.isEmpty {
            CompareSection(title: "Plugins, A → B", count: info.plugins.count) {
                Text("A: \(info.pluginsSourceA) · B: \(info.pluginsSourceB)")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)
                ForEach(info.plugins, id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        changeMark(p.a == nil ? .added : p.b == nil ? .removed : .changed)
                        Text(p.id)
                        Spacer()
                        Text("\(p.a ?? "—") → \(p.b ?? "—")").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private func storageSections(_ storage: SessionCompare.Storage) -> some View {
        ForEach(storage.layers, id: \.layer) { layer in
            if let missing = layer.missing {
                CompareSection(title: "Storage · \(layer.layer.displayName)", count: nil) {
                    Text("Not compared: \(missing).").foregroundStyle(.secondary).padding(.vertical, 3)
                }
            } else if !layer.changes.isEmpty {
                CompareSection(title: "Storage · \(layer.layer.displayName), A → B", count: layer.changes.count) {
                    ForEach(layer.changes, id: \.self) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            changeMark(c.kind)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.path).font(.callout.monospaced())
                                if c.fields.isEmpty {
                                    Text("\(c.old ?? "—") → \(c.new ?? "—")")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                } else {
                                    ForEach(c.fields.prefix(10), id: \.self) { f in
                                        Text("\(f.path): \(f.old ?? "—") → \(f.new ?? "—")")
                                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func changeMark(_ kind: StorageChange.Kind) -> some View {
        let (symbol, color): (String, Color) = switch kind {
        case .added: ("+", .green)
        case .removed: ("−", .red)
        case .changed: ("~", .orange)
        }
        return Text(symbol).font(.body.monospaced().weight(.bold)).foregroundStyle(color)
    }

    // MARK: - Logs

    @ViewBuilder
    private func logSections(_ logs: SessionCompare.Logs) -> some View {
        patternSection("Log lines only in B", logs.onlyInB)
        patternSection("Log lines only in A", logs.onlyInA)
        if !logs.levels.isEmpty {
            CompareSection(title: "Warnings and errors per subsystem, A → B", count: logs.levels.count) {
                ForEach(logs.levels, id: \.self) { l in
                    HStack {
                        Image(systemName: l.increased ? "arrow.up" : "arrow.down")
                            .foregroundStyle(l.increased ? .red : .green)
                        Circle().fill(l.level.displayColor).frame(width: 7, height: 7)
                        Text(EventRecord.shortSubsystem(l.subsystem)).lineLimit(1).help(l.subsystem)
                        Text(l.level.rawValue).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(l.a) → \(l.b)").monospacedDigit()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        if logs.capped {
            Text("A session has over \(SessionCompare.patternCap) distinct log patterns; the rarest weren't compared.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func patternSection(_ title: String, _ items: [SessionCompare.PatternCount]) -> some View {
        if !items.isEmpty {
            CompareSection(title: title, count: items.count) {
                ForEach(items, id: \.self) { p in
                    Button { open(.event(p.firstId)) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(p.level.displayColor).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.pattern).lineLimit(2)
                                Text(EventRecord.shortSubsystem(p.subsystem))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 8)
                            Text("×\(p.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show event #\(p.firstId)")
                }
            }
        }
    }

    // MARK: - Network

    @ViewBuilder
    private func networkSections(_ net: SessionCompare.Network) -> some View {
        groupSection("Requests only in B", net.onlyInB)
        groupSection("Requests only in A", net.onlyInA)
        pairSection("Status changed", net.statusChanged) { "\($0.statusText)" }
        pairSection("Median duration changed", net.durationChanged) { g in
            g.medianMs.map { NetworkEntry.compactDuration($0) } ?? "—"
        }
    }

    @ViewBuilder
    private func groupSection(_ title: String, _ items: [SessionCompare.RequestGroup]) -> some View {
        if !items.isEmpty {
            CompareSection(title: title, count: items.count) {
                ForEach(items, id: \.self) { g in
                    Button { open(.network(g.firstId)) } label: {
                        HStack {
                            Text(g.key).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("×\(g.count) · \(g.statusText)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show request #\(g.firstId)")
                }
            }
        }
    }

    @ViewBuilder
    private func pairSection(_ title: String, _ items: [SessionCompare.RequestPair],
                             _ value: @escaping (SessionCompare.RequestGroup) -> String) -> some View {
        if !items.isEmpty {
            CompareSection(title: title, count: items.count) {
                ForEach(items, id: \.self) { p in
                    HStack {
                        Text(p.key).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("A: \(value(p.a))") { open(.network(p.a.firstId)) }
                            .help("Show request #\(p.a.firstId)")
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Button("B: \(value(p.b))") { open(.network(p.b.firstId)) }
                            .help("Show request #\(p.b.firstId)")
                    }
                    .buttonStyle(.link)
                    .monospacedDigit()
                    .padding(.vertical, 3)
                }
            }
        }
    }

    /// Closes the sheet, then shows the row through `ui_show`'s path.
    private func open(_ link: JournalLink) {
        dismiss()
        Task {
            do {
                try await env.open(link, reveal: false)
            } catch let error as ToolError {
                toasts.error(error.personMessage)
            } catch {
                toasts.error(error.localizedDescription)
            }
        }
    }
}

/// A titled, collapsible block of rows. Its header scrolls with the rows,
/// so nothing shows through it.
private struct CompareSection<Rows: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let rows: Rows
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.bottom, 6)
            if expanded { rows }
            Divider().padding(.top, 8)
        }
    }
}
