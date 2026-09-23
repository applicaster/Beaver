//
//  HARExport.swift
//  Beaver
//

import Foundation

/// HAR 1.2 (http://www.softwareishard.com/blog/har-12-spec/) for the
/// Network tab's "Export HAR" button, so a capture opens in Chrome
/// DevTools, Charles or zapp-support.
public enum HARExport {

    public static func encode(_ entries: [NetworkEntry], creatorVersion: String) throws -> Data {
        let root: [String: Any] = ["log": [
            "version": "1.2",
            "creator": ["name": "Beaver", "version": creatorVersion],
            "entries": entries.map(entry),
        ]]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// The HAR's entries as network payloads, parsed by `NetworkEntry.parse`
    /// like any other. Entries without a request URL are skipped; anything
    /// that isn't a HAR decodes to `[]`. A base64-encoded `content.text`
    /// (`content.encoding == "base64"`) is decoded when it's valid UTF-8
    /// text; otherwise (binary, or bad base64) the raw text is kept as is.
    public static func decode(_ data: Data) -> [NetworkEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = (root["log"] as? [String: Any])?["entries"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap(payload)
    }

    private static func payload(_ h: [String: Any]) -> NetworkEntry? {
        guard let request = h["request"] as? [String: Any],
              let url = request["url"] as? String else { return nil }
        let response = h["response"] as? [String: Any] ?? [:]

        var o: [String: Any] = [
            "url": url,
            "method": request["method"] as? String ?? "GET",
            "requestHeaders": flatHeaders(request["headers"]),
            "responseHeaders": flatHeaders(response["headers"]),
        ]
        // HAR writes 0 for "no response".
        if let status = (response["status"] as? NSNumber)?.intValue, status > 0 { o["status"] = status }
        if let text = response["statusText"] as? String, !text.isEmpty { o["statusText"] = text }
        if let body = (request["postData"] as? [String: Any])?["text"] as? String { o["requestBody"] = body }
        if let content = response["content"] as? [String: Any], let body = content["text"] as? String {
            o["responseBody"] = bodyText(body, encoding: content["encoding"] as? String)
        }
        if let error = h["_error"] as? String { o["error"] = error }

        let start = (h["startedDateTime"] as? String).flatMap(millis)
        var timing: [String: Any] = [:]
        if let start {
            o["timestamp"] = start
            timing["startTime"] = start
        }
        // Bounded so a hostile file can't trap the Int conversion.
        if let time = (h["time"] as? NSNumber)?.doubleValue, time >= 0, time < 1e12 {
            timing["duration"] = Int(time)
        }
        if !timing.isEmpty { o["timing"] = timing }

        guard let json = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        return NetworkEntry.parse(String(decoding: json, as: UTF8.self), fallbackMillis: start ?? 0)
    }

    /// Decodes a base64 `content.text` when it decodes to valid UTF-8 text;
    /// otherwise (not base64-encoded, binary content, or malformed base64)
    /// returns `text` unchanged.
    private static func bodyText(_ text: String, encoding: String?) -> String {
        guard encoding == "base64",
              let data = Data(base64Encoded: text),
              let decoded = String(data: data, encoding: .utf8)
        else { return text }
        return decoded
    }

    /// `[{name, value}]` to a dictionary; a repeated name joins with ", ".
    private static func flatHeaders(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for pair in value as? [[String: Any]] ?? [] {
            guard let name = pair["name"] as? String else { continue }
            let value = pair["value"] as? String ?? ""
            out[name] = out[name].map { "\($0), \(value)" } ?? value
        }
        return out
    }

    private static func millis(_ iso: String) -> UInt64? {
        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))
            ?? (try? Date.ISO8601FormatStyle().parse(iso))
        guard let seconds = date?.timeIntervalSince1970, seconds >= 0 else { return nil }
        return UInt64((seconds * 1000).rounded())
    }

    private static func entry(_ e: NetworkEntry) -> [String: Any] {
        let time = e.durationMillis ?? 0
        let requestBody = e.requestBody.flatMap { $0.isEmpty ? nil : $0 }
        let responseBody = e.responseBody.flatMap { $0.isEmpty ? nil : $0 }

        var request: [String: Any] = [
            "method": e.method,
            "url": e.url,
            "httpVersion": "HTTP/1.1",
            "headers": headers(e.requestHeaders),
            "queryString": e.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] },
            "cookies": [Any](),
            "headersSize": -1,
            "bodySize": requestBody?.utf8.count ?? 0,
        ]
        if let requestBody {
            request["postData"] = [
                "mimeType": header("Content-Type", in: e.requestHeaders) ?? "application/octet-stream",
                "text": requestBody,
            ]
        }

        var content: [String: Any] = [
            // The reported (real, pre-truncation) size when the SDK sent
            // one, else what was actually captured.
            "size": e.responseBodySize ?? responseBody?.utf8.count ?? 0,
            "mimeType": header("Content-Type", in: e.responseHeaders) ?? "x-unknown",
        ]
        if let responseBody { content["text"] = responseBody }

        let httpStatus = e.status.flatMap { $0 >= 100 ? $0 : nil }
        let response: [String: Any] = [
            "status": httpStatus ?? 0,
            // statusLine is "403 Forbidden"; HAR wants the reason alone.
            "statusText": httpStatus.map {
                String(e.statusLine.dropFirst(String($0).count)).trimmingCharacters(in: .whitespaces)
            } ?? "",
            "httpVersion": "HTTP/1.1",
            "headers": headers(e.responseHeaders),
            "cookies": [Any](),
            "content": content,
            "redirectURL": header("Location", in: e.responseHeaders) ?? "",
            "headersSize": -1,
            "bodySize": responseBody?.utf8.count ?? -1,
        ]

        var o: [String: Any] = [
            "startedDateTime": isoMillis(e.startMillis),
            "time": time,
            "request": request,
            "response": response,
            "cache": [String: Any](),
            "timings": ["send": 0, "wait": time, "receive": 0],
        ]
        // Custom fields start with `_` per the spec.
        if let error = e.error { o["_error"] = error }
        return o
    }

    private static func headers(_ h: [String: String]) -> [[String: String]] {
        h.keys.sorted().map { ["name": $0, "value": h[$0]!] }
    }

    private static func header(_ name: String, in h: [String: String]) -> String? {
        h.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `2023-11-14T22:13:20.123Z`. The milliseconds are appended from the
    /// integer so they never go through a lossy Double.
    private static func isoMillis(_ ms: UInt64) -> String {
        let seconds = Date(timeIntervalSince1970: TimeInterval(ms / 1000)).formatted(.iso8601)
        return String(seconds.dropLast()) + String(format: ".%03dZ", Int(ms % 1000))
    }
}
