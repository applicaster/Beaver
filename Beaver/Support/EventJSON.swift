//
//  EventJSON.swift
//  Beaver
//

import Foundation

/// JSON import / export helpers, matching the file format of the old
/// Logger app so files are cross-compatible (D7).
///
/// Wire format reference: PROTOCOL.md §4.1.1. Each event object has
/// `subsystem`, `timestamp`, `level`, `message`, optional `category`,
/// optional `data`, optional `context`.
enum EventJSON {

    // MARK: - Decode

    /// Parses a file's bytes into decoded events. Accepts:
    ///  - a bare JSON array `[{...}, {...}]`
    ///  - a wrapped object `{"events": [...]}` (objects OR JSON strings)
    static func decode(_ data: Data) throws -> [DecodedEvent] {
        let json = try JSONSerialization.jsonObject(with: data)

        if let array = json as? [[String: Any]] {
            return array.compactMap(makeEvent)
        }

        if let object = json as? [String: Any], let events = object["events"] {
            if let array = events as? [[String: Any]] {
                return array.compactMap(makeEvent)
            }
            if let strings = events as? [String] {
                return strings.compactMap { string in
                    guard
                        let inner = string.data(using: .utf8),
                        let dict = try? JSONSerialization.jsonObject(with: inner) as? [String: Any]
                    else { return nil }
                    return makeEvent(dict)
                }
            }
        }
        return []
    }

    private static func makeEvent(_ dict: [String: Any]) -> DecodedEvent? {
        guard let subsystem = dict["subsystem"] as? String else { return nil }
        guard let message   = dict["message"]   as? String else { return nil }

        let timestamp: UInt64
        if let v = dict["timestamp"] as? UInt64 { timestamp = v }
        else if let v = dict["timestamp"] as? Int { timestamp = UInt64(v) }
        else if let v = dict["timestamp"] as? Double { timestamp = UInt64(v) }
        else { return nil }

        let level: LogLevel
        if let s = dict["level"] as? String, let parsed = LogLevel(rawValue: s) {
            level = parsed
        } else if let n = dict["level"] as? Int, let parsed = LogLevel(numericLevel: n) {
            level = parsed
        } else {
            return nil
        }

        let category = (dict["category"] as? String) ?? ""
        let dataJSON = (dict["data"]    as Any?).flatMap(jsonString)
        let contextJSON = (dict["context"] as Any?).flatMap(jsonString)

        return DecodedEvent(
            timestampMillis: timestamp,
            level: level,
            subsystem: subsystem,
            category: category,
            message: message,
            dataJSON: dataJSON,
            contextJSON: contextJSON
        )
    }

    // MARK: - Encode

    /// Renders an event list as a bare JSON array — matches the format
    /// the old Logger app exports.
    static func encode(_ events: [EventRecord], pretty: Bool = true) throws -> Data {
        let array: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "subsystem": event.subsystem,
                "timestamp": event.timestampMillis,
                "level":     event.level.rawValue,
                "message":   event.message,
                "category":  event.category,
            ]
            if let dataJSON = event.dataJSON,
               let parsed = try? JSONSerialization.jsonObject(with: Data(dataJSON.utf8)) {
                dict["data"] = parsed
            }
            if let contextJSON = event.contextJSON,
               let parsed = try? JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) {
                dict["context"] = parsed
            }
            return dict
        }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted] : []
        return try JSONSerialization.data(withJSONObject: array, options: options)
    }

    // MARK: - Helpers

    private static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
