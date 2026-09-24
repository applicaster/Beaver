//
//  LogTools.swift
//  Beaver
//

import Foundation

enum LogTools {
    static var all: [MCPTool] { [facets, query, get, wait, clear] }

    static let maxWaitMillis = 60_000

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
        let f = try await ctx.resolveFilter(args, sessionId: s.id)
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
        let f = try await ctx.resolveFilter(args, sessionId: s.id)
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

    static let get = MCPTool(
        name: "logs_get",
        title: "Get events",
        description: "Use when a log line needs its full message, data and context payloads. Up to 50 ids from logs_query or logs_wait. Payloads over 256 KB are cut, with truncated: true.",
        kind: .read,
        inputSchema: ToolSchema.object(["ids": ToolSchema.integers("Event ids, at most 50.")], required: ["ids"])
    ) { args, ctx in
        let ids = try args.int64s("ids") ?? []
        guard !ids.isEmpty else {
            throw ToolError("ids is required. Example: logs_get(ids: [48211]) — ids are the #numbers in logs_query rows.")
        }
        guard ids.count <= 50 else {
            throw ToolError("At most 50 ids per call; you sent \(ids.count). Split them.")
        }
        let events = try await ctx.store.events(ids: Set(ids)).sorted { $0.id < $1.id }
        let missing = ids.filter { id in !events.contains { $0.id == id } }
        var blocks: [String] = []
        var rows: [JSON] = []
        for e in events {
            let data = e.dataJSON.map { ToolText.capped($0, maxBytes: ToolText.payloadCap) }
            let context = e.contextJSON.map { ToolText.capped($0, maxBytes: ToolText.payloadCap) }
            var block = "#\(e.id) \(e.fullTimestamp) \(e.level.rawValue.uppercased()) "
                + (e.category.isEmpty ? e.subsystem : "\(e.subsystem)/\(e.category)") + "\n" + e.message
            if let data { block += "\ndata: " + data.text + (data.truncated ? " … [truncated]" : "") }
            if let context { block += "\ncontext: " + context.text + (context.truncated ? " … [truncated]" : "") }
            blocks.append(block)
            // Parsed when whole and valid, so the agent gets structure; the raw text otherwise.
            func payload(_ p: (text: String, truncated: Bool)?) -> JSON {
                guard let p else { return .null }
                if !p.truncated, let parsed = try? JSON.parse(Data(p.text.utf8)) { return parsed }
                return .string(p.text)
            }
            rows.append([
                "id": JSON(e.id), "sessionId": JSON(e.sessionId), "time": .string(e.fullTimestamp),
                "level": .string(e.level.rawValue), "subsystem": .string(e.subsystem),
                "category": .string(e.category), "message": .string(e.message),
                "data": payload(data), "dataTruncated": .bool(data?.truncated ?? false),
                "context": payload(context), "contextTruncated": .bool(context?.truncated ?? false),
            ])
        }
        return ToolResult(
            summary: "\(events.count) event(s)" + (missing.isEmpty ? "." : "; not found: \(missing.map(String.init).joined(separator: ", ")).")
                + (rows.contains { $0["dataTruncated"] == true || $0["contextTruncated"] == true } ? " Some payloads were cut at 256 KB." : ""),
            body: blocks.joined(separator: "\n\n"),
            structured: ["events": .array(rows), "missing": .array(missing.map { JSON($0) })],
            next: events.last.map { ["logs_query(afterId: \($0.id), order: \"oldest\") for what came after"] } ?? ["logs_query()"],
            sessionId: events.first?.sessionId,
            // Five at most: a row with fifty link buttons helps nobody.
            links: events.prefix(5).map { .event($0.id) }
        )
    }

