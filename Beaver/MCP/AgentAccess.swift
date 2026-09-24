//
//  AgentAccess.swift
//  Beaver
//
//  The only thing the app calls (design §3.2, M24). Access control for
//  customers, when it is decided, is one check in start().

import Foundation

public actor AgentAccess {
    public static let defaultPort: UInt16 = 9081
    public static let enabledKey = "agentAccessEnabled"
    public static let portKey = "mcpPort"

    private let server: MCPServer
    private var listener: MCPHTTPListener?

    public init(store: LogStore, ui: any AgentUI) {
        server = MCPServer(tools: BeaverTools.all,
                           context: ToolContext(store: store, ui: ui),
                           journal: AgentJournal(store: store))
    }

    /// Starts (or restarts) the listener; returns the bound port.
    ///
    /// Reentrancy-safe the same way `MCPHTTPListener.start`/`stop` are
    /// (see that actor): claim `self.listener` before the awaited bind, so
    /// a `stop()` landing while this is in flight can find and cancel it;
    /// check identity after the await, since another `start()` (or that
    /// `stop()`) may have already superseded us, in which case we cancel
    /// our own orphaned listener instead of publishing it.
    @discardableResult
    public func start(port: UInt16) async throws -> UInt16 {
        while listener != nil { await stop() }
        let server = self.server
        let listener = MCPHTTPListener { body, headers in
            await server.handle(body, client: headers["user-agent"], protocolVersion: headers["mcp-protocol-version"])
        }
        self.listener = listener
        do {
            let bound = try await listener.start(port: port)
            guard self.listener === listener else {
                await listener.stop()
                throw CancellationError()
            }
            return bound
        } catch {
            if self.listener === listener { self.listener = nil }
            await listener.stop()
            throw error
        }
    }

    public func stop() async {
        while let listener {
            self.listener = nil
            await listener.stop()
        }
    }

    public static func configuredPort(_ defaults: UserDefaults = .standard) -> UInt16 {
        let value = defaults.integer(forKey: portKey)
        return (1...65_535).contains(value) ? UInt16(value) : defaultPort
    }

    public static func setupCommand(port: UInt16) -> String {
        "claude mcp add --transport http beaver http://127.0.0.1:\(port)/mcp"
    }
}
