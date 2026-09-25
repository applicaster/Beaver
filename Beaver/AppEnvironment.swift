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

    /// Live session id — set on client connect, cleared on disconnect.
    /// Drives where inbound events get appended.
    public var currentSessionId: Int64?

    /// Session id the user is *viewing*. Defaults to `currentSessionId`,
    /// but can point at any past session via the Sessions sidebar.
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

    /// Commands the connected SDK exposes (from its `cmdlist` reply).
    /// Refreshed automatically on connect; cleared on disconnect.
    /// Merged with `CommandRegistry` for syntax help in the
    /// command-bar popover.
    public var availableCommands: [CommandHint] = []

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

    public init(store: LogStore, server: WSServer) {
        self.store = store
        self.server = server
    }

    /// Called when the WebSocket transitions to `.clientConnected`
    /// and a new session row is created in the store.
    ///
    /// Always shows the new session, even over a past or imported one
    /// the user opened: a device that connects is what they want to see.
    public func didConnectSession(_ id: Int64) {
        currentSessionId = id
        viewingSessionId = id
    }

    public func didDisconnectSession() {
        currentSessionId = nil
        // viewingSessionId stays — the user can keep reading the now-ended
        // session.
        availableCommands = []
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
