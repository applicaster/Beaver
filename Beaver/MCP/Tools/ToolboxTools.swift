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
        if try args.string("deviceId") == beaverId {
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
            throw ToolError("\(on) has no toolbox \"\(wanted)\". Toolboxes: "
                + boxes.map(\.name).joined(separator: ", ")
                + ". Example: toolboxes_list(deviceId: \"\(deviceId)\", toolbox: \"\(boxes.first?.name ?? "storage")\").")
        }
        // Suggest a read, never storage.delete because it sorts first.
        let first = box.tools.first { localName($0.name, startsWith: readVerbs) } ?? box.tools[0]
        return ToolResult(
            summary: "\(box.name) on \(on): \(box.tools.count) tool(s).",
            body: box.tools.map { $0.signature + ($0.description.isEmpty ? "" : " — " + $0.description) }
                .joined(separator: "\n"),
            structured: ["deviceId": .string(deviceId), "toolbox": .string(box.name), "tools": .array(box.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            })],
            next: ["tools_call(deviceId: \"\(deviceId)\", name: \"\(first.name)\", arguments: \(first.exampleArguments))"]
        )
    }

    // MARK: tools_call

    static let toolsCall = MCPTool(
        name: "tools_call",
        title: "Call an app's tool",
        description: "Use to run one tool from toolboxes_list on a connected app (e.g. storage.set, app.restart) and get its answer. deviceId \"beaver\" runs Beaver's own tool by its dotted name (logs.query). Omit deviceId for the default device, or the only connected one.",
        kind: .change,
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
        if try args.string("deviceId") == beaverId {
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
            var result = try await tool.run(ToolArguments(arguments), ctx)
            result.journalKind = tool.kind
            return result
        }
        let (_, id) = try await ctx.requireDevice(args, doing: "call \(name)", call: "tools_call(name: \"\(name)\")")
        let label = try await appLabel(ctx, id)
        let before = try await ctx.store.latestEventId(sessionId: id) ?? 0
        let reply = try await device(ctx, "tools/call", ["name": .string(name), "arguments": .object(arguments)],
                                     sessionId: id, timeout: DeviceMCPClient.callTimeout, what: name, label: label)
        let text = (reply["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        let box = Toolboxes.name(of: name)
        if reply["isError"]?.bool == true {
            var hint = ""
            if let listed = try? await device(ctx, "tools/list", [:], sessionId: id, timeout: DeviceMCPClient.listTimeout,
                                              what: "tools/list", label: label) {
                let tools = Toolboxes.tools(fromListResult: listed)
                if !tools.contains(where: { $0.name == name }) {
                    let same = tools.filter { Toolboxes.name(of: $0.name) == box }.map(\.name).sorted()
                    hint = same.isEmpty
                        ? " Toolboxes: " + Toolboxes.group(tools).map(\.name).joined(separator: ", ") + "."
                        : " Tools in \(box): " + same.joined(separator: ", ") + "."
                }
            }
            throw ToolError("\(name) failed on \(label): \(text).\(hint) Example: toolboxes_list(deviceId: \"\(id)\", toolbox: \"\(box)\") for its arguments.")
        }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var structured: [String: JSON] = ["deviceId": .string(String(id)), "name": .string(name),
                                          "isError": false, "text": .string(text), "afterId": JSON(before)]
        if let content = reply["structuredContent"] { structured["structuredContent"] = content }
        return ToolResult(
            summary: "\(name) on \(label): " + String(firstLine.prefix(200)),
            body: text,
            structured: .object(structured),
            next: ["logs_wait(afterId: \(before), timeoutMs: 15000) for what the app logged"],
            sessionId: id,
            journalKind: localName(name, startsWith: destructiveVerbs) ? .destructive : nil
        )
    }

    // MARK: Helpers

    /// An app tool named like these is journaled as destructive (its toast).
    static let destructiveVerbs = ["delete", "remove", "clear", "kill", "reset"]
    /// A tool named like these is safe to suggest in `Next:`.
    static let readVerbs = ["get", "list", "info", "dump", "tail", "facets"]

    /// Whether the name after its toolbox (`storage.delete` → `delete`)
    /// starts with one of `verbs`, in any case.
    static func localName(_ tool: String, startsWith verbs: [String]) -> Bool {
        let local = (tool.firstIndex(of: ".").map { tool[tool.index(after: $0)...] } ?? tool[...]).lowercased()
        return verbs.contains { local.hasPrefix($0) }
    }

    /// The device's tools, or Beaver's own for "beaver".
    private static func tools(_ args: ToolArguments, _ ctx: ToolContext) async throws
        -> (deviceId: String, label: String, tools: [DeviceTool]) {
        if try args.string("deviceId") == beaverId {
            return (beaverId, "Beaver", beaverDeviceTools())
        }
        let (_, id) = try await ctx.requireDevice(args, doing: "list its toolboxes", call: "toolboxes_list()")
        let label = try await appLabel(ctx, id)
        let result = try await device(ctx, "tools/list", [:], sessionId: id, timeout: DeviceMCPClient.listTimeout,
                                      what: "tools/list", label: label)
        return (String(id), label, Toolboxes.tools(fromListResult: result))
    }

    /// Beaver's own tools as toolboxes: not the gateway (no recursion) and
    /// not the destructive ones — tools_call has no destructiveHint, so
    /// they're only callable directly.
    private static func beaverDeviceTools() -> [DeviceTool] {
        BeaverTools.all.filter { !gatewayNames.contains($0.name) && $0.kind != .destructive }.map {
            DeviceTool(name: Toolboxes.beaverName($0.name), description: $0.description, inputSchema: $0.inputSchema)
        }
    }

    /// `Alpha 1.0 (iPhone 15, iOS 18.0)`: how summaries and errors name the app.
    private static func appLabel(_ ctx: ToolContext, _ id: Int64) async throws -> String {
        try await ctx.store.sessions().first { $0.id == id }.map(StatusTools.describeDevice) ?? "Device \"\(id)\""
    }

    /// One MCP request; `DeviceMCPError` becomes a ToolError that says what to do.
    private static func device(_ ctx: ToolContext, _ method: String, _ params: JSON, sessionId: Int64,
                               timeout: Duration, what: String, label: String) async throws -> JSON {
        do {
            return try await ctx.device.mcp(method, params: params, to: sessionId, timeout: timeout)
        } catch let error as DeviceMCPError {
            switch error {
            case .unsupported:
                throw ToolError("\(label) doesn't answer MCP, so it has no toolboxes: the app needs quick-brick-xray's native WebSocket sink. Its commands still work. Example: commands_list(deviceId: \"\(sessionId)\").")
            case .timeout:
                throw ToolError("\(label) didn't answer \(what) in time. It may still have run it — app.restart, for one, drops the connection before answering. Example: beaver_status(), then logs_query(sessionId: \(sessionId), since: \"1m\").")
            case .disconnected:
                throw ToolError("\(label) disconnected before answering \(what). Example: beaver_status() to see whether it came back.")
            case .rpc(_, let message):
                throw ToolError("\(label) refused \(what): \(message). Example: toolboxes_list(deviceId: \"\(sessionId)\").")
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