    static let wait = MCPTool(
        name: "logs_wait",
        title: "Wait for logs",
        description: "Use after you or the user do something on the device, to wait until a matching event is logged. Returns as soon as one arrives, or when timeoutMs passes (default 15000, max 60000). Pass afterId from an earlier result; without it, only events from now on count. Without sessionId it follows the device: if the app restarts it carries on in the new session and says so (sessionChanged). For minutes or longer, use watch_start.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.integer("Stay on this session; if it ends the call returns sessionEnded. Omit it to follow the device."),
            "filter": ToolSchema.filter,
            "afterId": ToolSchema.integer("Only events after this id. Default: the latest event now."),
            "timeoutMs": ToolSchema.integer("How long to wait. Default 15000, max 60000."),
            "limit": ToolSchema.integer("Most events to return. Default 50, max 500."),
        ])
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        let f = try await ctx.resolveFilter(args, sessionId: s.id)
        let requested = try args.int("timeoutMs") ?? 15_000
        let timeout = min(maxWaitMillis, max(0, requested))
        let limit = try args.limit(default: 50, max: 500)
        let start: Int64
        if let afterIdArg = try args.int64("afterId") {
            start = afterIdArg
        } else {
            start = try await ctx.store.latestEventId(sessionId: s.id) ?? 0
        }
        let w = try await ctx.waitForEvents(from: s, afterId: start, filter: f.filter, limit: limit,
                                            timeout: .milliseconds(timeout), untilFirst: true)
        let notes = f.notes
        let resolved = notes.isEmpty ? "" : " Resolved: " + notes.joined(separator: "; ") + "."
        let follow = w.followText.isEmpty ? "" : " " + w.followText
        var structured: [String: JSON] = [
            "sessionId": JSON(w.sessionId), "timedOut": .bool(w.timedOut), "afterId": JSON(start),
            "timeoutMs": JSON(timeout), "total": JSON(w.total), "hasMore": .bool(w.total > w.events.count),
            "events": .array(w.events.map { ["id": JSON($0.id), "line": .string(ToolText.eventLine($0))] }),
            "resolved": .array(notes.map(JSON.string)),
        ]
        structured.merge(w.followFields) { current, _ in current }
        if let last = w.events.last {
            structured["lastId"] = JSON(last.id)
            return ToolResult(
                summary: "\(w.total) new event(s) matched in session \(s.label) after #\(start) (\(ToolText.describe(f.filter))).\(resolved)\(follow)",
                body: w.events.map(ToolText.eventLine).joined(separator: "\n"),
                structured: .object(structured),
                next: ["logs_get(ids: [\(w.events[0].id)])", "logs_wait(afterId: \(last.id), …) for the next one"],
                sessionId: w.sessionId
            )
        }
        let why = w.sessionEnded ? "The session ended before anything matched" : "Nothing matched in \(timeout / 1000) s"
        return ToolResult(
            summary: "\(why) (session \(s.label), after #\(start), \(ToolText.describe(f.filter))).\(resolved)\(follow)",
            structured: .object(structured),
            next: w.sessionEnded
                ? ["beaver_status() to see the device's new session", "logs_wait(…) without sessionId to follow the device"]
                : ["logs_wait(afterId: \(start), …) to keep waiting", "logs_query(afterId: \(start)) to see what did arrive"],
            sessionId: w.sessionId
        )
    }

    static let clear = MCPTool(
        name: "logs_clear",
        title: "Clear the log view",
        description: "Use when the user wants a clean screen before reproducing something: hides the events up to now in Beaver's Log feed, like its Clear button (⌘K). Deletes nothing — logs_query still sees every event. Acts on the session the user is viewing.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.integer("The session the user is viewing (the default). Clear only acts on that one."),
        ])
    ) { args, ctx in
        let host = await ctx.ui.snapshot()
        guard let viewing = host.viewingSessionId else {
            throw ToolError("The user isn't viewing a session, so there's nothing on screen to clear. beaver_status() shows what is connected.")
        }
        if let wanted = try args.int64("sessionId"), wanted != viewing {
            throw ToolError("Clear only acts on the session the user is viewing (#\(viewing)); you passed #\(wanted). Omit sessionId, or ask the user to open session #\(wanted) first.")
        }
        guard let watermark = try await ctx.store.latestEventId(sessionId: viewing) else {
            throw ToolError("Session #\(viewing) has no events; nothing to clear. Example: logs_wait(timeoutMs: 15000) to wait for the first one.")
        }
        await ctx.ui.clearLogView(sessionId: viewing, through: watermark)
        return ToolResult(
            summary: "Cleared the Log feed of session #\(viewing): events up to #\(watermark) are hidden on screen. Nothing was deleted.",
            structured: ["sessionId": JSON(viewing), "watermark": JSON(watermark)],
            next: ["logs_wait(afterId: \(watermark), …) for what comes next", "logs_query(afterId: \(watermark))"],
            sessionId: viewing
        )
    }
}
