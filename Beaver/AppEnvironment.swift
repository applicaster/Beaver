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

    /// The last connections that went wrong before they became devices
    /// (`WSServer.recentProblems`), for the placeholder and `beaver_status`.
    public var connectionProblems: [WSServer.ConnectionProblem] = []

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

    /// Agent Access state for Settings → Agents: "On · 127.0.0.1:9081", "Off", "Port 9081 in use".
    public var agentAccessStatus: String = "Off"

    /// The bound MCP port while Agent Access is on.
    public var agentAccessPort: UInt16?

    /// The store's size on disk for Settings → General, as of the last
    /// retention pass (D83).
    public var storeSize: Int64?

    /// Releases the What's New sheet shows over the main window; empty
    /// when it's closed (D92).
    public var whatsNew: [Changelog.Release] = []

    /// The Connect a TV sheet is open over the main window (D94).
    public var showingConnectTV = false

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

    /// Called on a connection's first frame (`SessionRouter`). Shows the
    /// device over a past or imported session the user opened, but not over
    /// another live device (D73): that one stays, and the new one waits in
    /// the device menu. Not at connect: an app in the background retries its
    /// socket every ~30 s, and those silent connections would pull the view
    /// away. A session already viewed keeps its filter (D97: a reconnect).
    public func didSpeak(session: Int64) {
        guard viewingSessionId != session, !live.isLive(viewingSessionId) else { return }
        viewingSessionId = session
        startFromDefaultFilter()
    }

    /// D82: a launch and a newly connected device's session start from the
    /// saved filter marked Default. Without one, the filter carries over (D42).
    func startFromDefaultFilter() {
        Task {
            if let saved = try? await store.savedFilters().first(where: \.isDefault) {
                activeFilter = saved.filter
            }
        }
    }

    /// ⌘1…⌘9 (D82): the Log feed with the `index`-th saved filter, from any tab.
    func applySavedFilter(at index: Int) {
        Task {
            guard let saved = try? await store.savedFilters(), saved.indices.contains(index) else { return }
            selectedTab = .logs
            activeFilter = saved[index].filter
        }
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
    /// Sends to the connection that writes `sessionId`; false (nothing sent)
    /// once it's gone, and for a logs-only client (D89), which reads nothing:
    /// every command — on connect, from the Storages tab, the command bar, an
    /// agent — ends here.
    @discardableResult
    nonisolated public func send(command: String, to sessionId: Int64) async -> Bool {
        guard let connection = await MainActor.run(body: {
            self.live.logsOnlySessions.contains(sessionId) ? nil : self.live.connection(for: sessionId)
        }) else { return false }
        await server.send(command: command, to: connection)
        return true
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

    nonisolated public func connectTV(host: String, port: Int, name: String?) async throws -> Int64 {
        try await connectTVOnMain(host: host, port: port, name: name)
    }

    /// Connects in flight, by device id: the same TV twice at once is one bridge.
    private static let tvConnects = TVConnects()

    /// D94: the bridge is a `register` client of our own server, so the TV
    /// is the device zapp-support's bridge makes (D89): the inbound loop
    /// opens its session, Disconnect closes its socket and that stops it.
    private func connectTVOnMain(host: String, port: Int, name: String?) async throws -> Int64 {
        let bridge = try TVBridge(host: host, port: port, name: name)
        return try await Self.tvConnects.run(bridge.deviceId) { [self] in
            // Already connected, here or by zapp-support's script.
            if let id = live.session(deviceId: bridge.deviceId) { return id }
            switch serverState {
            case .listening, .clientConnected, .clientDisconnected: break
            case .stopped: throw TVBridgeError.beaverUnavailable(reason: "Beaver's WebSocket server hasn't started")
            case .failed(let reason): throw TVBridgeError.beaverUnavailable(reason: "Beaver's WebSocket server failed: \(reason)")
            }
            // The session opens, then the register lands in the store: wait for both.
            // A cancel or a timeout in here stops the bridge.
            let id = try await bridge.connect { @MainActor [self] in
                guard let id = live.session(deviceId: bridge.deviceId),
                      try await store.sessions().first(where: { $0.id == id })?.deviceUID == bridge.deviceId
                else { return nil }
                return id
            }
            RecentTVs.remember(RecentTV(host: host.trimmingCharacters(in: .whitespaces), port: port, name: name))
            return id
        }
    }

    nonisolated public func mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration,
                                onSent: (@Sendable () async -> Void)?) async throws -> JSON {
        let client = await MainActor.run { self.live.connection(for: sessionId).flatMap { self.mcpClients[$0] } }
        guard let client else { throw DeviceMCPError.notSent("the app is no longer connected") }
        return try await client.request(method, params: params, timeout: timeout, onSent: onSent)
    }
}
