//
//  ToolContext.swift
//  Beaver
//

import Foundation

/// What the tools may read of the running app. `AppEnvironment` conforms
/// in the app target; tests pass a fake. PR 3 adds the `ui_show` members.
public protocol AgentUI: Sendable {
    func snapshot() async -> HostSnapshot
    /// A command reached the device from outside the command bar; it
    /// joins the command bar's history like a typed one (design §5.6).
    func didSendCommand(_ command: String) async
    /// Hide the viewed Log feed's events up to `eventId`, like its Clear
    /// button (⌘K). Nothing is deleted.
    func clearLogView(sessionId: Int64, through eventId: Int64) async
    /// An attention note for the person (design §7.2, M28): the app decides
    /// whether a macOS notification goes out, and says why not.
    func notify(_ note: AgentNote) async -> NotifyOutcome
}

public struct HostSnapshot: Sendable, Equatable {
    public var serverState: String
    public var deviceConnected: Bool
    public var liveSessionId: Int64?
    public var viewingSessionId: Int64?
    public var commands: [CommandHint]
    public var deviceURL: String?
    public var beaverVersion: String
    public var mcpPort: UInt16
    public var notifications: AgentNotifications.State

    public init(serverState: String = "listening", deviceConnected: Bool = false,
                liveSessionId: Int64? = nil, viewingSessionId: Int64? = nil,
                commands: [CommandHint] = [], deviceURL: String? = "ws://192.168.1.5:9080",
                beaverVersion: String = "dev", mcpPort: UInt16 = 9081,
                notifications: AgentNotifications.State = .allowed) {
        self.serverState = serverState; self.deviceConnected = deviceConnected
        self.liveSessionId = liveSessionId; self.viewingSessionId = viewingSessionId
        self.commands = commands; self.deviceURL = deviceURL
        self.beaverVersion = beaverVersion; self.mcpPort = mcpPort
        self.notifications = notifications
    }
}

/// How tools reach the connected app (design M15, D57). `WSServer` is the
/// live one; tests use a fake.
public protocol DeviceLink: Sendable {
    func send(command: String) async
}

extension WSServer: DeviceLink {}

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
