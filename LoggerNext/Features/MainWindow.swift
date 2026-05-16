//
//  MainWindow.swift
//  LoggerNext
//

import SwiftUI
import UniformTypeIdentifiers

/// Root content view. NavigationSplitView with Sessions sidebar and a
/// per-feature detail area (Log feed / Storages). Bottom command bar
/// spans the whole window via `.safeAreaInset`.
struct MainWindow: View {
    @Environment(AppEnvironment.self) private var env

    @State private var selectedTab: Tab = .logFeed
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument: JSONExportDocument?

    enum Tab: Hashable {
        case logFeed
        case storages
        case sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            .navigationTitle(navigationTitle)
            .toolbar { toolbarContent }
            Divider()
            CommandBarView()
        }
        .frame(minWidth: 900, minHeight: 600)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: defaultExportName,
            onCompletion: { _ in exportDocument = nil }
        )
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedTab) {
            Label("Log feed", systemImage: "list.bullet.rectangle")
                .tag(Tab.logFeed)
            Label("Storages",  systemImage: "externaldrive")
                .tag(Tab.storages)
            Label("Sessions",  systemImage: "clock.arrow.circlepath")
                .tag(Tab.sessions)
        }
        .navigationTitle("LoggerNext")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selectedTab {
            case .logFeed:
                if let sessionId = env.viewingSessionId {
                    LogFeedView(sessionId: sessionId)
                        .id(sessionId)
                } else {
                    ConnectionPlaceholder(state: env.serverState)
                }
            case .storages:
                StoragesView()
            case .sessions:
                SessionsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingImporter = true
            } label: {
                ToolbarButtonLabel(systemImage: "square.and.arrow.down",
                                   title: "Import")
            }
            .buttonStyle(.plain)
            .help("Load events from a JSON file")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await prepareExport() }
            } label: {
                ToolbarButtonLabel(systemImage: "square.and.arrow.up",
                                   title: "Export")
            }
            .buttonStyle(.plain)
            .help("Save the visible events to a JSON file")
            .disabled(env.viewingSessionId == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                Task { await clearEvents() }
            } label: {
                ToolbarButtonLabel(systemImage: "xmark.circle",
                                   title: "Clear")
            }
            .buttonStyle(.plain)
            .help("Delete all events in the current session")
            .disabled(env.viewingSessionId == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                copyWebSocketURL()
            } label: {
                ToolbarButtonLabel(systemImage: "rectangle.and.pencil.and.ellipsis",
                                   title: "Copy IP")
            }
            .buttonStyle(.plain)
            .help("Copy ws://<ip>:9080 to the clipboard")
        }
        ToolbarItem(placement: .status) {
            ConnectionIndicator(state: env.serverState)
        }
    }

    private var navigationTitle: String {
        switch selectedTab {
        case .logFeed:  "Log feed"
        case .storages: "Storages"
        case .sessions: "Sessions"
        }
    }

    private var defaultExportName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = .init(identifier: "en_US_POSIX")
        return "loggernext_\(formatter.string(from: Date()))"
    }

    // MARK: - Toolbar actions

    private func copyWebSocketURL() {
        // Copy just `host:port` (no ws:// scheme) — the mobile SDK
        // wants the bare endpoint.
        let address = "\(NetworkInterface.bestAddress() ?? "localhost"):9080"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    private func clearEvents() async {
        guard let sid = env.viewingSessionId else { return }
        try? await env.store.clearEvents(sessionId: sid)
    }

    private func prepareExport() async {
        guard let sid = env.viewingSessionId else { return }
        // Pull every event in the session for export. Filter-aware export
        // ("Export filtered view") is a follow-up — see DECISIONS.md D7.
        // Cap the limit at 1M as defensive bound; sessions beyond that
        // need a streaming export path anyway.
        let events = (try? await env.store.events(
            sessionId: sid,
            filter: .none,
            offset: 0,
            limit: 1_000_000
        )) ?? []
        let data = (try? EventJSON.encode(events)) ?? Data()
        exportDocument = JSONExportDocument(data: data)
        showingExporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task {
            // Security-scoped resource access for sandbox.
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else { return }
            let events = (try? EventJSON.decode(data)) ?? []
            guard !events.isEmpty else { return }

            // Create a new "imported" session per D7 — don't destroy the
            // current live session.
            guard let session = try? await env.store.createSession(
                source: .imported,
                clientLabel: url.deletingPathExtension().lastPathComponent
            ) else { return }
            try? await env.store.appendBulk(events, to: session.id)
            // Switch the LogFeed to the newly imported session.
            env.viewingSessionId = session.id
        }
    }
}

// MARK: - Subviews

/// Icon + small caption rendered as a toolbar item. Matches the layout
/// of the old Logger app where each toolbar button shows its purpose
/// underneath the symbol.
private struct ToolbarButtonLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
            Text(title)
                .font(.system(size: 10))
        }
        .foregroundStyle(.primary)
        .frame(minWidth: 56)
        .contentShape(Rectangle())
    }
}

private struct ConnectionPlaceholder: View {
    let state: WSServer.State

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
            if let address = NetworkInterface.bestAddress() {
                Text("ws://\(address):9080")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        switch state {
        case .stopped:                  "Server not started"
        case .listening:                "Waiting for a client to connect…"
        case .clientConnected:          "Loading session…"
        case .clientDisconnected(let r): "Disconnected: \(r)"
        case .failed(let r):            "Server error: \(r)"
        }
    }
}

private struct ConnectionIndicator: View {
    let state: WSServer.State

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label).font(.caption)
        }
    }

    private var color: Color {
        switch state {
        case .clientConnected:       .green
        case .listening:             .yellow
        case .clientDisconnected:    .orange
        case .failed:                .red
        case .stopped:               .gray
        }
    }

    private var label: String {
        switch state {
        case .clientConnected:       "Connected"
        case .listening:             "Listening"
        case .clientDisconnected:    "Disconnected"
        case .failed:                "Error"
        case .stopped:               "Stopped"
        }
    }
}

// MARK: - FileDocument for export

struct JSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
