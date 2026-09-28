//
//  AppEnvironment.swift
//  Beaver
//

import Foundation
import SwiftUI

/// Dependency container injected into the SwiftUI view tree via
/// `.environment(...)`. See `ARCHITECTURE.md §9`. Replaces the
/// current Logger's three singletons (`LoggerAppManager.shared`,
/// `NotificationManager.shared`, `UserDefaultManager`).
@Observable
@MainActor
public final class AppEnvironment {
    public let store: LogStore
    public let server: WSServer

    /// Connected devices: which connection writes which live session (D73).
    /// Drives where inbound events get appended.
    public var live = LiveDevices()

    /// Each connection's MCP client (D75). Keyed by connection, not session:
    /// a deleted live session's replacement keeps talking to the same app.
    @ObservationIgnored public var mcpClients: [UUID: DeviceMCPClient] = [:]

    /// The device agents' device tools use without a deviceId (D76).
    /// In memory until Beaver quits.
    public var defaultDevice: DefaultDevice?

    public func isLive(_ sessionId: Int64?) -> Bool { live.isLive(sessionId) }

    /// Session id the user is *viewing*: a device from the toolbar device
    /// menu, or any past session via the Sessions sidebar.
    ///
    /// Switching starts Network and Storages at their defaults and drops
    /// the selection, as rebuilding their view models always did — the
    /// same rule `UIState.applying` follows for an agent's switch.
    public var viewingSessionId: Int64? {
        didSet {
            guard viewingSessionId != oldValue else { return }
            networkFilter = NetworkFilter()
            storageLayer = .session
            storageSearch = ""
            selectedEventId = nil
            selectedNetworkId = nil
        }
    }

    /// Latest server state for the connection indicator.
    public var serverState: WSServer.State = .stopped

    /// Number of events in the *viewing* session. Drives toolbar
    /// button availability (Export / Clear / Bookmarks) — those
    /// actions only make sense when there's something to act on.
    public var viewingEventCount: Int = 0

    /// Whether the viewing session has any network requests, kept as a
    /// count for parity with `viewingEventCount`. Only gates the toolbar
    /// (zero vs. non-zero) — callers stop refreshing it once it's above
    /// zero, so it is not kept accurate as more requests arrive.
    public var viewingNetworkCount: Int = 0

    /// Commands the viewed device's SDK exposes (from its `cmdlist`
    /// reply). Requested on connect; gone on disconnect. Merged with
    /// `CommandRegistry` for syntax help in the command-bar popover.
    public var availableCommands: [CommandHint] {
        viewingSessionId.flatMap { live.commands[$0] } ?? []
    }

    /// Mirror of the active `LogFeedViewModel.filter`. The Log-feed
    /// view keeps this in sync via an `.onChange` modifier so the
    /// toolbar's Export action (in `MainWindow`) can scope its query
    /// to the rows the user is currently looking at — see D26.
    public var activeFilter: Filter = .none

    /// Menu text for Agent Access: "On · 127.0.0.1:9081", "Off", "Port 9081 in use".
    public var agentAccessStatus: String = "Off"

    /// The bound MCP port while Agent Access is on.
    public var agentAccessPort: UInt16?

    // MARK: - Window state an agent can set (D54, design §7.1)
    //
    // The view models follow these (`UIStateSync`), and write the
    // person's own changes back, so `ui_state` reports what is on screen.

    /// The sidebar tab.
    public var selectedTab: UITab = .logs

    /// The Network tab's filter.
    public var networkFilter = NetworkFilter()

    /// Storages: the layer tab and the Discover search.
    public var storageLayer: StorageSnapshot.Namespace = .session
    public var storageSearch = ""

    /// The Log feed's selected event and the Network tab's selected
    /// request, each while exactly one row is selected.
    public var selectedEventId: Int64?
    public var selectedNetworkId: Int64?

    /// The Scheme Generator's form; the view edits it in place.
    public var schemeLink = SchemeLink()

    public init(store: LogStore, server: WSServer) {
        self.store = store
        self.server = server
    }

    /// Called when a connection opens and its session row is created.
    ///
    /// Shows the new device over a past or imported session the user
    /// opened, but not over another live device (D73): that one stays,
    /// and the new one waits in the device menu.
    public func didConnect(_ connection: UUID, session: Int64) {
        if live.connect(connection, session: session, viewing: viewingSessionId) {
            viewingSessionId = session
        }
    }

    /// viewingSessionId stays — the user can keep reading the now-ended
    /// session. Returns the session that ended.
    @discardableResult
    public func didDisconnect(_ connection: UUID) -> Int64? {
        live.disconnect(connection)
    }

    /// Re-query the event count for the viewing session. Called on
    /// session switch and whenever the store broadcasts a change that
    /// could affect the count (`.appended`, `.cleared`,
    /// `.sessionStarted/Ended`).
    public func refreshViewingEventCount() async {
        guard let sid = viewingSessionId else {
            viewingEventCount = 0
            viewingNetworkCount = 0
            return
        }
        let count = (try? await store.eventCount(sessionId: sid, filter: .none)) ?? 0
        viewingEventCount = count
        viewingNetworkCount = (try? await store.networkEntryCount(sessionId: sid)) ?? 0
    }
}

extension AppEnvironment: DeviceLink {
    /// Sends to the connection that writes `sessionId`; no-op once it's gone.
    nonisolated public func send(command: String, to sessionId: Int64) async {
        guard let connection = await MainActor.run(body: { self.live.connection(for: sessionId) }) else { return }
        await server.send(command: command, to: connection)
    }

    /// `cmdlist` for the command-help popover; its reply skips the Log feed.
    func sendQuietCmdlist(to sessionId: Int64) async {
        live.expectQuietCmdlist(for: sessionId)
        await send(command: "cmdlist", to: sessionId)
    }

    nonisolated public func disconnect(_ sessionId: Int64) async {
        guard let connection = await MainActor.run(body: { self.live.connection(for: sessionId) }) else { return }
        await server.disconnect(connection)
    }

    nonisolated public func mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration,
                                onSent: (@Sendable () async -> Void)?) async throws -> JSON {
        let client = await MainActor.run { self.live.connection(for: sessionId).flatMap { self.mcpClients[$0] } }
        guard let client else { throw DeviceMCPError.notSent("the app is no longer connected") }
        return try await client.request(method, params: params, timeout: timeout, onSent: onSent)
    }
}
