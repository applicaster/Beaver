//
//  AppEnvironment+AgentUI.swift
//  Beaver
//

import AppKit
import Foundation

extension AppEnvironment: AgentUI {
    nonisolated public func snapshot() async -> HostSnapshot {
        await MainActor.run {
            let (connected, state): (Bool, String) = switch serverState {
            case .stopped: (false, "stopped")
            case .listening: (false, "listening")
            case .clientConnected: (true, "clientConnected")
            case .clientDisconnected(let reason): (false, "clientDisconnected: \(reason)")
            case .failed(let reason): (false, "failed: \(reason)")
            }
            return HostSnapshot(
                serverState: state,
                deviceConnected: connected,
                liveSessionId: currentSessionId,
                commands: availableCommands,
                deviceURL: NetworkInterface.bestAddress().map { "ws://\($0):9080" },
                beaverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                mcpPort: agentAccessPort ?? 0,
                ui: uiState,
                windowOpen: mainWindow != nil,
                frontmost: NSApp.isActive
            )
        }
    }

    nonisolated public func show(_ change: UIChange) async {
        await MainActor.run { apply(change) }
    }

    /// The window state as one value.
    var uiState: UIState {
        var s = UIState()
        s.tab = selectedTab
        s.sessionId = viewingSessionId
        s.logFilter = activeFilter
        s.networkFilter = networkFilter
        s.storageLayer = storageLayer
        s.storageSearch = storageSearch
        s.selectedEventId = selectedEventId
        s.selectedNetworkId = selectedNetworkId
        return s
    }

    /// Writes only what changes, the session first: switching it resets
    /// the rest (see `viewingSessionId`), and `target` already says what
    /// each field ends up as.
    func apply(_ change: UIChange) {
        let target = uiState.applying(change)
        if viewingSessionId != target.sessionId { viewingSessionId = target.sessionId }
        if selectedTab != target.tab { selectedTab = target.tab }
        if activeFilter != target.logFilter { activeFilter = target.logFilter }
        if networkFilter != target.networkFilter { networkFilter = target.networkFilter }
        if storageLayer != target.storageLayer { storageLayer = target.storageLayer }
        if storageSearch != target.storageSearch { storageSearch = target.storageSearch }
        if selectedEventId != target.selectedEventId { selectedEventId = target.selectedEventId }
        if selectedNetworkId != target.selectedNetworkId { selectedNetworkId = target.selectedNetworkId }
        if change.reveal { reveal() }
    }

    /// Brings Beaver's window forward (M12). The only code that takes
    /// focus: reached from `ui_show(reveal: true)` and a person's click.
    func reveal() {
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        // Cooperative activation (macOS 14+'s plain `activate()`) declines
        // a request made from the background; an explicit
        // ui_show(reveal: true) is the user asking, so force it.
        // AgentFocusUITests checks it lands.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The main window while it is open, on screen or in the Dock. Panels
    /// (popovers, About, Sparkle) don't count. Not `canBecomeMain` alone:
    /// it is false while the window is minimised.
    private var mainWindow: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && ($0.isMiniaturized || ($0.isVisible && $0.canBecomeMain)) }
    }

    /// Shows what a journal link points at, through `ui_show`'s path
    /// (design §7.2). Not journaled: the person clicked, not an agent.
    /// PR 2's toast "Show" and notification click call it with
    /// `reveal: true`.
    func open(_ link: AgentLink, reveal: Bool) async throws {
        _ = try await UITools.open(link, reveal: reveal, ToolContext(store: store, ui: self))
    }
}
