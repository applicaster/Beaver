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
    /// Bumped by every `start()`/`stop()`; the value a call bumped it to
    /// is its ticket. Checked against the current value at every point
    /// where that call is about to touch `self.listener` after an
    /// `await` — including inside `drain()`'s loop, not just before and
    /// after it — so a call whose ticket is no longer current backs off
    /// instead of undoing or redoing a later call's work. See `start()`.
    private var generation: UInt64 = 0
    /// Test seam only (production callers pass nothing): invoked once a
    /// `start()` has claimed its listener, before that listener is bound,
    /// so a test can pause a `start()` there and race a `stop()` against
    /// it deterministically.
    private let beforeBind: (@Sendable () async -> Void)?
    /// Test seam only (production callers pass nothing): invoked from
    /// `drain()` right after it clears `self.listener`, before it awaits
    /// that listener's `stop()`, so a test can pause a drain mid-flight
    /// and race another call against it deterministically.
    private let duringDrain: (@Sendable () async -> Void)?

    public init(store: LogStore, ui: any AgentUI, device: any DeviceLink,
                beforeBind: (@Sendable () async -> Void)? = nil,
                duringDrain: (@Sendable () async -> Void)? = nil) {
        server = MCPServer(tools: BeaverTools.all,
                           context: ToolContext(store: store, ui: ui, device: device),
                           journal: AgentJournal(store: store))
        self.beforeBind = beforeBind
        self.duringDrain = duringDrain
    }

    /// Starts (or restarts) the listener; returns the bound port.
    ///
    /// Reentrancy-safe the same way `MCPHTTPListener.start`/`stop` are,
    /// one level up, via a generation counter rather than a raw identity
    /// check alone: a `stop()` (or a later `start()`) that lands anywhere
    /// during this call — including while it is draining the previous
    /// listener, or while a *previous* call's drain is itself suspended
    /// mid-stop — bumps `generation` and wins. This call, and `drain()`
    /// on its behalf, notice the mismatch (checked after draining, inside
    /// `drain()`'s own loop, and again after the bind) and throw
    /// `CancellationError` instead of publishing, or leaving bound, a
    /// listener nobody asked for. Overlapping `start()`s are
    /// last-call-wins. Callers that only care about the latest
    /// `start()`/`stop()` should ignore a `CancellationError` thrown by a
    /// superseded `start()`.
    @discardableResult
    public func start(port: UInt16) async throws -> UInt16 {
        generation &+= 1
        let mine = generation
        await drain(mine)
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
        await drain(generation)
    }

    /// Stops and clears whatever listener is currently claimed, as long
    /// as `mine` is still the current generation. Looped because a
    /// listener that shows up while we're awaiting a stop (another call
    /// raced in, saw the same generation as `mine`, and claimed one) must
    /// be stopped too before we're done — but gated on `generation` so
    /// that once a *later* call has moved the generation on, this loop
    /// stops touching `self.listener` and leaves it for that later call
    /// to manage, rather than tearing down a listener it never drained.
    private func drain(_ mine: UInt64) async {
        while generation == mine, let listener {
            self.listener = nil
            await duringDrain?()
            await listener.stop()
        }
    }

    public static func configuredPort(_ defaults: UserDefaults = .standard) -> UInt16 {
        let value = defaults.integer(forKey: portKey)
        return (1...65_535).contains(value) ? UInt16(value) : defaultPort
    }

    public static func setupCommand(port: UInt16) -> String {
        "claude mcp add --scope user --transport http beaver http://127.0.0.1:\(port)/mcp"
    }

    /// One card on the Agent panel's "Connect agent" screen: a client (or a
    /// check), a short note, and the one thing to copy.
    public struct SetupStep: Sendable, Equatable {
        public let title: String
        public let note: String
        public let code: String
    }

    /// How to hand Beaver to an agent, for the port Beaver is on. The
    /// "Connect agent" screen shows these as cards; README.md → "Agent
    /// Access (MCP)" carries the same steps for the default port.
    public static func setupSteps(port: UInt16) -> [SetupStep] {
        let url = "http://127.0.0.1:\(port)/mcp"
        return [
            SetupStep(
                title: "Claude Code",
                note: "Run once in Terminal — it works in every project. Then just ask, e.g. “use beaver: what went wrong with login?”. Remove later with: claude mcp remove beaver",
                code: setupCommand(port: port)),
            SetupStep(
                title: "Cursor",
                note: "Add to ~/.cursor/mcp.json (merge into \"mcpServers\" if the file already exists), then enable beaver in Cursor Settings → MCP.",
                code: """
                    {
                      "mcpServers": {
                        "beaver": { "url": "\(url)" }
                      }
                    }
                    """),
            SetupStep(
                title: "Perplexity (Mac app)",
                note: "Settings → Connectors → install the PerplexityXPC helper → Add Connector → Simple. Name it beaver and paste this command. Needs Node.js; it bridges Perplexity's local connectors to Beaver.",
                code: "npx -y mcp-remote \(url)"),
            SetupStep(
                title: "Other MCP clients",
                note: "Add a Streamable HTTP server at this address. A client that only runs commands can use the Perplexity command instead.",
                code: url),
            SetupStep(
                title: "Check it answers",
                note: "Run in Terminal while Beaver is open. You should get a JSON list of Beaver's tools.",
                code: "curl -s -X POST \(url) -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'"),
            SetupStep(
                title: "First prompt",
                note: "Paste into your agent. Plain words are enough — it finds its way around Beaver on its own, and everything it does shows up in the Agent panel.",
                code: "Use beaver: look at the app's logs from the last 10 minutes and tell me about errors and failing network requests."),
        ]
    }

    /// The same steps as one plain text, for "Copy all".
    public static func setupInstructions(port: UInt16) -> String {
        let intro = """
            Connect an AI agent to Beaver

            Beaver runs an MCP server on this Mac at http://127.0.0.1:\(port)/mcp (loopback only). \
            Keep Beaver open with Agent Access (MCP) turned on in the app menu.
            """
        let steps = setupSteps(port: port).map { step in
            "\(step.title)\n\(step.note)\n\n\(step.code)"
        }
        return ([intro] + steps).joined(separator: "\n\n")
    }
}
