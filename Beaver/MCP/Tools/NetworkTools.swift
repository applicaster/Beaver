//
//  NetworkTools.swift
//  Beaver
//

import Foundation

enum NetworkTools {
    static let all = [query, get, copy]

    /// `errors`, `2xx`…`5xx`, `failed`, `noStatus`, or a code.
    static func statusPick(_ raw: String) throws -> NetworkFilter.StatusPick {
        let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let code = Int(p) { return .code(code) }
        switch p {
        case "errors", "error": return .errors
        case "2xx": return .statusClass(.success)
        case "3xx": return .statusClass(.redirect)
        case "4xx": return .statusClass(.clientError)
        case "5xx": return .statusClass(.serverError)
        case "failed": return .statusClass(.failed)
        case "nostatus", "none": return .noStatus
        default:
            throw ToolError("Unknown status \"\(raw)\". Use errors, 2xx, 3xx, 4xx, 5xx, failed, noStatus, or a code like 401.")
        }
    }

    /// Any of `picks`.
    static func statusMatcher(_ picks: [String]) throws -> @Sendable (NetworkEntry) -> Bool {
        let matchers = try picks.map(statusPick)
        return { entry in matchers.contains { $0.matches(entry) } }
    }

    static func line(_ e: NetworkEntry) -> String {
        let status = e.status.map(String.init) ?? ("failed" + (e.error.map { " (\($0))" } ?? ""))
        let duration = e.durationMillis.map(NetworkEntry.compactDuration) ?? "—"
        let size = e.responseBytes.map(NetworkEntry.compactSize) ?? "—"
        let url = e.url.count > 300 ? String(e.url.prefix(300)) + "…" : e.url
        return "#\(e.id) \(e.method) \(status) \(duration) \(size) \(url)"
    }

