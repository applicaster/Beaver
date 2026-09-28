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
    /// A command reached the device from outside the command bar; it
    /// joins the command bar's history like a typed one (design §5.6).
    func didSendCommand(_ command: String) async
    /// Hide the viewed Log feed's events up to `eventId`, like its Clear
    /// button (⌘K). Nothing is deleted.
    func clearLogView(sessionId: Int64, through eventId: Int64) async
    /// An attention note for the person (design §7.2, M28): the app decides
    /// whether a macOS notification goes out, and says why not.
    func notify(_ note: AgentNote) async -> NotifyOutcome
    /// Puts `text` on the clipboard, like a Copy button. Takes no focus.
    func copyToClipboard(_ text: String) async
    /// Sets or clears the default device (D76). Doesn't change the window.
    func setDefaultDevice(_ device: DefaultDevice?) async
}

public struct HostSnapshot: Sendable, Equatable {
    public var serverState: String
    /// One per connected device, oldest first (D73). A device's MCP
    /// `deviceId` is its live session id.
    public var liveSessionIds: [Int64]
    /// Each live app's `cmdlist` answer.
    public var commandsBySession: [Int64: [CommandHint]]
    public var deviceURL: String?
    public var beaverVersion: String
    public var mcpPort: UInt16
    /// What the window shows (design §7.1).
    public var ui: UIState
    /// The main window is open, on screen or in the Dock.
    public var windowOpen: Bool
    /// Beaver is the active app.
    public var frontmost: Bool

    public var deviceConnected: Bool { !liveSessionIds.isEmpty }

    /// The session the window shows.
    public var viewingSessionId: Int64? {
        get { ui.sessionId }
        set { ui.sessionId = newValue }
    }
    public var notifications: AgentNotifications.State
    /// The agents' default device (D76), if set.
    public var defaultDevice: DefaultDevice?

    public init(serverState: String = "listening", liveSessionIds: [Int64] = [],
                viewingSessionId: Int64? = nil, commandsBySession: [Int64: [CommandHint]] = [:],
                deviceURL: String? = "ws://192.168.1.5:9080",
                beaverVersion: String = "dev", mcpPort: UInt16 = 9081,
                ui: UIState = UIState(), windowOpen: Bool = true, frontmost: Bool = false,
                notifications: AgentNotifications.State = .allowed, defaultDevice: DefaultDevice? = nil) {
        self.serverState = serverState
        self.liveSessionIds = liveSessionIds
        self.commandsBySession = commandsBySession
        self.deviceURL = deviceURL
        self.beaverVersion = beaverVersion; self.mcpPort = mcpPort
        self.ui = ui; self.windowOpen = windowOpen; self.frontmost = frontmost
        if let viewingSessionId { self.ui.sessionId = viewingSessionId }
        self.notifications = notifications
        self.defaultDevice = defaultDevice
    }
}

/// How tools reach the connected apps (design M15, D57, D73). The app
/// environment routes to the right connection; tests use a fake.
public protocol DeviceLink: Sendable {
    /// Sends to the device whose live session is `sessionId`; no-op once it's gone.
    func send(command: String, to sessionId: Int64) async
    /// Closes that device's connection; its session ends. No-op once it's gone.
    func disconnect(_ sessionId: Int64) async
    /// One MCP request to the app whose live session is `sessionId` (D75).
    /// Throws `DeviceMCPError`; `.disconnected` once it's gone.
    func mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration) async throws -> JSON
}


/// Everything a tool handler gets.
public struct ToolContext: Sendable {
    public let store: LogStore
    public let ui: any AgentUI
    public let device: any DeviceLink
    /// Design M29: in memory until Beaver quits (or Agent Access is turned off).
    public let watches: Watches
    public let now: @Sendable () -> Date

    public init(store: LogStore, ui: any AgentUI, device: any DeviceLink, watches: Watches = Watches(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.ui = ui
        self.device = device
        self.watches = watches
        self.now = now
    }
}
