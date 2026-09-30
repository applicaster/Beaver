//
//  IssueTools.swift
//  Beaver
//
//  issues_list and issues_ignore (D95): the Issues tab, for agents.

import Foundation

enum IssueTools {
    static var all: [MCPTool] { [list, ignore] }

    static let list: MCPTool = MCPTool(
        name: "issues_list",
        title: "Issues",
        description: "Use first when asked what's broken in a session: its warnings and errors grouped by signature (subsystem + message with numbers, ids and times normalised, as sessions_compare does), each with level, count, first/last event id and time, and whether the user ignored it as known noise for this app. Errors first, then most frequent.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "minLevel": ToolSchema.string("warning (default: warnings and errors) or error.", oneOf: ["warning", "error"]),
            "includeIgnored": ToolSchema.boolean("Also list the signatures the user ignored (marked ignored: true). Default false."),
            "limit": ToolSchema.integer("Issues to list. Default 30, max 500."),
        ])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        let s = try await ctx.resolveSession(args)
        var minLevel = LogLevel.warning
        if let raw = args["minLevel"] {
            guard let level = ToolInput.level(raw), level >= .warning else {
                throw ToolError("minLevel is warning or error; got \(raw.text). Example: issues_list(minLevel: \"error\").")
            }
            minLevel = level
        }
        let includeIgnored = try args.bool("includeIgnored") ?? false
        let limit = try args.limit(default: 30, max: Issues.cap)
        let report = try await ctx.store.issues(sessionId: s.id, minLevel: minLevel)
        let groups = Issues.Sort.errorsFirst.sorted(includeIgnored ? report.groups : report.shown)
        let ignoredCount = report.groups.count - report.shown.count
        let what = minLevel == .error ? "error" : "warning/error"

        var summary = "Session \(s.label): \(report.shown.count) \(what) issue(s) — \(report.errors) error, \(report.warnings) warning"
        if ignoredCount > 0 { summary += "; \(ignoredCount) ignored" + (includeIgnored ? "" : " (includeIgnored: true lists them)") }
        summary += "."
        let lines = groups.prefix(limit).map { g in
            "\(g.ignored ? "[ignored] " : "")\(g.level.rawValue.uppercased()) ×\(g.count) \(g.subsystem): \(g.pattern) "
                + "(first #\(g.firstId) \(Issues.Group.stamp(g.firstAt)), last #\(g.lastId) \(Issues.Group.stamp(g.lastAt)))"
        }
        var body = lines.joined(separator: "\n")
        if groups.count > limit { body += "\n… \(groups.count - limit) more; raise limit (max \(Issues.cap))" }
        if report.capped { body += "\nCapped: over \(Issues.cap) signatures; the rarest aren't listed." }

        var next: [String] = []
        if let top = groups.first(where: { !$0.ignored }) {
            next.append("logs_get(ids: [\(top.firstId)])")
            next.append("logs_query(sessionId: \(s.id), filter: \(logFilter(top, minLevel).text))")
            next.append("ui_show(tab: \"issues\") to point the user at them")
        } else {
            next.append("logs_facets(sessionId: \(s.id), filter: {minLevel: \"warning\"})")
        }
        return ToolResult(
            summary: summary,
            body: body,
            structured: [
                "sessionId": JSON(s.id), "minLevel": .string(minLevel.rawValue),
                "errors": JSON(report.errors), "warnings": JSON(report.warnings),
                "ignored": JSON(ignoredCount), "capped": .bool(report.capped),
                "issues": .array(groups.prefix(limit).map { g in
                    ["signature": .string(g.signature), "subsystem": .string(g.subsystem), "pattern": .string(g.pattern),
                     "level": .string(g.level.rawValue), "count": JSON(g.count),
                     "firstId": JSON(g.firstId), "lastId": JSON(g.lastId),
                     "firstTime": .string(Issues.Group.stamp(g.firstAt)), "lastTime": .string(Issues.Group.stamp(g.lastAt)),
                     "example": .string(String(g.example.prefix(ToolText.messageCap))),
                     "ignored": .bool(g.ignored), "filter": logFilter(g, minLevel)]
                }),
            ],
            next: next,
            sessionId: s.id
        )
    }

    /// `logs_query`'s filter for exactly this issue's events.
    static func logFilter(_ g: Issues.Group, _ minLevel: LogLevel) -> JSON {
        ["minLevel": .string(minLevel.rawValue), "subsystems": [.string(g.subsystem)], "pattern": .string(g.pattern)]
    }

    static let ignore: MCPTool = MCPTool(
        name: "issues_ignore",
        title: "Ignore an issue",
        description: "Use only when the user asks to mark an issue as known noise (or to unignore it with ignored: false). It is their setting: the signature is hidden from the Issues tab and issues_list in every session of this app, now and later. Pass the signature from issues_list.",
        kind: .change,
        idempotent: true,
        inputSchema: ToolSchema.object([
            "signature": ToolSchema.string("An issue's signature from issues_list: \"<subsystem> ␟ <pattern>\"."),
            "ignored": ToolSchema.boolean("true to ignore (default), false to show it again."),
            "sessionId": ToolSchema.integer("A session of the app the ignore is for. Default: live, viewed, most recent."),
        ], required: ["signature"])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        let example = "Example: issues_ignore(signature: \"com.app/quick_brick/Player ␟ Buffer low <n>%\")."
        guard let raw = try args.string("signature"), let sig = Issues.parse(signature: raw) else {
            throw ToolError("signature is required, as issues_list gives it (subsystem, \" ␟ \", pattern). \(example)")
        }
        let ignored = try args.bool("ignored") ?? true
        let s = try await ctx.resolveSession(args)
        do {
            try await ctx.store.setIssueIgnored(ignored, subsystem: sig.subsystem, pattern: sig.pattern, sessionId: s.id)
        } catch let unknown as Issues.UnknownApp {
            throw ToolError((unknown.errorDescription ?? "") + " Pick a session sessions_list shows with an app name.")
        }
        let app = s.session.appPackage ?? s.session.appName ?? "this app"
        return ToolResult(
            summary: ignored ? "Ignored \(sig.subsystem): \(sig.pattern) for \(app), in every session."
                : "Unignored \(sig.subsystem): \(sig.pattern) for \(app).",
            structured: ["signature": .string(raw), "ignored": .bool(ignored), "app": .string(app), "sessionId": JSON(s.id)],
            next: ["issues_list(sessionId: \(s.id), includeIgnored: true)"],
            sessionId: s.id
        )
    }
}
