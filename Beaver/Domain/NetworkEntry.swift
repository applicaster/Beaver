//
//  NetworkEntry.swift
//  Beaver
//

import Foundation

/// One captured HTTP request/response, as sent by the SDK in a `network`
/// frame (PROTOCOL.md §4.3). One frame is one finished request; there is no
/// request/response pairing on the wire.
///
/// `payloadJSON` is the payload as received. The store saves it and reads
/// it back through `parse`, so live and reopened sessions go through the
/// same code.
public struct NetworkEntry: Identifiable, Hashable, Sendable {

    public enum StatusClass: String, CaseIterable, Sendable {
        case success, redirect, clientError, serverError, failed, other

        public var displayName: String {
            switch self {
            case .success:     "2xx"
            case .redirect:    "3xx"
            case .clientError: "4xx"
            case .serverError: "5xx"
            case .failed:      "Failed"
            case .other:       "Other"
            }
        }
    }

    public let id: Int64
    public let requestId: String
    public let url: String
    public let method: String
    public let status: Int?
    public let statusText: String?
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBody: String?
    public let responseBody: String?
    public let startMillis: UInt64
    public let durationMillis: Int?
    public let error: String?
    public let payloadJSON: String

    public var host: String { URLComponents(string: url)?.host ?? "" }

    /// Path plus query, the "Path" column. Falls back to the whole URL
    /// when it doesn't parse, so the row is never blank.
    public var path: String {
        guard let c = URLComponents(string: url), c.host != nil else { return url }
        let p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        return c.percentEncodedQuery.map { "\(p)?\($0)" } ?? p
    }

    public var statusClass: StatusClass {
        guard let status else { return .failed }
        switch status {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default:        return .other
        }
    }

    /// `fallbackMillis` is used when the payload has neither `timing.startTime`
    /// nor `timestamp`. The decoder passes "now"; the store passes the row's
    /// saved `timestamp_ms`, so a reopened entry keeps its time.
    public static func parse(_ payloadJSON: String, id: Int64 = 0, fallbackMillis: UInt64) -> NetworkEntry? {
        guard let data = payloadJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = o["url"] as? String
        else { return nil }

        let timing = o["timing"] as? [String: Any]
        let start = ProtocolDecoder.timestampMillis(timing?["startTime"])
            ?? ProtocolDecoder.timestampMillis(o["timestamp"])
            ?? fallbackMillis
        let duration: Int? = int(timing?["duration"]) ?? {
            guard let end = int(timing?["endTime"]), let s = int(timing?["startTime"]) else { return nil }
            return end - s
        }()

        return NetworkEntry(
            id: id,
            requestId: o["requestId"] as? String ?? "",
            url: url,
            method: (o["method"] as? String ?? "GET").uppercased(),
            status: int(o["status"]),
            statusText: o["statusText"] as? String,
            requestHeaders: headers(o["requestHeaders"]),
            responseHeaders: headers(o["responseHeaders"]),
            requestBody: o["requestBody"] as? String,
            responseBody: o["responseBody"] as? String,
            startMillis: start,
            durationMillis: duration,
            error: o["error"] as? String,
            payloadJSON: payloadJSON
        )
    }

    /// Accepts a JSON number or numeric string; rejects JSON booleans.
    /// On Darwin, `NSNumber` 0/1 bridges to `Bool` via `as?`, so a plain
    /// `!(value is Bool)` check would wrongly reject `"duration":0` and
    /// wrongly accept `"status":true` as `1`. Checking the CFNumber's
    /// underlying type avoids both.
    private static func int(_ value: Any?) -> Int? {
        if let s = value as? String { return Int(s) }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        return nil
    }

    private static func headers(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.mapValues { ($0 as? String) ?? "\($0)" }
    }
}
