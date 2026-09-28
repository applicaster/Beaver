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

    @Test("A call that never reached the app says nothing ran, retries the same call, and isn't journaled destructive")
    func notSent() async throws {
        let (store, a, ui, device) = try await alpha { _, _ in
            throw DeviceMCPError.notSent("the app didn't answer initialize in time")
        }
        do {
            _ = try await run(ToolboxTools.toolsCall, ["name": "app.killProcess", "arguments": ["force": true]],
                              store, ui, device)
            Issue.record("expected a ToolError")
        } catch let e as ToolError {
            #expect(e.message == "app.killProcess didn't reach Alpha 1.0 (iPhone 15, iOS 18.0): the app didn't answer "
                + "initialize in time. Nothing ran on the app. Example: tools_call(deviceId: \"\(a.id)\", "
                + "name: \"app.killProcess\", arguments: {\"force\":true}) to try again, or beaver_status().")
            #expect(!e.message.contains("may still have run"))
            #expect(e.journalKind == nil)
        }
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

    // MARK: Bug hunt fixes (batch B)

    /// Alpha (older) and Beta, both live; the default is `defaultDevice`.
    private func alphaBeta(default defaultDevice: DefaultDevice?,
                           _ answer: @escaping @Sendable (String, JSON) async throws -> JSON = ToolboxToolsTests.ok)
        async throws -> (LogStore, Session, Session, FakeUI, FakeDevice) {
        let (store, a, ui, device) = try await alpha(answer)
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: b.id, appName: "Beta", appVersion: "2.0", deviceModel: "Pixel 8",
                                             platform: "Android", osVersion: "15", deviceUID: "B")
        ui.update { $0.liveSessionIds = [a.id, b.id]; $0.defaultDevice = defaultDevice }
        return (store, a, b, ui, device)
    }

    @Test("B1: tools_call asks the client to confirm; its kind stays change")
    func toolsCallDestructiveHint() {
        #expect(ToolboxTools.toolsCall.listing["annotations"]?["destructiveHint"] == true)
        #expect(ToolboxTools.toolsCall.kind == .change)
        #expect(ToolboxTools.toolsCall.description.contains("confirm"))
        #expect(ToolboxTools.toolboxesList.listing["annotations"]?["destructiveHint"] == false)
    }

    @Test("B1: restart, execute and launch app tools are journaled destructive; storage.set stays a change")
    func widerHeuristic() async throws {
        let (store, _, ui, device) = try await alpha()
        for name in ["app.restart", "console.execute", "app.launchMainActivity"] {
            let r = try await run(ToolboxTools.toolsCall, ["name": .string(name)], store, ui, device)
            #expect(r.journalKind == .destructive, "\(name)")
        }
        for name in ["storage.set", "storage.setBatch"] {
            let r = try await run(ToolboxTools.toolsCall, ["name": .string(name)], store, ui, device)
            #expect(r.journalKind == nil, "\(name)")
        }
    }

    @Test("B4: a destructive app tool that drops the connection: may have run, journaled destructive")
    func disconnectedDestructive() async throws {
        for error in [DeviceMCPError.disconnected, .timeout] {
            let (store, _, ui, device) = try await alpha { _, _ in throw error }
            do {
                _ = try await run(ToolboxTools.toolsCall, ["name": "app.killProcess"], store, ui, device)
                Issue.record("expected a ToolError")
            } catch let e as ToolError {
                #expect(e.journalKind == .destructive)
                #expect(e.message.contains("may still have run"))
                #expect(e.message.contains("app.killProcess end the app"))
                #expect(e.message.contains("beaver_status()"))
            }
            do {
                _ = try await run(ToolboxTools.toolsCall, ["name": "storage.get"], store, ui, device)
            } catch let e as ToolError {
                #expect(e.journalKind == nil)
            }
        }
    }

    @Test("B4: tools_call app.restart watches for the app dropping, like commands_send")
    func restartWatchesDisconnect() async throws {
        let (store, a, ui, _) = try await alpha()
        let device = FakeDevice(onMCP: { [ui] _, _ in
            ui.update { $0.liveSessionIds = [] }
            throw DeviceMCPError.disconnected
        })
        let ctx = makeContext(store, fakeUI: ui, device: device)
        _ = try? await ToolboxTools.toolsCall.run(ToolArguments(["name": "app.restart"]), ctx)
        try await Task.sleep(for: .milliseconds(400))
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: b.id, appName: "Alpha", appVersion: "1.0", deviceModel: "iPhone 15",
                                             platform: "iOS", osVersion: "18.0", deviceUID: "A")
        ui.update { $0.liveSessionIds = [b.id] }
        var rows: [AgentActivity] = []
        for _ in 0..<40 where rows.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            rows = try await store.agentActivity().filter { $0.kind == .system }
        }
        #expect(rows.first?.summary == "Device disconnected after \"app.restart\" → session #\(b.id)")
        #expect(a.id != b.id)
    }

    @Test("B2/B3: tools_call names the default target and points logs_wait at its session")
    func callNamesTargetAndSession() async throws {
        let (store, a, _, ui, device) = try await alphaBeta(default: .uid("A"))
        let r = try await run(ToolboxTools.toolsCall, ["name": "storage.get"], store, ui, device)
        #expect(device.mcpCalls.last?.sessionId == a.id)
        #expect(r.summary.hasPrefix("storage.get on Alpha 1.0 (iPhone 15, iOS 18.0) (default): "))
        #expect(r.next.first?.hasPrefix("logs_wait(sessionId: \(a.id), afterId: ") == true)
        #expect(r.next.first?.contains("beaver_status()") == true)
        let explicit = try await run(ToolboxTools.toolsCall, ["deviceId": JSON(a.id), "name": "storage.get"],
                                     store, ui, device)
        #expect(!explicit.summary.contains("(default)"))
    }

    @Test("B5: non-text items are counted; empty text says done (no text)")
    func nonText() async throws {
        let (store, _, ui, device) = try await alpha { method, _ in
            method == "tools/list" ? ToolboxToolsTests.toolsList
                : ["content": [["type": "image", "data": "…"], ["type": "text", "text": ""],
                               ["type": "resource", "resource": [:]]], "isError": false]
        }
        let r = try await run(ToolboxTools.toolsCall, ["name": "app.screenshot"], store, ui, device)
        #expect(r.summary == "app.screenshot on Alpha 1.0 (iPhone 15, iOS 18.0): done (no text)")
        #expect(r.body.contains("(+2 non-text item(s): image, resource)"))
    }

    @Test("B5: structured keeps structuredContent and drops the duplicate text")
    func noTripleCopy() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolsCall, ["name": "storage.get"], store, ui, device)
        #expect(r.structured["structuredContent"] != nil)
        #expect(r.structured["text"] == nil)
        let (store2, _, ui2, device2) = try await alpha { _, _ in ["content": [["type": "text", "text": "hi"]]] }
        let plain = try await run(ToolboxTools.toolsCall, ["name": "storage.get"], store2, ui2, device2)
        #expect(plain.structured["text"] == "hi")
    }

    @Test("B5: the beaver path returns the app path's shape")
    func beaverShape() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "beaver.status"], store, ui, device)
        #expect(r.structured["deviceId"] == "beaver")
        #expect(r.structured["name"] == "beaver.status")
        #expect(r.structured["isError"] == false)
        #expect(r.structured["text"]?.string?.hasPrefix("A device is connected") == true)
        #expect(r.structured["structuredContent"]?["devices"]?.array?.count == 1)
        #expect(r.summary.hasPrefix("A device is connected"))
        #expect(r.journalKind == .read)
    }

    @Test("B5: \"Beaver\" and \" beaver \" are Beaver, even with no app connected")
    func beaverAnyCase() async throws {
        let store = try LogStore(source: .inMemory)
        let ui = FakeUI()
        let device = FakeDevice()
        for id in ["Beaver", " beaver ", "BEAVER"] {
            let r = try await run(ToolboxTools.toolsCall, ["deviceId": .string(id), "name": "beaver.status"],
                                  store, ui, device)
            #expect(r.structured["deviceId"] == "beaver")
            let list = try await run(ToolboxTools.toolboxesList, ["deviceId": .string(id)], store, ui, device)
            #expect(list.structured["deviceId"] == "beaver")
        }
        let m = await message { _ = try await run(ToolboxTools.setDefault, ["deviceId": "Beaver"], store, ui, device) }
        #expect(m.contains("The default is for apps"))
    }

    @Test("B5: other device tools given deviceId beaver point at Beaver's tools")
    func beaverOnDeviceTool() async throws {
        let (store, _, ui, device) = try await alpha()
        let m = await message {
            _ = try await CommandTools.send.run(ToolArguments(["deviceId": "Beaver", "command": "x"]),
                                                makeContext(store, fakeUI: ui, device: device))
        }
        #expect(m.contains("toolboxes_list(deviceId: \"beaver\")"))
        #expect(device.sent.isEmpty)
    }

    @Test("B5: an app with no tools says so, and doesn't repeat the failed call")
    func noToolsHints() async throws {
        let (store, _, ui, device) = try await alpha { method, _ in
            method == "tools/list" ? ["tools": []] : ["content": [["type": "text", "text": "unknown tool"]], "isError": true]
        }
        let m = await message { _ = try await run(ToolboxTools.toolboxesList, ["toolbox": "storage"], store, ui, device) }
        #expect(m.contains("This app has no tools."))
        #expect(m.contains("Example: beaver_status()"))
        #expect(!m.contains("Toolboxes: ."))
        let c = await message { _ = try await run(ToolboxTools.toolsCall, ["name": "storage.get"], store, ui, device) }
        #expect(c.contains("This app has no tools."))
        #expect(c.contains("Example: beaver_status()"))
        #expect(!c.contains("toolboxes_list(deviceId"))
    }

    @Test("B5: a toolbox with no read tool suggests a placeholder, never a mutating tool")
    func nextWithoutRead() async throws {
        let (store, a, ui, device) = try await alpha { _, _ in ["tools": [
            ["name": "app.clearCache", "inputSchema": ["type": "object"]],
            ["name": "app.restart", "inputSchema": ["type": "object"]],
        ]] }
        let r = try await run(ToolboxTools.toolboxesList, ["toolbox": "app"], store, ui, device)
        #expect(r.next.first?.contains("tools_call(deviceId: \"\(a.id)\", name: \"app.…\", arguments: {…})") == true)
        #expect(!r.next.joined().contains("clearCache"))
        #expect(!r.next.joined().contains("restart"))
        let beaver = try await run(ToolboxTools.toolboxesList, ["deviceId": "beaver", "toolbox": "devices"],
                                   store, ui, device)
        #expect(!beaver.next.joined().contains("devices.disconnect"))
    }
}
