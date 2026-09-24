import Testing
import Foundation
@testable import BeaverCore

@Suite("MCP server")
struct MCPServerTests {

    private static let echo = MCPTool(
        name: "echo", title: "Echo", description: "Use when testing.", kind: .read,
        inputSchema: ToolSchema.object(["x": ToolSchema.string("Anything.")])
    ) { args, _ in
        let x = try args.string("x") ?? ""
        if x == "fail" { throw ToolError("It failed. Example: echo(x: \"ok\").") }
        return ToolResult(summary: "echo \(x)", structured: ["x": .string(x)], next: ["echo(x: \"again\")"])
    }

    private func server() throws -> (MCPServer, LogStore) {
        let store = try LogStore(source: .inMemory)
        let server = MCPServer(tools: [Self.echo], context: makeContext(store), journal: AgentJournal(store: store))
        return (server, store)
    }

    private func call(_ s: MCPServer, _ body: String, version: String? = nil) async throws -> JSON? {
        guard let data = await s.handle(Data(body.utf8), client: "claude-code/2.1.0 (cli)", protocolVersion: version) else {
            return nil
        }
        return try JSON.parse(data)
    }

    @Test("initialize negotiates the version and carries instructions")
    func initialize() async throws {
        let (s, _) = try server()
        let known = try await call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        #expect(known?["result"]?["protocolVersion"] == "2025-03-26")
        #expect(known?["result"]?["instructions"]?.string?.contains("beaver_status") == true)
        #expect(known?["result"]?["capabilities"]?["tools"] != nil)
        let unknown = try await call(s, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(unknown?["result"]?["protocolVersion"] == "2025-06-18")
    }

    @Test("tools/list lists the tools")
    func list() async throws {
        let (s, _) = try server()
        let reply = try await call(s, #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        #expect(reply?["id"] == "a")
        #expect(reply?["result"]?["tools"]?.array?.first?["name"] == "echo")
    }

    @Test("tools/call: text, structuredContent from 2025-06-18 on, journaled")
    func callTool() async throws {
        let (s, store) = try server()
        let body = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"x":"hi 🔥"}}}"#
        let new = try await call(s, body, version: "2025-06-18")
        #expect(new?["result"]?["isError"] == false)
        #expect(new?["result"]?["content"]?.array?.first?["text"]?.string?.hasPrefix("echo hi 🔥") == true)
        #expect(new?["result"]?["structuredContent"]?["x"] == "hi 🔥")
        let old = try await call(s, body, version: nil)
        #expect(old?["result"]?["structuredContent"] == nil)
        // A later protocol version than the newest Beaver knows still gets
        // structuredContent: it's a `>=` comparison, not an exact match.
        let newer = try await call(s, body, version: "2025-11-25")
        #expect(newer?["result"]?["structuredContent"]?["x"] == "hi 🔥")

        let journal = try await store.agentActivity()
        #expect(journal.count == 3)
        #expect(journal.first?.tool == "echo")
        #expect(journal.first?.client == "claude-code")
        #expect(journal.first?.summary == "echo hi 🔥")
    }

    @Test("A tool error is a result with isError, and is journaled as an error")
    func toolError() async throws {
        let (s, store) = try server()
        let reply = try await call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"x":"fail"}}}"#)
        #expect(reply?["result"]?["isError"] == true)
        #expect(reply?["result"]?["content"]?.array?.first?["text"]?.string?.contains("Example") == true)
        #expect(try await store.agentActivity().first?.isError == true)
    }

    @Test("A JSON-encoded string in params.arguments is parsed into an object")
    func stringEncodedArguments() async throws {
        let (s, _) = try server()
        let body = #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"echo","arguments":"{\"x\":\"hi\"}"}}"#
        let reply = try await call(s, body)
        #expect(reply?["result"]?["isError"] == false)
        #expect(reply?["result"]?["content"]?.array?.first?["text"]?.string?.hasPrefix("echo hi") == true)
    }

    @Test("An arguments string that doesn't parse as JSON falls back to no arguments")
    func unparsableStringArguments() async throws {
        let (s, _) = try server()
        let body = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"echo","arguments":"not json"}}"#
        let reply = try await call(s, body)
        #expect(reply?["result"]?["isError"] == false)
        #expect(reply?["result"]?["content"]?.array?.first?["text"]?.string?.hasPrefix("echo ") == true)
    }

    @Test("Unknown tool is an isError result that points at tools/list")
    func unknownTool() async throws {
        let (s, _) = try server()
        let reply = try await call(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#)
        #expect(reply?["result"]?["isError"] == true)
        #expect(reply?["result"]?["content"]?.array?.first?["text"]?.string?.contains("beaver_guide") == true)
    }

    @Test("Unknown tool call is journaled as an error")
    func unknownToolJournaled() async throws {
        let (s, store) = try server()
        _ = try await call(s, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#)
        let journal = try await store.agentActivity()
        #expect(journal.first?.tool == "nope")
        #expect(journal.first?.isError == true)
    }

    @Test("Notifications and responses get no reply")
    func notifications() async throws {
        let (s, _) = try server()
        #expect(try await call(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try await call(s, #"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)
    }

    @Test("Protocol errors", arguments: [
        ("not json", -32700),
        (#"{"id":1,"method":"ping"}"#, -32600),
        (#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#, -32601),
        (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#, -32602),
    ])
    func errors(body: String, code: Int) async throws {
        let (s, _) = try server()
        let reply = try await call(s, body)
        #expect(reply?["error"]?["code"]?.int == code)
    }

    @Test("ping")
    func ping() async throws {
        let (s, _) = try server()
        let reply = try await call(s, #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        #expect(reply?["result"] == .object([:]))
    }

    @Test("Client names from User-Agent")
    func clientNames() {
        #expect(AgentJournal.clientName("claude-code/2.1.0 (cli)") == "claude-code")
        #expect(AgentJournal.clientName("Cursor/1.2") == "Cursor")
        #expect(AgentJournal.clientName(nil) == nil)
        #expect(AgentJournal.clientName("") == nil)
    }

    @Test("instructions teach the action loop, follow-the-device, watches and notes")
    func instructionsCoverActions() {
        for phrase in ["commands_send", "collectLogsMs", "storage_set", "watch_start", "journal_note",
                       "attention", "howToEnable", "sessionChanged"] {
            #expect(MCPServer.instructions.contains(phrase), "\(phrase)")
        }
    }
}
