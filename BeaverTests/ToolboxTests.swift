import Testing
import Foundation
@testable import BeaverCore

@Suite("Toolboxes (D75)")
struct ToolboxTests {

    static let list: JSON = ["tools": [
        ["name": "storage.set", "description": "Set a key",
         "inputSchema": ["type": "object",
                         "properties": ["value": ["type": "string"],
                                        "key": ["type": "string", "description": "The key"],
                                        "namespace": ["type": "string"],
                                        "layer": ["type": "string", "enum": ["session", "local"]]],
                         "required": ["key", "value"]]],
        ["name": "app.restart", "description": "Restart", "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "ping"],
        ["description": "no name"],
    ]]

    @Test("tools/list becomes tools; an entry without a name is skipped")
    func parse() {
        let tools = Toolboxes.tools(fromListResult: Self.list)
        #expect(tools.map(\.name) == ["storage.set", "app.restart", "ping"])
        #expect(tools[2].description == "")
    }

    @Test("Review focus: grouped by prefix, sorted; a dotless name goes to other; nothing gives nothing")
    func group() {
        let boxes = Toolboxes.group(Toolboxes.tools(fromListResult: Self.list))
        #expect(boxes.map(\.name) == ["app", "other", "storage"])
        #expect(Toolboxes.group([]).isEmpty)
        #expect(Toolboxes.name(of: ".odd") == "other")
    }

    @Test("Parameters: required first, then by name; one line each")
    func parameters() throws {
        let set = try #require(Toolboxes.tools(fromListResult: Self.list).first)
        #expect(set.parameters.map(\.name) == ["key", "value", "layer", "namespace"])
        #expect(set.parameters[0].line == "key: string (required) — The key")
        #expect(set.parameters[2].line == "layer: string, one of session|local")
        #expect(set.signature == "storage.set(key: string, value: string, layer?: string, namespace?: string)")
        #expect(set.exampleArguments == "{key: …, value: …}")
    }

    @Test("Beaver's own tools: first _ becomes . and back")
    func beaverNames() {
        #expect(Toolboxes.beaverName("logs_query") == "logs.query")
        #expect(Toolboxes.beaverName("devices_set_default") == "devices.set_default")
        #expect(Toolboxes.beaverToolName("devices.set_default") == "devices_set_default")
        #expect(Toolboxes.beaverToolName("status") == "status")
    }
}
