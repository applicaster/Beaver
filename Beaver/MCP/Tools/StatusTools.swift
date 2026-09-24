//
//  StatusTools.swift
//  Beaver
//

import Foundation

enum StatusTools {
    static let all = [status, sessionsList]

    static let status = MCPTool(
        name: "beaver_status",
        title: "Beaver status",
        description: "Use first, and whenever you are unsure what is connected: whether a device is connected and which app, the live and viewed session ids, the latest event id (a starting point for afterId), and where the device should connect.",
        kind: .read,
        inputSchema: ToolSchema.object([:])
    ) { _, ctx in
        let host = await ctx.ui.snapshot()
        let sessions = try await ctx.store.sessions()
        var devices: [JSON] = []
        var lines: [String] = []
        if host.deviceConnected, let live = host.liveSessionId,
           let session = sessions.first(where: { $0.id == live }) {
            let latest = try await ctx.store.latestEventId(sessionId: live)
            // ponytail: "current" until the device handshake (phase 2) gives a stable device id.
            devices.append([
                "id": "current",
                "app": JSON(session.appName), "appVersion": JSON(session.appVersion),
                "model": JSON(session.deviceModel), "platform": JSON(session.platform),
                "osVersion": JSON(session.osVersion),
                "liveSessionId": JSON(live), "latestEventId": JSON(latest),
            ])
            lines.append("Device: \(describeDevice(session)) — live session #\(live)"
                + (latest.map { ", latest event #\($0)" } ?? ", no events yet"))
        }
        lines.append("Beaver \(host.beaverVersion) · WebSocket \(host.serverState)"
            + (host.deviceURL.map { " · the device connects to \($0)" } ?? ""))
        if let viewing = host.viewingSessionId { lines.append("The user is viewing session #\(viewing).") }
        lines.append("\(sessions.count) session(s) stored.")
        let notificationsSuffix: String = switch host.notifications {
        case .allowed: "."
        case .muted: " (the user muted them in Beaver)."
        case .notDetermined: " — Beaver asks the user the first time you send an attention note."
        case .denied: " — attention notes can't reach the user in the background. Turn on: \(AgentNotifications.howToEnable)."
        }
        lines.append("Agent notifications: \(host.notifications.rawValue)" + notificationsSuffix)

        let summary = devices.isEmpty
            ? "No device is connected. \(sessions.isEmpty ? "No sessions are stored yet." : "Past sessions can still be read.")"
            : "A device is connected: \(lines[0].dropFirst("Device: ".count))."
        let next: [String] = devices.isEmpty
            ? (sessions.isEmpty
                ? ["ask the user to connect the app to \(host.deviceURL ?? "Beaver") with remote assistance, then beaver_status()"]
                : ["sessions_list()", "logs_facets(sessionId: \(sessions[0].id))"])
            : ["logs_facets(since: \"10m\")", "logs_query(filter: {minLevel: \"warning\"}, since: \"10m\")"]
        return ToolResult(
            summary: summary,
            body: lines.joined(separator: "\n"),
            structured: [
                "beaver": ["version": .string(host.beaverVersion), "mcpPort": JSON(host.mcpPort)],
                "webSocket": ["state": .string(host.serverState), "deviceURL": JSON(host.deviceURL)],
                "devices": .array(devices),
                "viewingSessionId": JSON(host.viewingSessionId),
                "sessionCount": JSON(sessions.count),
                "notifications": .string(host.notifications.rawValue),
            ],
            next: next,
            sessionId: host.liveSessionId
        )
    }

    static let sessionsList = MCPTool(
        name: "sessions_list",
        title: "List sessions",
        description: "Use when you need a session other than the live one, or to see what Beaver has stored: every session, newest first, with its app, device, and event and request counts.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "limit": ToolSchema.integer("How many, newest first. Default 20, max 200."),
            "source": ToolSchema.string("Only live or only imported sessions.", oneOf: ["live", "imported", "any"]),
        ])
    ) { args, ctx in
        let limit = try args.limit(default: 20, max: 200)
        let sourceStr = try args.string("source")
        let source: Session.Source?
        if let s = sourceStr {
            let normalized = s.lowercased()
            if normalized == "any" {
                source = nil
            } else if normalized == "live" {
                source = .live
            } else if normalized == "imported" {
                source = .imported
            } else {
                throw ToolError("source must be live, imported or any. Example: sessions_list(source: \"live\").")
            }
        } else {
            source = nil
        }
        let all = try await ctx.store.sessions().filter { source == nil || $0.source == source }
        guard !all.isEmpty else {
            return ToolResult(summary: "Beaver has no sessions yet.",
                              structured: ["sessions": []],
                              next: ["beaver_status() to see how the device connects"])
        }
        // `Session.isActive` (no endedAt) isn't enough on its own: a crash
        // can leave an old session unended even though it's no longer the
        // device's current one. Only the host's own liveSessionId says
        // which session is actually live now.
        let host = await ctx.ui.snapshot()
        var rows: [JSON] = []
        var lines: [String] = []
        for session in all.prefix(limit) {
            let events = try await ctx.store.eventCount(sessionId: session.id, filter: .none)
            let requests = try await ctx.store.networkEntryCount(sessionId: session.id)
            let liveNow = session.id == host.liveSessionId
            rows.append([
                "id": JSON(session.id), "source": .string(session.source.rawValue),
                "startedAt": .string(session.startedAt.ISO8601Format()),
                "endedAt": JSON(session.endedAt?.ISO8601Format()),
                "app": JSON(session.appName), "appVersion": JSON(session.appVersion),
                "device": JSON(session.deviceModel), "platform": JSON(session.platform),
                "events": JSON(events), "requests": JSON(requests),
                "liveNow": .bool(liveNow),
            ])
            lines.append("#\(session.id) \(session.source.rawValue)\(liveNow ? " (live now)" : "")"
                + " · started \(session.startedAt.ISO8601Format())"
                + " · \(describeDevice(session)) · \(events) events · \(requests) requests")
        }
        return ToolResult(
            summary: "\(all.count) session(s), newest first" + (all.count > limit ? "; showing \(limit)." : "."),
            body: lines.joined(separator: "\n"),
            structured: ["sessions": .array(rows), "total": JSON(all.count)],
            next: ["logs_facets(sessionId: \(all[0].id))"]
        )
    }

    static func describeDevice(_ s: Session) -> String {
        let app = [s.appName, s.appVersion].compactMap { $0 }.joined(separator: " ")
        let device = [s.deviceModel, [s.platform, s.osVersion].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        switch (app.isEmpty, device.isEmpty) {
        case (true, true): return "unknown app"
        case (false, true): return app
        case (true, false): return device
        case (false, false): return "\(app) (\(device))"
        }
    }
}
