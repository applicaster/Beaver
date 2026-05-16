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
    @State private var showingBookmarks = false
    @State private var bookmarksSnapshot: [BookmarkedEvent] = []

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
        // Switching sessions changes which session the toolbar acts on.
        .onChange(of: env.viewingSessionId) { _, _ in
            Task { await env.refreshViewingEventCount() }
        }
        .task {
            // Initial fetch so toolbar disabled state is correct on
            // first appearance.
            await env.refreshViewingEventCount()
        }
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
        // No explicit alignment — defaults to center, which is what
        // ContentUnavailableView placeholders want. Fully-populated
        // views (LogFeedContent, StoragesContent) fill the space via
        // their own .frame(maxWidth/maxHeight: .infinity) modifiers
        // with internal top-leading alignment, so they pin correctly
        // regardless of what the parent says.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .disabled(!hasEvents)
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
            .disabled(!hasEvents)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await prepareBookmarks() }
            } label: {
                ToolbarButtonLabel(systemImage: "bookmark",
                                   title: "Bookmarks")
            }
            .buttonStyle(.plain)
            .help("Show bookmarked events in this session")
            .disabled(!hasEvents)
            .popover(isPresented: $showingBookmarks, arrowEdge: .bottom) {
                BookmarksPopover(
                    bookmarks: bookmarksSnapshot,
                    onSelect: { eventId in
                        showingBookmarks = false
                        // Tell whichever LogFeedViewModel is active to
                        // jump. We use a NotificationCenter signal so
                        // we don't have to thread the view model up.
                        NotificationCenter.default.post(
                            name: .loggerNextJumpToBookmark,
                            object: eventId
                        )
                    },
                    onRemove: { eventId, sessionId in
                        Task {
                            try? await env.store.removeBookmark(
                                eventId: eventId,
                                sessionId: sessionId
                            )
                            await prepareBookmarks()
                        }
                    }
                )
            }
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

    private func prepareBookmarks() async {
        guard let sid = env.viewingSessionId else {
            print("[Bookmarks] prepare: no viewing session")
            return
        }
        do {
            let bms = try await env.store.bookmarks(sessionId: sid)
            print("[Bookmarks] prepare(viewingSession=\(sid)) -> \(bms.count)")
            bookmarksSnapshot = bms
        } catch {
            print("[Bookmarks] prepare ERROR: \(error)")
            bookmarksSnapshot = []
        }
        showingBookmarks = true
    }

    /// True iff there's a viewing session AND it has at least one event.
    /// Gates the Export / Clear / Bookmarks toolbar buttons so they
    /// can't fire on an empty session.
    private var hasEvents: Bool {
        env.viewingSessionId != nil && env.viewingEventCount > 0
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

        // If no client is currently connected, drop back to the
        // "Waiting for a client…" placeholder. An empty session
        // without a live feed is a dead end; the placeholder is the
        // more useful empty state. While a client IS connected we
        // stay on the session — new events will resume the feed.
        if case .clientConnected = env.serverState {
            // active client → stay
        } else {
            env.viewingSessionId = nil
        }
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

// MARK: - Bookmarks popover

extension Notification.Name {
    /// Posted with `object: Int64 (eventId)` when a bookmark is
    /// clicked in the toolbar popover. LogFeedView listens for it and
    /// jumps the active session's view model to the event.
    static let loggerNextJumpToBookmark = Notification.Name("LoggerNextJumpToBookmark")
}

private struct BookmarksPopover: View {
    let bookmarks: [BookmarkedEvent]
    let onSelect: (Int64) -> Void
    let onRemove: (_ eventId: Int64, _ sessionId: Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "No bookmarks",
                    systemImage: "bookmark",
                    description: Text("Right-click any event → Bookmark.")
                )
                .frame(width: 320, height: 160)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(bookmarks) { be in
                            BookmarkRow(
                                bookmarked: be,
                                onSelect: { onSelect(be.event.id) },
                                onRemove: { onRemove(be.event.id, be.bookmark.sessionId) }
                            )
                            Divider()
                        }
                    }
                }
                .frame(width: 360, height: 320)
            }
        }
    }
}

private struct BookmarkRow: View {
    let bookmarked: BookmarkedEvent
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(bookmarked.event.message)
                    .font(.caption)
                    .lineLimit(2)
                Text("\(bookmarked.event.subsystem) · \(bookmarked.event.timeOfDayWithMillis)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Remove bookmark")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
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