    static let query = MCPTool(
        name: "network_query",
        title: "Query network requests",
        description: "Use to find HTTP requests the app made: filter by status (errors, 4xx, 401…), method, host (globs work) and text in the URL, headers or bodies. One line per request: id, method, status, duration, size, URL. Details: network_get.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "sessionId": ToolSchema.sessionId,
            "status": ToolSchema.strings("Any of: errors, 2xx, 3xx, 4xx, 5xx, failed, noStatus, or codes like 401."),
            "method": ToolSchema.strings("Any of these methods, e.g. [\"POST\"]."),
            "host": ToolSchema.strings("Any of these hosts; * globs and fragments work."),
            "search": ToolSchema.string("Text in the URL, status, headers or bodies; case-insensitive."),
            "afterId": ToolSchema.integer("Only requests with a larger id; returns the oldest first."),
            "limit": ToolSchema.integer("Rows. Default 100, max 500."),
        ])
    ) { args, ctx in
        let s = try await ctx.resolveSession(args)
        let afterId = try args.int64("afterId")
        let limit = try args.limit(default: 100, max: 500)
        var entries = try await ctx.store.networkEntries(sessionId: s.id, afterId: afterId ?? 0)
        var notes: [String] = []

        // Resolve host filter against all hosts in the session, before other filters narrow them
        var resolvedHosts: Set<String>? = nil
        if let hosts = try args.strings("host"), !hosts.isEmpty {
            let allEntries = try await ctx.store.networkEntries(sessionId: s.id)
            let available = Array(Set(allEntries.map(\.host))).sorted()
            let r = ToolInput.resolveNames(hosts, among: available)
            if let miss = r.misses.first {
                throw ToolError("No host matches \"\(miss.pattern)\" in session #\(s.id). Closest: \(miss.closest.joined(separator: ", ")). Example: network_query() lists them all.")
            }
            resolvedHosts = Set(r.resolved)
            if r.resolved.sorted() != hosts.sorted() { notes.append("host \(hosts.joined(separator: ", ")) → \(r.resolved.joined(separator: ", "))") }
        }

        if let picks = try args.strings("status"), !picks.isEmpty {
            let matches = try statusMatcher(picks)
            entries = entries.filter(matches)
        }
        if let methods = try args.strings("method"), !methods.isEmpty {
            let set = Set(methods.map { $0.uppercased() })
            entries = entries.filter { set.contains($0.method) }
        }
        if let hosts = resolvedHosts {
            entries = entries.filter { hosts.contains($0.host) }
        }
        if let search = try args.string("search"), !search.isEmpty {
            var f = NetworkFilter()
            f.search = search
            entries = entries.filter(f.matches)
        }
        let page = afterId == nil ? Array(entries.suffix(limit)) : Array(entries.prefix(limit))
        let resolved = notes.isEmpty ? "" : " Resolved: " + notes.joined(separator: "; ") + "."
        guard let first = page.first else {
            return ToolResult(summary: "No requests match in session \(s.label).\(resolved)",
                              structured: ["sessionId": JSON(s.id), "total": 0, "requests": []],
                              next: ["network_query() without filters", "logs_query(filter: {search: \"http\"})"],
                              sessionId: s.id)
        }
        return ToolResult(
            summary: "\(entries.count) request(s) match in session \(s.label); showing \(page.count) in arrival order.\(resolved)",
            body: page.map(line).joined(separator: "\n"),
            structured: [
                "sessionId": JSON(s.id), "total": JSON(entries.count),
                "requests": .array(page.map { e in
                    ["id": JSON(e.id), "method": .string(e.method), "url": .string(e.url),
                     "status": JSON(e.status), "error": JSON(e.error),
                     "durationMs": JSON(e.durationMillis), "responseBytes": JSON(e.responseBytes)]
                }),
            ],
            next: ["network_get(id: \(first.id))", "network_copy(id: \(first.id), format: \"curl\")"],
            sessionId: s.id
        )
    }

    static let get = MCPTool(
        name: "network_get",
        title: "Get a request",
        description: "Use to read one request in full: method, URL, status, timing, request and response headers and bodies. Bodies are as the SDK sent them (capped at 100 KB by the SDK, and at 256 KB here).",
        kind: .read,
        inputSchema: ToolSchema.object([
            "id": ToolSchema.integer("Request id from network_query."),
            "includeBodies": ToolSchema.boolean("Default true."),
        ], required: ["id"])
    ) { args, ctx in
        guard let id = try args.int64("id") else {
            throw ToolError("id is required. Example: network_get(id: 391) — ids come from network_query().")
        }
        guard let e = try await ctx.store.networkEntry(id: id) else {
            throw ToolError("No request #\(id). Example: network_query() lists the ids.")
        }
        let includeBodies = try args.bool("includeBodies") ?? true
        func headers(_ h: [String: String]) -> String {
            h.isEmpty ? "  (none)" : NetworkEntry.sortedHeaders(h).map { "  \($0.name): \($0.value)" }.joined(separator: "\n")
        }
        // `capped` is what goes in `structuredContent` too — the same text
        // the agent reads in `body`, not the untouched raw string, so a
        // truncated display and an uncut structured value can never disagree.
        func body(_ b: String?, sdkTruncated: Bool) -> (display: String, capped: String?, truncated: Bool) {
            guard let b, !b.isEmpty else { return ("  (empty)", b, false) }
            let c = ToolText.capped(b, maxBytes: ToolText.payloadCap)
            let display = c.text + (sdkTruncated ? "\n  [cut by the SDK at 100 KB]" : "") + (c.truncated ? "\n  [cut at 256 KB]" : "")
            return (display, c.text, c.truncated || sdkTruncated)
        }
        var lines = ["\(e.method) \(e.url)",
                     e.status.map { "Status: \($0) \(e.statusText ?? "")" } ?? "Failed: \(e.error ?? "no response")",
                     "Started: \(Date(timeIntervalSince1970: Double(e.startMillis) / 1000).ISO8601Format())"
                        + (e.durationMillis.map { " · \($0) ms" } ?? ""),
                     "Request headers:", headers(e.requestHeaders)]
        let request = body(e.requestBody, sdkTruncated: e.isRequestBodyTruncated)
        let response = body(e.responseBody, sdkTruncated: e.isResponseBodyTruncated)
        if includeBodies { lines += ["Request body:", request.display] }
        lines += ["Response headers:", headers(e.responseHeaders)]
        if includeBodies { lines += ["Response body:", response.display] }
        return ToolResult(
            summary: "Request #\(id): \(e.method) \(e.host)\(e.path) → \(e.status.map(String.init) ?? "failed").",
            body: lines.joined(separator: "\n"),
            structured: [
                "id": JSON(id), "method": .string(e.method), "url": .string(e.url),
                "status": JSON(e.status), "statusText": JSON(e.statusText), "error": JSON(e.error),
                "startMs": JSON(e.startMillis), "durationMs": JSON(e.durationMillis),
                "requestHeaders": .object(e.requestHeaders.mapValues(JSON.string)),
                "responseHeaders": .object(e.responseHeaders.mapValues(JSON.string)),
                "requestBody": includeBodies ? JSON(request.capped) : .null,
                "responseBody": includeBodies ? JSON(response.capped) : .null,
                "bodiesTruncated": .bool(request.truncated || response.truncated),
            ],
            next: ["network_copy(id: \(id), format: \"curl\") to replay it"],
            links: [AgentLink(networkId: id)]
        )
    }

    static let copy = MCPTool(
        name: "network_copy",
        title: "Copy a request",
        description: "Use to reproduce a request outside the app: the same cURL, fetch() or JSON text as Beaver's Copy menu, with what may make a replay fail (redacted headers, cut bodies).",
        kind: .read,
        inputSchema: ToolSchema.object([
            "id": ToolSchema.integer("Request id from network_query."),
            "format": ToolSchema.string("curl (default), fetch or json.", oneOf: ["curl", "fetch", "json"]),
        ], required: ["id"])
    ) { args, ctx in
        guard let id = try args.int64("id") else {
            throw ToolError("id is required. Example: network_copy(id: 391, format: \"curl\").")
        }
        guard let e = try await ctx.store.networkEntry(id: id) else {
            throw ToolError("No request #\(id). Example: network_query() lists the ids.")
        }
        let format = (try args.string("format") ?? "curl").lowercased()
        let label: String
        let text: String
        switch format {
        case "curl":
            label = "cURL"
            text = e.curlCommand
        case "fetch":
            label = "fetch"
            text = e.fetchSnippet
        case "json":
            label = "JSON"
            text = NetworkEntry.prettyPayloadJSON(try await ctx.store.networkPayload(id: id) ?? "{}")
        default:
            throw ToolError("Unknown format \"\(format)\". Use curl, fetch or json.")
        }
        // Same warnings as the Copy menu's toast: "Copied cURL: Authorization redacted by the SDK".
        let warnings = e.copyToast(label).dropFirst("Copied \(label)".count)
        let capped = ToolText.capped(text, maxBytes: ToolText.payloadCap)
        let cutNote = capped.truncated ? " (cut at 256 KB)" : ""
        return ToolResult(summary: "\(label) for request #\(id)\(warnings)\(cutNote).", body: capped.text,
                          structured: ["id": JSON(id), "format": .string(format), "text": .string(capped.text),
                                       "truncated": .bool(capped.truncated)],
                          next: ["network_get(id: \(id)) for headers and bodies", "network_query(status: \"errors\") for other failing requests"],
                          links: [AgentLink(networkId: id)])
    }
}
