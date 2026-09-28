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
                result = try await SessionCompare.run(store: env.store, a: a, b: b)
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
            List {
                if let logs = r.logs { logSections(logs) }
                if let net = r.network { networkSections(net) }
                ForEach(r.pending, id: \.self) { section in
                    Section(section == .storage ? "Storage" : "App Info") {
                        Text(section == .storage
                             ? "Not compared yet: comes with the storage diff."
                             : "Not compared yet: comes with App Info (app, SDK and plugin versions, device).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Logs

    @ViewBuilder
    private func logSections(_ logs: SessionCompare.Logs) -> some View {
        patternSection("Log lines only in B", logs.onlyInB)
        patternSection("Log lines only in A", logs.onlyInA)
        if !logs.levels.isEmpty {
            Section("Warnings and errors per subsystem, A → B") {
                ForEach(logs.levels, id: \.self) { l in
                    HStack {
                        Image(systemName: l.increased ? "arrow.up" : "arrow.down")
                            .foregroundStyle(l.increased ? .red : .green)
                        Circle().fill(l.level.displayColor).frame(width: 7, height: 7)
                        Text(l.subsystem).lineLimit(1)
                        Spacer()
                        Text("\(l.a) → \(l.b)").monospacedDigit()
                    }
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
            Section("\(title) (\(items.count))") {
                ForEach(items, id: \.self) { p in
                    Button { open(.event(p.firstId)) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Circle().fill(p.level.displayColor).frame(width: 7, height: 7)
                            Text(p.subsystem).foregroundStyle(.secondary).lineLimit(1)
                            Text(p.pattern).lineLimit(2)
                            Spacer()
                            Text("×\(p.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
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
            Section("\(title) (\(items.count))") {
                ForEach(items, id: \.self) { g in
                    Button { open(.network(g.firstId)) } label: {
                        HStack {
                            Text(g.key).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("×\(g.count) · \(g.statusText)").monospacedDigit().foregroundStyle(.secondary)
                        }
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
            Section("\(title) (\(items.count))") {
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
