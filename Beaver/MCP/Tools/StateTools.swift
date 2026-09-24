//
//  StateTools.swift
//  Beaver
//

import Foundation

enum StateTools {
    static let all = [commandsList, bookmarksList, filtersList]

    static let commandsList = MCPTool(
        name: "commands_list",
        title: "Device commands",
        description: "Use to see which commands the connected app accepts, with syntax where Beaver knows it. The app reports them when it connects (cmdlist).",
        kind: .read,
        inputSchema: ToolSchema.object([:])
    ) { _, ctx in
        let hints = await ctx.ui.snapshot().commands
        guard !hints.isEmpty else {
            return ToolResult(summary: "No command list yet: no device is connected, or it hasn't answered cmdlist.",
                              structured: ["commands": []], next: ["beaver_status()"])
        }
        let lines = hints.map { h in
            [h.syntax ?? h.name, h.description].compactMap { $0 }.joined(separator: " — ")
        }
        let nextSuggestions = hints.first.map { h in ["logs_query(filter: {search: \"\(h.name)\"}) to see what a command logged"] } ?? []
        return ToolResult(
            summary: "The app accepts \(hints.count) command(s).",
            body: lines.joined(separator: "\n"),
            structured: ["commands": .array(hints.map { h in
                ["name": .string(h.name), "syntax": JSON(h.syntax), "description": JSON(h.description), "group": .string(h.group)]
            })],
            next: nextSuggestions
        )
    }

    static let bookmarksList = MCPTool(
        name: "bookmarks_list",
        title: "Bookmarks",
        description: "Use to see what the user bookmarked in a session: events and network requests they marked as important.",
        kind: .read,
        inputSchema: ToolSchema.object(["sessionId": ToolSchema.sessionId])
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        let events = try await ctx.store.bookmarks(sessionId: s.id).map(\.event)
        let requestIds = try await ctx.store.networkBookmarkIds(sessionId: s.id)
        let requests = try await ctx.store.networkEntries(sessionId: s.id).filter { requestIds.contains($0.id) }
        let lines = events.map(ToolText.eventLine) + requests.map(NetworkTools.line)
        let nextSuggestions = events.first.map { e in ["logs_get(ids: [\(e.id)])"] } ?? ["logs_query()"]
        return ToolResult(
            summary: "Session \(s.label): \(events.count) bookmarked event(s), \(requests.count) bookmarked request(s).",
            body: lines.joined(separator: "\n"),
            structured: ["sessionId": JSON(s.id),
                         "events": .array(events.map { ["id": JSON($0.id), "line": .string(ToolText.eventLine($0))] }),
                         "requests": .array(requests.map { ["id": JSON($0.id), "line": .string(NetworkTools.line($0))] })],
            next: nextSuggestions,
            sessionId: s.id
        )
    }

    static let filtersList = MCPTool(
        name: "filters_list",
        title: "Saved filters",
        description: "Use to see the filters the user saved in Beaver, with what each one matches.",
        kind: .read,
        inputSchema: ToolSchema.object([:])
    ) { _, ctx in
        let saved = try await ctx.store.savedFilters()
        let nextSuggestions: [String]
        if saved.isEmpty {
            nextSuggestions = ["beaver_guide(topic: \"organise\")"]
        } else {
            nextSuggestions = saved.prefix(1).map { f in
                let filterRepr = ToolText.describe(f.filter)
                return "logs_query(filter: {…\(filterRepr)…}) to apply the \"\(f.name)\" filter"
            }
        }
        return ToolResult(
            summary: saved.isEmpty ? "No saved filters." : "\(saved.count) saved filter(s).",
            body: saved.map { "\($0.name) — \(ToolText.describe($0.filter))" }.joined(separator: "\n"),
            structured: ["filters": .array(saved.map { ["name": .string($0.name), "describes": .string(ToolText.describe($0.filter))] })],
            next: nextSuggestions
        )
    }
}
