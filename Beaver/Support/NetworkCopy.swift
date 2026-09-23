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
        var parts = ["curl -X \(method) \(Self.shellQuoted(url))"]
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

    public var responseBytes: Int? { responseBody?.utf8.count }

    /// "403 Forbidden", "-999 — cancelled", or the error / "—" with no status.
    public var statusLine: String {
        guard let status else { return error ?? "—" }
        guard status >= 100 else { return error.map { "\(status) — \($0)" } ?? "\(status)" }
        // iOS sends "no error" as statusText for every response; Foundation's
        // own reason for 200 is "no error" too.
        let text = statusText?.trimmingCharacters(in: .whitespaces) ?? ""
        var reason = text.isEmpty || text.lowercased() == "no error"
            ? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
            : text
        if reason.lowercased() == "no error" { reason = "OK" }
        return "\(status) \(reason)"
    }

    // MARK: Helpers

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
