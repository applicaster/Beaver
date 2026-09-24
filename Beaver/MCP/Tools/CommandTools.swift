//
//  CommandTools.swift
//  Beaver
//

import Foundation

enum CommandTools {
    static let all = [send]

    static let maxCollectMillis = 30_000

    static let send = MCPTool(
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
    ) { args, ctx in
        guard let command = try args.string("command").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("command is required. Example: commands_send(command: \"storage.list\") — commands_list() shows what the app accepts.")
        }
        _ = try await ctx.requireDevice(args, doing: "send a command")
        let session = try await ctx.resolveSession(ToolArguments())
        let collect = min(maxCollectMillis, max(0, try args.int("collectLogsMs") ?? 0))
        let limit = try args.limit(default: 100, max: 500)
        let filter = collect > 0 ? try await ctx.resolveFilter(args, sessionId: session.id)
                                 : ResolvedFilter(filter: .none, notes: [])
        let before = try await ctx.store.latestEventId(sessionId: session.id) ?? 0

        await ctx.device.send(command: command)
        await ctx.ui.didSendCommand(command)
        ctx.watchForDisconnect(after: command, sessionId: session.id)

        guard collect > 0 else {
            return ToolResult(
                summary: "Sent \"\(command)\" to the app (session \(session.label)).",
                structured: ["sent": .string(command), "sessionId": JSON(session.id), "afterId": JSON(before)],
                next: ["logs_wait(afterId: \(before), timeoutMs: 15000) for what it logs",
                       "commands_send(command: \"\(command)\", collectLogsMs: 5000) to send and collect in one call"],
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
        next.append(w.events.last.map { "logs_wait(afterId: \($0.id), …) for what comes next" }
            ?? "logs_wait(afterId: \(before), timeoutMs: 15000) in case the app is slow")
        return ToolResult(
            summary: "Sent \"\(command)\"; \(w.total) event(s) logged in \(collect) ms (\(ToolText.describe(filter.filter))).\(resolved)\(follow)",
            body: w.events.map(ToolText.eventLine).joined(separator: "\n"),
            structured: .object(structured),
            next: next,
            sessionId: w.sessionId
        )
    }
}
