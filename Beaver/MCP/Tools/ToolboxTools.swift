//
//  ToolboxTools.swift
//  Beaver
//
//  D75/D76: the connected apps' toolboxes through one gateway, Beaver's
//  own tools as device "beaver", and the default device.

import Foundation

enum ToolboxTools {
    static let all = [setDefault, toolboxesList, toolsCall]

    /// Not reachable through "beaver": no recursion.
    static let gatewayNames: Set<String> = ["devices_set_default", "toolboxes_list", "tools_call"]

    static let beaverId = "beaver"

    // MARK: devices_set_default

    static let setDefault = MCPTool(
        name: "devices_set_default",
        title: "Set the default device",
        description: "Use when several apps are connected and you will work with one of them: device tools (commands_send, storage_set, toolboxes_list, tools_call, …) then use it when you omit deviceId. It follows the app when it restarts. Pass deviceId: null to clear it. The user can set it too, in the device popover.",
        kind: .change,
        idempotent: true,
        inputSchema: ToolSchema.object([
            "deviceId": ToolSchema.string("The app's deviceId from beaver_status, or null to clear the default."),
        ])
    ) { args, ctx in
        guard let raw = args.values["deviceId"] else {
            throw ToolError("deviceId is required. Example: devices_set_default(deviceId: \"12\"), or devices_set_default(deviceId: null) to clear it.")
        }
        if raw == .null {
            await ctx.ui.setDefaultDevice(nil)
            return ToolResult(summary: "No default device: with several apps connected, device tools need deviceId.",
                              structured: ["default": .null], next: ["beaver_status()"])
        }
        if try ToolContext.isBeaver(args) {
            throw ToolError("The default is for apps; Beaver is always deviceId \"beaver\". Example: devices_set_default(deviceId: \"12\") with an id from beaver_status().")
        }
        let (_, id) = try await ctx.requireDevice(args, doing: "make it the default", call: "devices_set_default()")
        guard let session = try await ctx.store.sessions().first(where: { $0.id == id }) else {
            throw ToolError("Session #\(id) is gone. Example: beaver_status(), then devices_set_default(deviceId: …).")
        }
        let device = DefaultDevice(session: session)
        await ctx.ui.setDefaultDevice(device)
        let lasts = if case .uid = device { "it stays the default when the app restarts" }
                    else { "this app sends no device id, so the default ends when it reconnects" }
        return ToolResult(
            summary: "Default device: \(StatusTools.describeDevice(session)) (deviceId \"\(id)\"); \(lasts).",
            structured: ["default": .string(String(id)), "uid": JSON(session.deviceUID)],
            next: ["toolboxes_list() for its toolboxes", "commands_list() for its commands"],
            sessionId: id
        )
    }

    // MARK: toolboxes_list

