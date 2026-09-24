//
//  ToolContext.swift
//  Beaver
//

import Foundation

/// What the tools may read of the running app. `AppEnvironment` conforms
/// in the app target; tests pass a fake. PR 3 adds the `ui_show` members.
public protocol AgentUI: Sendable {
    func snapshot() async -> HostSnapshot
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

    public init(serverState: String = "listening", deviceConnected: Bool = false,
                liveSessionId: Int64? = nil, viewingSessionId: Int64? = nil,
                commands: [CommandHint] = [], deviceURL: String? = "ws://192.168.1.5:9080",
                beaverVersion: String = "dev", mcpPort: UInt16 = 9081) {
        self.serverState = serverState; self.deviceConnected = deviceConnected
        self.liveSessionId = liveSessionId; self.viewingSessionId = viewingSessionId
        self.commands = commands; self.deviceURL = deviceURL
        self.beaverVersion = beaverVersion; self.mcpPort = mcpPort
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
    public let now: @Sendable () -> Date

    public init(store: LogStore, ui: any AgentUI, device: any DeviceLink,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.ui = ui
        self.device = device
        self.now = now
    }
}
