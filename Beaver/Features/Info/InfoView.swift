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
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                appColumn(r).frame(minWidth: 560, maxWidth: .infinity, alignment: .topLeading)
                deviceColumn(r).frame(minWidth: 380, maxWidth: 560, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 16) {
                appColumn(r)
                deviceColumn(r)
            }
        }
    }

    private func appColumn(_ r: AppInfoReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoCard(title: "Identity & versions", rows: r.identity)
            TableCard(title: "Screens (\(r.screens.count), \(r.screensSource))",
                      rows: r.screens.map { [$0.name, $0.id, $0.type ?? ""] },
                      empty: "No screens found: the full list needs rivers.json or layout.json, and no visits were logged.")
            TableCard(title: "Plugins (\(r.plugins.count), \(r.pluginsSource))",
                      rows: r.plugins.map { [$0.id, $0.version ?? ""] }, empty: "No plugins found.")
            TableCard(title: "Cell styles (\(r.cellStyles.count), \(r.cellStylesSource))",
                      rows: r.cellStyles.map { [$0.plugin, $0.id] }, empty: "No cell styles found.")
            ConfigFilesCard(sessionId: sessionId, report: r)
        }
    }

    private func deviceColumn(_ r: AppInfoReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            InfoCard(title: "Device", rows: r.device.identity + r.device.hardware)
            InfoCard(title: "Advertising", rows: r.device.advertising, empty: r.device.advertisingNote)
            if !r.device.userAgent.isEmpty { InfoCard(title: "User agent", rows: r.device.userAgent) }
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

    var body: some View {
        if !rows.isEmpty || empty != nil {
            GroupBox(title) {
                if rows.isEmpty {
                    Text(empty ?? "").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(rows, id: \.label) { InfoGridRow(row: $0) }
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
        GridRow {
            Text(row.label).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.value).font(.body.monospaced()).lineLimit(3).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.value, forType: .string)
                    toasts.success("Copied \(row.label)")
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
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

/// Plain columns of text, selectable.
private struct TableCard: View {
    let title: String
    let rows: [[String]]
    let empty: String

    var body: some View {
        GroupBox(title) {
            if rows.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(rows.indices, id: \.self) { i in
                        GridRow {
                            ForEach(rows[i].indices, id: \.self) { c in
                                Text(rows[i][c])
                                    .font(c == 0 ? .body : .caption.monospaced())
                                    .foregroundStyle(c == 0 ? .primary : .secondary)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
