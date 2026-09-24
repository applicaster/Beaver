import Testing
import Foundation
@testable import BeaverCore

@Suite("MCP tool model")
struct MCPToolTests {

    @Test("Arguments are forgiving about shapes")
    func arguments() throws {
        let a = ToolArguments(["n": "42", "s": "x", "one": "a", "many": ["a", 5], "ids": 7, "none": .null])
        #expect(try a.int("n") == 42)
        #expect(try a.string("s") == "x")
        #expect(try a.strings("one") == ["a"])
        #expect(try a.strings("many") == ["a", "5"])
        #expect(try a.int64s("ids") == [7])
        #expect(a["none"] == nil)
        #expect(try a.string("absent") == nil)
    }

    @Test("A wrong type says what was expected")
    func wrongType() {
        let a = ToolArguments(["limit": ["x"]])
        #expect(throws: ToolError("limit must be a number, e.g. limit: 100.")) { try a.int("limit") }
    }

    @Test("Limits clamp to 1…max")
    func limits() throws {
        #expect(try ToolArguments([:]).limit(default: 100, max: 500) == 100)
        #expect(try ToolArguments(["limit": 9999]).limit(default: 100, max: 500) == 500)
        #expect(try ToolArguments(["limit": 0]).limit(default: 100, max: 500) == 1)
    }

    @Test("Result text: summary, body, Next")
    func resultText() {
        let r = ToolResult(summary: "2 events.", body: "#1 a\n#2 b", next: ["logs_get(ids: [1])"])
        #expect(r.text == "2 events.\n\n#1 a\n#2 b\n\nNext: logs_get(ids: [1])")
        #expect(ToolResult(summary: "Done.").text == "Done.")
    }

    @Test("Annotations follow the kind")
    func annotations() {
        let read = MCPTool(name: "x_read", title: "X", description: "Use when…", kind: .read,
                           inputSchema: ToolSchema.object([:])) { _, _ in ToolResult(summary: "") }
        let listing = read.listing
        #expect(listing["name"] == "x_read")
        #expect(listing["annotations"]?["readOnlyHint"] == true)
        #expect(listing["annotations"]?["destructiveHint"] == false)
        #expect(listing["inputSchema"]?["type"] == "object")
    }
}
