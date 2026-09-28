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
            .frame(maxWidth: 960, alignment: .leading)
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
        InfoCard(title: "Identity & versions", rows: r.identity)
        cmsLine(r.cms)
        TableCard(title: "Screens (\(r.screens.count), \(r.screensSource))",
                  rows: r.screens.map { [$0.name, $0.id, $0.type ?? ""] },
                  empty: "No screens found: the full list needs rivers.json or layout.json, and no visits were logged.")
        TableCard(title: "Plugins (\(r.plugins.count), \(r.pluginsSource))",
                  rows: r.plugins.map { [$0.id, $0.version ?? ""] }, empty: "No plugins found.")
        TableCard(title: "Cell styles (\(r.cellStyles.count), \(r.cellStylesSource))",
                  rows: r.cellStyles.map { [$0.plugin, $0.id] }, empty: "No cell styles found.")
        InfoCard(title: "Device", rows: r.device.identity + r.device.hardware)
        InfoCard(title: "Advertising", rows: r.device.advertising, empty: r.device.advertisingNote)
        if !r.device.userAgent.isEmpty { InfoCard(title: "User agent", rows: r.device.userAgent) }
        TableCard(title: "Config files",
                  rows: AppInfo.ConfigKind.allCases.compactMap { kind in
                      r.configs[kind].map { [kind.rawValue, $0.url, $0.error.map { "couldn't load: " + $0 } ?? $0.found] }
                  },
                  empty: "No config file URL found in storage or captured requests.")
    }

    @ViewBuilder
    private func cmsLine(_ cms: AppInfoReport.CMS) -> some View {
        HStack(spacing: 6) {
            switch cms {
            case .loaded:
                Label("Zapp CMS build_params loaded", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .noToken:
                Text("Set a Zapp token to add the CMS's versions and the exact config URLs.").foregroundStyle(.secondary)
            case .noVersionId:
                Text("Zapp CMS not asked: the app's storage has no version_id.").foregroundStyle(.secondary)
            case .failed(let why):
                Label("Zapp CMS: \(why)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button(cms == .noToken ? "Set Zapp Token…" : "Change Token…") {
                if let changed = ZappTokenPrompt.run() {
                    toasts.success(changed)
                    Task { await load() }
                }
            }
            .buttonStyle(.link)
        }
        .font(.caption)
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
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        if !rows.isEmpty || empty != nil {
            GroupBox(title) {
                if rows.isEmpty {
                    Text(empty ?? "").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(rows, id: \.label) { row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary)
                                Text(row.value).font(.body.monospaced()).lineLimit(3).textSelection(.enabled)
                                    .onTapGesture {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(row.value, forType: .string)
                                        toasts.success("Copied \(row.label)")
                                    }
                                    .help("Click to copy")
                                Text(row.source).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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

/// The Zapp access token prompt, from the app menu and the Info tab. The
/// token is the one zapptool uses (accounts.applicaster.com → Users → your
/// user → Access Tokens); it stays in the login keychain.
enum ZappTokenPrompt {
    /// A toast line when the token changed; nil when cancelled.
    @MainActor
    static func run() -> String? {
        let alert = NSAlert()
        alert.messageText = "Zapp Access Token"
        alert.informativeText = """
            With your Zapp token, App Info asks the Zapp CMS for the app version's build parameters \
            and exact config URLs, as zapptool does. Create one at accounts.applicaster.com → Users → \
            your user → Access Tokens. It's kept in your login keychain.
            """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = ZappToken.read() == nil ? "Paste the token" : "A token is set — paste a new one"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if ZappToken.read() != nil { alert.addButton(withTitle: "Remove Token") }
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            return ZappToken.write(token) ? "Zapp token saved" : "Couldn't save the token to the keychain"
        case .alertThirdButtonReturn:
            ZappToken.write(nil)
            return "Zapp token removed"
        default:
            return nil
        }
    }
}
