//
//  NetworkTools.swift
//  Beaver
//

import Foundation

enum NetworkTools {
    static let all = [query, get, copy]

    /// `errors`, `2xx`…`5xx`, `failed`, `noStatus`, or codes; any of them.
    static func statusMatcher(_ picks: [String]) throws -> @Sendable (NetworkEntry) -> Bool {
        let matchers: [@Sendable (NetworkEntry) -> Bool] = try picks.map { raw in
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let code = Int(p) { return { $0.status == code } }
            let pick: NetworkFilter.StatusPick? = switch p {
            case "errors", "error": .errors
            case "2xx": .statusClass(.success)
            case "3xx": .statusClass(.redirect)
            case "4xx": .statusClass(.clientError)
            case "5xx": .statusClass(.serverError)
            case "failed": .statusClass(.failed)
            case "nostatus", "none": .noStatus
            default: nil
            }
            guard let pick else {
                throw ToolError("Unknown status \"\(raw)\". Use errors, 2xx, 3xx, 4xx, 5xx, failed, noStatus, or a code like 401.")
            }
            return { pick.matches($0) }
        }
        return { entry in matchers.contains { $0(entry) } }
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
        if let picks = try args.strings("status"), !picks.isEmpty {
            let matches = try statusMatcher(picks)
            entries = entries.filter(matches)
        }
        if let methods = try args.strings("method"), !methods.isEmpty {
            let set = Set(methods.map { $0.uppercased() })
            entries = entries.filter { set.contains($0.method) }
        }
        if let hosts = try args.strings("host"), !hosts.isEmpty {
            let available = Array(Set(entries.map(\.host))).sorted()
            let r = ToolInput.resolveNames(hosts, among: available)
            if r.resolved.sorted() != hosts.sorted() { notes.append("host \(hosts.joined(separator: ", ")) → \(r.resolved.joined(separator: ", "))") }
            let set = Set(r.resolved)
            entries = entries.filter { set.contains($0.host) }
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
        func body(_ b: String?, sdkTruncated: Bool) -> (String, Bool) {
            guard let b, !b.isEmpty else { return ("  (empty)", false) }
            let c = ToolText.capped(b, maxBytes: ToolText.payloadCap)
            return (c.text + (sdkTruncated ? "\n  [cut by the SDK at 100 KB]" : "") + (c.truncated ? "\n  [cut at 256 KB]" : ""), c.truncated || sdkTruncated)
        }
        var lines = ["\(e.method) \(e.url)",
                     e.status.map { "Status: \($0) \(e.statusText ?? "")" } ?? "Failed: \(e.error ?? "no response")",
                     "Started: \(Date(timeIntervalSince1970: Double(e.startMillis) / 1000).ISO8601Format())"
                        + (e.durationMillis.map { " · \($0) ms" } ?? ""),
                     "Request headers:", headers(e.requestHeaders)]
        let request = body(e.requestBody, sdkTruncated: e.isRequestBodyTruncated)
        let response = body(e.responseBody, sdkTruncated: e.isResponseBodyTruncated)
        if includeBodies { lines += ["Request body:", request.0] }
        lines += ["Response headers:", headers(e.responseHeaders)]
        if includeBodies { lines += ["Response body:", response.0] }
        return ToolResult(
            summary: "Request #\(id): \(e.method) \(e.host)\(e.path) → \(e.status.map(String.init) ?? "failed").",
            body: lines.joined(separator: "\n"),
            structured: [
                "id": JSON(id), "method": .string(e.method), "url": .string(e.url),
                "status": JSON(e.status), "statusText": JSON(e.statusText), "error": JSON(e.error),
                "startMs": JSON(e.startMillis), "durationMs": JSON(e.durationMillis),
                "requestHeaders": .object(e.requestHeaders.mapValues(JSON.string)),
                "responseHeaders": .object(e.responseHeaders.mapValues(JSON.string)),
                "requestBody": includeBodies ? JSON(e.requestBody) : .null,
                "responseBody": includeBodies ? JSON(e.responseBody) : .null,
                "bodiesTruncated": .bool(request.1 || response.1),
            ],
            next: ["network_copy(id: \(id), format: \"curl\") to replay it"]
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
        return ToolResult(summary: "\(label) for request #\(id)\(warnings).", body: text,
                          structured: ["id": JSON(id), "format": .string(format), "text": .string(text)])
    }
}
