//
//  CompareTool.swift
//  Beaver
//
//  sessions_compare (D81): the Sessions tab's Compare, for agents.

import Foundation

extension SessionTools {
    static let compare = MCPTool(
        name: "sessions_compare",
        title: "Compare two sessions",
        description: "Use when something works in one session and not in another (app 4.5 vs 4.6, device A vs B): log lines only in one of them (numbers, ids, times and query values normalised), warnings and errors per subsystem A vs B, requests only in one, requests whose status class or median duration changed, storage keys that differ (each layer's latest snapshot, with the fields inside JSON values), and App Info that differs (app/SDK/QuickBrick versions, Zapp ids, device, plugin versions). a is the session that works, b the one that doesn't. Both must be the same app (same bundle id, else the same app name); other versions and devices are fine.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "a": ToolSchema.integer("The session that works (sessions_list shows ids)."),
            "b": ToolSchema.integer("The session that fails."),
            "sections": ToolSchema.strings("Any of logs, network, storage, appInfo (default: all four)."),
            "limit": ToolSchema.integer("Rows per list. Default 20, max 200."),
        ], required: ["a", "b"])
    ) { args, ctx in
        let example = "Example: sessions_compare(a: 12, b: 14, sections: [\"logs\", \"network\"])."
        guard let a = try args.int64("a"), let b = try args.int64("b") else {
            throw ToolError("a and b are required: the session that works and the one that fails; sessions_list() shows the ids. \(example)")
        }
        guard a != b else { throw ToolError("a and b are both session #\(a); pick two. \(example)") }
        for id in [a, b] { _ = try await ctx.resolveSession(ToolArguments(["sessionId": JSON(id)])) }
        var sections = Set(SessionCompare.Section.allCases)
        if let raw = try args.strings("sections"), !raw.isEmpty {
            sections = try Set(raw.map { name in
                guard let s = SessionCompare.Section.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
                    throw ToolError("Unknown section \"\(name)\". Use logs, network, storage or appInfo. \(example)")
                }
                return s
            })
        }
        let limit = try args.limit(default: 20, max: 200)
        let r: SessionCompare.Result
        do {
            r = try await SessionCompare.run(store: ctx.store, a: a, b: b, sections: sections, zapp: ctx.zapp)
        } catch let different as SessionCompare.DifferentApps {
            throw ToolError((different.errorDescription ?? "") + " sessions_list() shows each session's app; pick two of the same app (other versions or devices are fine). \(example)")
        }

        var parts: [String] = [], lines: [String] = [], next: [String] = []
        var structured: [String: JSON] = ["a": JSON(a), "b": JSON(b)]
        func list<T>(_ title: String, _ items: [T], _ line: (T) -> String) {
            guard !items.isEmpty else { return }
            lines.append("\(title) (\(items.count)):")
            lines += items.prefix(limit).map { "  " + line($0) }
            if items.count > limit { lines.append("  … \(items.count - limit) more; raise limit (max 200)") }
        }

        if let logs = r.logs {
            let up = logs.levels.filter(\.increased).count
            parts.append("logs: \(logs.onlyInA.count) pattern(s) only in #\(a), \(logs.onlyInB.count) only in #\(b), warnings/errors up in \(up) subsystem(s)")
            func line(_ p: SessionCompare.PatternCount) -> String {
                "\(p.level.rawValue) \(p.subsystem): \(p.pattern) ×\(p.count) (first #\(p.firstId))"
            }
            list("Only in #\(b)", logs.onlyInB, line)
            list("Only in #\(a)", logs.onlyInA, line)
            list("Warnings/errors per subsystem, #\(a) → #\(b)", logs.levels) {
                "\($0.increased ? "▲" : "▼") \($0.subsystem) \($0.level.rawValue): \($0.a) → \($0.b)"
            }
            if logs.capped {
                lines.append("Capped: a session has over \(SessionCompare.patternCap) patterns; the rarest weren't compared.")
            }
            if let p = logs.onlyInB.first {
                next.append("logs_get(ids: [\(p.firstId)])")
                next.append("logs_query(sessionId: \(b), filter: {minLevel: \"\(p.level.rawValue)\", subsystems: [\"\(p.subsystem)\"]})")
            }
            func patterns(_ ps: [SessionCompare.PatternCount]) -> JSON {
                .array(ps.prefix(limit).map {
                    ["subsystem": .string($0.subsystem), "pattern": .string($0.pattern),
                     "level": .string($0.level.rawValue), "count": JSON($0.count), "firstId": JSON($0.firstId)]
                })
            }
            structured["logs"] = [
                "onlyInA": patterns(logs.onlyInA), "onlyInB": patterns(logs.onlyInB),
                "onlyInACount": JSON(logs.onlyInA.count), "onlyInBCount": JSON(logs.onlyInB.count),
                "levels": .array(logs.levels.prefix(limit).map {
                    ["subsystem": .string($0.subsystem), "level": .string($0.level.rawValue),
                     "a": JSON($0.a), "b": JSON($0.b), "increased": .bool($0.increased)]
                }),
                "capped": .bool(logs.capped),
            ]
        }

        if let net = r.network {
            parts.append("network: \(net.onlyInA.count) request(s) only in #\(a), \(net.onlyInB.count) only in #\(b), \(net.statusChanged.count) status change(s), \(net.durationChanged.count) duration change(s)")
            func line(_ g: SessionCompare.RequestGroup) -> String {
                "\(g.key) ×\(g.count) \(g.statusText) (first #\(g.firstId))"
            }
            list("Requests only in #\(b)", net.onlyInB, line)
            list("Requests only in #\(a)", net.onlyInA, line)
            list("Status changed", net.statusChanged) {
                "\($0.key): \($0.a.statusText) → \($0.b.statusText) (#\($0.a.firstId) → #\($0.b.firstId))"
            }
            list("Median duration changed", net.durationChanged) {
                "\($0.key): \($0.a.medianMs ?? 0) ms → \($0.b.medianMs ?? 0) ms (#\($0.a.firstId) → #\($0.b.firstId))"
            }
            if let p = net.statusChanged.first {
                next.append("network_get(id: \(p.b.firstId))")
                next.append("network_query(sessionId: \(b), status: \"errors\")")
            } else if let g = net.onlyInB.first {
                next.append("network_get(id: \(g.firstId))")
            }
            func groups(_ gs: [SessionCompare.RequestGroup]) -> JSON {
                .array(gs.prefix(limit).map {
                    ["key": .string($0.key), "count": JSON($0.count), "firstId": JSON($0.firstId),
                     "status": .string($0.statusText), "medianMs": JSON($0.medianMs)]
                })
            }
            func side(_ g: SessionCompare.RequestGroup) -> JSON {
                ["firstId": JSON(g.firstId), "count": JSON(g.count), "status": .string(g.statusText), "medianMs": JSON(g.medianMs)]
            }
            func pairs(_ ps: [SessionCompare.RequestPair]) -> JSON {
                .array(ps.prefix(limit).map { ["key": .string($0.key), "a": side($0.a), "b": side($0.b)] })
            }
            structured["network"] = [
                "onlyInA": groups(net.onlyInA), "onlyInB": groups(net.onlyInB),
                "statusChanged": pairs(net.statusChanged), "durationChanged": pairs(net.durationChanged),
            ]
        }

        if let storage = r.storage {
            let total = storage.layers.reduce(0) { $0 + $1.changes.count }
            parts.append("storage: \(total) key(s) differ" + (storage.layers.isEmpty ? " (no storage on either side)" : ""))
            for layer in storage.layers {
                if let missing = layer.missing { lines.append("Storage \(layer.layer.displayName): not compared — \(missing)") }
                list("Storage \(layer.layer.displayName), #\(a) → #\(b)", layer.changes) { c in
                    let head = "\(c.kind == .added ? "+" : c.kind == .removed ? "−" : "~") \(c.path)"
                    if !c.fields.isEmpty {
                        return head + ": " + c.fields.prefix(5).map { "\($0.path) \($0.old ?? "∅") → \($0.new ?? "∅")" }.joined(separator: "; ")
                            + (c.fields.count > 5 ? "; …" : "")
                    }
                    return head + ": \(ToolText.capped(c.old ?? "∅", maxBytes: 200).text) → \(ToolText.capped(c.new ?? "∅", maxBytes: 200).text)"
                }
            }
            if total > 0 { next.append("storage_diff(sessionId: \(b)) for what changed within #\(b)") }
            structured["storage"] = .object(Dictionary(uniqueKeysWithValues: storage.layers.map { layer in
                (layer.layer.rawValue, [
                    "missing": JSON(layer.missing),
                    "changeCount": JSON(layer.changes.count),
                    "changes": .array(layer.changes.prefix(limit).map { c in
                        ["path": .string(c.path), "kind": .string(c.kind.rawValue), "a": JSON(c.old), "b": JSON(c.new),
                         "fields": .array(c.fields.prefix(20).map { ["path": .string($0.path), "kind": .string($0.kind.rawValue),
                                                                     "a": JSON($0.old), "b": JSON($0.new)] })]
                    }),
                ] as JSON)
            }))
        }

        if let info = r.appInfo {
            parts.append("app info: \(info.values.count) value(s) and \(info.plugins.count) plugin(s) differ")
            list("App Info, #\(a) → #\(b)", info.values) { "\($0.label): \($0.a ?? "∅") → \($0.b ?? "∅")" }
            list("Plugins, #\(a) (\(info.pluginsSourceA)) → #\(b) (\(info.pluginsSourceB))", info.plugins) { p in
                switch (p.a, p.b) {
                case (nil, let v?): "+ \(p.id) \(v)"
                case (let v?, nil): "− \(p.id) \(v)"
                default: "~ \(p.id) \(p.a ?? "") → \(p.b ?? "")"
                }
            }
            if !info.values.isEmpty || !info.plugins.isEmpty { next.append("app_info(sessionId: \(b)) for everything about #\(b)") }
            structured["appInfo"] = [
                "values": .array(info.values.prefix(limit).map { ["label": .string($0.label), "a": JSON($0.a), "b": JSON($0.b)] }),
                "plugins": .array(info.plugins.prefix(limit).map { ["id": .string($0.id), "a": JSON($0.a), "b": JSON($0.b)] }),
                "pluginsSourceA": .string(info.pluginsSourceA), "pluginsSourceB": .string(info.pluginsSourceB),
            ]
        }
        if next.isEmpty { next.append("logs_facets(sessionId: \(b), filter: {minLevel: \"warning\"})") }
        return ToolResult(
            summary: "Session #\(a) vs #\(b): " + parts.joined(separator: "; ") + ".",
            body: lines.joined(separator: "\n"),
            structured: .object(structured),
            next: next,
            sessionId: b,
            links: [.session(a), .session(b)]
        )
    }
}
