//
//  InfoTools.swift
//  Beaver
//
//  D79: the Info tab for agents — what app and device a session is.

import Foundation

enum InfoTools {
    static let all = [appInfo, appConfig]

    static let appInfo = MCPTool(
        name: "app_info",
        title: "App and device info",
        description: "Use to learn what app and device a session is: app, SDK and QuickBrick versions, Zapp ids, the layout's screens, type mapping (entry type → screen), cell styles and plugins, and the device's model, OS, language, country and advertising id — each value with where it came from (storage, a config file, logs) — the app's own storage, so the build it runs, not Zapp's latest. Config files come from Zapp's public bucket, at the URLs the app keeps in storage.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
        ])
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        let r = try await AppInfoReport.build(store: ctx.store, sessionId: s.id, http: ctx.zapp)
        let isLive = await ctx.ui.snapshot().liveSessionIds.contains(s.id)

        func rows(_ rows: [InfoRow]) -> JSON {
            .array(rows.map { ["label": .string($0.label), "value": .string($0.value), "source": .string($0.source)] })
        }
        func lines(_ title: String, _ rows: [InfoRow]) -> String? {
            rows.isEmpty ? nil : title + ":\n" + rows.map { "  \($0.label): \($0.value)  [\($0.source)]" }.joined(separator: "\n")
        }
        let app = r.identity.first { $0.label == "App name" }?.value ?? s.session.appName ?? "app"
        let version = r.identity.first { $0.label == "App version" }?.value
        func hw(_ label: String) -> String? { r.device.hardware.first { $0.label == label }?.value }
        let os = hw("OS version").map { v in hw("Platform").map { "\($0) \(v)" } ?? v }
        let device = [hw("Model"), os].compactMap { $0 }
        let configs = AppInfo.ConfigKind.allCases.compactMap { kind in
            r.configs[kind].map { "  \(kind.rawValue): \($0.url) (\($0.found))" + ($0.error.map { " — couldn't load: \($0)" } ?? "")
                + ($0.sha256 != nil ? " [saved]" : "") }
        }

        let screenLines = r.screens.isEmpty ? "  none found"
            : r.screens.map { s -> String in "  \(s.name)  \(s.id)" + (s.type.map { "  " + $0 } ?? "") }.joined(separator: "\n")
        let pluginLines = r.plugins.map { p -> String in "  " + p.id + (p.version.map { " " + $0 } ?? "") }.joined(separator: "\n")
        let typeLines = r.typeMapping.map { f -> String in "  \(f.type) → \(f.screenName ?? "(no such screen)")  \(f.screenId)" }
            .joined(separator: "\n")
        let cellLines = r.cellStyles.map { c -> String in "  \(c.id)  \(c.plugin)" }.joined(separator: "\n")
        var sections: [String?] = [lines("Identity & versions", r.identity)]
        sections.append("Screens (\(r.screens.count), \(r.screensSource)):\n" + screenLines)
        sections.append(r.typeMapping.isEmpty ? nil : "Type mapping — entry type → screen (\(r.typeMapping.count), layout.json):\n" + typeLines)
        sections.append("Plugins (\(r.plugins.count), \(r.pluginsSource)):\n" + pluginLines)
        sections.append(r.cellStyles.isEmpty ? nil : "Cell styles (\(r.cellStyles.count), \(r.cellStylesSource)):\n" + cellLines)
        sections.append(lines("Device", r.device.identity + r.device.hardware))
        sections.append(lines("Advertising", r.device.advertising) ?? r.device.advertisingNote)
        sections.append(lines("User agent", r.device.userAgent))
        let savedNote = r.configsSavedAt.map { " (saved with the session \($0.ISO8601Format()), as Zapp had them; read one with app_config)" }
            ?? " (in Zapp now; app_config(download: true) saves them with the session)"
        sections.append(configs.isEmpty ? "Config files: none found." : "Config files\(savedNote):\n" + configs.joined(separator: "\n"))
        let body = sections.compactMap { $0 }.joined(separator: "\n\n")

        let structured: JSON = [
            "sessionId": JSON(s.id),
            "storageAsOf": JSON(r.storageAsOf?.ISO8601Format()),
            "app": [
                "identity": rows(r.identity),
                "screens": .array(r.screens.map { ["id": .string($0.id), "name": .string($0.name), "type": JSON($0.type)] }),
                "screensSource": .string(r.screensSource),
                "plugins": .array(r.plugins.map { ["id": .string($0.id), "version": JSON($0.version)] }),
                "pluginsSource": .string(r.pluginsSource),
                "cellStyles": .array(r.cellStyles.map { ["id": .string($0.id), "plugin": .string($0.plugin)] }),
                "typeMapping": .array(r.typeMapping.map {
                    ["type": .string($0.type), "screenId": .string($0.screenId), "screenName": JSON($0.screenName)]
                }),
            ],
            "device": [
                "identity": rows(r.device.identity), "hardware": rows(r.device.hardware),
                "advertising": rows(r.device.advertising), "userAgent": rows(r.device.userAgent),
            ],
            "configs": .object(Dictionary(uniqueKeysWithValues: r.configs.map { kind, c in
                (kind.rawValue, ["url": .string(c.url), "found": .string(c.found), "error": JSON(c.error),
                                 "saved": .bool(c.sha256 != nil), "size": JSON(c.size)] as JSON)
            })),
            "configsSavedAt": JSON(r.configsSavedAt?.ISO8601Format()),
        ]

        guard r.storageAsOf != nil else {
            return ToolResult(
                summary: "No storage in session \(s.label) yet: App Info reads the app's storage."
                    + (r.screens.isEmpty ? "" : " \(r.screens.count) screens visited, from logs."),
                body: body, structured: structured,
                next: isLive ? ["storage_snapshot(sessionId: \(s.id)) to ask the app for its storage, then app_info again"]
                             : ["sessions_list() to pick a session that has storage"],
                sessionId: s.id)
        }
        return ToolResult(
            summary: "App Info of session \(s.label): \(app)\(version.map { " " + $0 } ?? "")"
                + (device.isEmpty ? "" : " on " + device.joined(separator: " ")) + ". "
                + "\(r.screens.count) screens (\(r.screensSource)), \(r.plugins.count) plugins (\(r.pluginsSource)).",
            body: body,
            structured: structured,
            next: ["storage_snapshot(sessionId: \(s.id)) for the raw storage",
                   "ui_show(tab: \"info\", sessionId: \(s.id)) to show it to the user"],
            sessionId: s.id
        )
    }

    static let appConfig = MCPTool(
        name: "app_config",
        title: "Read an app config file",
        description: "Use to read the app's launch-time config files (layout, pluginConfigurations, remoteConfigurations, cellStyles, presetsMapping, pipesEndpoints, styles, their tablet variants, rivers) as saved with the session: Beaver downloads them from Zapp when the device connects, so they are Zapp's as of then, not after a later publish (the app itself may still run a debug build's bundled copy). Without kind: the saved files. With kind: the JSON at path (dot-separated keys and array indexes, e.g. \"general_settings.layout_id\" or \"screens.0.name\"); objects also list their keys, arrays their count. Files are large (cell styles 1–2 MB): walk down with path.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "kind": ToolSchema.string("Which file.", oneOf: AppInfo.ConfigKind.allCases.map(\.rawValue)),
            "path": ToolSchema.string("Dot-separated keys and indexes inside the file. Omitted: the whole file (cut at maxChars)."),
            "maxChars": ToolSchema.integer("Characters of JSON to return. Default 20000, max 200000."),
            "download": ToolSchema.boolean("Session has no saved copy (connected before Beaver 4.19, or imported): download the files from Zapp now and save them with it. Default false."),
        ])
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        var saved = try await ctx.store.savedConfigs(sessionId: s.id)
        if saved.isEmpty, try args.bool("download") == true {
            try await ConfigSnapshot.capture(store: ctx.store, sessionId: s.id, http: ctx.zapp)
            saved = try await ctx.store.savedConfigs(sessionId: s.id)
        }
        guard !saved.isEmpty else {
            throw ToolError("Session \(s.label) has no saved config files (it connected before Beaver 4.19, was imported, or its storage doesn't name the app). app_info(sessionId: \(s.id)) lists their URLs; app_config(sessionId: \(s.id), download: true) saves Zapp's current ones.")
        }
        let at = saved[0].savedAt.ISO8601Format()
        guard let raw = try args.string("kind") else {
            let lines = saved.sorted { $0.kind.rawValue < $1.kind.rawValue }.map { c in
                "\(c.kind.rawValue): " + (c.size.map { "\($0) bytes" } ?? "not saved: \(c.error ?? "only listed")") + "  \(c.url)"
            }
            return ToolResult(
                summary: "Session \(s.label): \(saved.filter { $0.sha256 != nil }.count) config files saved \(at), as Zapp had them.",
                body: lines.joined(separator: "\n"),
                structured: ["sessionId": JSON(s.id), "savedAt": .string(at), "files": .array(saved.map { c in
                    ["kind": .string(c.kind.rawValue), "url": .string(c.url), "size": JSON(c.size), "error": JSON(c.error)]
                })],
                next: ["app_config(sessionId: \(s.id), kind: \"remoteConfigurations\", path: \"general_settings\")"],
                sessionId: s.id)
        }
        let kinds = saved.map(\.kind.rawValue).sorted().joined(separator: ", ")
        guard let file = saved.first(where: { $0.kind.rawValue == raw }) else {
            throw ToolError("No saved \"\(raw)\" in session \(s.label); it has \(kinds). Example: app_config(kind: \"layout\", path: \"screens.0\").")
        }
        guard let sha = file.sha256, let data = try await ctx.store.configData(sha256: sha) else {
            throw ToolError("\(raw) couldn't be downloaded when saved: \(file.error ?? "unknown"). Its URL: \(file.url)")
        }
        var value = try JSON.parse(data)
        let path = try args.string("path") ?? ""
        var walked: [String] = []
        for step in path.split(separator: ".").map(String.init) {
            switch value {
            case .object(let o) where o[step] != nil: value = o[step]!
            case .array(let a) where Int(step).map(a.indices.contains) == true: value = a[Int(step)!]
            case .object(let o):
                throw ToolError("No key \"\(step)\" at \"\(walked.joined(separator: "."))\"; keys: \(o.keys.sorted().prefix(50).joined(separator: ", ")).")
            case .array(let a):
                throw ToolError("\"\(walked.joined(separator: "."))\" is an array of \(a.count): use an index 0…\(max(a.count - 1, 0)).")
            default:
                throw ToolError("\"\(walked.joined(separator: "."))\" is a value, not an object or array.")
            }
            walked.append(step)
        }
        let maxChars = try args.limit("maxChars", default: 20_000, max: 200_000)
        let text = value.prettyText
        let cut = text.count > maxChars
        var shape = ""
        var structured: [String: JSON] = ["sessionId": JSON(s.id), "kind": .string(raw), "path": .string(path),
                                "url": .string(file.url), "savedAt": .string(at), "truncated": .bool(cut)]
        if case .object(let o) = value {
            shape = ", object with \(o.count) keys"
            structured["keys"] = .array(o.keys.sorted().map { .string($0) })
        } else if case .array(let a) = value {
            shape = ", array of \(a.count)"
            structured["count"] = JSON(a.count)
        }
        return ToolResult(
            summary: "\(raw)\(path.isEmpty ? "" : " → " + path) of session \(s.label) (saved \(at))\(shape)"
                + (cut ? ", first \(maxChars) of \(text.count) characters" : "") + ".",
            body: cut ? String(text.prefix(maxChars)) + "\n… cut; narrow with path or raise maxChars" : text,
            structured: .object(structured),
            next: ["app_config(sessionId: \(s.id), kind: \"\(raw)\", path: \"\(path.isEmpty ? "" : path + ".")<key>\")"],
            sessionId: s.id)
    }
}
