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
