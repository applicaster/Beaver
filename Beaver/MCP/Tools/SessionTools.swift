//
//  SessionTools.swift
//  Beaver
//
//  Session files and deletion (design §5.2). Same readers and writers as
//  the Import / Export buttons (SESSION_FILE_FORMAT.md).

import Foundation

enum SessionTools {
    static let all = [importFile, exportFile, delete]

    static func requiredPath(_ args: ToolArguments, example: String) throws -> URL {
        guard let raw = try args.string("path").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("path is required. \(example)")
        }
        return try ToolInput.fileURL(raw)
    }

    static let importFile = MCPTool(
        name: "sessions_import",
        title: "Import a session file",
        description: "Use when the user or a customer has a log file: opens a Beaver or zapp-support JSON export, or a HAR file from a browser or proxy, as a new imported session (like Beaver's Import button). The window stays on what the user is viewing. path must be absolute or start with ~.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "path": ToolSchema.string("The file, e.g. ~/Downloads/customer.json or /Users/me/Desktop/app.har."),
        ], required: ["path"])
    ) { args, ctx in
        let url = try requiredPath(args, example: "Example: sessions_import(path: \"~/Downloads/customer.json\").")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("No file at \(url.path). Example: sessions_import(path: \"~/Downloads/customer.json\").")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ToolError("Can't read \(url.path): \(error.localizedDescription).")
        }
        guard let r = try await SessionImport.run(data, label: url.deletingPathExtension().lastPathComponent,
                                                  store: ctx.store) else {
            throw ToolError("\(url.lastPathComponent) isn't a session file Beaver can open: expected a Beaver or zapp-support JSON export, or a HAR file.")
        }
        let id = r.session.id
        return ToolResult(
            summary: "Imported \(url.lastPathComponent) as session #\(id): \(r.events) event(s), \(r.requests) request(s), \(r.storageLayers) storage layer(s).",
            structured: ["sessionId": JSON(id), "events": JSON(r.events), "requests": JSON(r.requests),
                         "storageLayers": JSON(r.storageLayers), "path": .string(url.path)],
            next: ["logs_facets(sessionId: \(id))", "network_query(sessionId: \(id), status: \"errors\")"],
            sessionId: id
        )
    }

    static let exportFile = MCPTool(
        name: "sessions_export",
        title: "Export a session file",
        description: "Use to save a session to a file the user can send or open elsewhere: JSON (default, the same file as Beaver's Export button, readable by zapp-support; filter narrows the events) or HAR (the network requests). Never replaces an existing file unless overwrite: true. path must be absolute or start with ~.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "path": ToolSchema.string("Where to write, e.g. ~/Desktop/errors-only.json."),
            "format": ToolSchema.string("json (default) or har.", oneOf: ["json", "har"]),
            "filter": ToolSchema.filter,
            "overwrite": ToolSchema.boolean("Replace the file if it exists. Default false."),
        ], required: ["path"])
    ) { args, ctx in
        let example = "Example: sessions_export(path: \"~/Desktop/session.json\", filter: {minLevel: \"error\"})."
        let s = try await ctx.resolveSession(args)
        let url = try requiredPath(args, example: example)
        let format = (try args.string("format") ?? "json").lowercased()
        guard ["json", "har"].contains(format) else { throw ToolError("format must be json or har. \(example)") }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), try args.bool("overwrite") != true {
            throw ToolError("\(url.path) already exists. Pass overwrite: true to replace it, or choose another path.")
        }
        var isDir: ObjCBool = false
        let folder = url.deletingLastPathComponent()
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("No folder \(folder.path). \(example)")
        }
        let data: Data
        var counts: [String: JSON] = [:]
        if format == "har" {
            guard args["filter"] == nil else {
                throw ToolError("filter works with format: \"json\" only; a HAR holds every request. Example: sessions_export(path: \"~/Desktop/requests.har\", format: \"har\").")
            }
            let entries = try await ctx.store.networkEntries(sessionId: s.id)
            guard !entries.isEmpty else { throw ToolError("Session \(s.label) has no network requests to export as HAR.") }
            let version = await ctx.ui.snapshot().beaverVersion
            data = try HARExport.encode(entries, creatorVersion: version)
            counts["requests"] = JSON(entries.count)
        } else {
            let f = try await ctx.resolveFilter(args, sessionId: s.id)
            let scope: SessionExport.Scope = f.filter.isEmpty ? .everything : .filtered(f.filter)
            guard let made = await SessionExport.make(store: ctx.store, sessionId: s.id, scope: scope) else {
                throw ToolError("Session \(s.label) has nothing to export under that filter. logs_facets(sessionId: \(s.id)) shows what it holds.")
            }
            data = made
            counts["events"] = JSON(try await ctx.store.eventCount(sessionId: s.id, filter: f.filter))
            counts["requests"] = JSON(try await ctx.store.networkEntryCount(sessionId: s.id))
        }
        do { try data.write(to: url, options: .atomic) } catch {
            throw ToolError("Can't write \(url.path): \(error.localizedDescription).")
        }
        let what = counts.keys.sorted().map { "\(counts[$0]?.int ?? 0) \($0)" }.joined(separator: ", ")
        return ToolResult(
            summary: "Exported session \(s.label) to \(url.path) (\(format.uppercased()): \(what)).",
            structured: .object((["sessionId": JSON(s.id), "path": .string(url.path), "format": .string(format),
                                  "bytes": JSON(data.count)] as [String: JSON]).merging(counts) { current, _ in current }),
            next: ["tell the user the file is at \(url.path)"],
            sessionId: s.id
        )
    }

    static let delete = MCPTool(
        name: "sessions_delete",
        title: "Delete sessions",
        description: "Use when the user asks to delete a stored session, or every session (all: true): its logs, requests, storage snapshots and bookmarks go. Say which explicitly; there is no default. The agent journal keeps its entries.",
        kind: .destructive,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.integer("The session to delete (sessions_list shows them)."),
            "all": ToolSchema.boolean("Delete every session."),
        ])
    ) { args, ctx in
        let all = try args.bool("all") ?? false
        let id = try args.int64("sessionId")
        let sessions = try await ctx.store.sessions()
        switch (id, all) {
        case (nil, true):
            try await ctx.store.deleteAllSessions()
            return ToolResult(summary: "Deleted all \(sessions.count) session(s).",
                              structured: ["deleted": JSON(sessions.count)],
                              next: ["beaver_status()"])
        case (let id?, false):
            guard let s = sessions.first(where: { $0.id == id }) else {
                throw ToolError("No session #\(id). Example: sessions_list() shows the ids that exist.")
            }
            let events = try await ctx.store.eventCount(sessionId: id, filter: .none)
            try await ctx.store.deleteSession(id: id)
            return ToolResult(
                summary: "Deleted session #\(id) (\(s.source.rawValue), \(StatusTools.describeDevice(s)), \(events) events).",
                structured: ["deleted": 1, "sessionId": JSON(id)],
                next: ["sessions_list()"])
        case (_?, true):
            throw ToolError("Pass either sessionId or all: true, not both. Example: sessions_delete(sessionId: 12).")
        case (nil, false):
            throw ToolError("Say which: sessions_delete(sessionId: 12), or sessions_delete(all: true) for every session. sessions_list() shows the ids.")
        }
    }
}
