//
//  MCPServer.swift
//  Beaver
//
//  JSON-RPC 2.0 for MCP, stateless, owns no socket (design M2). One
//  message in, one reply out; nil for notifications and responses.

import Foundation

public struct MCPServer: Sendable {

    /// Newest first: an unknown requested version gets the first (M21).
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Shown to the model by every mainstream client (design §8). Keep it
    /// short; the full flows live in MCP.md, served by beaver_guide.
    public static let instructions = """
        Beaver is a macOS log viewer. One mobile app connects to it over WebSocket, and Beaver \
        stores everything the app sends: logs, network requests, storage snapshots. \
        Start with beaver_status. If no device is connected you can still read past sessions \
        (sessions_list). Omitting sessionId means the live session, else the one the user is \
        viewing, else the most recent. Before filtering by subsystem or category call \
        logs_facets: names are namespaced and you will not guess them (globs like "*auth*" and \
        name fragments work, and results say what they matched). Use since: "5m" or afterId to \
        look at recent events. To wait for something to be logged, call logs_wait with afterId. \
        Rows are one line each; full payloads come from logs_get and network_get. Network bodies \
        are capped at 100 KB by the SDK and some headers are [REDACTED], so a replayed cURL may \
        fail. Every result ends with Next: suggestions. Everything you call is listed in \
        Beaver's Agent panel for the user. If unsure how to do something, call beaver_guide.
        """

    let tools: [MCPTool]
    let context: ToolContext
    let journal: AgentJournal

    public init(tools: [MCPTool], context: ToolContext, journal: AgentJournal) {
        self.tools = tools
        self.context = context
        self.journal = journal
    }

    public var toolNames: [String] { tools.map(\.name) }

    public func handle(_ data: Data, client: String?, protocolVersion: String?) async -> Data? {
        guard let message = try? JSON.parse(data), let o = message.object else {
            return Self.error(id: .null, code: -32700, "Parse error: send one JSON-RPC 2.0 object.")
        }
        let id = o["id"] ?? .null
        guard o["jsonrpc"] == "2.0" else {
            return Self.error(id: id, code: -32600, "Invalid request: jsonrpc must be \"2.0\".")
        }
        // No method: a response to something we never sent. No id: a notification.
        guard let method = o["method"]?.string, o["id"] != nil else { return nil }
        let params = o["params"]?.object ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string
            let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil }
                ?? Self.supportedVersions[0]
            let host = await context.ui.snapshot()
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "beaver", "title": "Beaver", "version": .string(host.beaverVersion)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.map(\.listing))])
        case "tools/call":
            guard let name = params["name"]?.string else {
                return Self.error(id: id, code: -32602, "Invalid params: tools/call needs a tool name.")
            }
            let arguments = ToolArguments(Self.argumentsObject(params["arguments"]))
            // structuredContent exists from 2025-06-18 on — a `>=` compare
            // on the YYYY-MM-DD form, so a later version we don't know by
            // name yet still gets it; a client that sends no header is
            // 2025-03-26 by the spec's rule.
            let structured = protocolVersion.map { $0 >= "2025-06-18" } ?? false
            return Self.result(id: id, await call(name, arguments, client: client, structured: structured))
        default:
            return Self.error(id: id, code: -32601, "Method not found: \(method). Beaver serves tools only.")
        }
    }

    private func call(_ name: String, _ arguments: ToolArguments, client: String?, structured: Bool) async -> JSON {
        guard let tool = tools.first(where: { $0.name == name }) else {
            let errorMessage = "Unknown tool \(name). Call tools/list for the tools, or beaver_guide() for how to use them."
            await journal.record(toolName: name, kind: .read, client: client, result: nil, error: errorMessage)
            return Self.content(errorMessage, structured: nil, isError: true)
        }
        do {
            let result = try await tool.run(arguments, context)
            await journal.record(toolName: tool.name, kind: tool.kind, client: client, result: result, error: nil)
            let structuredValue: JSON? = if structured { result.structured } else { nil }
            return Self.content(result.text, structured: structuredValue, isError: false)
        } catch let error as ToolError {
            await journal.record(toolName: tool.name, kind: tool.kind, client: client, result: nil, error: error.message)
            return Self.content(error.message, structured: nil, isError: true)
        } catch {
            let message = "Beaver failed to run \(name): \(error.localizedDescription)"
            await journal.record(toolName: tool.name, kind: tool.kind, client: client, result: nil, error: message)
            return Self.content(message, structured: nil, isError: true)
        }
    }

    /// A weak client sometimes double-encodes `arguments` as a JSON string
    /// rather than an object. Parse it in that case; fall back to no
    /// arguments only when it isn't an object either way.
    private static func argumentsObject(_ value: JSON?) -> [String: JSON] {
        if let object = value?.object { return object }
        if let text = value?.string, let parsed = try? JSON.parse(Data(text.utf8)) { return parsed.object ?? [:] }
        return [:]
    }

    private static func content(_ text: String, structured: JSON?, isError: Bool) -> JSON {
        var o = [String: JSON]()
        o["content"] = .array([.object(["type": .string("text"), "text": .string(text)])])
        o["isError"] = .bool(isError)
        if let structured { o["structuredContent"] = structured }
        return .object(o)
    }

    private static func result(id: JSON, _ result: JSON) -> Data {
        JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).data()
    }

    private static func error(id: JSON, code: Int, _ message: String) -> Data {
        JSON.object(["jsonrpc": "2.0", "id": id,
                     "error": ["code": .number(Double(code)), "message": .string(message)]]).data()
    }
}
