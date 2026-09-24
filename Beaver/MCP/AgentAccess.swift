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
    /// Bumped by every `start()`/`stop()`; the value a `start()` bumped it
    /// to is its ticket — if it's no longer current when checked, a later
    /// call has already decided the outcome and this one backs off. See
    /// `start()`.
    private var generation: UInt64 = 0
    /// Test seam only (production callers pass nothing): invoked once a
    /// `start()` has claimed its listener, before that listener is bound,
    /// so a test can pause a `start()` there and race a `stop()` against
    /// it deterministically.
    private let beforeBind: (@Sendable () async -> Void)?

    public init(store: LogStore, ui: any AgentUI, beforeBind: (@Sendable () async -> Void)? = nil) {
        server = MCPServer(tools: BeaverTools.all,
                           context: ToolContext(store: store, ui: ui),
                           journal: AgentJournal(store: store))
        self.beforeBind = beforeBind
    }

    /// Starts (or restarts) the listener; returns the bound port.
    ///
    /// Reentrancy-safe the same way `MCPHTTPListener.start`/`stop` are,
    /// one level up, via a generation counter rather than a raw identity
    /// check alone: a `stop()` (or a later `start()`) that lands anywhere
    /// during this call — including while it is draining the previous
    /// listener — bumps `generation` and wins; this call notices the
    /// mismatch (checked right after draining, and again after the bind)
    /// and throws `CancellationError` instead of publishing, or leaving
    /// bound, a listener nobody asked for. Overlapping `start()`s are
    /// last-call-wins. Callers that only care about the latest
    /// `start()`/`stop()` should ignore a `CancellationError` thrown by a
    /// superseded `start()`.
    @discardableResult
    public func start(port: UInt16) async throws -> UInt16 {
        generation &+= 1
        let mine = generation
        await drain()
        guard generation == mine else { throw CancellationError() }
        let server = self.server
        let listener = MCPHTTPListener { body, headers in
            await server.handle(body, client: headers["user-agent"], protocolVersion: headers["mcp-protocol-version"])
        }
        self.listener = listener
        await beforeBind?()
        do {
            let bound = try await listener.start(port: port)
            guard generation == mine, self.listener === listener else {
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
        generation &+= 1
        await drain()
    }

    /// Stops and clears whatever listener is currently claimed. Looped
    /// because a listener that shows up while we're awaiting a stop
    /// (another call raced in) must be stopped too before we're done.
    private func drain() async {
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
