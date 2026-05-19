//
//  SessionsView.swift
//  LoggerNext
//

import SwiftUI

/// Sessions tab — history of every recorded session. Selecting a
/// session opens it in the Log feed; right-clicking offers Delete with
/// a confirmation prompt; a footer button wipes the whole history.
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
        VStack(spacing: 0) {
            List(vm.sessions, selection: $env.viewingSessionId) { item in
                row(for: item)
                    .tag(Optional(item.id))
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            env.viewingSessionId = item.id
                            onOpenInLogFeed(item.id)
                        } label: {
                            Label("Open in Log feed",
                                  systemImage: "arrow.forward.circle")
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
        // Selecting a row by single-click jumps the user into the Log
        // feed — saves the extra trip through the sidebar. SessionsView
        // is only mounted while the Sessions tab is showing, so this
        // onChange can only fire from user clicks in the list (or from
        // a brand-new session arriving via the WebSocket — also a
        // reasonable reason to jump to the live feed).
        .onChange(of: env.viewingSessionId) { _, new in
            if let new { onOpenInLogFeed(new) }
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

    /// Live = the session created on the active WebSocket connection.
    /// Deleting it while the device is mid-stream would yank the rug
    /// out from under the inbound writer, so we gate the menu item.
    private func isLiveSession(_ item: SessionListItem) -> Bool {
        env.currentSessionId == item.id
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
        .onHover { isHovered = $0 }
    }
}
