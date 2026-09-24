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

    /// One exported session: its events, the device storage as it
    /// stood, and every captured network request. A file holding only
    /// events still decodes — `storage` and `network` are simply
    /// empty — so everything written before this existed, and
    /// anything the old Logger app produced, still opens.
    struct Export {
        var events: [DecodedEvent]
        var storage: [StorageSnapshot.Namespace: String]
        var network: [NetworkCapture]

        init(
            events: [DecodedEvent] = [],
            storage: [StorageSnapshot.Namespace: String] = [:],
            network: [NetworkCapture] = []
        ) {
            self.events = events
            self.storage = storage
            self.network = network
        }
    }

    // MARK: - Decode

    /// Parses a file's bytes into decoded events. Accepts:
    ///  - a bare JSON array `[{...}, {...}]`
    ///  - a wrapped object `{"events": [...]}` (objects OR JSON strings)
    static func decode(_ data: Data) throws -> [DecodedEvent] {
        try decodeExport(data).events
    }

    /// Parses a file's bytes into a session. Accepts:
    ///  - a bare JSON array `[{...}, {...}]` — events only, the legacy
    ///    shape and what the old Logger app wrote
    ///  - a wrapped object `{"events": [...]}` (objects OR JSON strings)
    ///  - the same object with `"storage": {"session": …, "local": …,
    ///    "secure": …}` alongside
    static func decodeExport(_ data: Data) throws -> Export {
        let json = try JSONSerialization.jsonObject(with: data)

        if let array = json as? [[String: Any]] {
            return Export(events: array.compactMap(makeEvent))
        }

        guard let object = json as? [String: Any] else { return Export() }
        // A storage-only export is the storage object itself.
        if object["events"] == nil && object["storage"] == nil && object["network"] == nil {
            return Export(storage: decodeStorage(object))
        }
        return Export(
            events: decodeEvents(object["events"]),
            storage: decodeStorage(object["storage"]),
            network: decodeNetwork(object["network"])
        )
    }

    private static func decodeEvents(_ value: Any?) -> [DecodedEvent] {
        if let array = value as? [[String: Any]] {
            return array.compactMap(makeEvent)
        }
        // Some producers ship each event as a JSON string.
        if let strings = value as? [String] {
            return strings.compactMap { string in
                guard
                    let inner = string.data(using: .utf8),
                    let dict = try? JSONSerialization.jsonObject(with: inner) as? [String: Any]
                else { return nil }
                return makeEvent(dict)
            }
        }
        return []
    }

    /// Keyed by the wire names (`secure`, not `keychain`) so a file
    /// round-trips through the same vocabulary the device speaks.
    private static func decodeStorage(_ value: Any?) -> [StorageSnapshot.Namespace: String] {
        guard let object = value as? [String: Any] else { return [:] }
        var result: [StorageSnapshot.Namespace: String] = [:]
        for namespace in StorageSnapshot.Namespace.allCases {
            guard let payload = object[namespace.wireKey],
                  let json = jsonString(payload)
            else { continue }
            result[namespace] = json
        }
        return result
    }

    /// Each element is re-serialised to a string and handed to the
    /// same parser the store uses, so an imported entry goes through
    /// the one code path a live one does. Tolerates each element
    /// arriving as a JSON string, mirroring `decodeEvents`.
    private static func decodeNetwork(_ value: Any?) -> [NetworkCapture] {
        if let array = value as? [[String: Any]] {
            return array.compactMap { dict in
                guard let json = jsonString(dict) else { return nil }
                return NetworkCapture(json, fallbackMillis: 0)
            }
        }
        if let strings = value as? [String] {
            return strings.compactMap { NetworkCapture($0, fallbackMillis: 0) }
        }
        return []
    }

    private static func makeEvent(_ dict: [String: Any]) -> DecodedEvent? {
        guard let subsystem = dict["subsystem"] as? String else { return nil }
        guard let message   = dict["message"]   as? String else { return nil }

        guard let timestamp = ProtocolDecoder.timestampMillis(dict["timestamp"]) else { return nil }

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
        let array = eventObjects(events)
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted] : []
        return try JSONSerialization.data(withJSONObject: array, options: options)
    }

    /// The wire shape of one event, shared by both encoders.
    private static func eventObjects(_ events: [EventRecord]) -> [[String: Any]] {
        events.map { event in
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
    }

    /// Events plus the device storage and captured network requests in
    /// one file, so an exported session is self-contained: "why didn't
    /// his token refresh" is answered by the storage half, "what did
    /// that call actually return" by the network half, and shipping
    /// the logs alone left both out.
    ///
    /// Falls back to the bare array when there is neither storage nor
    /// network entries, keeping the file readable by anything that
    /// only knows the old shape. `"storage"` and `"network"` are each
    /// omitted when empty rather than written as `{}`/`[]`.
    static func encode(
        _ events: [EventRecord],
        storage: [StorageSnapshot.Namespace: String],
        network: [String] = [],
        pretty: Bool = true
    ) throws -> Data {
        guard !storage.isEmpty || !network.isEmpty else {
            return try encode(events, pretty: pretty)
        }
        var root: [String: Any] = ["events": eventObjects(events)]
        if !storage.isEmpty {
            root["storage"] = storageObject(storage)
        }
        if !network.isEmpty {
            root["network"] = network.compactMap { payload in
                try? JSONSerialization.jsonObject(with: Data(payload.utf8))
            }
        }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted] : []
        return try JSONSerialization.data(withJSONObject: root, options: options)
    }

    /// Storage alone, as `{storageType: {namespace: {key: value}}}` —
    /// zapp-support's storage export shape, and what `decodeExport`
    /// reads back. Keychain values become `"[REDACTED]"` (keys kept) so
    /// the file can go on a ticket without the user's tokens.
    static func encodeStorage(
        _ storage: [StorageSnapshot.Namespace: String],
        redactKeychain: Bool
    ) throws -> Data {
        var object = storageObject(storage)
        if redactKeychain, let secure = object[StorageSnapshot.Namespace.keychain.wireKey] {
            object[StorageSnapshot.Namespace.keychain.wireKey] = redacted(secure)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func storageObject(_ storage: [StorageSnapshot.Namespace: String]) -> [String: Any] {
        var object: [String: Any] = [:]
        for (namespace, json) in storage {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { continue }
            object[namespace.wireKey] = parsed
        }
        return object
    }

    private static func redacted(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: dict.mapValues(redacted)
        case let array as [Any]:        array.map(redacted)
        default:                        "[REDACTED]"
        }
    }

    // MARK: - Helpers

    private static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
