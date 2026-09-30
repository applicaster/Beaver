//
//  InfoView.swift
//  Beaver
//
//  D79: App Info and Device Info for the viewed session, zapp-support's two
//  tabs in one. Every value shows where it came from; clicking copies it.

import AppKit
import SwiftUI

struct InfoView: View {
    let sessionId: Int64
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var report: AppInfoReport?
    @State private var session: Session?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let failure {
                    Text("Couldn't build App Info: \(failure)").foregroundStyle(.red)
                }
                if let report { content(report) } else if loading { ProgressView() }
            }
            .padding(20)
            .frame(maxWidth: 1600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: sessionId) {
            await load()
            // Storage arrives a moment after a device connects: build again
            // when the first snapshot lands. Later refreshes (Storages'
            // auto-refresh every 2 s) would rescan everything, so Reload
            // is manual after that.
            for await change in await env.store.changes() {
                if case .storageUpdated(let sid, _) = change, sid == sessionId, report?.storageAsOf == nil {
                    await load()
                }
                if case .configsSaved(let sid) = change, sid == sessionId { await load() }
                // What the app says it was built with (D85) lands a moment after it connects.
                if case .appBuildRecorded(let sid) = change, sid == sessionId { await load() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let icon = report?.iconURL.flatMap(URL.init(string:)) {
                AsyncImage(url: icon) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
            }
            Text("App & Device Info").font(.title2.weight(.semibold))
            if let asOf = report?.storageAsOf {
                Text("storage as of " + asOf.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                guard let session else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.fingerprint(capturedAt: Date()), forType: .string)
                toasts.success("Copied device fingerprint")
            } label: { Label("Copy Fingerprint", systemImage: "doc.on.doc") }
                .help("App, device, device id, session and time — for a ticket")
                .disabled(session == nil)
            Button {
                Task {
                    await ConfigCache.shared.clear()
                    await load()
                }
            } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Read storage, logs and the app's config files again")
                .disabled(loading)
        }
    }

    @ViewBuilder
    private func content(_ r: AppInfoReport) -> some View {
        if r.storageAsOf == nil {
            Text("No storage snapshot yet — App Info reads the app's storage. It arrives while the app is connected.")
                .foregroundStyle(.secondary)
        }
        // Side by side when the window is wide, one column when it isn't:
        // a single column capped at 960 left a hole on the right.
        // Who it is on the left — app, then device, so every id sits
        // together; the layout's lists on the right.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                identityColumn(r).frame(minWidth: 380, maxWidth: 560, alignment: .topLeading)
                listsColumn(r).frame(minWidth: 560, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 16) {
                identityColumn(r)
                listsColumn(r)
            }
        }
    }

    /// D85: the build's plugins beside Zapp's, or Zapp's alone, "build not confirmed".
    @ViewBuilder
    private func pluginsCard(_ r: AppInfoReport) -> some View {
        if let why = r.pluginsNotConfirmed {
            TableCard(title: "Plugins (\(r.plugins.count), \(r.pluginsSource)) — build not confirmed: \(why)",
                      rows: r.plugins.map { [$0.id, $0.version ?? ""] }, copy: [0], empty: "No plugins found.")
        } else {
            // What needs a rebuild first, then what only the build has, then the rest.
            let order: [AppBuild.PluginRow.Status: Int] = [.rebuildNeeded: 0, .onlyInZapp: 1, .onlyInBuild: 2]
            let rows = r.pluginRows.enumerated()
                .sorted { (order[$0.element.status] ?? 3, $0.offset) < (order[$1.element.status] ?? 3, $1.offset) }
                .map(\.element)
            let differ = rows.filter { $0.status != .same }.count
            TableCard(title: "Plugins (\(rows.count), built into the app; build · Zapp now)",
                      rows: rows.map { p in
                          [p.id, p.name ?? "", p.build ?? "—", p.zapp ?? "—", p.status == .same ? "" : p.status.rawValue]
                      },
                      copy: [0],
                      warn: Set(rows.indices.filter { rows[$0].status == .rebuildNeeded || rows[$0].status == .onlyInZapp }),
                      warnFrom: 2,
                      warning: differ == 0 ? nil
                        : "\(differ) of \(rows.count) plugins differ from Zapp now — a rebuild picks up Zapp's versions",
                      empty: "The build has no plugins.")
        }
    }

    private func identityColumn(_ r: AppInfoReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let contradicted = r.identity.filter { $0.label.hasSuffix(" (storage)") }
            InfoCard(title: "Identity & versions", rows: r.identity,
                     warning: contradicted.isEmpty ? nil
                        : "The build differs from storage: " + contradicted.map { $0.label.replacingOccurrences(of: " (storage)", with: "") }
                            .joined(separator: ", "))
            InfoCard(title: "Built into the app" + (r.build.map { " (app.info, \($0.fetchedAt.formatted(date: .omitted, time: .standard)))" } ?? ""),
                     rows: r.build?.rows ?? [],
                     empty: r.build == nil
                        ? "Not reported: Beaver asks the app when it connects with X-Ray's native sink."
                        : "This app's X-Ray has no app.info.")
            InfoCard(title: "Device", rows: r.device.identity + r.device.hardware)
            if !r.device.userAgent.isEmpty { InfoCard(title: "User agent", rows: r.device.userAgent) }
            if !r.sentKeys.isEmpty {
                // What the app's own requests will send: the login state.
                InfoCard(title: "Sign-in — keys the data sources send", rows: r.sentKeys)
            }
            InfoCard(title: "Advertising", rows: r.device.advertising, empty: r.device.advertisingNote)
        }
    }

    private func listsColumn(_ r: AppInfoReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TableCard(title: "Screens (\(r.screens.count), \(r.screensSource))",
                      rows: r.screens.map { [$0.name, $0.id, $0.type ?? ""] }, copy: [1],
                      empty: "No screens found: the full list needs rivers.json or layout.json, and no visits were logged.")
            if !r.typeMapping.isEmpty {
                TableCard(title: "Type mapping — entry type → screen (\(r.typeMapping.count), layout.json)",
                          rows: r.typeMapping.map { [$0.type, $0.screenName ?? "no such screen", $0.screenId] }, copy: [2],
                          empty: "")
            }
            if !r.navigation.isEmpty {
                TableCard(title: "Navigation — menu item → screen (layout.json)",
                          rows: r.navigation.map { [$0.title, $0.menu, $0.screenName ?? "no such screen", $0.screenId] }, copy: [3],
                          empty: "")
            }
            if !r.dataSources.isEmpty {
                TableCard(title: "Data sources (\(r.dataSources.count), pipes endpoints)",
                          rows: r.dataSources.map { d in
                              [d.method, d.url, d.sends.map { "\($0.key) as \($0.as)" }.joined(separator: ", ")]
                          }, copy: [1], empty: "")
            }
            pluginsCard(r)
            TableCard(title: "Cell styles (\(r.cellStyles.count), \(r.cellStylesSource))",
                      rows: r.cellStyles.map { [$0.plugin, $0.id] }, copy: [1], empty: "No cell styles found.")
            ConfigFilesCard(sessionId: sessionId, report: r)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        session = try? await env.store.sessions().first { $0.id == sessionId }
        do {
            report = try await AppInfoReport.build(store: env.store, sessionId: sessionId, http: .live)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Label, value (click copies), source.
private struct InfoCard: View {
    let title: String
    let rows: [InfoRow]
    var empty: String?
    /// A line in orange above the rows, e.g. what differs.
    var warning: String?

    var body: some View {
        if !rows.isEmpty || empty != nil {
            GroupBox(title) {
                if rows.isEmpty {
                    Text(empty ?? "").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let warning { WarningLine(text: warning) }
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(rows, id: \.label) { InfoGridRow(row: $0) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Label, value, source. The value is selectable, so a click can't also
/// copy it (selection takes the click): a copy button shows on hover.
private struct InfoGridRow: View {
    let row: InfoRow
    @Environment(ToastCenter.self) private var toasts
    @State private var hovered = false

    var body: some View {
        // D85: storage says otherwise than the app's own build.
        let contradicted = row.label.hasSuffix(" (storage)")
        GridRow {
            Text(row.label).foregroundStyle(contradicted ? Color.orange : .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.value).font(.body.monospaced()).lineLimit(3).textSelection(.enabled)
                    .foregroundStyle(contradicted ? Color.orange : .primary)
                    .help(contradicted ? "Storage says this, but the app's build reports the value above" : "")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.value, forType: .string)
                    toasts.success("Copied \(row.label)")
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy \(row.label)")
                .accessibilityLabel("Copy \(row.label)")
                .opacity(hovered ? 1 : 0)
            }
            Text(row.source).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                .truncationMode(.middle)
        }
        .onHover { hovered = $0 }
    }
}

/// Plain columns of text, selectable; the `copy` columns (ids) get a copy
/// button on hover, as Identity's rows do.
private struct TableCard: View {
    let title: String
    let rows: [[String]]
    var copy: Set<Int> = []
    /// Rows to act on: their cells from column `warnFrom` on are orange
    /// (the name before them stays readable).
    var warn: Set<Int> = []
    var warnFrom = 0
    /// A line in orange above the rows.
    var warning: String? = nil
    let empty: String

    var body: some View {
        GroupBox(title) {
            if rows.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let warning { WarningLine(text: warning) }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(rows.indices, id: \.self) { i in TableCardRow(cells: rows[i], copy: copy, warnFrom: warn.contains(i) ? warnFrom : nil) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TableCardRow: View {
    let cells: [String]
    let copy: Set<Int>
    /// From which column the cells are orange; nil: none.
    var warnFrom: Int?
    @Environment(ToastCenter.self) private var toasts
    @State private var hovered = false

    var body: some View {
        GridRow {
            ForEach(cells.indices, id: \.self) { c in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(cells[c])
                        .font(c == 0 ? .body : .caption.monospaced())
                        .foregroundStyle(warnFrom.map { c >= $0 } == true ? Color.orange : c == 0 ? .primary : .secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    if copy.contains(c), !cells[c].isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cells[c], forType: .string)
                            toasts.success("Copied \(cells[c])")
                        } label: { Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .help("Copy \(cells[c])")
                            .accessibilityLabel("Copy \(cells[c])")
                            .opacity(hovered ? 1 : 0)
                    }
                }
            }
        }
        .onHover { hovered = $0 }
    }
}

/// The app's launch-time config files. Saved with the session when the
/// device connected (D79): Open shows the file as Zapp had it then. A
/// session without a saved copy (older, imported) can save Zapp's now.
private struct ConfigFilesCard: View {
    let sessionId: Int64
    let report: AppInfoReport
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var saving = false

    var body: some View {
        GroupBox {
            let kinds = AppInfo.ConfigKind.allCases.filter { report.configs[$0] != nil }
            if kinds.isEmpty {
                Text("No config file URL found in storage or captured requests.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(kinds, id: \.self) { kind in
                        let c = report.configs[kind]!
                        GridRow {
                            Text(kind.rawValue)
                            Text(c.url).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Text(c.error.map { "couldn't load: " + $0 }
                                 ?? c.size.map { "\(c.found) · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" }
                                 ?? c.found)
                                .font(.caption).foregroundStyle(c.error == nil ? .secondary : Color.orange).lineLimit(2)
                            if let sha = c.sha256 {
                                Button("Open") { open(sha, kind) }
                                    .buttonStyle(.link).font(.caption)
                                    .help("Open the saved \(kind.rawValue) file in your JSON viewer")
                            } else {
                                Color.clear.frame(width: 1, height: 1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack {
                Text("Config files").font(.headline)
                if let at = report.configsSavedAt {
                    Text("saved \(at.formatted(date: .abbreviated, time: .standard)), as Zapp had them")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Downloaded when the device connected and kept with the session. Zapp overwrites these files on every publish, so the session keeps its own copy.")
                } else {
                    Text("in Zapp now").font(.caption).foregroundStyle(.secondary)
                    Button(saving ? "Saving…" : "Save with Session") { save() }
                        .buttonStyle(.link).font(.caption).disabled(saving || report.configs.isEmpty)
                        .help("Download every file as Zapp has it now and keep it with this session, so you can open them. Live sessions save theirs when the device connects.")
                }
            }
        }
    }

    private func open(_ sha: String, _ kind: AppInfo.ConfigKind) {
        Task {
            do {
                guard let data = try await env.store.configData(sha256: sha) else { throw ZappError("the saved file is gone") }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Beaver Config Files", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("session-\(sessionId)-\(kind.rawValue).json")
                try data.write(to: file)
                NSWorkspace.shared.open(file)
            } catch {
                toasts.error("Couldn't open \(kind.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let n = try await ConfigSnapshot.capture(store: env.store, sessionId: sessionId, http: .liveUncached)
                toasts.success("Saved \(n) config files with the session")
            } catch {
                toasts.error("Couldn't save the config files: \(error.localizedDescription)")
            }
        }
    }
}

/// ⚠ and a sentence in orange: something in the card to act on.
private struct WarningLine: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }
}
