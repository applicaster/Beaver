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
    @State private var showingTimeJump = false

    /// Per-session view-models, owned here so their state (filter,
    /// sort, exclude, expanded namespaces, search term, etc.)
    /// survives tab switches. Without this, the `switch
    /// selectedTab` below tears down each tab's view subtree —
    /// including its `@State` VM — so coming back from Storages
    /// would reset every Log-feed filter pill.
    ///
    /// Rebuilt only when `env.viewingSessionId` actually changes
    /// (see `.task(id:)` below).
    @State private var logFeedVM: LogFeedViewModel?
    @State private var storagesVM: StoragesViewModel?

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
        // Keep the per-session VMs in sync with the active session.
        // Fires on first appearance and whenever the user switches
        // sessions — but NOT on tab switches, because the task id
        // hasn't changed. That's the whole point: filter / sort /
        // expand state survives Log feed → Storages → Log feed.
        .task(id: env.viewingSessionId) {
            guard let sid = env.viewingSessionId else {
                logFeedVM = nil
                storagesVM = nil
                return
            }
            if logFeedVM?.sessionId != sid {
                logFeedVM = LogFeedViewModel(store: env.store, sessionId: sid)
            }
            if storagesVM?.sessionId != sid {
                let fresh = StoragesViewModel(store: env.store, sessionId: sid)
                // Subscribe before the first request so the inbound
                // `.storageUpdated` broadcast isn't dropped. See
                // StoragesViewModel.bootstrap() docstring.
                await fresh.bootstrap()
                storagesVM = fresh
                // Auto-fetch the first storage snapshot so the user
                // doesn't have to click Reload to see anything.
                // No-op if no client is connected; safe to call
                // regardless of which tab the user is currently
                // viewing — the snapshot lands in the store and
                // both this VM and any future visit pick it up.
                fresh.requestRefresh(via: env.server)
            }
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
        .navigationTitle("Beaver")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selectedTab {
            case .logFeed:
                if let vm = logFeedVM {
                    // No `.id(sessionId)` here — the VM is replaced
                    // on session change (via the `.task(id:)` above)
                    // which is sufficient to reset all per-session
                    // state. Forcing an additional view rebuild on
                    // session change would just throw away the
                    // selection / scroll position we just restored.
                    LogFeedView(vm: vm)
                } else {
                    ConnectionPlaceholder(state: env.serverState)
                }
            case .storages:
                // Same pattern as Log feed above: when no session
                // is active the tab shows ConnectionPlaceholder so
                // the visual idiom matches across tabs and there's
                // no centered-vs-top-aligned layout jump when a
                // session arrives.
                if let vm = storagesVM {
                    StoragesView(vm: vm)
                } else {
                    ConnectionPlaceholder(state: env.serverState)
                }
            case .sessions:
                SessionsView(onOpenInLogFeed: { _ in
                    // The row already mutated `env.viewingSessionId`
                    // (via the List selection binding). All we have
                    // to do is flip to the Log feed tab.
                    selectedTab = .logFeed
                })
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
        // Leading edge: device / app context. Hidden entirely
        // until the SDK has reported its applicaster.v2 metadata.
        // Sits at the same vertical height as the right-side
        // toolbar buttons so the toolbar reads as one consistent
        // strip rather than left-padded space.
        ToolbarItem(placement: .navigation) {
            if let ctx = storagesVM?.appContext, ctx.isNonEmpty {
                ToolbarDeviceBadge(context: ctx)
            }
        }
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
                                   title: hasFilter ? "Export (filtered)" : "Export")
            }
            .buttonStyle(.plain)
            .help(hasFilter
                  ? "Save only the events matching the current filter to a JSON file. Clear the filter to export everything."
                  : "Save every event in the current session to a JSON file. Set a filter first to narrow the export.")
            .disabled(!hasEvents)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                Task { await clearEvents() }
            } label: {
                ToolbarButtonLabel(systemImage: "xmark.circle",
                                   title: "Clear",
                                   tint: hasEvents ? .red : nil)
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
                showingTimeJump = true
            } label: {
                ToolbarButtonLabel(systemImage: "clock.arrow.circlepath",
                                   title: "Jump To Time")
            }
            .buttonStyle(.plain)
            .help("Scroll to the event closest to a typed time (HH:MM:SS[.mmm])")
            .disabled(!hasEvents)
            .popover(isPresented: $showingTimeJump, arrowEdge: .bottom) {
                JumpToTimePopover { date in
                    showingTimeJump = false
                    NotificationCenter.default.post(
                        name: .loggerNextJumpToTime,
                        object: date
                    )
                }
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
        // Centered Connected pill. `.principal` keeps it anchored
        // in the middle of the title bar so the device badge can
        // sit on the leading edge and the action buttons on the
        // trailing edge — three groups, three positions.
        ToolbarItem(placement: .principal) {
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

    /// True iff the user has narrowed the Log feed with any filter.
    /// Drives the Export button's label ("Export" vs "Export (filtered)")
    /// so the user knows what they're about to ship.
    private var hasFilter: Bool {
        !env.activeFilter.isEmpty
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
        // Copy the full ws://<ip>:9080 URL. The mobile SDK accepts
        // both forms, but the prefixed form is what users paste into
        // browser address bars / SDK init code, so it's the more
        // useful default.
        let host = NetworkInterface.bestAddress() ?? "localhost"
        let url = "ws://\(host):9080"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
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
        // Filter-aware export (D26). `env.activeFilter` mirrors the
        // Log-feed view model's current filter. Passing it through
        // means clicking Export ships exactly the rows the user is
        // looking at — narrow the view down with the filter pills
        // first, then Export emits just those events. Clear the
        // filter to export the whole session.
        //
        // Cap the limit at 1M as defensive bound; sessions beyond
        // that need a streaming export path anyway.
        let events = (try? await env.store.events(
            sessionId: sid,
            filter: env.activeFilter,
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
/// underneath the symbol. Optional `tint` lets destructive actions
/// (e.g., Clear) render in red so the danger is visible at a glance.
/// Compact "what device + app am I looking at" badge that lives
/// on the leading edge of the main toolbar (placement
/// `.navigation`). Reads from `StoragesViewModel.AppContext`
/// (populated as soon as the first `storage.list` response comes
/// back from the SDK) and renders as two stacked lines, vertically
/// matching the right-side toolbar buttons:
///
///     [icon] Miami Heat
///            11.0.1 · iPhone 15 Pro Max · iOS 26.4.2
///
/// Right-click → "Copy device fingerprint" pastes the same info
/// as a single line into the clipboard for bug reports.
private struct ToolbarDeviceBadge: View {
    let context: StoragesViewModel.AppContext

    /// Single muted subtitle line: `<version> · <device> · <OS> <ver>`.
    /// Each piece is skipped if missing, so e.g. an SDK that doesn't
    /// report a device model still produces a clean subtitle.
    private var subtitle: String {
        var parts: [String] = []
        if let v = context.appVersion { parts.append(v) }
        if let d = context.deviceModel { parts.append(d) }
        if let os = context.osVersion {
            parts.append((context.platform ?? "OS") + " " + os)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(context.appName ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Matches ConnectionIndicator's chrome — same padding,
        // same solid background, same border weight — so the
        // two toolbar clouds read as siblings at different ends
        // of the bar.
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color(.controlBackgroundColor))
        )
        .contentShape(Capsule())
        .help(fingerprint)
        .contextMenu {
            Button("Copy device fingerprint") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fingerprint, forType: .string)
            }
        }
    }

    /// One-line string used by both the help tooltip and the
    /// right-click copy action.
    private var fingerprint: String {
        var parts: [String] = []
        if let n = context.appName {
            parts.append(n + (context.appVersion.map { " \($0)" } ?? ""))
        }
        if let d = context.deviceModel { parts.append(d) }
        if let os = context.osVersion {
            parts.append((context.platform ?? "OS") + " " + os)
        }
        return parts.joined(separator: " · ")
    }
}

private struct ToolbarButtonLabel: View {
    let systemImage: String
    let title: String
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? .primary)
        // Fixed width (not `minWidth`) so every toolbar button is
        // exactly the same horizontal extent. 76pt comfortably
        // fits the longest current label ("Jump To Time") at 10pt
        // and gives short labels a sensible amount of empty space
        // on either side. If you add a label longer than ~12 chars,
        // bump this.
        .frame(width: 76)
        .contentShape(Rectangle())
    }
}

private struct ConnectionPlaceholder: View {
    let state: WSServer.State

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: iconName,
            description: Text(descriptionText)
        )
    }

    private var title: String {
        switch state {
        case .stopped:                "Server not started"
        case .listening:              "Waiting for a client to connect"
        case .clientConnected:        "Loading session…"
        case .clientDisconnected:     "Disconnected"
        case .failed:                 "Server error"
        }
    }

    private var iconName: String {
        switch state {
        case .listening, .clientConnected:
            "antenna.radiowaves.left.and.right"
        case .clientDisconnected:
            "wifi.slash"
        case .failed, .stopped:
            "exclamationmark.triangle"
        }
    }

    private var descriptionText: String {
        // Keep these single-line so the placeholder centers at the
        // same vertical position as the Storages "No session selected"
        // empty state. Multi-line descriptions push the title up.
        // The full URL is available via the Copy IP toolbar button.
        switch state {
        case .stopped:
            return "The WebSocket listener hasn't started."
        case .listening:
            return "Connect a device to begin streaming logs."
        case .clientConnected:
            return "One moment — preparing the session."
        case .clientDisconnected:
            return "Reopen the device app to reconnect."
        case .failed(let reason):
            return reason
        }
    }
}

