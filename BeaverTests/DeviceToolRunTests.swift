import Testing
import Foundation
@testable import BeaverCore

@Suite("A person runs an app's tool (D91)")
struct DeviceToolRunTests {

    static let tool = DeviceTool(name: "player.configure", description: "", inputSchema: [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Shown on screen"],
            "volume": ["type": "number", "default": 0.5],
            "count": ["type": "integer"],
            "muted": ["type": "boolean", "default": true],
            "layer": ["type": "string", "enum": ["local", "session"]],
            "options": ["type": "object"],
            "ids": ["type": "array"],
            "anything": ["description": "no type"],
        ],
        "required": ["title", "layer"],
    ])

    // MARK: Form

    @Test("inputSchema → fields: native controls, JSON for object/array/untyped, required first")
    func fields() {
        let f = ToolForm.fields(Self.tool)
        #expect(f.map(\.name) == ["layer", "title", "anything", "count", "ids", "muted", "options", "volume"])
        let kinds = Dictionary(uniqueKeysWithValues: f.map { ($0.name, $0.kind) })
        #expect(kinds["title"] == .text)
        #expect(kinds["volume"] == .number)
        #expect(kinds["count"] == .integer)
        #expect(kinds["muted"] == .boolean)
        #expect(kinds["layer"] == .choice(["local", "session"]))
        #expect(kinds["options"] == .json("object"))
        #expect(kinds["ids"] == .json("array"))
        #expect(kinds["anything"] == .json("any"))
        #expect(f.first { $0.name == "title" }?.required == true)
        #expect(f.first { $0.name == "title" }?.help == "Shown on screen")
        #expect(f.first { $0.name == "volume" }?.placeholder == "default: 0.5")
    }

    @Test("A non-string enum is typed, not a picker")
    func numericEnum() {
        let t = DeviceTool(name: "x.y", description: "", inputSchema: [
            "properties": ["level": ["type": "integer", "enum": [1, 2]]]])
        #expect(ToolForm.fields(t).first?.kind == .integer)
    }

    @Test("Values → arguments: typed, unset optionals left out, required checkbox gets its default")
    func arguments() throws {
        let fields = ToolForm.fields(Self.tool)
        let args = try ToolForm.arguments([
            "title": " Hi ", "layer": "local", "volume": "0.8", "count": "3", "muted": "false",
            "options": #"{"a": 1}"#, "ids": "[1, 2]", "anything": "plain",
        ], fields)
        #expect(args == ["title": " Hi ", "layer": "local", "volume": 0.8, "count": 3, "muted": false,
                         "options": ["a": 1], "ids": [1, 2], "anything": "plain"])
        let minimal = try ToolForm.arguments(["title": "t", "layer": "session"], fields)
        #expect(minimal == ["title": "t", "layer": "session"])

        let flag = DeviceTool(name: "a.b", description: "", inputSchema: [
            "properties": ["on": ["type": "boolean"]], "required": ["on"]])
        #expect(try ToolForm.arguments([:], ToolForm.fields(flag)) == ["on": false])
    }

    @Test("Validation: required, numbers and JSON fields")
    func validation() {
        let fields = ToolForm.fields(Self.tool)
        func error(_ values: [String: String]) -> ToolFormError? {
            do { _ = try ToolForm.arguments(["title": "t", "layer": "local"].merging(values) { $1 }, fields); return nil }
            catch { return error }
        }
        #expect(error(["title": "  "])?.message == "title is required.")
        #expect(error(["layer": ""])?.field == "layer")
        #expect(error(["volume": "loud"])?.message == "volume must be a number.")
        #expect(error(["count": "2.5"])?.message == "count must be a whole number.")
        #expect(error(["options": "[1]"])?.message.contains("must be JSON: an object") == true)
        #expect(error(["options": "{oops"])?.field == "options")
        #expect(error(["ids": #"{"a":1}"#])?.message.contains("an array") == true)
        #expect(error(["anything": #"{"a":1}"#]) == nil)
    }

    // MARK: Confirmation

    @Test("Confirmation: the name after the toolbox contains a risky word, any case")
    func confirmation() {
        for name in ["app.restart", "app.killProcess", "storage.delete", "storage.removeNamespace", "cache.CLEAR",
                     "app.reset", "storage.set", "auth.Logout", "db.wipeAll", "restart"] {
            #expect(DeviceToolCall.needsConfirmation(name), "\(name)")
        }
        for name in ["storage.get", "app.info", "restart.status", "logs.tail", "debugfeatures.list"] {
            #expect(!DeviceToolCall.needsConfirmation(name), "\(name)")
        }
    }

    // MARK: The call

    @Test("ok: sends tools/call with name and arguments; the answer's structuredContent is the value")
    func callOK() async {
        let device = FakeDevice(onMCP: { _, params in
            ["content": [["type": "text", "text": "done"], ["type": "image"]], "structuredContent": ["echo": params]]
        })
        let r = await DeviceToolCall.run("storage.set", arguments: ["key": "v"], on: device, sessionId: 7)
        #expect(device.mcpCalls.first?.method == "tools/call")
        #expect(device.mcpCalls.first?.sessionId == 7)
        #expect(device.mcpCalls.first?.params == ["name": "storage.set", "arguments": ["key": "v"]])
        let reply = try? r.get()
        #expect(reply?.text == "done")
        #expect(reply?.otherTypes == ["image"])
        #expect(reply?.value["echo"]?["name"] == "storage.set")
    }

    @Test("Text that is JSON shows as JSON; other text as text")
    func replyValue() {
        #expect(DeviceToolCall.Reply(["content": [["type": "text", "text": #"{"a":1}"#]]]).value == ["a": 1])
        #expect(DeviceToolCall.Reply(["content": [["type": "text", "text": "42"]]]).value == "42")
    }

    @Test("Failures: app error, not sent (nothing ran), timeout and drop (may still have run)")
    func failures() async {
        func run(_ answer: @escaping @Sendable (String, JSON) async throws -> JSON) async -> DeviceToolCall.Failure? {
            if case .failure(let f) = await DeviceToolCall.run("app.restart", arguments: [:], on: FakeDevice(onMCP: answer),
                                                              sessionId: 1) { return f }
            return nil
        }
        let app = await run { _, _ in ["content": [["type": "text", "text": "missing key"]], "isError": true] }
        #expect(app == .appError("missing key"))
        #expect(app?.message == "The app says: missing key")

        let notSent = await run { _, _ in throw DeviceMCPError.notSent("the app is no longer connected") }
        #expect(notSent?.message == "Didn't reach the app: the app is no longer connected. Nothing ran.")

        let timeout = await run { _, _ in throw DeviceMCPError.timeout }
        #expect(timeout?.message == "The app didn't answer in time. It may still have run.")
        let drop = await run { _, _ in throw DeviceMCPError.disconnected }
        #expect(drop?.message.hasSuffix("It may still have run.") == true)

        #expect(await run { _, _ in throw DeviceMCPError.unsupported } == .unsupported)
        #expect(await run { _, _ in throw DeviceMCPError.rpc(code: -32601, message: "no such method") }
                == .refused("no such method"))
    }

    // MARK: Log feed line

    @Test("Log feed line: beaver.tools, 'You ran … → ok' with arguments and result in data")
    func logLineOK() throws {
        let reply = DeviceToolCall.Reply(["content": [["type": "text", "text": "x"]], "structuredContent": ["n": 1]])
        let e = DeviceToolCall.logEvent(name: "storage.set", arguments: ["key": "v"], outcome: .success(reply),
                                        at: Date(timeIntervalSince1970: 1_000))
        #expect(e.subsystem == "beaver.tools")
        #expect(e.level == .info)
        #expect(e.timestampMillis == 1_000_000)
        #expect(e.message == #"You ran storage.set {"key":"v"} → ok"#)
        let data = try JSON.parse(Data(try #require(e.dataJSON).utf8))
        #expect(data == ["tool": "storage.set", "arguments": ["key": "v"], "ok": true, "result": ["n": 1]])
    }

    @Test("Log feed line: an error is a warning with the reason; no arguments, no braces")
    func logLineError() throws {
        let e = DeviceToolCall.logEvent(name: "app.restart", arguments: [:], outcome: .failure(.mayHaveRun("The app didn't answer in time.")),
                                        at: Date())
        #expect(e.level == .warning)
        #expect(e.message == "You ran app.restart → error: The app didn't answer in time. It may still have run.")
        let data = try JSON.parse(Data(try #require(e.dataJSON).utf8))
        #expect(data["ok"] == false)
        #expect(data["failure"] == "mayHaveRun")
    }

    @Test("Log feed line: a big result is capped in data, long arguments in the message")
    func logLineCaps() throws {
        let big = String(repeating: "a", count: DeviceToolCall.resultCap + 10)
        let reply = DeviceToolCall.Reply(["content": [["type": "text", "text": .string(big)]]])
        let long = String(repeating: "b", count: 500)
        let e = DeviceToolCall.logEvent(name: "logs.dump", arguments: ["q": .string(long)], outcome: .success(reply), at: Date())
        let data = try JSON.parse(Data(try #require(e.dataJSON).utf8))
        #expect(data["resultTruncated"] == true)
        #expect(data["result"]?.string?.count == DeviceToolCall.resultCap)
        #expect(data["arguments"]?["q"]?.string == long)
        #expect(e.message.count < 300)
        #expect(e.message.hasSuffix("… → ok"))
    }

    @Test("History keeps the newest 20")
    func history() {
        var runs: [ToolRun] = []
        for i in 0..<25 { runs = ToolRun.adding(ToolRun(name: "t\(i)", arguments: [:], at: Date(), error: nil), to: runs) }
        #expect(runs.count == ToolRun.limit)
        #expect(runs.first?.name == "t24")
    }

    @Test("The line lands in the session, where logs_query finds it by subsystem")
    func lineInSession() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        await store.append(DeviceToolCall.logEvent(name: "app.info", arguments: [:],
                                                   outcome: .success(DeviceToolCall.Reply([:])), at: Date()), to: s.id)
        try await waitForEvents(1, session: s.id, in: store)
        let r = try await LogTools.query.run(ToolArguments(["sessionId": .number(Double(s.id)), "filter": ["subsystems": ["beaver.tools"]]]),
                                             makeContext(store))
        #expect(r.body.contains("You ran app.info → ok"))
    }
}
