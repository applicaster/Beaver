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
    }
}
