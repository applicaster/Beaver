import Testing
import Foundation
@testable import BeaverCore

@Suite("Toolbox tools (D75, D76)")
struct ToolboxToolsTests {

    static let toolsList: JSON = ["tools": [
        ["name": "storage.set", "description": "Set a key",
         "inputSchema": ["type": "object", "properties": ["key": ["type": "string"], "value": ["type": "string"]],
                         "required": ["key", "value"]]],
        ["name": "storage.get", "description": "Get a key",
         "inputSchema": ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]]],
        ["name": "app.restart", "description": "Restart the app", "inputSchema": ["type": "object", "properties": [:]]],
    ]]

    static let ok: @Sendable (String, JSON) async throws -> JSON = { method, params in
        if method == "tools/list" { return ToolboxToolsTests.toolsList }
        return ["content": [["type": "text", "text": "set volume\nsecond line"]], "isError": false,
                "structuredContent": ["echo": params]]
    }

    /// One live app, Alpha (uid A); `answer` plays its MCP server.
    private func alpha(_ answer: @escaping @Sendable (String, JSON) async throws -> JSON = ToolboxToolsTests.ok)
        async throws -> (LogStore, Session, FakeUI, FakeDevice) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: "1.0", deviceModel: "iPhone 15",
                                             platform: "iOS", osVersion: "18.0", deviceUID: "A")
        let ui = FakeUI(value: HostSnapshot(serverState: "clientConnected", liveSessionIds: [a.id]))
        return (store, a, ui, FakeDevice(onMCP: answer))
    }

    private func run(_ tool: MCPTool, _ args: [String: JSON], _ store: LogStore, _ ui: FakeUI,
                     _ device: FakeDevice) async throws -> ToolResult {
        try await tool.run(ToolArguments(args), makeContext(store, fakeUI: ui, device: device))
    }

    private func message(_ body: () async throws -> Void) async -> String {
        do { try await body(); Issue.record("expected a ToolError"); return "" }
        catch let e as ToolError { return e.message }
        catch { Issue.record("unexpected \(error)"); return "" }
    }

    // MARK: toolboxes_list

    @Test("toolboxes_list: each toolbox with its tools")
    func listToolboxes() async throws {
        let (store, a, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolboxesList, [:], store, ui, device)
        #expect(r.summary.contains("app (1)"))
        #expect(r.summary.contains("storage (2)"))
        #expect(r.structured["toolboxes"]?.array?.compactMap { $0["name"]?.string } == ["app", "storage"])
        #expect(device.mcpCalls.map(\.method) == ["tools/list"])
        #expect(device.mcpCalls.first?.sessionId == a.id)
        #expect(r.next.first?.contains("toolboxes_list(deviceId: \"\(a.id)\", toolbox: \"app\")") == true)
    }

    @Test("toolboxes_list(toolbox:): tools with schemas and a ready tools_call")
    func listOneToolbox() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolboxesList, ["toolbox": "storage"], store, ui, device)
        #expect(r.body.contains("storage.set(key: string, value: string) — Set a key"))
        #expect(r.structured["tools"]?.array?.count == 2)
        #expect(r.structured["tools"]?.array?.first?["inputSchema"]?["required"] == ["key"])
        #expect(r.next.contains { $0.contains("tools_call(") && $0.contains("{key: …}") })
    }

    @Test("toolboxes_list(toolbox:): Next suggests a read, not the delete that sorts first")
    func nextSuggestsRead() async throws {
        let (store, _, ui, device) = try await alpha { _, _ in ["tools": [
            ["name": "storage.delete", "inputSchema": ["type": "object"]],
            ["name": "storage.get", "inputSchema": ["type": "object"]],
            ["name": "storage.set", "inputSchema": ["type": "object"]],
        ]] }
        let r = try await run(ToolboxTools.toolboxesList, ["toolbox": "storage"], store, ui, device)
        #expect(r.next.first?.contains("name: \"storage.get\"") == true)
    }

    @Test("toolboxes_list: an unknown toolbox lists the real ones")
    func unknownToolbox() async throws {
        let (store, _, ui, device) = try await alpha()
        let m = await message { _ = try await run(ToolboxTools.toolboxesList, ["toolbox": "player"], store, ui, device) }
        #expect(m.contains("app, storage"))
    }

    @Test("Review focus: an app with no tools says so")
    func noToolboxes() async throws {
        let (store, _, ui, device) = try await alpha { _, _ in ["tools": []] }
        let r = try await run(ToolboxTools.toolboxesList, [:], store, ui, device)
        #expect(r.summary.contains("no toolboxes"))
    }

    @Test("An app that doesn't answer MCP: says why")
    func unsupported() async throws {
        let (store, _, ui, device) = try await alpha { _, _ in throw DeviceMCPError.unsupported }
        let m = await message { _ = try await run(ToolboxTools.toolboxesList, [:], store, ui, device) }
        #expect(m.contains("native WebSocket sink"))
    }

    // MARK: tools_call

    @Test("tools_call forwards name and arguments, returns the app's text and structuredContent")
    func call() async throws {
        let (store, a, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolsCall,
                              ["name": "storage.set", "arguments": ["key": "volume", "value": "3"]], store, ui, device)
        let sent = try #require(device.mcpCalls.last)
        #expect(sent.method == "tools/call")
        #expect(sent.params == ["name": "storage.set", "arguments": ["key": "volume", "value": "3"]])
        #expect(r.summary.hasPrefix("storage.set on Alpha"))
        #expect(r.summary.hasSuffix("set volume"))
        #expect(r.body == "set volume\nsecond line")
        #expect(r.structured["structuredContent"]?["echo"]?["name"] == "storage.set")
        #expect(r.sessionId == a.id)
    }

    @Test("tools_call journals a delete/remove/clear/kill/reset app tool as destructive, others by default")
    func journalKind() async throws {
        let (store, _, ui, device) = try await alpha()
        for name in ["storage.delete", "storage.removeNamespace", "app.killProcess", "Cache.CLEAR", "app.reset"] {
            let r = try await run(ToolboxTools.toolsCall, ["name": .string(name)], store, ui, device)
            #expect(r.journalKind == .destructive, "\(name)")
        }
        let get = try await run(ToolboxTools.toolsCall, ["name": "storage.get"], store, ui, device)
        #expect(get.journalKind == nil)
        let beaver = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "beaver.status"], store, ui, device)
        #expect(beaver.journalKind == .read)
    }

    @Test("Review focus: arguments sent as a JSON string are parsed")
    func stringArguments() async throws {
        let (store, _, ui, device) = try await alpha()
        _ = try await run(ToolboxTools.toolsCall,
                          ["name": "storage.get", "arguments": #"{"key":"volume"}"#], store, ui, device)
        #expect(device.mcpCalls.last?.params["arguments"] == ["key": "volume"])
    }

    @Test("The app's isError becomes a ToolError pointing at the toolbox")
    func appError() async throws {
        let (store, _, ui, device) = try await alpha { method, _ in
            method == "tools/list" ? ToolboxToolsTests.toolsList
                : ["content": [["type": "text", "text": "missing value"]], "isError": true]
        }
        let m = await message { _ = try await run(ToolboxTools.toolsCall, ["name": "storage.set"], store, ui, device) }
        #expect(m.contains("storage.set failed on Alpha"))
        #expect(m.contains("missing value"))
        #expect(m.contains("toolbox: \"storage\""))
    }

    @Test("An unknown tool lists the toolbox's tools")
    func unknownTool() async throws {
        let (store, _, ui, device) = try await alpha { method, _ in
            method == "tools/list" ? ToolboxToolsTests.toolsList
                : ["content": [["type": "text", "text": "Tool storage.sett not found"]], "isError": true]
        }
        let m = await message { _ = try await run(ToolboxTools.toolsCall, ["name": "storage.sett"], store, ui, device) }
        #expect(m.contains("storage.get, storage.set"))
    }

    @Test("A timeout says the call may still have run")
    func timeout() async throws {
        let (store, _, ui, device) = try await alpha { _, _ in throw DeviceMCPError.timeout }
        let m = await message { _ = try await run(ToolboxTools.toolsCall, ["name": "app.restart"], store, ui, device) }
        #expect(m.contains("may still have run"))
    }

    // MARK: "beaver"

    @Test("Beaver as a device: its tools as toolboxes, without the gateway")
    func beaverToolboxes() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolboxesList, ["deviceId": "beaver", "toolbox": "logs"], store, ui, device)
        let names = r.structured["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(names.contains("logs.query"))
        let all = try await run(ToolboxTools.toolboxesList, ["deviceId": "beaver"], store, ui, device)
        #expect(!all.body.contains("tools.call"))
        #expect(!all.body.contains("toolboxes.list"))
        #expect(device.mcpCalls.isEmpty)
    }

    @Test("A destructive Beaver tool isn't listed under beaver")
    func beaverExcludesDestructive() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolboxesList, ["deviceId": "beaver"], store, ui, device)
        #expect(!r.body.contains("sessions.delete"))
        #expect(!r.body.contains("storage.delete"))
        #expect(!r.body.contains("filters.delete"))
    }

    @Test("tools_call on beaver runs Beaver's tool; the gateway can't be called through it")
    func beaverCall() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "beaver.status"], store, ui, device)
        #expect(r.summary.hasPrefix("A device is connected"))
        let m = await message {
            _ = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "tools.call"], store, ui, device)
        }
        #expect(m.contains("toolboxes_list(deviceId: \"beaver\")"))
    }

    @Test("tools_call on beaver refuses a destructive tool, naming the direct call")
    func beaverCallRefusesDestructive() async throws {
        let (store, _, ui, device) = try await alpha()
        let m = await message {
            _ = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "sessions.delete"], store, ui, device)
        }
        #expect(m.contains("sessions.delete is destructive"))
        #expect(!m.contains("sessions_delete()"))
        #expect(m.contains("sessions_delete(…)"))
    }

    @Test("tools_call on beaver, an unknown name: lists the tools in its toolbox")
    func beaverUnknownToolListsToolbox() async throws {
        let (store, _, ui, device) = try await alpha()
        let m = await message {
            _ = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "logs.quer"], store, ui, device)
        }
        #expect(m.contains("logs.query"))
    }

    // MARK: devices_set_default

    @Test("devices_set_default sets by device id, clears with null, refuses beaver and a missing deviceId")
    func setDefault() async throws {
        let (store, a, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.setDefault, ["deviceId": JSON(a.id)], store, ui, device)
        #expect(ui.value.defaultDevice == .uid("A"))
        #expect(r.summary.contains("Alpha"))
        _ = try await run(ToolboxTools.setDefault, ["deviceId": .null], store, ui, device)
        #expect(ui.value.defaultDevice == nil)
        let beaver = await message { _ = try await run(ToolboxTools.setDefault, ["deviceId": "beaver"], store, ui, device) }
        #expect(beaver.contains("apps"))
        let missing = await message { _ = try await run(ToolboxTools.setDefault, [:], store, ui, device) }
        #expect(missing.contains("deviceId: null"))
    }

    // MARK: beaver_status

    @Test("beaver_status marks the default and shows device id, bundle id and Beaver's deviceId")
    func status() async throws {
        let (store, a, ui, device) = try await alpha()
        try await store.setSessionDeviceInfo(id: a.id, appName: nil, appVersion: nil, deviceModel: nil, platform: nil,
                                             osVersion: nil, appPackage: "com.example.alpha")
        ui.update { $0.defaultDevice = .uid("A") }
        let r = try await run(StatusTools.status, [:], store, ui, device)
        let first = try #require(r.structured["devices"]?.array?.first)
        #expect(first["default"] == true)
        #expect(first["uid"] == "A")
        #expect(first["appPackage"] == "com.example.alpha")
        #expect(r.structured["devices"]?.array?.count == 1)
        #expect(r.structured["beaver"]?["deviceId"] == "beaver")
        #expect(r.summary.contains("Default device: Alpha"))
    }
}
