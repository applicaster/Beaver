//
//  InfoTools.swift
//  Beaver
//
//  D79: the Info tab for agents — what app and device a session is.

import Foundation

enum InfoTools {
    static let all = [appInfo]

    static let appInfo = MCPTool(
        name: "app_info",
        title: "App and device info",
        description: "Use to learn what app and device a session is: app, SDK and QuickBrick versions, Zapp ids, the layout's screens, cell styles and plugins, and the device's model, OS, language, country and advertising id — each value with where it came from (storage, CMS, a config file, logs). Config files come from Zapp's public bucket; the Zapp CMS is asked only when the user set a Zapp token in Beaver's Settings → Zapp.",
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
        let cms: String = switch r.cms {
        case .noToken: "Zapp CMS not asked: no Zapp token (the user can set one in Beaver → Settings… → Zapp)."
        case .noVersionId: "Zapp CMS not asked: the app's storage has no version_id."
        case .loaded: "Zapp CMS: build_params loaded."
        case .failed(let why): "Zapp CMS failed: \(why)"
        }
        let configs = AppInfo.ConfigKind.allCases.compactMap { kind in
            r.configs[kind].map { "  \(kind.rawValue): \($0.url) (\($0.found))" + ($0.error.map { " — couldn't load: \($0)" } ?? "") }
        }

        let screenLines = r.screens.isEmpty ? "  none found"
            : r.screens.map { s -> String in "  \(s.name)  \(s.id)" + (s.type.map { "  " + $0 } ?? "") }.joined(separator: "\n")
        let pluginLines = r.plugins.map { p -> String in "  " + p.id + (p.version.map { " " + $0 } ?? "") }.joined(separator: "\n")
        let cellLines = r.cellStyles.map { c -> String in "  \(c.id)  \(c.plugin)" }.joined(separator: "\n")
        var sections: [String?] = [lines("Identity & versions", r.identity)]
        sections.append("Screens (\(r.screens.count), \(r.screensSource)):\n" + screenLines)
        sections.append("Plugins (\(r.plugins.count), \(r.pluginsSource)):\n" + pluginLines)
        sections.append(r.cellStyles.isEmpty ? nil : "Cell styles (\(r.cellStyles.count), \(r.cellStylesSource)):\n" + cellLines)
        sections.append(lines("Device", r.device.identity + r.device.hardware))
        sections.append(lines("Advertising", r.device.advertising) ?? r.device.advertisingNote)
        sections.append(lines("User agent", r.device.userAgent))
        sections.append(configs.isEmpty ? "Config files: none found." : "Config files:\n" + configs.joined(separator: "\n"))
        sections.append(cms)
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
            ],
            "device": [
                "identity": rows(r.device.identity), "hardware": rows(r.device.hardware),
                "advertising": rows(r.device.advertising), "userAgent": rows(r.device.userAgent),
            ],
            "configs": .object(Dictionary(uniqueKeysWithValues: r.configs.map { kind, c in
                (kind.rawValue, ["url": .string(c.url), "found": .string(c.found), "error": JSON(c.error)] as JSON)
            })),
            "cms": .string(cms),
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
}
