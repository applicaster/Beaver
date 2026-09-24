//
//  LogTools.swift
//  Beaver
//

import Foundation

enum LogTools {
    static var all: [MCPTool] { [facets, query] }

    static let facets = MCPTool(
        name: "logs_facets",
        title: "Log facets",
        description: "Use before logs_query, and to see what arrived in a time range: counts per level, subsystem and category. Subsystem names are namespaced strings you will not guess, so read them here first.",
        kind: .read,
        inputSchema: ToolSchema.object(
            ["sessionId": ToolSchema.sessionId, "filter": ToolSchema.filter]
                .merging(ToolSchema.range) { first, _ in first })
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        let f = try await ctx.resolveFilter(args["filter"], sessionId: s.id)
        let r = try await ctx.resolveRange(args, sessionId: s.id)
        let levels = try await ctx.store.levelCounts(sessionId: s.id, filter: f.filter, afterId: r.afterId, beforeId: r.beforeId)
        let subsystems = try await ctx.store.facetCounts(sessionId: s.id, facet: .subsystem, filter: f.filter, afterId: r.afterId, beforeId: r.beforeId)
        let categories = try await ctx.store.facetCounts(sessionId: s.id, facet: .category, filter: f.filter, afterId: r.afterId, beforeId: r.beforeId)
        let inRange = levels.values.reduce(0, +)
        let matching = levels.filter { $0.key.severity >= f.filter.minLevel.severity }.values.reduce(0, +)

        let top = 30
        func list(_ counts: [FacetCount]) -> String {
            let shown = counts.prefix(top).map { "\($0.value) \($0.count)" }.joined(separator: ", ")
            return counts.count > top ? shown + " (+\(counts.count - top) more)" : shown
        }
        let levelLine = LogLevel.allCases.reversed()
            .compactMap { l in levels[l].map { "\(l.rawValue) \($0)" } }.joined(separator: " · ")
        let notes = f.notes + r.notes
        return ToolResult(
            summary: "Session \(s.label): \(matching) of \(inRange) events match (\(ToolText.describe(f.filter)))."
                + (notes.isEmpty ? "" : " Resolved: " + notes.joined(separator: "; ") + "."),
            body: ["Levels: \(levelLine.isEmpty ? "none" : levelLine)",
                   "Subsystems: \(subsystems.isEmpty ? "none" : list(subsystems))",
                   "Categories: \(categories.isEmpty ? "none" : list(categories))"].joined(separator: "\n"),
            structured: [
                "sessionId": JSON(s.id), "matching": JSON(matching), "inRange": JSON(inRange),
                "levels": .object(Dictionary(uniqueKeysWithValues: levels.map { ($0.key.rawValue, JSON($0.value)) })),
                "subsystems": .array(subsystems.prefix(100).map { ["value": .string($0.value), "count": JSON($0.count)] }),
                "subsystemsMore": JSON(max(0, subsystems.count - 100)),
                "categories": .array(categories.prefix(100).map { ["value": .string($0.value), "count": JSON($0.count)] }),
                "categoriesMore": JSON(max(0, categories.count - 100)),
                "resolved": .array(notes.map(JSON.string)),
            ],
            next: (subsystems.first.map { ["logs_query(filter: {subsystems: [\"\($0.value)\"]})"] } ?? [])
                + ["logs_query(filter: {minLevel: \"warning\"})"],
            sessionId: s.id
        )
    }

    static let query = MCPTool(
        name: "logs_query",
        title: "Query logs",
        description: "Use to read log lines: filter by level, text, regex, exclusions, subsystem and category, id range or time (since: \"5m\"). One line per event, ids first; newest first by default. Full payloads: logs_get.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "filter": ToolSchema.filter,
            "limit": ToolSchema.integer("Rows per page. Default 100, max 500."),
            "order": ToolSchema.string("newest (default) or oldest first.", oneOf: ["newest", "oldest"]),
            "includeData": ToolSchema.boolean("Add each event's data payload, cut at 2 KB. Default false; logs_get gives it in full."),
        ].merging(ToolSchema.range) { first, _ in first })
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        let f = try await ctx.resolveFilter(args["filter"], sessionId: s.id)
        let r = try await ctx.resolveRange(args, sessionId: s.id)
        let limit = try args.limit(default: 100, max: 500)
        let newestFirst = (try args.string("order"))?.lowercased() != "oldest"
        let includeData = try args.bool("includeData") ?? false
        let page = try await ctx.store.eventPage(sessionId: s.id, filter: f.filter, afterId: r.afterId,
                                                 beforeId: r.beforeId, limit: limit, newestFirst: newestFirst,
                                                 includePayloads: includeData)
        let notes = f.notes + r.notes
        let resolved = notes.isEmpty ? "" : " Resolved: " + notes.joined(separator: "; ") + "."
        guard let last = page.events.last else {
            return ToolResult(
                summary: "No events match in session \(s.label) (\(ToolText.describe(f.filter))).\(resolved)",
                structured: ["sessionId": JSON(s.id), "total": 0, "events": [], "nextCursor": .null,
                             "resolved": .array(notes.map(JSON.string))],
                next: ["logs_facets() to see what the session has", "loosen the filter or widen since"],
                sessionId: s.id
            )
        }
        let hasMore = page.total > page.events.count
        let cursor: JSON = hasMore ? (newestFirst ? ["beforeId": JSON(last.id)] : ["afterId": JSON(last.id)]) : .null
        var lines: [String] = []
        var rows: [JSON] = []
        for e in page.events {
            var line = ToolText.eventLine(e)
            var row: [String: JSON] = [
                "id": JSON(e.id), "time": .string(e.fullTimestamp), "level": .string(e.level.rawValue),
                "subsystem": .string(e.subsystem), "category": .string(e.category),
                "message": .string(String(e.message.prefix(ToolText.messageCap))),
            ]
            if includeData, let data = e.dataJSON {
                let capped = ToolText.capped(data, maxBytes: 2048)
                line += "\n    data: " + capped.text + (capped.truncated ? " … (logs_get for all)" : "")
                row["data"] = .string(capped.text)
                row["dataTruncated"] = .bool(capped.truncated)
            }
            lines.append(line)
            rows.append(.object(row))
        }
        var next = ["logs_get(ids: [\(page.events[0].id)]) for the full event"]
        if hasMore {
            next.append("logs_query(… same filter …, \(newestFirst ? "beforeId" : "afterId"): \(last.id)) for the next page")
        }
        return ToolResult(
            summary: "\(page.total) event(s) match in session \(s.label) (\(ToolText.describe(f.filter))); "
                + "showing \(page.events.count), \(newestFirst ? "newest" : "oldest") first.\(resolved)",
            body: lines.joined(separator: "\n"),
            structured: ["sessionId": JSON(s.id), "total": JSON(page.total), "events": .array(rows),
                         "nextCursor": cursor, "resolved": .array(notes.map(JSON.string))],
            next: next,
            sessionId: s.id
        )
    }
}
