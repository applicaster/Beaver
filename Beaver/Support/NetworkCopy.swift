//
//  NetworkCopy.swift
//  Beaver
//

import Foundation

/// Text the Network detail pane copies and shows: cURL, request/response
/// as JSON, and the status line.
extension NetworkEntry {

    /// `curl -X GET 'url' -H 'Name: value' --data-raw 'body'`, headers
    /// sorted by name and kept as sent (including `[REDACTED]`).
    public var curlCommand: String {
        var parts = ["curl -X \(Self.shellQuoted(method)) \(Self.shellQuoted(url))"]
        parts += requestHeaders.keys.sorted().map { "-H \(Self.shellQuoted("\($0): \(requestHeaders[$0]!)"))" }
        if let requestBody, !requestBody.isEmpty { parts.append("--data-raw \(Self.shellQuoted(requestBody))") }
        return parts.joined(separator: " ")
    }

    /// A JS `fetch(...)` call reproducing the request.
    public var fetchSnippet: String {
        var lines = ["fetch(\(Self.jsLiteral(url)), {", "  method: \(Self.jsLiteral(method)),"]
        if !requestHeaders.isEmpty {
            lines.append("  headers: {")
            lines += requestHeaders.keys.sorted().map {
                "    \(Self.jsLiteral($0)): \(Self.jsLiteral(requestHeaders[$0]!)),"
            }
            lines.append("  },")
        }
        if let requestBody, !requestBody.isEmpty { lines.append("  body: \(Self.jsLiteral(requestBody)),") }
        lines.append("});")
        return lines.joined(separator: "\n")
    }