private struct ConnectionIndicator: View {
    let state: WSServer.State

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label).font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        // Solid control background instead of .bar material — the
        // .principal toolbar placement layers its own chrome
        // behind the item which made .bar nearly invisible and
        // the border barely register. controlBackgroundColor +
        // a stronger border opacity reads as a proper pill.
        .background(
            Capsule().fill(Color(.controlBackgroundColor))
        )
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

    /// Posted with `object: Date` when the user picks a target time in
    /// the "Jump to Time" toolbar popover. LogFeedView listens for it
    /// and tells the active view model to scroll to the nearest event
    /// (respecting the active filter). See D27.
    static let loggerNextJumpToTime = Notification.Name("LoggerNextJumpToTime")
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

// MARK: - Jump-to-Time popover

/// Tiny popover with a typed time field. The user enters a time of
/// day like `14:13:42` or `14:13:42.565` (milliseconds optional but
/// honored when present), hits Jump, and the active
/// LogFeedViewModel scrolls to the event whose timestamp is closest.
/// Date is implicitly "today" — works fine for live debugging, the
/// common case. See D27.
private struct JumpToTimePopover: View {
    let onJump: (Date) -> Void

    @State private var input: String = ""
    @State private var parseError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jump to time").font(.headline)
            Text("Enter HH:MM:SS or HH:MM:SS.mmm. Matches by time-of-day only — date is ignored, so this works for sessions from any day. Respects the active filter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                TextField("14:13:42 or 14:13:42.565", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(submit)
                    .onChange(of: input) { _, _ in parseError = nil }
                if let parseError {
                    Text(parseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button("Now") { input = JumpToTimePopover.formatNow() }
                    .help("Insert the current time of day")
                Spacer()
                Button("Jump", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            if input.isEmpty { input = JumpToTimePopover.formatNow() }
        }
    }

    private func submit() {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard let date = JumpToTimePopover.parse(raw) else {
            parseError = "Couldn't parse \"\(raw)\". Use HH:MM:SS or HH:MM:SS.mmm."
            return
        }
        parseError = nil
        onJump(date)
    }

    // MARK: - Parsing

    /// Parse `HH:MM`, `HH:MM:SS`, or `HH:MM:SS.mmm` into a Date on
    /// today. Returns nil if any field is out of range or the shape
    /// doesn't match. Tolerates leading/trailing whitespace; the
    /// caller already trims.
    static func parse(_ raw: String) -> Date? {
        // Split off the optional .ms suffix from the seconds field.
        var seconds = 0
        var milliseconds = 0
        let timeAndMs = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let timePart = String(timeAndMs[0])
        if timeAndMs.count == 2 {
            // Accept 1–4 ms digits; pad / truncate to 3 for nanos.
            let msDigits = String(timeAndMs[1]).prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
            guard let m = Int(msDigits), m >= 0, m < 1000 else { return nil }
            milliseconds = m
        }

        let pieces = timePart.split(separator: ":")
        guard pieces.count == 2 || pieces.count == 3 else { return nil }
        guard let h = Int(pieces[0]), h >= 0, h < 24 else { return nil }
        guard let m = Int(pieces[1]), m >= 0, m < 60 else { return nil }
        if pieces.count == 3 {
            guard let s = Int(pieces[2]), s >= 0, s < 60 else { return nil }
            seconds = s
        }

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        comps.second = seconds
        comps.nanosecond = milliseconds * 1_000_000
        return Calendar.current.date(from: comps)
    }

    static func formatNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = .init(identifier: "en_US_POSIX")
        return f.string(from: Date())
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
