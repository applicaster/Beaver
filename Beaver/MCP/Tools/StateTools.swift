//
//  StateTools.swift
//  Beaver
//

import Foundation

enum StateTools {
    static let all = [commandsList, bookmarksList, bookmarksSet, filtersList, filtersSave, filtersDelete]

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

    static let bookmarksSet = MCPTool(
        name: "bookmarks_set",
        title: "Bookmark",
        description: "Use to mark an event or a network request for the user (a star in Beaver, and in bookmarks_list), or to remove the mark with on: false. Pass eventId or networkId.",
        kind: .change,
        idempotent: true,
        inputSchema: ToolSchema.object([
            "eventId": ToolSchema.integer("An event id from logs_query."),
            "networkId": ToolSchema.integer("A request id from network_query."),
            "on": ToolSchema.boolean("true to bookmark (default), false to remove the bookmark."),
        ])
    ) { args, ctx in
        let on = try args.bool("on") ?? true
        let eventId = try args.int64("eventId")
        let networkId = try args.int64("networkId")
        switch (eventId, networkId) {
        case (let id?, nil):
            guard let e = try await ctx.store.events(ids: [id]).first else {
                throw ToolError("No event #\(id). Example: bookmarks_set(eventId: 48211) with an id from logs_query.")
            }
            if on {
                try await ctx.store.addBookmark(eventId: id, sessionId: e.sessionId)
            } else {
                try await ctx.store.removeBookmark(eventId: id, sessionId: e.sessionId)
            }
            return ToolResult(summary: on ? "Bookmarked event #\(id)." : "Removed the bookmark from event #\(id).",
                              structured: ["eventId": JSON(id), "on": .bool(on), "sessionId": JSON(e.sessionId)],
                              next: ["bookmarks_list(sessionId: \(e.sessionId))"],
                              sessionId: e.sessionId, links: [.event(id)])
        case (nil, let id?):
            guard let sid = try await ctx.store.networkEntrySessionId(id: id) else {
                throw ToolError("No request #\(id). Example: bookmarks_set(networkId: 391) with an id from network_query.")
            }
            if try await ctx.store.networkBookmarkIds(sessionId: sid).contains(id) != on {
                try await ctx.store.toggleNetworkBookmark(entryId: id, sessionId: sid)
            }
            return ToolResult(summary: on ? "Bookmarked request #\(id)." : "Removed the bookmark from request #\(id).",
                              structured: ["networkId": JSON(id), "on": .bool(on), "sessionId": JSON(sid)],
                              next: ["bookmarks_list(sessionId: \(sid))"],
                              sessionId: sid, links: [.network(id)])
        default:
            throw ToolError("Pass eventId or networkId (one of them). Example: bookmarks_set(eventId: 48211) or bookmarks_set(networkId: 391, on: false).")
        }
    }

    static let filtersSave = MCPTool(
        name: "filters_save",
        title: "Save a filter",
        description: "Use to save a named log filter the user can pick in Beaver's Log feed (filters_list shows them). Saving under an existing name replaces it. Subsystem and category patterns are resolved to exact names first.",
        kind: .change,
        idempotent: true,
        inputSchema: ToolSchema.object([
            "name": ToolSchema.string("The name the user sees, e.g. \"Auth problems\"."),
            "filter": ToolSchema.filter,
            "sessionId": ToolSchema.integer("Resolve subsystem / category patterns against this session. Default: live, viewed, most recent."),
        ], required: ["name", "filter"])
    ) { args, ctx in
        let example = "Example: filters_save(name: \"Auth problems\", filter: {minLevel: \"warning\", subsystems: [\"*auth*\"]})."
        guard let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("name is required. \(example)")
        }
        // A filter without subsystems or categories needs no session, so
        // this works on a fresh install too.
        let sessionId: Int64 = args["sessionId"] != nil
            ? try await ctx.resolveSession(args).id
            : ((try? await ctx.resolveSession(args))?.id ?? 0)
        let f = try await ctx.resolveFilter(args, sessionId: sessionId)
        guard !f.filter.isEmpty else { throw ToolError("filter is empty: a saved filter needs at least one condition. \(example)") }
        let existed = try await ctx.store.savedFilters().contains { $0.name == name }
        try await ctx.store.upsertSavedFilter(name: name, filter: f.filter)
        let resolved = f.notes.isEmpty ? "" : " Resolved: " + f.notes.joined(separator: "; ") + "."
        return ToolResult(
            summary: "Saved filter “\(name)”: \(ToolText.describe(f.filter))" + (existed ? " (replaced the old one)." : ".") + resolved,
            structured: ["name": .string(name), "describes": .string(ToolText.describe(f.filter)),
                         "replaced": .bool(existed), "resolved": .array(f.notes.map(JSON.string))],
            next: ["filters_list()", "logs_query(filter: {…same…}) to see what it matches"],
            links: [.savedFilter(name)]
        )
    }

    static let filtersDelete = MCPTool(
        name: "filters_delete",
        title: "Delete a saved filter",
        description: "Use when the user asks to remove one of their saved filters, by name (filters_list shows them).",
        kind: .destructive,
        inputSchema: ToolSchema.object(["name": ToolSchema.string("The saved filter's name.")], required: ["name"])
    ) { args, ctx in
        let saved = try await ctx.store.savedFilters()
        let names = saved.map(\.name).joined(separator: ", ")
        guard let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("name is required. Saved: \(names.isEmpty ? "none" : names). Example: filters_delete(name: \"Auth problems\").")
        }
        guard let match = saved.first(where: { $0.name == name })
                ?? saved.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolError("No saved filter “\(name)”. Saved: \(names.isEmpty ? "none" : names). Example: filters_delete(name: \"\(saved.first?.name ?? "Auth problems")\").")
        }
        try await ctx.store.deleteSavedFilter(id: match.id)
        return ToolResult(summary: "Deleted saved filter “\(match.name)” (\(ToolText.describe(match.filter))).",
                          structured: ["name": .string(match.name)],
                          next: ["filters_list()"])
    }
}
