//
//  CommandTools.swift
//  Beaver
//

import Foundation

enum CommandTools {
    static let all: [MCPTool] = [send, disconnect, connectTV]

    static let maxCollectMillis = 30_000

    static let send: MCPTool = MCPTool(
        name: "commands_send",
        title: "Send a command",
        description: "Use to make the connected app do something: send one of the commands from commands_list, exactly as the user would type it in Beaver's command bar. With collectLogsMs, also returns the events logged in that window, following the app into its new session if the command restarts it. Beaver sends any command; it can't know which ones restart the app.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "command": ToolSchema.string("The command line, e.g. \"storage.list\" or \"debug.flag.on newPlayer\"."),
            "collectLogsMs": ToolSchema.integer("Also collect the events logged for this long after sending. Default 0, max 30000."),
            "filter": ToolSchema.filter,
            "limit": ToolSchema.integer("Most events to return with collectLogsMs. Default 100, max 500."),
            "deviceId": ToolSchema.deviceId,
        ], required: ["command"])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        guard let command = try args.string("command").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("command is required. Example: commands_send(command: \"storage.list\") — commands_list() shows what the app accepts.")
        }
        let (host, live) = try await ctx.requireDevice(args, doing: "send a command",
                                                   call: "commands_send(command: \"\(command)\")")
        let session = try await ctx.liveSession(live)
        let target = try await ctx.describeTarget(live, args, host)
        let collect = min(maxCollectMillis, max(0, try args.int("collectLogsMs") ?? 0))
        let limit = try args.limit(default: 100, max: 500)
        let filter = collect > 0 ? try await ctx.resolveFilter(args, sessionId: session.id)
                                 : ResolvedFilter(filter: .none, notes: [])
        let before = try await ctx.store.latestEventId(sessionId: session.id) ?? 0

        await ctx.device.send(command: command, to: live)
        await ctx.ui.didSendCommand(command)
        await ctx.watchForDisconnect(after: command, sessionId: session.id)

        guard collect > 0 else {
            return ToolResult(
                summary: "Sent \"\(command)\" to \(target) (session \(session.label)).",
                structured: ["sent": .string(command), "sessionId": JSON(session.id), "afterId": JSON(before)],
                next: ["logs_wait(sessionId: \(session.id), afterId: \(before), timeoutMs: 15000) for what it logs "
                       + "(after a restart, beaver_status() shows its new session)",
                       "commands_send(deviceId: \"\(live)\", command: \"\(command)\", collectLogsMs: 5000) to send and collect in one call"],
                sessionId: session.id
            )
        }
        let w = try await ctx.waitForEvents(from: session, afterId: before, filter: filter.filter, limit: limit,
                                            timeout: .milliseconds(collect), untilFirst: false)
        let resolved = filter.notes.isEmpty ? "" : " Resolved: " + filter.notes.joined(separator: "; ") + "."
        let follow = w.followText.isEmpty ? "" : " " + w.followText
        var structured: [String: JSON] = [
            "sent": .string(command), "sessionId": JSON(w.sessionId), "afterId": JSON(before),
            "collectLogsMs": JSON(collect), "total": JSON(w.total), "hasMore": .bool(w.total > w.events.count),
            "events": .array(w.events.map { ["id": JSON($0.id), "line": .string(ToolText.eventLine($0))] }),
            "resolved": .array(filter.notes.map(JSON.string)),
        ]
        structured.merge(w.followFields) { current, _ in current }
        var next: [String] = w.events.first.map { ["logs_get(ids: [\($0.id)]) for the full event"] } ?? []
        next.append(w.events.last.map { "logs_wait(sessionId: \(w.sessionId), afterId: \($0.id), …) for what comes next" }
            ?? "logs_wait(sessionId: \(w.sessionId), afterId: \(before), timeoutMs: 15000) in case the app is slow")
        return ToolResult(
            summary: "Sent \"\(command)\" to \(target); \(w.total) event(s) logged in \(collect) ms (\(ToolText.describe(filter.filter))).\(resolved)\(follow)",
            body: w.events.map(ToolText.eventLine).joined(separator: "\n"),
            structured: .object(structured),
            next: next,
            sessionId: w.sessionId
        )
    }

    static let disconnect: MCPTool = MCPTool(
        name: "devices_disconnect",
        title: "Disconnect a device",
        description: "Use when the user asks to drop a connected app, or a stale one is in the way: Beaver closes that app's connection and its session ends, like the Disconnect button. With quick-brick-xray 2.72.0 or later the app stays disconnected until it returns to the foreground or is relaunched; an older SDK reconnects within seconds, into the same session. With several apps connected, pass deviceId from beaver_status: the default device doesn't count here.",
        kind: .change,
        inputSchema: ToolSchema.object(["deviceId": ToolSchema.deviceId])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        let (_, live) = try await ctx.requireDevice(args, doing: "disconnect it", call: "devices_disconnect()",
                                                    useDefault: false, logsOnlyOK: true)
        let session = try await ctx.liveSession(live)
        await ctx.device.disconnect(live)
        return ToolResult(
            summary: "Disconnected \(StatusTools.describeDevice(session.session)) (session #\(live)).",
            structured: ["disconnected": .string(String(live)), "sessionId": JSON(live)],
            next: ["beaver_status() — an older SDK (before quick-brick-xray 2.72.0) is back within seconds, in the same session; a newer one stays away until the app is foregrounded or relaunched"],
            sessionId: live
        )
    }

    /// D94: Beaver reads the TV itself; the TV is the same logs-only device
    /// zapp-support's bridge makes (D89).
    static let connectTV: MCPTool = MCPTool(
        name: "devices_connect_tv",
        title: "Connect a smart TV",
        description: "Use when the user wants logs from a smart TV app (Vizio, Vidaa, other web TVs with remote debugging on): Beaver reads the TV over the Chrome DevTools Protocol and it shows up as a device that only sends logs — console lines, exceptions, log entries. Pass the TV's IP address and its DevTools port (Vizio 9555, Vidaa 9226, others usually 9222). An already connected TV returns its device. devices_disconnect stops reading it.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "host": ToolSchema.string("The TV's IP address, e.g. \"192.168.1.40\"."),
            "port": ToolSchema.integer("The TV's DevTools port: Vizio 9555, Vidaa 9226, others usually 9222. Default 9222."),
            "name": ToolSchema.string("What Beaver calls it, e.g. \"Living room Vizio\". Default: the app's page title @ host:port."),
        ], required: ["host"])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        guard let host = try args.string("host").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("host is required. Example: devices_connect_tv(host: \"192.168.1.40\", port: 9555)")
        }
        let port = try args.int("port") ?? 9222
        let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty)
        let id: Int64
        do {
            id = try await ctx.device.connectTV(host: host, port: port, name: name)
        } catch let error as TVBridgeError {
            throw ToolError("\(error.localizedDescription) Ask the user to check, then try again. "
                + "Example: devices_connect_tv(host: \"\(host)\", port: \(port))")
        }
        let session = try await ctx.liveSession(id)
        return ToolResult(
            summary: "Connected the TV \(StatusTools.describeDevice(session.session)) as device \"\(id)\"; it only sends logs.",
            structured: ["deviceId": .string(String(id)), "sessionId": JSON(id), "platform": .string(CDP.platform)],
            next: ["logs_query(sessionId: \(id), since: \"5m\") for what it logged",
                   "logs_wait(sessionId: \(id), filter: {minLevel: \"error\"}, timeoutMs: 30000) for its next error",
                   "devices_disconnect(deviceId: \"\(id)\") to stop reading it"],
            sessionId: id
        )
    }
}
