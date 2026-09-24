//
//  ToolContext.swift
//  Beaver
//

import Foundation

/// The running app as the tools see it. `AppEnvironment` conforms in the
/// app target; tests pass a fake.
public protocol AgentUI: Sendable {
    func snapshot() async -> HostSnapshot
    /// Changes what the window shows. Brings Beaver forward only when
    /// `change.reveal` (M12); otherwise nothing takes focus.
    func show(_ change: UIChange) async
}

public struct HostSnapshot: Sendable, Equatable {
    public var serverState: String
    public var deviceConnected: Bool
    public var liveSessionId: Int64?
    public var commands: [CommandHint]
    public var deviceURL: String?
    public var beaverVersion: String
    public var mcpPort: UInt16
    /// What the window shows (design §7.1).
    public var ui: UIState
    /// The main window is open, on screen or in the Dock.
    public var windowOpen: Bool
    /// Beaver is the active app.
    public var frontmost: Bool

    /// The session the window shows.
    public var viewingSessionId: Int64? {
        get { ui.sessionId }
        set { ui.sessionId = newValue }
    }

    public init(serverState: String = "listening", deviceConnected: Bool = false,
                liveSessionId: Int64? = nil, viewingSessionId: Int64? = nil,
                commands: [CommandHint] = [], deviceURL: String? = "ws://192.168.1.5:9080",
                beaverVersion: String = "dev", mcpPort: UInt16 = 9081,
                ui: UIState = UIState(), windowOpen: Bool = true, frontmost: Bool = false) {
        self.serverState = serverState; self.deviceConnected = deviceConnected
        self.liveSessionId = liveSessionId
        self.commands = commands; self.deviceURL = deviceURL
        self.beaverVersion = beaverVersion; self.mcpPort = mcpPort
        self.ui = ui; self.windowOpen = windowOpen; self.frontmost = frontmost
        if let viewingSessionId { self.ui.sessionId = viewingSessionId }
    }
}

/// Everything a tool handler gets.
public struct ToolContext: Sendable {
    public let store: LogStore
    public let ui: any AgentUI
    public let now: @Sendable () -> Date

    public init(store: LogStore, ui: any AgentUI, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.ui = ui
        self.now = now
    }
}
