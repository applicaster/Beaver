//
//  WatchTools.swift
//  Beaver
//
//  Watches (design §5.10, M29): "since here, matching this", for minutes
//  to hours, without the agent looping.

import Foundation

enum WatchTools {
    static let all = [start, status, stop]

    static let startExample = "Example: watch_start(name: \"player errors\", filter: {minLevel: \"error\", subsystems: [\"player*\"]}, notify: {atCount: 10})."

    static let start = MCPTool(
        name: "watch_start",
        title: "Start a watch",
        description: "Use to keep an eye on something for minutes or hours (while the user tests), instead of looping logs_wait: counts events matching filter from now on. With notify, the user gets an attention note and a notification at the first match or at a count — you are not woken; check watch_status later. Without sessionId it follows the device into new sessions.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "name": ToolSchema.string("A name to check it by, e.g. \"player errors\". Reusing a name replaces that watch."),
            "filter": ToolSchema.filter,
            "sessionId": ToolSchema.integer("Watch only this session. Omit it to follow the device."),
            "notify": ["type": "object",
                       "description": "Tell the user: {onFirst: true} at the first match, or {atCount: 10}. Fires once."],
        ], required: ["name"])
    ) { args, ctx in
        guard let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("name is required. \(startExample)")
        }
        let notifyAt = try parseNotify(args["notify"])
        let s = try await ctx.resolveSession(args)
        let f = try await ctx.resolveFilter(args, sessionId: s.id)
        let startId = try await ctx.store.latestEventId(sessionId: s.id) ?? 0
        let watch = Watches.Watch(name: name, filter: f.filter, filterText: ToolText.describe(f.filter),
                                  follows: s.how != .given, sessionId: s.id, startId: startId,
                                  startedAt: ctx.now(), notifyAt: notifyAt, firedAt: nil)
        let replaced = await ctx.watches.add(watch)
        if notifyAt != nil { await ctx.watches.setTask(ctx.startNotifyTask(for: watch), for: name) }
        let resolved = f.notes.isEmpty ? "" : " Resolved: " + f.notes.joined(separator: "; ") + "."
        let notifyText = notifyAt.map { $0 == 1 ? " The user is notified at the first match." : " The user is notified at \($0) matches." } ?? ""
        return ToolResult(
            summary: "Watching “\(name)” in session \(s.label) after #\(startId) (\(watch.filterText))."
                + (watch.follows ? " It follows the device into new sessions." : "")
                + notifyText + (replaced ? " Replaced the earlier watch with this name." : "") + resolved,
            structured: ["name": .string(name), "sessionId": JSON(s.id), "startId": JSON(startId),
                         "startedAt": .string(watch.startedAt.ISO8601Format()), "follows": .bool(watch.follows),
                         "notifyAt": JSON(notifyAt), "replaced": .bool(replaced),
                         "resolved": .array(f.notes.map(JSON.string))],
            next: ["watch_status(name: \"\(name)\") later to see what matched",
                   "logs_query(afterId: \(startId), filter: {…same…}, order: \"oldest\") for the lines themselves"],
            sessionId: s.id
        )
    }

    static let status = MCPTool(
        name: "watch_status",
        title: "Watch status",
        description: "Use to see what a watch caught since it started: matches, first and last matching event, counts per level, subsystem and category, the sessions it covered, and whether notify fired. No name: every watch.",
        kind: .read,
        inputSchema: ToolSchema.object(["name": ToolSchema.string("The watch; omit for all.")])
    ) { args, ctx in
        let list: [Watches.Watch]
        if let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty) {
            guard let w = await ctx.watches.get(name) else {
                let active = await activeNames(ctx)
                throw ToolError("No watch “\(name)”. \(active) \(startExample)")
            }
            list = [w]
        } else {
            list = await ctx.watches.all()
        }
        guard !list.isEmpty else {
            return ToolResult(summary: "No watches. They live until Beaver quits.",
                              structured: ["watches": []], next: [startExample])
        }
        let statuses = try await list.asyncMap { try await ctx.status(of: $0) }
        return report(statuses, verb: "Watch", ctx)
    }

    static let stop = MCPTool(
        name: "watch_stop",
        title: "Stop a watch",
        description: "Use when a watch is no longer needed: returns its final status and forgets it. all: true stops every watch. The events stay; logs_query(afterId: startId) still reads them.",
        kind: .change,
        idempotent: true,
        inputSchema: ToolSchema.object([
            "name": ToolSchema.string("The watch to stop."),
            "all": ToolSchema.boolean("Stop every watch."),
        ])
    ) { args, ctx in
        if try args.bool("all") == true {
            let gone = await ctx.watches.removeAll()
            let statuses = try await gone.asyncMap { try await ctx.status(of: $0) }
            guard !statuses.isEmpty else { return ToolResult(summary: "No watches to stop.", structured: ["watches": []]) }
            return report(statuses, verb: "Stopped", ctx)
        }
        guard let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("Say which: watch_stop(name: \"player errors\"), or watch_stop(all: true).")
        }
        guard let w = await ctx.watches.remove(name) else {
            let active = await activeNames(ctx)
            return ToolResult(summary: "No watch “\(name)”; nothing to stop. \(active)",
                              structured: ["watches": []], next: ["watch_status()"])
        }
        return report([try await ctx.status(of: w)], verb: "Stopped", ctx)
    }

    static func parseNotify(_ value: JSON?) throws -> Int? {
        guard let value, value != .null else { return nil }
        let example = "Example: notify: {atCount: 10} or notify: {onFirst: true}."
        guard let object = value.object else { throw ToolError("notify must be an object. \(example)") }
        let a = ToolArguments(object)
        if let n = try a.int("atCount") {
            guard n >= 1 else { throw ToolError("atCount must be 1 or more. \(example)") }
            return n
        }
        if try a.bool("onFirst") == true { return 1 }
        throw ToolError("notify needs atCount or onFirst. \(example)")
    }

    static func activeNames(_ ctx: ToolContext) async -> String {
        let names = await ctx.watches.all().map { "“\($0.name)”" }
        return names.isEmpty ? "There are no watches." : "Watches: \(names.joined(separator: ", "))."
    }

    /// One line per watch: `“player errors” — 23 matches since 14:10:05 in #13 → #14 (…); first #…, last #…; …`.
    static func report(_ statuses: [WatchStatus], verb: String, _ ctx: ToolContext) -> ToolResult {
        func counts(_ list: [FacetCount]) -> String {
            list.prefix(10).map { "\($0.value) \($0.count)" }.joined(separator: ", ")
        }
        var lines: [String] = []
        var rows: [JSON] = []
        for s in statuses {
            let w = s.watch
            var line = "“\(w.name)” — \(s.total) match\(s.total == 1 ? "" : "es") since \(w.startedAt.formatted(date: .omitted, time: .standard))"
                + " in " + s.sessions.map { "#\($0)" }.joined(separator: " → ") + " (\(w.filterText))"
            if let first = s.first, let last = s.last { line += "; first #\(first.id), last #\(last.id)" }
            let levelText = LogLevel.allCases.reversed().compactMap { l in s.levels[l].map { "\(l.rawValue) \($0)" } }.joined(separator: ", ")
            if !levelText.isEmpty { line += "; levels \(levelText)" }
            if !s.subsystems.isEmpty { line += "; subsystems \(counts(s.subsystems))" }
            if !s.categories.isEmpty { line += "; categories \(counts(s.categories))" }
            if let at = w.notifyAt {
                line += "; notify at \(at): " + (w.firedAt.map { "fired \($0.formatted(date: .omitted, time: .standard))" } ?? "not yet")
            }
            lines.append(line)
            rows.append([
                "name": .string(w.name), "total": JSON(s.total), "sessions": .array(s.sessions.map { JSON($0) }),
                "startId": JSON(w.startId), "startedAt": .string(w.startedAt.ISO8601Format()),
                "follows": .bool(w.follows), "filter": .string(w.filterText),
                "firstId": JSON(s.first?.id), "lastId": JSON(s.last?.id),
                "levels": .object(Dictionary(uniqueKeysWithValues: s.levels.map { ($0.key.rawValue, JSON($0.value)) })),
                "subsystems": .array(s.subsystems.prefix(50).map { ["value": .string($0.value), "count": JSON($0.count)] }),
                "categories": .array(s.categories.prefix(50).map { ["value": .string($0.value), "count": JSON($0.count)] }),
                "notifyAt": JSON(w.notifyAt), "fired": .bool(w.firedAt != nil),
                "firedAt": JSON(w.firedAt?.ISO8601Format()),
            ])
        }
        let head = statuses.count == 1
            ? "\(verb == "Stopped" ? "Stopped " : "")\(lines[0])"
            : "\(verb == "Stopped" ? "Stopped \(statuses.count) watches" : "\(statuses.count) watches")."
        let next = statuses.first(where: { $0.first != nil }).map { s in
            ["logs_get(ids: [\(s.first?.id ?? 0)]) for the first match",
             "logs_query(afterId: \(s.watch.startId), filter: {…}, order: \"oldest\")"]
        } ?? ["watch_status() again later"]
        return ToolResult(summary: head, body: lines.joined(separator: "\n"),
                          structured: ["watches": .array(rows)], next: next)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
