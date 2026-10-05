//
//  SessionsView.swift
//  Beaver
//

import SwiftUI

/// Sessions tab — history of every recorded session. Selecting a
/// session shows its details on the right (device, toolboxes,
/// Disconnect); Open, a double-click or Return opens it in the Log
/// feed. Right-clicking offers the same and Delete; a footer button
/// wipes the whole history.
struct SessionsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var vm: SessionsViewModel?

    /// Callback the parent (MainWindow) provides so we can flip the
    /// selected tab to "Log feed" when the user picks a row. Passing a
    /// closure keeps `MainWindow.selectedTab` local to that view rather
    /// than hoisting it into `AppEnvironment`.
    let onOpenInLogFeed: (Int64) -> Void

    @State private var pendingDelete: SessionListItem?
    @State private var pendingDeleteAll = false
    @State private var comparing: ComparePair?
    /// The row whose details show. Not `env.viewingSessionId`: picking a
    /// row no longer takes the window to that session — Open does.
    @State private var selectedId: Int64?

    private struct ComparePair: Identifiable {
        let a: Int64, b: Int64
        var id: String { "\(a)-\(b)" }
    }

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if vm == nil {
                vm = SessionsViewModel(store: env.store)
            }
        }
    }

    @ViewBuilder
    private func content(vm: SessionsViewModel) -> some View {
        @Bindable var env = env
        HSplitView {
            VStack(spacing: 0) {
                List(vm.sessions, selection: $selectedId) { item in
                    row(for: item)
                        .tag(item.id)
                        .contentShape(Rectangle())
                }
                // Double-click or Return opens the session, as Open does.
                .contextMenu(forSelectionType: Int64.self) { ids in
                    if let id = ids.first, let item = vm.sessions.first(where: { $0.id == id }) {
                        rowMenu(item, vm: vm)
                    }
                } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
                .overlay {
                    if vm.sessions.isEmpty {
                        ContentUnavailableView(
                            "No sessions yet",
                            systemImage: "tray",
                            description: Text("Connect a mobile client to record one.")
                        )
                    }
                }

                footer(vm: vm)
            }
            .frame(minWidth: 380, maxWidth: .infinity)
            detail(vm: vm)
                .frame(minWidth: 400, idealWidth: 420, maxWidth: 520, maxHeight: .infinity)
        }
        .onAppear { if selectedId == nil { selectedId = env.viewingSessionId } }
        .sheet(item: $comparing) { pair in
            // The pickers offer only this app's sessions.
            SessionCompareView(sessions: vm.sessions.filter { s in
                s.id == pair.a || vm.sessions.first { $0.id == pair.a }.map { SessionCompare.sameApp(s.session, $0.session) } == true
            }, a: pair.a, b: pair.b)
        }
        // MARK: Delete-one confirmation
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                let id = item.id
                let title = item.title
                pendingDelete = nil
                // D97: the device can come back into this session while
                // the dialog is open; the inbound writer is using it again.
                guard !env.isLive(id) else {
                    toasts.error("\"\(title)\" is live again — disconnect the device first")
                    return
                }
                Task {
                    await vm.deleteSession(id: id)
                    toasts.success("Deleted \"\(title)\"")
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { item in
            Text("\"\(item.title)\" and its \(item.eventCount) events will be removed. This can't be undone.")
        }
        // MARK: Delete-all confirmation
        .confirmationDialog(
            "Delete all sessions?",
            isPresented: $pendingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                pendingDeleteAll = false
                Task {
                    await vm.deleteAllSessions()
                    toasts.success("All sessions deleted")
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteAll = false
            }
        } message: {
            Text("Every recorded session, plus its events and storage snapshots, will be removed. This can't be undone.")
        }
    }

    /// Right-click menu of a row.
    @ViewBuilder
    private func rowMenu(_ item: SessionListItem, vm: SessionsViewModel) -> some View {
        Button {
            open(item.id)
        } label: {
            Label("Open in Log feed",
                  systemImage: "arrow.forward.circle")
        }
        Menu {
            ForEach(related(to: item, in: vm)) { other in
                Button("#\(other.id) \(other.title)" + (other.appLabel.map { " · \($0)" } ?? "")) {
                    comparing = ComparePair(a: item.id, b: other.id)
                }
            }
        } label: {
            Label("Compare with", systemImage: "arrow.left.arrow.right")
        }
        .disabled(related(to: item, in: vm).isEmpty)
        .help(related(to: item, in: vm).isEmpty ? "No other session of this app to compare with" : "")
        if isLiveSession(item) {
            Button {
                Task { await env.disconnect(item.id) }
            } label: {
                Label("Disconnect", systemImage: "eject")
            }
            .help(DevicePopover.disconnectHelp)
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = item
        } label: {
            // SwiftUI's macOS menu styling doesn't
            // automatically tint destructive items in
            // this version, so apply the colour
            // directly to each piece of the label.
            // (`.foregroundStyle` on the Label itself
            // gets stripped by the menu renderer; the
            // per-element form below sticks.)
            Label {
                Text("Delete session…")
                    .foregroundColor(.red)
            } icon: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
        }
        .tint(.red)
        .disabled(isLiveSession(item))
        
    }

    /// Other sessions of the same app: the only ones Compare takes.
    private func related(to item: SessionListItem, in vm: SessionsViewModel) -> [SessionListItem] {
        vm.sessions.filter { $0.id != item.id && SessionCompare.sameApp($0.session, item.session) }
    }

    private func open(_ id: Int64) {
        env.viewingSessionId = id
        onOpenInLogFeed(id)
    }

    // MARK: - Details

    @ViewBuilder
    private func detail(vm: SessionsViewModel) -> some View {
        if let item = vm.sessions.first(where: { $0.id == selectedId }) {
            SessionDetailPane(
                item: item,
                isLive: isLiveSession(item),
                isViewed: env.viewingSessionId == item.id,
                sessions: vm.sessions.map(\.session),
                others: related(to: item, in: vm),
                onOpen: { open(item.id) },
                onCompare: { comparing = ComparePair(a: item.id, b: $0) },
                onRequestDelete: { pendingDelete = item }
            )
            .id(item.id)
        } else {
            ContentUnavailableView("Select a session", systemImage: "sidebar.right",
                                   description: Text("Its device, the app's toolboxes and Open show here."))
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for item: SessionListItem) -> some View {
        SessionRow(
            item: item,
            isLive: isLiveSession(item),
            onRequestDelete: { pendingDelete = item }
        )
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(vm: SessionsViewModel) -> some View {
        Divider()
        HStack {
            Text(vm.sessions.count == 1
                 ? "1 session"
                 : "\(vm.sessions.count) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                pendingDeleteAll = true
            } label: {
                Label("Delete all sessions…", systemImage: "trash")
                    .foregroundStyle(vm.sessions.isEmpty ? Color.secondary : Color.red)
            }
            .buttonStyle(.plain)
            .disabled(vm.sessions.isEmpty)
            .help("Wipe every recorded session and its events")
        }
        // A bit more leading inset than 12 so the "N sessions"
        // text doesn't hug the sidebar boundary at the bottom-left
        // seam — macOS Tahoe's rounded-corner sidebar treatment
        // makes that look like two views intersecting if the
        // footer text sits flush against the divider.
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        // `.bar` is the system material macOS uses for status /
        // bottom bars; it paints a uniform background across the
        // full footer width so the sidebar's bottom-right curve
        // doesn't bleed through the seam.
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Live = a session a connected device is writing to (D73).
    /// Deleting it while the device is mid-stream would yank the rug
    /// out from under the inbound writer, so we gate the menu item.
    private func isLiveSession(_ item: SessionListItem) -> Bool {
        env.isLive(item.id)
    }
}

// MARK: - Session row

/// One row in the sessions list. Splits out of `SessionsView` so we
/// can own per-row hover state and reveal a trash button on the
/// right edge — same affordance used by the bookmarks popover.
private struct SessionRow: View {
    let item: SessionListItem
    let isLive: Bool
    let onRequestDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                    if isLive {
                        Text("LIVE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green))
                    }
                    if let app = item.appLabel {
                        Text("·").foregroundStyle(.tertiary)
                        Text(app)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let device = item.deviceLabel {
                    Text(device)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            // Disconnect lives in the details pane (and the right-click
            // menu); a second one in the row was one too many.

            // Reserve space always so hovering doesn't reflow the
            // row. Becomes visible + hit-testable only while hovered,
            // and only for non-live sessions (live deletion is gated
            // by the same rule in the context menu).
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(isLive
                  ? "Disconnect the device before deleting the live session"
                  : "Delete this session")
            .disabled(isLive)
            .opacity((isHovered && !isLive) ? 1 : 0)
            .allowsHitTesting(isHovered && !isLive)
        }
        .contentShape(Rectangle())
        // The separator starts under the title, like every row. Without
        // this, List lined it up with the Disconnect button's text.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Session details

/// The selected session: Open, what it is, and — through the device
/// popover's content — the device, Disconnect, the agents' default and
/// the app's toolboxes (D75/D76).
private struct SessionDetailPane: View {
    let item: SessionListItem
    let isLive: Bool
    let isViewed: Bool
    let sessions: [Session]
    let others: [SessionListItem]
    let onOpen: () -> Void
    let onCompare: (Int64) -> Void
    let onRequestDelete: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var issues: Issues.Report?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button(action: onOpen) {
                        Label(isViewed ? "Show in Log feed" : "Open", systemImage: "arrow.forward.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Open this session in the Log feed (or double-click it, or press Return)")
                    Menu {
                        ForEach(others) { other in
                            Button("#\(other.id) \(other.title)" + (other.appLabel.map { " · \($0)" } ?? "")) {
                                onCompare(other.id)
                            }
                        }
                    } label: {
                        Label("Compare with", systemImage: "arrow.left.arrow.right")
                    }
                    .fixedSize()
                    .disabled(others.isEmpty)
                    .help(others.isEmpty ? "No other session of this app to compare with"
                                         : "Compare with another session of this app")
                    Spacer()
                    if !isLive {
                        Button(role: .destructive, action: onRequestDelete) {
                            Image(systemName: "trash")
                        }
                        .help("Delete this session")
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    fact("Session", "#\(item.id)")
                    fact("Started", item.session.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let ended = item.session.endedAt {
                        fact("Ended", ended.formatted(date: .abbreviated, time: .standard))
                    }
                    fact("Status", item.subtitle)
                }
                .font(.callout)
                if let issues, !issues.shown.isEmpty {
                    issueSummary(issues)
                }
                Divider()
                DevicePopover(session: item.session, isLive: isLive, sessions: sessions, width: nil)
            }
            .padding(16)
        }
        // Once per selection; the Issues tab is the live view (D95).
        .task { issues = try? await env.store.issues(sessionId: item.id) }
    }

    private func issueSummary(_ r: Issues.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                env.viewingSessionId = item.id
                env.selectedTab = .issues
            } label: {
                Label("\(r.shown.count) issues: \(r.errors) errors, \(r.warnings) warnings",
                      systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.link)
            .help("Open this session's Issues")
            ForEach(Issues.Sort.errorsFirst.sorted(r.shown).prefix(3)) { g in
                HStack(spacing: 6) {
                    Circle().fill(g.level.displayColor).frame(width: 6, height: 6)
                    Text(g.pattern).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("×\(g.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
                .help("\(g.subsystem): \(g.example)")
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
