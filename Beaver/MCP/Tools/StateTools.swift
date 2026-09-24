//
//  StateTools.swift
//  Beaver
//

import Foundation

enum StateTools {
    static let all = [storageSnapshot, commandsList, bookmarksList, filtersList]

    static func layers(_ raw: String?) throws -> [StorageSnapshot.Namespace] {
        switch raw?.lowercased() {
        case nil, "all", "": return StorageSnapshot.Namespace.allCases
        case "session": return [.session]
        case "local": return [.local]
        case "secure", "keychain": return [.keychain]
        case let other?:
            throw ToolError("Unknown layer \"\(other)\". Use storage_snapshot(layer: \"local\") or session, secure (keychain), all.")
        }
    }

    static let storageSnapshot = MCPTool(
        name: "storage_snapshot",
        title: "Storage snapshot",
        description: "Use to read the app's session, local and keychain (secure) storage: the latest snapshot Beaver has for the session, with its time. Top-level keys inside a layer are the SDK's namespaces (applicaster.v2 by default).",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "layer": ToolSchema.string("session, local, secure (keychain) or all (default).",
                                       oneOf: ["session", "local", "secure", "keychain", "all"]),
        ])
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        let wanted = try layers(try args.string("layer"))
        var blocks: [String] = []
        var out: [String: JSON] = [:]
        for ns in wanted {
            guard let snap = try await ctx.store.latestStorageSnapshot(sessionId: s.id, namespace: ns) else {
                blocks.append("\(ns.displayName): no snapshot")
                continue
            }
            // Cap the raw dataJSON text first, then parse if whole
            let capped = ToolText.capped(snap.dataJSON, maxBytes: ToolText.payloadCap)
            let prettyIfWhole = !capped.truncated ? (try? JSON.parse(Data(capped.text.utf8)).prettyText) : nil
            let text = ToolText.capped(prettyIfWhole ?? capped.text, maxBytes: ToolText.payloadCap)
            blocks.append("\(ns.displayName) — as of \(snap.takenAt.ISO8601Format()):\n\(text.text)"
                + (text.truncated ? "\n[cut at 256 KB]" : ""))
            // Parsed when whole and valid, so the agent gets structure; the raw text otherwise.
            func payload(_ p: (text: String, truncated: Bool)) -> JSON {
                if !p.truncated, let parsed = try? JSON.parse(Data(p.text.utf8)) { return parsed }
                return .string(p.text)
            }
            out[ns.rawValue] = ["takenAt": .string(snap.takenAt.ISO8601Format()),
                                "data": payload(capped),
                                "dataTruncated": .bool(capped.truncated)]
        }
        let found = out.count
        let result = ToolResult(
            summary: found == 0
                ? "No storage snapshot in session \(s.label) yet. One arrives when the Storages tab is opened while the device is connected."
                : "Storage of session \(s.label): \(found) of \(wanted.count) layer(s).",
            body: blocks.joined(separator: "\n\n"),
            structured: ["sessionId": JSON(s.id), "layers": .object(out)],
            next: found == 0 ? ["ask the user to open Beaver's Storages tab while the device is connected"]
                             : ["logs_query(filter: {search: \"storage\"}) for storage-related logs"],
            sessionId: s.id
        )
        return result
    }

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
