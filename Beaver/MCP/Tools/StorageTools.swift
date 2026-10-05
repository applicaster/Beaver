//
//  StorageTools.swift
//  Beaver
//
//  The app's storage (design §5.5): read, set, delete — the same wire
//  commands and read-back as the Storages tab (M16, D58).

import Foundation

enum StorageTools {
    static let all: [MCPTool] = [snapshot, diff, set, delete]

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

    static let snapshot: MCPTool = MCPTool(
        name: "storage_snapshot",
        title: "Storage snapshot",
        description: "Use to read the app's session, local and keychain (secure) storage. With a device connected it first asks the app for fresh storage (refresh, default true); otherwise, or with refresh: false, it reads the latest snapshot Beaver stored for the session, with its time. Top-level keys inside a layer are the SDK's namespaces (applicaster.v2 by default).",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "layer": ToolSchema.string("session, local, secure (keychain) or all (default).",
                                       oneOf: ["session", "local", "secure", "keychain", "all"]),
            "refresh": ToolSchema.boolean("Ask the connected app for fresh storage first. Default true; past and imported sessions are read as stored."),
            "timeoutMs": ToolSchema.integer("How long to wait for the app's answer. Default 5000, max 30000."),
        ])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        let s = try await ctx.resolveSession(args)
        let wanted = try layers(try args.string("layer"))
        let refreshNote = try await refreshIfLive(args, session: s, layers: wanted, ctx)
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
        let host = await ctx.ui.snapshot()
        let isLive = host.liveSessionIds.contains(s.id)
        return ToolResult(
            summary: found == 0
                ? "No storage snapshot in session \(s.label) yet.\(refreshNote)"
                : "Storage of session \(s.label): \(found) of \(wanted.count) layer(s).\(refreshNote)",
            body: blocks.joined(separator: "\n\n"),
            structured: ["sessionId": JSON(s.id), "layers": .object(out)],
            next: found > 0
                ? ["storage_diff(sessionId: \(s.id)) for what changed during the session",
                   "storage_set(" + (isLive ? "deviceId: \"\(s.id)\", " : "") + "layer: \"local\", key: \"…\", value: \"…\") to change a value",
                   "logs_query(sessionId: \(s.id), filter: {search: \"storage\"}) for storage-related logs"]
                : (isLive ? ["storage_snapshot(sessionId: \(s.id), timeoutMs: 15000) to give the app longer"]
                          : ["beaver_status() — storage arrives while the app is connected"]),
            sessionId: s.id
        )
    }

    /// Appended to the snapshot summary: where the data came from.
    static func refreshIfLive(_ args: ToolArguments, session s: ResolvedSession,
                              layers: [StorageSnapshot.Namespace], _ ctx: ToolContext) async throws -> String {
        guard try args.bool("refresh") ?? true else { return " Stored snapshot (refresh: false)." }
        let host = await ctx.ui.snapshot()
        guard host.liveSessionIds.contains(s.id) else {
            return host.deviceConnected
                ? " Not refreshed: session #\(s.id) isn't live."
                : " Not refreshed: no device is connected; this is the last stored snapshot."
        }
        guard !host.logsOnly.contains(s.id) else {
            return " Not refreshed: this device only sends logs (a smart TV read over DevTools), so it has no storage to send."
        }
        let timeout = min(30_000, max(0, try args.int("timeoutMs") ?? 5_000))
        guard let fresh = await StorageCommand.refresh(layers, sessionId: s.id, timeout: .milliseconds(timeout),
                                                       store: ctx.store, device: ctx.device) else {
            return " Not refreshed: the device disconnected; this is the last stored snapshot."
        }
        if fresh.isEmpty { return " The app didn't answer within \(timeout) ms; this is the last stored snapshot." }
        let missing = layers.filter { !fresh.contains($0) }
        let app = StatusTools.describeDevice(s.session)
        return missing.isEmpty
            ? " Fresh from \(app)."
            : " Fresh from \(app), which sent no \(missing.map(\.displayName).joined(separator: ", ")) layer."
    }

    /// Two snapshots of each layer, key by key (D80). Beaver keeps a new
    /// snapshot only when a layer's content changes.
    static let diff: MCPTool = MCPTool(
        name: "storage_diff",
        title: "Storage changes",
        description: "Use to see what changed in the app's storage during a session, e.g. what login wrote. Compares two snapshots of each layer key by key: added, removed, changed with old and new value; a JSON value (also JSON text in a string) lists the fields that changed inside it. Default: the session's earliest snapshot against the latest, fresh from the app when connected. since or beforeEventId start from the last snapshot before that time or event; fromId / toId pick snapshots by id — the result lists each layer's snapshot ids and times.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "layer": ToolSchema.string("session, local, secure (keychain) or all (default).",
                                       oneOf: ["session", "local", "secure", "keychain", "all"]),
            "since": ToolSchema.string("Start from the last snapshot before this time: 30s, 5m, 2h, 1d back, or an ISO 8601 time."),
            "beforeEventId": ToolSchema.integer("Start from the last snapshot before this event's time, e.g. the log line of a login."),
            "fromId": ToolSchema.integer("Start from this snapshot (its layer only). Default: the earliest."),
            "toId": ToolSchema.integer("End at this snapshot (its layer only). Default: the latest."),
            "refresh": ToolSchema.boolean("Ask the connected app for fresh storage first, unless toId is given. Default true."),
            "timeoutMs": ToolSchema.integer("How long to wait for the app's answer. Default 5000, max 30000."),
        ])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        let s = try await ctx.resolveSession(args)
        let example = "Example: storage_diff(sessionId: \(s.id), layer: \"local\", since: \"5m\")."

        // A snapshot id names its layer.
        func pinned(_ name: String) async throws -> StorageSnapshot? {
            guard let id = try args.int64(name) else { return nil }
            guard let snap = try await ctx.store.storageSnapshot(id: id), snap.sessionId == s.id else {
                throw ToolError("No storage snapshot #\(id) in session \(s.label). "
                    + "storage_diff(sessionId: \(s.id)) lists each layer's snapshot ids.")
            }
            return snap
        }
        let from = try await pinned("fromId"), to = try await pinned("toId")
        if let from, let to, from.namespace != to.namespace {
            throw ToolError("fromId #\(from.id) is a \(from.namespace.wireKey) snapshot and toId #\(to.id) a "
                + "\(to.namespace.wireKey) one: pick two of the same layer. \(example)")
        }
        let wanted = try (from ?? to).map { [$0.namespace] } ?? layers(try args.string("layer"))

        var start: (date: Date, label: String)?
        if let since = try args.string("since") {
            guard let date = ToolInput.time(since, now: ctx.now()) else {
                throw ToolError("since \"\(since)\" is not a duration (30s, 5m, 2h, 1d) or an ISO 8601 time. \(example)")
            }
            start = (date, "since \(since)")
        }
        if let eventId = try args.int64("beforeEventId") {
            guard let e = try await ctx.store.events(ids: [eventId]).first, e.sessionId == s.id else {
                throw ToolError("No event #\(eventId) in session \(s.label). "
                    + "Example: logs_query(sessionId: \(s.id), filter: {search: \"login\"}) finds the line to start from.")
            }
            start = (e.date, "before event #\(eventId)")
        }
        let refreshNote = to == nil ? try await refreshIfLive(args, session: s, layers: wanted, ctx) : ""

        var blocks: [String] = [], out: [String: JSON] = [:], counts: [String] = []
        var total = 0, compared = 0
        var firstChange: (layer: StorageSnapshot.Namespace, change: StorageChange)?
        for ns in wanted {
            let history = try await ctx.store.storageSnapshotHistory(sessionId: s.id, namespace: ns)
            var newer = to
            if newer == nil, let latest = history.last {
                newer = try await ctx.store.storageSnapshot(id: latest.id)
            }
            guard let newer else {
                blocks.append("\(ns.displayName): no snapshot")
                continue
            }
            var older = from
            var note = ""
            if older == nil, let start {
                older = try await ctx.store.storageSnapshot(sessionId: s.id, namespace: ns, asOf: start.date)
                if older == nil { note = " (none before \(start.label): from the earliest)" }
            }
            if older == nil { older = try await ctx.store.storageSnapshot(id: history[0].id) }
            guard let older else { continue }

            let listed = JSON.array(history.map { h -> JSON in ["id": JSON(h.id), "takenAt": .string(h.takenAt.ISO8601Format())] })
            func stamp(_ snap: StorageSnapshot) -> JSON {
                ["id": JSON(snap.id), "takenAt": .string(snap.takenAt.ISO8601Format())]
            }
            let range = "#\(older.id) (\(older.takenAt.ISO8601Format())) → #\(newer.id) (\(newer.takenAt.ISO8601Format()))"
            guard older.id != newer.id else {
                blocks.append("\(ns.displayName): one snapshot, #\(newer.id) as of \(newer.takenAt.ISO8601Format()) — nothing to compare.")
                out[ns.rawValue] = ["from": stamp(older), "to": stamp(newer), "changes": [], "snapshots": listed]
                continue
            }
            compared += 1
            let changes = StorageDiff.changes(from: older.dataJSON, to: newer.dataJSON)
            total += changes.count
            if !changes.isEmpty { counts.append("\(ns.wireKey) \(changes.count)") }
            if firstChange == nil, let c = changes.first { firstChange = (ns, c) }
            blocks.append("\(ns.displayName) \(range)\(note): "
                + (changes.isEmpty ? "no changes" : "\(changes.count) change(s)\n" + changes.map(diffLines).joined(separator: "\n")))
            out[ns.rawValue] = ["from": stamp(older), "to": stamp(newer), "snapshots": listed,
                                "changes": .array(changes.map(diffJSON))]
        }

        let base = from.map { "snapshot #\($0.id)" } ?? start?.label ?? "earliest snapshot"
        let head = "Storage of session \(s.label), \(base) → \(to.map { "snapshot #\($0.id)" } ?? "latest")"
        let summary: String
        var next: [String]
        if out.isEmpty {
            summary = "No storage snapshot in session \(s.label) yet.\(refreshNote)"
            next = ["beaver_status() — storage arrives while the app is connected"]
        } else if compared == 0 {
            summary = "Storage of session \(s.label): nothing to compare — one snapshot per layer. "
                + "Imported sessions keep one; a live one gets a new snapshot each time storage changes.\(refreshNote)"
            let host = await ctx.ui.snapshot()
            next = host.liveSessionIds.contains(s.id)
                ? ["storage_diff(sessionId: \(s.id)) again after the app changes its storage (e.g. after login)"]
                : ["storage_snapshot(sessionId: \(s.id), refresh: false) for what is stored"]
        } else if let firstChange {
            summary = "\(head): \(total) change(s) (\(counts.joined(separator: ", "))).\(refreshNote)"
            next = ["storage_snapshot(sessionId: \(s.id), layer: \"\(firstChange.layer.wireKey)\", refresh: false) for the whole layer",
                    "logs_query(sessionId: \(s.id), filter: {search: \"\(firstChange.change.key ?? firstChange.change.namespace)\"}) "
                        + "for what the app logged about it"]
        } else {
            summary = "\(head): no changes.\(refreshNote)"
            next = ["storage_diff(sessionId: \(s.id), fromId: <id>) — pick an earlier snapshot from snapshots"]
        }
        if from == nil, start == nil, total > 0 {
            next.append("storage_diff(sessionId: \(s.id), beforeEventId: <id>) for only what changed after an event")
        }
        return ToolResult(
            summary: summary,
            body: ToolText.capped(blocks.joined(separator: "\n\n"), maxBytes: ToolText.payloadCap).text,
            structured: ["sessionId": JSON(s.id), "layers": .object(out)],
            next: next,
            sessionId: s.id
        )
    }

    /// `+ ns/key = new`, `- ns/key (was old)`, `~ ns/key: old → new`, then
    /// up to 10 changed fields inside a JSON value.
    static func diffLines(_ c: StorageChange) -> String {
        func short(_ s: String?) -> String {
            guard let s else { return "" }
            return s.count > 200 ? String(s.prefix(200)) + "…" : s
        }
        func line(_ mark: StorageChange.Kind, _ name: String, _ old: String?, _ new: String?) -> String {
            switch mark {
            case .added: "+ \(name) = \(short(new))"
            case .removed: "- \(name) (was \(short(old)))"
            case .changed: "~ \(name): \(short(old)) → \(short(new))"
            }
        }
        var lines = [line(c.kind, c.path, c.old, c.new)]
        lines += c.fields.prefix(10).map { "    " + line($0.kind, $0.path, $0.old, $0.new) }
        if c.fields.count > 10 { lines.append("    … \(c.fields.count - 10) more field(s)") }
        return lines.joined(separator: "\n")
    }

    static func diffJSON(_ c: StorageChange) -> JSON {
        func capped(_ s: String?) -> JSON { JSON(s.map { ToolText.capped($0, maxBytes: 4096).text }) }
        return ["namespace": .string(c.namespace), "key": JSON(c.key), "change": .string(c.kind.rawValue),
                "old": capped(c.old), "new": capped(c.new),
                "fields": .array(c.fields.map {
                    ["path": .string($0.path), "change": .string($0.kind.rawValue), "old": capped($0.old), "new": capped($0.new)]
                })]
    }

    static let set: MCPTool = MCPTool(
        name: "storage_set",
        title: "Set a storage value",
        description: "Use to change a value in the connected app's storage (session, local or secure/keychain), like editing it in Beaver's Storages tab. Beaver then re-reads storage and says whether the app applied it (applied, notApplied, or noAnswer when the app didn't send storage back). The key, value and namespace can't contain spaces, tabs or line breaks: the app splits commands on spaces.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "layer": ToolSchema.string("session, local or secure (keychain).", oneOf: ["session", "local", "secure", "keychain"]),
            "key": ToolSchema.string("The key, e.g. onboardingDone."),
            "value": ToolSchema.string("The new value. JSON objects and arrays are sent compact."),
            "namespace": ToolSchema.string("The SDK namespace inside the layer. Default applicaster.v2."),
            "deviceId": ToolSchema.deviceId,
        ], required: ["layer", "key", "value"])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        let example = "Example: storage_set(layer: \"local\", key: \"onboardingDone\", value: \"false\")."
        let layer = try oneLayer(args, example: example)
        let key = try word(args, "key", example: example)
        guard let given = args["value"] else {
            throw ToolError("value is required. \(example) To remove a key use storage_delete.")
        }
        let wire = StorageCommand.wireValue(given.string ?? given.text)
        let parent = try optionalWord(args, "namespace", example: example)
        if let problem = StorageCommand.valueProblem(wire, parent: parent) {
            throw ToolError("Not sent. \(problem) \(example)")
        }
        return try await edit(.set, layer: layer, key: key, value: wire, parent: parent, args, ctx)
    }

    static let delete: MCPTool = MCPTool(
        name: "storage_delete",
        title: "Delete a storage key",
        description: "Use to remove a key from the connected app's storage (session, local or secure/keychain), like Delete in Beaver's Storages tab. Beaver then re-reads storage and says whether the app applied it.",
        kind: .destructive,
        inputSchema: ToolSchema.object([
            "layer": ToolSchema.string("session, local or secure (keychain).", oneOf: ["session", "local", "secure", "keychain"]),
            "key": ToolSchema.string("The key to remove."),
            "namespace": ToolSchema.string("The SDK namespace inside the layer. Default applicaster.v2."),
            "deviceId": ToolSchema.deviceId,
        ], required: ["layer", "key"])
    ) { (args: ToolArguments, ctx: ToolContext) async throws -> ToolResult in
        let example = "Example: storage_delete(layer: \"local\", key: \"onboardingDone\")."
        let layer = try oneLayer(args, example: example)
        let key = try word(args, "key", example: example)
        let parent = try optionalWord(args, "namespace", example: example)
        return try await edit(.delete, layer: layer, key: key, value: nil, parent: parent, args, ctx)
    }

    static func oneLayer(_ args: ToolArguments, example: String) throws -> StorageSnapshot.Namespace {
        guard let raw = try args.string("layer") else {
            throw ToolError("layer is required: session, local or secure. \(example)")
        }
        let found: [StorageSnapshot.Namespace]
        do {
            found = try layers(raw)
        } catch {
            throw ToolError("Unknown layer \"\(raw)\": use session, local or secure. \(example)")
        }
        guard found.count == 1 else { throw ToolError("Pick one layer: session, local or secure. \(example)") }
        return found[0]
    }

    /// A key or namespace: one word, since the app splits commands on spaces.
    static func word(_ args: ToolArguments, _ name: String, example: String) throws -> String {
        guard let value = try optionalWord(args, name, example: example) else {
            throw ToolError("\(name) is required. \(example)")
        }
        return value
    }

    static func optionalWord(_ args: ToolArguments, _ name: String, example: String) throws -> String? {
        guard let value = try args.string(name).flatMap(ToolContext.trimmedNonEmpty) else { return nil }
        guard !value.contains(where: \.isWhitespace) else {
            throw ToolError("Not sent: \(name) \"\(value)\" contains a space, and the app splits commands on spaces. \(example)")
        }
        return value
    }

    static func edit(_ action: StorageCommand.Action, layer: StorageSnapshot.Namespace, key: String,
                     value: String?, parent: String?, _ args: ToolArguments, _ ctx: ToolContext) async throws -> ToolResult {
        let (host, live) = try await ctx.requireDevice(args, doing: "change its storage",
            call: "storage_\(action.rawValue)(layer: \"\(layer.wireKey)\", key: \"\(key)\")")
        guard StorageCommand.isSupported(action, in: layer, by: (host.commandsBySession[live] ?? []).map(\.name)) else {
            throw ToolError("This app doesn't accept \(StorageCommand.name(action, in: layer)) (it isn't in commands_list()), "
                + "so Beaver can't \(action.rawValue) \(layer.wireKey) keys. storage_snapshot() still reads them.")
        }
        let command = value.map { StorageCommand.set(layer, key: key, value: $0, parent: parent) }
            ?? StorageCommand.delete(layer, key: key, parent: parent)
        let target = try await ctx.describeTarget(live, args, host)
        let before = try await ctx.store.latestEventId(sessionId: live) ?? 0
        let outcome = await StorageCommand.sendAndVerify(command, layer: layer, parent: parent, key: key,
                                                         expected: value, sessionId: live,
                                                         store: ctx.store, device: ctx.device)
        let path = "\(layer.wireKey)/\(parent ?? StorageCommand.defaultNamespace)/\(key)"
        let request = (value.map { "Set \(path) = \($0)" } ?? "Delete \(path)") + " on \(target)"
        let summary = switch outcome {
        case .applied: "\(request): applied (Beaver re-read the app's storage and saw it)."
        case .notApplied: "\(request): not applied — the app sent its storage back without the change."
        case .noAnswer: "\(request): sent, but the app didn't send its storage back within 3 s, so Beaver can't tell whether it applied."
        case .notSent: "\(request): not sent — the device disconnected."
        }
        return ToolResult(
            summary: summary,
            structured: ["outcome": .string(outcome.rawValue), "command": .string(command),
                         "layer": .string(layer.wireKey), "namespace": .string(parent ?? StorageCommand.defaultNamespace),
                         "key": .string(key), "value": JSON(value), "sessionId": JSON(live)],
            next: outcome == .applied
                ? ["storage_snapshot(sessionId: \(live), layer: \"\(layer.wireKey)\")",
                   "logs_wait(sessionId: \(live), afterId: \(before), filter: {search: \"\(key)\"}, timeoutMs: 15000) "
                       + "for what the app does with it (\(ToolText.restartNote))"]
                : outcome == .notSent ? ["beaver_status() to see whether it is back"]
                : ["logs_query(sessionId: \(live), filter: {search: \"\(key)\"}, since: \"1m\") for the app's own message about it",
                   "beaver_status()"],
            sessionId: live
        )
    }
}
