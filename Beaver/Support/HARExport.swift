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
            "size": responseBody?.utf8.count ?? 0,
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