    static let toolboxesList = MCPTool(
        name: "toolboxes_list",
        title: "List an app's toolboxes",
        description: "Use to see what a connected app lets you do beyond commands: its toolboxes (storage, app, logs, debugfeatures, React ones…) and, with toolbox, each tool's arguments. deviceId \"beaver\" lists Beaver's own tools the same way. Then call one with tools_call.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "deviceId": ToolSchema.deviceId,
            "toolbox": ToolSchema.string("One toolbox's tools with their arguments, e.g. \"storage\"."),
        ])
    ) { args, ctx in
        let (deviceId, label, tools) = try await tools(args, ctx)
        let boxes = Toolboxes.group(tools)
        let on = deviceId == beaverId ? "Beaver" : label
        guard let wanted = try args.string("toolbox").flatMap(ToolContext.trimmedNonEmpty) else {
            guard let first = boxes.first else {
                return ToolResult(summary: "\(on) has no toolboxes.",
                                  structured: ["deviceId": .string(deviceId), "toolboxes": []],
                                  next: ["commands_list(deviceId: \"\(deviceId)\") for its commands"])
            }
            return ToolResult(
                summary: "\(on) has \(boxes.count) toolbox(es): "
                    + boxes.map { "\($0.name) (\($0.tools.count))" }.joined(separator: ", ") + ".",
                body: boxes.map { "\($0.name) — " + $0.tools.map(\.name).joined(separator: ", ") }.joined(separator: "\n"),
                structured: ["deviceId": .string(deviceId), "toolboxes": .array(boxes.map { box in
                    ["name": .string(box.name), "tools": .array(box.tools.map { .string($0.name) })]
                })],
                next: ["toolboxes_list(deviceId: \"\(deviceId)\", toolbox: \"\(first.name)\") for its arguments"]
            )
        }
        guard let box = boxes.first(where: { $0.name == wanted }) else {
            throw ToolError("\(on) has no toolbox \"\(wanted)\"." + toolboxesHint(boxes, deviceId: deviceId))
        }
        // Suggest a read, never storage.delete because it sorts first; without
        // a read, a placeholder the agent fills from the list above.
        let next = box.tools.first { localName($0.name, startsWith: readVerbs) }
            .map { "tools_call(deviceId: \"\(deviceId)\", name: \"\($0.name)\", arguments: \($0.exampleArguments))" }
            ?? "tools_call(deviceId: \"\(deviceId)\", name: \"\(box.name).…\", arguments: {…}) with a tool from the list above"
        return ToolResult(
            summary: "\(box.name) on \(on): \(box.tools.count) tool(s).",
            body: box.tools.map { $0.signature + ($0.description.isEmpty ? "" : " — " + $0.description) }
                .joined(separator: "\n"),
            structured: ["deviceId": .string(deviceId), "toolbox": .string(box.name), "tools": .array(box.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            })],
            next: [next]
        )
    }

    // MARK: tools_call

    static let toolsCall = MCPTool(
        name: "tools_call",
        title: "Call an app's tool",
        description: "Use to run one tool from toolboxes_list on a connected app (e.g. storage.set, app.restart) and get its answer. deviceId \"beaver\" runs Beaver's own tool by its dotted name (logs.query). Omit deviceId for the default device, or the only connected one. It is marked destructive, so clients that honor destructiveHint ask the user to confirm, because app tools can delete data or restart the app.",
        kind: .change,
        destructiveHint: true,
        inputSchema: ToolSchema.object([
            "deviceId": ToolSchema.deviceId,
            "name": ToolSchema.string("The tool's full name from toolboxes_list, e.g. \"storage.set\"."),
            "arguments": ["type": "object", "description": "The tool's arguments, as its inputSchema in toolboxes_list says."],
        ], required: ["name"])
    ) { args, ctx in
        guard let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("name is required. Example: tools_call(name: \"storage.get\", arguments: {key: \"volume\"}) — toolboxes_list() shows the names.")
        }
        let arguments = try argumentsObject(args["arguments"])
        if try ToolContext.isBeaver(args) {
            let local = Toolboxes.beaverToolName(name)
            guard !gatewayNames.contains(local), let tool = BeaverTools.all.first(where: { $0.name == local }) else {
                let own = beaverDeviceTools()
                let box = Toolboxes.name(of: name)
                let same = own.filter { Toolboxes.name(of: $0.name) == box }.map(\.name).sorted()
                let hint = same.isEmpty
                    ? " Toolboxes: " + Toolboxes.group(own).map(\.name).joined(separator: ", ") + "."
                    : " Tools in \(box): " + same.joined(separator: ", ") + "."
                throw ToolError("Beaver has no tool \"\(name)\" here.\(hint) Example: toolboxes_list(deviceId: \"beaver\") for its tools.")
            }
            guard tool.kind != .destructive else {
                let required = DeviceTool(name: local, description: "", inputSchema: tool.inputSchema).parameters
                    .filter(\.required).map { "\($0.name): …" }.joined(separator: ", ")
                let message = required.isEmpty
                    ? "\(name) is destructive, so Beaver doesn't run it through tools_call. Call \(local) directly; "
                        + "its description says which arguments it takes. Example: \(local)(…)."
                    : "\(name) is destructive, so Beaver doesn't run it through tools_call. Example: \(local)(\(required))."
                throw ToolError(message)
            }
            // The app path's shape (spec §5.1), the inner result inside.
            var result = try await tool.run(ToolArguments(arguments), ctx)
            result.structured = ["deviceId": .string(beaverId), "name": .string(name), "isError": false,
                                 "text": .string(result.summary), "structuredContent": result.structured]
            result.journalKind = tool.kind
            return result
        }
        let (host, id) = try await ctx.requireDevice(args, doing: "call \(name)", call: "tools_call(name: \"\(name)\")")
        let label = try await ctx.describeTarget(id, args, host)
        let risky = localName(name, startsWith: destructiveVerbs)
        let before = try await ctx.store.latestEventId(sessionId: id) ?? 0
        // Started first: the app may drop before it answers.
        if localName(name, startsWith: endsAppVerbs) { await ctx.watchForDisconnect(after: name, sessionId: id) }
        let reply = try await device(ctx, "tools/call", ["name": .string(name), "arguments": .object(arguments)],
                                     sessionId: id, timeout: DeviceMCPClient.callTimeout, what: name, label: label,
                                     retry: "tools_call(deviceId: \"\(id)\", name: \"\(name)\", arguments: \(JSON.object(arguments).text))",
                                     journalKind: risky ? .destructive : nil)
        let content = reply["content"]?.array ?? []
        let text = content.compactMap { $0["text"]?.string }.joined(separator: "\n")
        let box = Toolboxes.name(of: name)
        if reply["isError"]?.bool == true {
            var hint = " Example: toolboxes_list(deviceId: \"\(id)\", toolbox: \"\(box)\") for its arguments."
            if let listed = try? await device(ctx, "tools/list", [:], sessionId: id, timeout: DeviceMCPClient.listTimeout,
                                              what: "tools/list", label: label, retry: "toolboxes_list(deviceId: \"\(id)\")") {
                let tools = Toolboxes.tools(fromListResult: listed)
                if !tools.contains(where: { $0.name == name }) {
                    let same = tools.filter { Toolboxes.name(of: $0.name) == box }.map(\.name).sorted()
                    hint = same.isEmpty
                        ? toolboxesHint(Toolboxes.group(tools), deviceId: String(id))
                        : " Tools in \(box): " + same.joined(separator: ", ") + "." + hint
                }
            }
            throw ToolError("\(name) failed on \(label): \(text).\(hint)")
        }
        let others = content.filter { $0["type"]?.string != "text" }.map { $0["type"]?.string ?? "unknown" }
        let body = [text, others.isEmpty ? "" : "(+\(others.count) non-text item(s): \(others.joined(separator: ", ")))"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var structured: [String: JSON] = ["deviceId": .string(String(id)), "name": .string(name),
                                          "isError": false, "afterId": JSON(before)]
        // One copy: the body carries the text; structuredContent is the data.
        if let data = reply["structuredContent"] { structured["structuredContent"] = data }
        else { structured["text"] = .string(text) }
        return ToolResult(
            summary: "\(name) on \(label): " + (text.isEmpty ? "done (no text)" : String(firstLine.prefix(200))),
            body: body,
            structured: .object(structured),
            next: ["logs_wait(sessionId: \(id), afterId: \(before), timeoutMs: 15000) for what the app logged "
                   + "(after a restart, beaver_status() shows its new session)"],
            sessionId: id,
            journalKind: risky ? .destructive : nil
        )
    }

    // MARK: Helpers

    /// An app tool named like these is journaled as destructive (its toast).
    static let destructiveVerbs = ["delete", "remove", "clear", "kill", "reset", "restart", "execute", "launch"]
    /// An app tool named like these may end the app: watch for it dropping.
    static let endsAppVerbs = ["restart", "kill", "launch"]
    /// A tool named like these is safe to suggest in `Next:`.
    static let readVerbs = ["get", "list", "info", "dump", "tail", "facets", "status", "state", "snapshot",
                            "inspect", "current"]

    /// Whether the name after its toolbox (`storage.delete` → `delete`)
    /// starts with one of `verbs`, in any case.
    static func localName(_ tool: String, startsWith verbs: [String]) -> Bool {
        let local = (tool.firstIndex(of: ".").map { tool[tool.index(after: $0)...] } ?? tool[...]).lowercased()
        return verbs.contains { local.hasPrefix($0) }
    }

    /// The device's tools, or Beaver's own for "beaver".
    private static func tools(_ args: ToolArguments, _ ctx: ToolContext) async throws
        -> (deviceId: String, label: String, tools: [DeviceTool]) {
        if try ToolContext.isBeaver(args) {
            return (beaverId, "Beaver", beaverDeviceTools())
        }
        let (host, id) = try await ctx.requireDevice(args, doing: "list its toolboxes", call: "toolboxes_list()")
        let label = try await ctx.describeTarget(id, args, host)
        let result = try await device(ctx, "tools/list", [:], sessionId: id, timeout: DeviceMCPClient.listTimeout,
                                      what: "tools/list", label: label, retry: "toolboxes_list(deviceId: \"\(id)\")")
        return (String(id), label, Toolboxes.tools(fromListResult: result))
    }

    /// Beaver's own tools as toolboxes: not the gateway (no recursion) and
    /// not the destructive ones (D75) — they're only callable directly,
    /// under their own name and annotations.
    private static func beaverDeviceTools() -> [DeviceTool] {
        BeaverTools.all.filter { !gatewayNames.contains($0.name) && $0.kind != .destructive }.map {
            DeviceTool(name: Toolboxes.beaverName($0.name), description: $0.description, inputSchema: $0.inputSchema)
        }
    }

    /// " Toolboxes: a, b. Example: …", or that the app has none.
    private static func toolboxesHint(_ boxes: [Toolbox], deviceId: String) -> String {
        guard let first = boxes.first else { return " This app has no tools. Example: beaver_status()." }
        return " Toolboxes: " + boxes.map(\.name).joined(separator: ", ")
            + ". Example: toolboxes_list(deviceId: \"\(deviceId)\", toolbox: \"\(first.name)\")."
    }

    /// One MCP request; `DeviceMCPError` becomes a ToolError that says what
    /// to do. `journalKind` goes on a timeout or a drop: the call may have run.
    /// `retry` is the same call again, for when it never reached the app.
    private static func device(_ ctx: ToolContext, _ method: String, _ params: JSON, sessionId: Int64,
                               timeout: Duration, what: String, label: String, retry: String,
                               journalKind: AgentActivity.Kind? = nil) async throws -> JSON {
        let mayHaveRun = method == "tools/call"
            ? " It may still have run it (app.restart and app.killProcess end the app before answering)." : ""
        do {
            return try await ctx.device.mcp(method, params: params, to: sessionId, timeout: timeout)
        } catch let error as DeviceMCPError {
            switch error {
            case .unsupported:
                throw ToolError("\(label) doesn't answer MCP, so it has no toolboxes: the app needs quick-brick-xray's native WebSocket sink. Its commands still work. Example: commands_list(deviceId: \"\(sessionId)\").")
            case .timeout:
                throw ToolError("\(label) didn't answer \(what) in time.\(mayHaveRun) Example: beaver_status(), then logs_query(sessionId: \(sessionId), since: \"1m\").",
                                journalKind: journalKind)
            case .disconnected:
                throw ToolError("\(label) disconnected before answering \(what).\(mayHaveRun) Example: beaver_status() to see whether it came back, then logs_query(sessionId: \(sessionId), since: \"1m\").",
                                journalKind: journalKind)
            case .rpc(_, let message):
                throw ToolError("\(label) refused \(what): \(message). Example: toolboxes_list(deviceId: \"\(sessionId)\").")
            case .notSent(let reason):
                throw ToolError("\(what) didn't reach \(label): \(reason). Nothing ran on the app. Example: \(retry) to try again, or beaver_status().")
            }
        }
    }

    /// An object, or a weak client's JSON string of one.
    private static func argumentsObject(_ value: JSON?) throws -> [String: JSON] {
        guard let value else { return [:] }
        if let object = value.object { return object }
        if let s = value.string, let data = s.data(using: .utf8), let object = (try? JSON.parse(data))?.object {
            return object
        }
        throw ToolError("arguments must be an object. Example: tools_call(name: \"storage.get\", arguments: {key: \"volume\"}).")
    }
}
