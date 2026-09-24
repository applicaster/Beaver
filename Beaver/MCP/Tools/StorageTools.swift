//
//  StorageTools.swift
//  Beaver
//
//  The app's storage (design §5.5): read, set, delete — the same wire
//  commands and read-back as the Storages tab (M16, D58).

import Foundation

enum StorageTools {
    static let all = [snapshot, set, delete]

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

    static let snapshot = MCPTool(
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
    ) { args, ctx in
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
        let isLive = host.deviceConnected && host.liveSessionId == s.id
        return ToolResult(
            summary: found == 0
                ? "No storage snapshot in session \(s.label) yet.\(refreshNote)"
                : "Storage of session \(s.label): \(found) of \(wanted.count) layer(s).\(refreshNote)",
            body: blocks.joined(separator: "\n\n"),
            structured: ["sessionId": JSON(s.id), "layers": .object(out)],
            next: found > 0
                ? ["storage_set(layer: \"local\", key: \"…\", value: \"…\") to change a value",
                   "logs_query(filter: {search: \"storage\"}) for storage-related logs"]
                : (isLive ? ["storage_snapshot(timeoutMs: 15000) to give the app longer"]
                          : ["beaver_status() — storage arrives while the app is connected"]),
            sessionId: s.id
        )
    }

    /// Appended to the snapshot summary: where the data came from.
    static func refreshIfLive(_ args: ToolArguments, session s: ResolvedSession,
                              layers: [StorageSnapshot.Namespace], _ ctx: ToolContext) async throws -> String {
        guard try args.bool("refresh") ?? true else { return " Stored snapshot (refresh: false)." }
        let host = await ctx.ui.snapshot()
        guard host.deviceConnected, host.liveSessionId == s.id else {
            return host.deviceConnected
                ? " Not refreshed: session #\(s.id) isn't the live one."
                : " Not refreshed: no device is connected; this is the last stored snapshot."
        }
        let timeout = min(30_000, max(0, try args.int("timeoutMs") ?? 5_000))
        let fresh = await StorageCommand.refresh(layers, sessionId: s.id, timeout: .milliseconds(timeout),
                                                 store: ctx.store, device: ctx.device)
        if fresh.isEmpty { return " The app didn't answer within \(timeout) ms; this is the last stored snapshot." }
        let missing = layers.filter { !fresh.contains($0) }
        return missing.isEmpty
            ? " Fresh from the app."
            : " Fresh from the app, which sent no \(missing.map(\.displayName).joined(separator: ", ")) layer."
    }

    static let set = MCPTool(
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
    ) { args, ctx in
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

    static let delete = MCPTool(
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
    ) { args, ctx in
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
        let (host, live) = try await ctx.requireDevice(args, doing: "change its storage")
        guard StorageCommand.isSupported(action, in: layer, by: host.commands.map(\.name)) else {
            throw ToolError("This app doesn't accept \(StorageCommand.name(action, in: layer)) (it isn't in commands_list()), "
                + "so Beaver can't \(action.rawValue) \(layer.wireKey) keys. storage_snapshot() still reads them.")
        }
        let command = value.map { StorageCommand.set(layer, key: key, value: $0, parent: parent) }
            ?? StorageCommand.delete(layer, key: key, parent: parent)
        let outcome = await StorageCommand.sendAndVerify(command, layer: layer, parent: parent, key: key,
                                                         expected: value, sessionId: live,
                                                         store: ctx.store, device: ctx.device)
        let path = "\(layer.wireKey)/\(parent ?? StorageCommand.defaultNamespace)/\(key)"
        let request = value.map { "Set \(path) = \($0)" } ?? "Delete \(path)"
        let summary = switch outcome {
        case .applied: "\(request): applied (Beaver re-read the app's storage and saw it)."
        case .notApplied: "\(request): not applied — the app sent its storage back without the change."
        case .noAnswer: "\(request): sent, but the app didn't send its storage back within 3 s, so Beaver can't tell whether it applied."
        }
        return ToolResult(
            summary: summary,
            structured: ["outcome": .string(outcome.rawValue), "command": .string(command),
                         "layer": .string(layer.wireKey), "namespace": .string(parent ?? StorageCommand.defaultNamespace),
                         "key": .string(key), "value": JSON(value), "sessionId": JSON(live)],
            next: outcome == .applied
                ? ["storage_snapshot(layer: \"\(layer.wireKey)\")",
                   "logs_wait(filter: {search: \"\(key)\"}) for what the app does with it"]
                : ["logs_query(filter: {search: \"\(key)\"}, since: \"1m\") for the app's own message about it",
                   "beaver_status()"],
            sessionId: live
        )
    }
}
