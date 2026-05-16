//
//  AppEnvironment.swift
//  LoggerNext
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
    public var viewingSessionId: Int64?

    /// Latest server state for the connection indicator.
    public var serverState: WSServer.State = .stopped

    /// Number of events in the *viewing* session. Drives toolbar
    /// button availability (Export / Clear / Bookmarks) — those
    /// actions only make sense when there's something to act on.
    public var viewingEventCount: Int = 0

    /// Commands the connected SDK exposes (from its `cmdlist` reply).
    /// Refreshed automatically on connect; cleared on disconnect.
    /// Merged with `CommandRegistry` for syntax help in the
    /// command-bar popover.
    public var availableCommands: [CommandHint] = []

    public init(store: LogStore, server: WSServer) {
        self.store = store
        self.server = server
    }

    /// Auto-track the live session when no past one is being inspected.
    public func didConnectSession(_ id: Int64) {
        currentSessionId = id
        if viewingSessionId == nil {
            viewingSessionId = id
        }
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
            return
        }
        let count = (try? await store.eventCount(sessionId: sid, filter: .none)) ?? 0
        viewingEventCount = count
    }
}
