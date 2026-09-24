//
//  JournalTools.swift
//  Beaver
//
//  journal_note (design §5.9): how the agent tells the person something.
//  The dispatcher writes the note to the journal, with its level and links.

import Foundation

enum JournalTools {
    static let all = [note]

    static let linksExample = "Example: links: [{eventId: 48211}, {networkId: 391}]."

    static let note = MCPTool(
        name: "journal_note",
        title: "Note for the user",
        description: "Use to tell the user what you found, in Beaver's Agent panel, with links they can click (events, requests, sessions, saved filters). level attention also shows a toast in Beaver and a macOS notification when Beaver is in the background — use it only for what they must look at now (a cause found, a decision needed, something broken). If the result says notified: false, tell the user and pass on howToEnable.",
        kind: .note,
        inputSchema: ToolSchema.object([
            "text": ToolSchema.string("What to tell the user, one or two sentences. At most 1000 characters."),
            "level": ToolSchema.string("info (default): the Agent panel only. attention: also a toast and a notification.",
                                       oneOf: ["info", "attention"]),
            "links": ["type": "array", "items": ["type": "object"],
                      "description": "What the note points at: objects like {eventId: 48211}, {networkId: 391}, {sessionId: 13}, {savedFilter: \"Auth\"}. The first is what Show opens. At most 10."],
        ], required: ["text"])
    ) { args, ctx in
        guard let text = try args.string("text").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("text is required. Example: journal_note(text: \"Login fails: the refresh token expired\", links: [{eventId: 48211}]).")
        }
        guard text.count <= AgentJournal.noteCap else {
            throw ToolError("text is \(text.count) characters; keep it to at most \(AgentJournal.noteCap) and put details behind links.")
        }
        let level = try args.string("level")?.lowercased() ?? "info"
        guard ["info", AgentActivity.attention].contains(level) else {
            throw ToolError("level must be info or attention. Example: journal_note(text: \"…\", level: \"attention\").")
        }
        let links = try await parseLinks(args["links"], ctx)
        let outcome = level == AgentActivity.attention
            ? await ctx.ui.notify(AgentNote(text: text, links: links))
            : NotifyOutcome(notified: false, reason: "level info: shown in the Agent panel only. Use level: \"attention\" when the user must look now.")

        var structured: [String: JSON] = ["level": .string(level), "notified": .bool(outcome.notified),
                                          "reason": JSON(outcome.reason), "links": .array(links.map(\.json))]
        var body = "In the Agent panel" + (links.isEmpty ? "." : " with \(links.map(\.label).joined(separator: ", ")).")
        if level == AgentActivity.attention {
            body += outcome.notified ? " The user was signalled." : " Not notified: \(outcome.reason ?? "")"
            if let how = outcome.howToEnable {
                structured["howToEnable"] = .string(how)
                body += " Tell the user how to turn notifications on: \(how)."
            }
        }
        let sessionLink = links.lazy.compactMap { link -> Int64? in
            if case .session(let id) = link { return id }
            return nil
        }.first
        return ToolResult(
            summary: text,
            body: body,
            structured: .object(structured),
            next: outcome.howToEnable != nil
                ? ["tell the user: \(outcome.howToEnable ?? "")"]
                : ["watch_start(name: …, filter: {…}) to keep an eye on it"],
            sessionId: sessionLink,
            level: level,
            links: links,
            notice: level == AgentActivity.attention && !outcome.notified ? "Not notified: \(outcome.reason ?? "")" : nil
        )
    }

    /// Each link must point at something that exists now, so the person
    /// never clicks a dead one.
    static func parseLinks(_ value: JSON?, _ ctx: ToolContext) async throws -> [JournalLink] {
        guard let value, value != .null else { return [] }
        let items = value.array ?? [value]
        guard items.count <= 10 else { throw ToolError("At most 10 links per note. \(linksExample)") }
        var links: [JournalLink] = []
        for item in items {
            guard let object = item.object else {
                throw ToolError("Each link is an object like {eventId: 48211}. \(linksExample)")
            }
            let a = ToolArguments(object)
            if let id = try a.int64("eventId") {
                guard try await !ctx.store.events(ids: [id]).isEmpty else {
                    throw ToolError("No event #\(id) to link to. \(linksExample)")
                }
                links.append(.event(id))
            } else if let id = try a.int64("networkId") {
                guard try await ctx.store.networkEntrySessionId(id: id) != nil else {
                    throw ToolError("No request #\(id) to link to. \(linksExample)")
                }
                links.append(.network(id))
            } else if let id = try a.int64("sessionId") {
                guard try await ctx.store.sessions().contains(where: { $0.id == id }) else {
                    throw ToolError("No session #\(id) to link to. \(linksExample)")
                }
                links.append(.session(id))
            } else if let name = try a.string("savedFilter") {
                guard try await ctx.store.savedFilters().contains(where: { $0.name == name }) else {
                    throw ToolError("No saved filter “\(name)” to link to (filters_list shows them). \(linksExample)")
                }
                links.append(.savedFilter(name))
            } else {
                throw ToolError("Unknown link \(item.text). \(linksExample)")
            }
        }
        return links
    }
}