    /// Scheme, host, port and path, with `...` when a query or fragment was
    /// cut: `https://host/beacon/user-data/favorites...`. The URL itself
    /// when there is nothing to cut or it doesn't parse.
    public var shortURL: String {
        guard let c = URLComponents(string: url), let scheme = c.scheme, let host = c.percentEncodedHost,
              c.percentEncodedQuery != nil || c.percentEncodedFragment != nil
        else { return url }
        return "\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")\(c.percentEncodedPath)..."
    }

    /// Percent-decoded, in URL order.
    public var queryItems: [URLQueryItem] { URLComponents(string: url)?.queryItems ?? [] }

    public var rawQuery: String? { URLComponents(string: url)?.percentEncodedQuery }

    /// Query parameters as a sorted JSON object; a repeated key becomes an array.
    public var queryJSON: String? {
        let items = queryItems
        guard !items.isEmpty else { return nil }
        var values: [String: [String]] = [:]
        for item in items { values[item.name, default: []].append(item.value ?? "") }
        return Self.pretty(values.mapValues { $0.count == 1 ? $0[0] as Any : $0 as Any })
    }

    /// The SDK caps bodies at 100 000 characters and marks the cut.
    public var isResponseBodyTruncated: Bool { responseBody?.hasSuffix(TruncatedJSON.marker) ?? false }
    public var isRequestBodyTruncated: Bool { requestBody?.hasSuffix(TruncatedJSON.marker) ?? false }

    /// `237 B`, `4.2 KB`, `42 KB`, `1.5 MB` — decimal units like
    /// `ByteCountFormatter`'s `.file` style, so a 100 000-character body
    /// reads `100 KB`; short enough for the table's Size column.
    public static func compactSize(_ bytes: Int) -> String {
        guard bytes >= 1000 else { return "\(bytes) B" }
        var value = Double(bytes) / 1000, unit = "KB"
        if value >= 999.5 { value /= 1000; unit = "MB" }
        return value < 9.95 ? String(format: "%.1f ", value) + unit : "\(Int(value.rounded())) \(unit)"
    }

    /// The table's Size cell stands out from 1 MB, or when it shows the
    /// `+` of a body the SDK cut and no reported size says how big it was.
    public var isTableSizeWarning: Bool {
        guard let bytes = responseBodySize ?? responseBytes else { return false }
        return bytes >= 1_000_000 || (isResponseBodyTruncated && responseBodySize == nil)
    }

    /// Duration colour tier: quiet under 1 s, slow to 3 s, very slow after.
    public enum DurationTier: Sendable {
        case normal, slow, verySlow

        public init(millis: Int?) {
            switch millis ?? 0 {
            case ..<1000: self = .normal
            case ..<3000: self = .slow
            default: self = .verySlow
            }
        }
    }

    /// Headers by name, ignoring case (ties broken by the exact name), for
    /// the detail pane's grid and its Raw lines.
    public static func sortedHeaders(_ h: [String: String]) -> [(name: String, value: String)] {
        h.sorted { ($0.key.lowercased(), $0.key) < ($1.key.lowercased(), $1.key) }.map { ($0.key, $0.value) }
    }

    public var requestJSON: String {
        var o: [String: Any] = ["method": method, "url": url]
        if !requestHeaders.isEmpty { o["headers"] = requestHeaders }
        if let body = Self.bodyValue(requestBody) { o["body"] = body }
        return Self.pretty(o)
    }

    public var responseJSON: String {
        var o: [String: Any] = [:]
        if let status { o["status"] = status }
        if let statusText { o["statusText"] = statusText }
        if !responseHeaders.isEmpty { o["headers"] = responseHeaders }
        if let body = Self.bodyValue(responseBody) { o["body"] = body }
        if let error { o["error"] = error }
        return Self.pretty(o)
    }

    /// The payload as received, pretty-printed; raw when it won't re-parse.
    public var prettyPayloadJSON: String {
        guard let o = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) else { return payloadJSON }
        return Self.pretty(o)
    }

    public var responseBytes: Int? {
        guard let responseBody, !responseBody.isEmpty else { return nil }
        return responseBody.utf8.count
    }

    /// The original body size, best source first: the SDK's own reported
    /// size, then (for a truncated response) the `Content-Length` header,
    /// then the bytes actually captured.
    public struct BodySize: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            case reported
            /// The `Content-Encoding` value (lowercased, trimmed); `nil`
            /// when absent or `identity`.
            case contentLength(encoding: String?)
            case captured
        }
        public let bytes: Int
        public let source: Source
        /// True only for `.captured` when the SDK cut the body short — the
        /// real size is at least this many bytes, possibly more.
        public let isLowerBound: Bool
    }

    public var responseSize: BodySize? {
        if let responseBodySize { return BodySize(bytes: responseBodySize, source: .reported, isLowerBound: false) }
        if isResponseBodyTruncated, let bytes = Self.contentLength(responseHeaders) {
            let normalized = Self.header("Content-Encoding", in: responseHeaders)?
                .trimmingCharacters(in: .whitespaces).lowercased()
            let encoding = normalized == "identity" ? nil : normalized
            return BodySize(bytes: bytes, source: .contentLength(encoding: encoding), isLowerBound: false)
        }
        guard let responseBytes else { return nil }
        return BodySize(bytes: responseBytes, source: .captured, isLowerBound: isResponseBodyTruncated)
    }

    public var requestSize: BodySize? {
        if let requestBodySize { return BodySize(bytes: requestBodySize, source: .reported, isLowerBound: false) }
        guard let requestBody, !requestBody.isEmpty else { return nil }
        return BodySize(bytes: requestBody.utf8.count, source: .captured, isLowerBound: isRequestBodyTruncated)
    }

    private static func contentLength(_ headers: [String: String]) -> Int? {
        header("Content-Length", in: headers).flatMap { Int($0) }
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// "403 Forbidden", "-999 — cancelled", or the error / "—" with no status.
    public var statusLine: String {
        guard let status else { return error ?? "—" }
        guard status >= 100 else { return error.map { "\(status) — \($0)" } ?? "\(status)" }
        // iOS sends "no error" as statusText for every response; Foundation's
        // own reason for 200 is "no error" too.
        let text = statusText?.trimmingCharacters(in: .whitespaces) ?? ""
        let reason = text.isEmpty || text.lowercased() == "no error"
            ? Self.reasonPhrases[status]
            : text
        guard let reason, reason.lowercased() != "no error" else { return "\(status)" }
        return "\(status) \(reason)"
    }

    /// The Status dropdown's label: "404 Not Found", "-999", "No status".
    public static func statusLabel(for pick: NetworkFilter.StatusPick) -> String {
        switch pick {
        case .errors: "Errors"
        case .statusClass(let c): c.displayName
        case .noStatus: "No status"
        case .code(let code): (reasonPhrases[code] ?? urlErrorNames[code]).map { "\(code) \($0)" } ?? "\(code)"
        }
    }

    /// NSURLError codes the iOS SDK sends in place of an HTTP status.
    private static let urlErrorNames: [Int: String] = [
        -999: "cancelled", -1001: "timed out", -1003: "host not found", -1004: "cannot connect",
        -1005: "connection lost", -1009: "offline", -1200: "TLS error", -1202: "bad certificate",
    ]

    // MARK: Helpers

    /// Fixed English IANA reason phrases, independent of the device locale.
    private static let reasonPhrases: [Int: String] = [
        100: "Continue", 101: "Switching Protocols",
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
        412: "Precondition Failed", 413: "Payload Too Large", 415: "Unsupported Media Type",
        422: "Unprocessable Entity", 429: "Too Many Requests",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout",
    ]

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Parsed JSON (object or array) when the body is JSON, else the raw text.
    /// A JSON string literal, which is also a valid JS one.
    private static func jsLiteral(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    private static func bodyValue(_ body: String?) -> Any? {
        guard let body, !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) ?? body
    }

    private static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}
