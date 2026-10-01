//
//  ProtocolDecoder.swift
//  Beaver
//

import Foundation

/// Pure, stateless decoder for the mobile-SDK wire protocol.
/// Contract documented in `PROTOCOL.md`.
public enum ProtocolDecoder {

    /// One decoded frame from the client.
    public enum InboundPacket: Sendable {
        case event(DecodedEvent)
        case storage(namespaces: [StorageSnapshot.Namespace: String])
        case network(NetworkCapture)
        /// PROTOCOL.md §4.4 (D77).
        case clientHandshake(ClientHandshake)
        /// A JSON-RPC message from the app's MCP server (PROTOCOL.md §4.5, D75).
        case mcp(JSON)
        case unknown(typeRaw: String)
    }

    public enum DecodeError: Error, Sendable {
        case notJSON
        case noTypeField
        case malformedEvent(String)        // human-readable reason
        case malformedStorage(String)
        case malformedNetwork(String)
        case malformedMCP(String)
    }

    /// Decode a raw WebSocket text frame.
    public static func decode(_ data: Data) -> Result<InboundPacket, DecodeError> {
        // 1. Parse the outer envelope.
        guard
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.notJSON)
        }
        guard let typeRaw = envelope["type"] as? String else {
            // The SDK also accepts bare JSON-RPC; Beaver never sends it,
            // but a bare reply is still an MCP message, not an unknown frame.
            if envelope["jsonrpc"] != nil { return decodeMCP(envelope) }
            return .failure(.noTypeField)
        }

        switch typeRaw {
        case "event":
            return decodeEvent(envelope: envelope)
        case "storage":
            return decodeStorage(envelope: envelope)
        case "network":
            return decodeNetwork(envelope: envelope)
        case "handshake":
            return .success(.clientHandshake(decodeHandshake(envelope: envelope)))
        case "register":
            return .success(.clientHandshake(decodeRegister(envelope: envelope)))
        case "mcp":
            return decodeMCP(envelope["payload"])
        default:
            return .success(.unknown(typeRaw: typeRaw))
        }
    }

    // MARK: - Event

    private static func decodeEvent(envelope: [String: Any]) -> Result<InboundPacket, DecodeError> {
        // PROTOCOL.md §4.1: the `event` field is a JSON string nested
        // inside the outer envelope (double-encoded). Preserved for
        // wire compatibility.
        guard let eventString = envelope["event"] as? String else {
            return .failure(.malformedEvent("missing 'event' string field"))
        }
        guard let innerData = eventString.data(using: .utf8) else {
            return .failure(.malformedEvent("event field not valid UTF-8"))
        }
        guard
            let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any]
        else {
            return .failure(.malformedEvent("inner event payload is not a JSON object"))
        }

        // Required fields.
        guard let subsystem = inner["subsystem"] as? String else {
            return .failure(.malformedEvent("missing 'subsystem'"))
        }
        guard let timestamp = timestampMillis(inner["timestamp"]) else {
            return .failure(.malformedEvent("missing or non-numeric 'timestamp'"))
        }
        guard let message = inner["message"] as? String else {
            return .failure(.malformedEvent("missing 'message'"))
        }

        // Level: string OR integer per protocol.
        let level: LogLevel
        // "warn" and "log" are the browser console's names (D89).
        if let levelString = inner["level"] as? String,
           let parsed = LogLevel(rawValue: levelString) ?? ["warn": .warning, "log": .info][levelString] {
            level = parsed
        } else if let levelInt = inner["level"] as? Int,
                  let parsed = LogLevel(numericLevel: levelInt) {
            level = parsed
        } else {
            return .failure(.malformedEvent("unknown or missing 'level'"))
        }

        let category = (inner["category"] as? String) ?? ""

        // data / context: re-encode as compact JSON strings.
        let dataJSON  = inner["data"].flatMap   { reencodeJSON($0) }
        let contextJSON = inner["context"].flatMap { reencodeJSON($0) }

        let event = DecodedEvent(
            timestampMillis: timestamp,
            level: level,
            subsystem: subsystem,
            category: category,
            message: message,
            dataJSON: dataJSON,
            contextJSON: contextJSON
        )
        return .success(.event(event))
    }

    // MARK: - Storage

    private static func decodeStorage(envelope: [String: Any]) -> Result<InboundPacket, DecodeError> {
        // PROTOCOL.md §4.2: `data` is keyed by namespace name. Each
        // namespace's value is opaque; we preserve it as JSON.
        guard let data = envelope["data"] as? [String: Any] else {
            return .failure(.malformedStorage("missing 'data' object"))
        }

        var result: [StorageSnapshot.Namespace: String] = [:]
        for namespace in StorageSnapshot.Namespace.allCases {
            if let value = data[namespace.wireKey],
               let json = reencodeJSON(value) {
                result[namespace] = json
            }
        }
        return .success(.storage(namespaces: result))
    }

    // MARK: - Network

    private static func decodeNetwork(envelope: [String: Any]) -> Result<InboundPacket, DecodeError> {
        // PROTOCOL.md §4.3: same double encoding as `event`.
        guard let payload = envelope["event"] as? String else {
            return .failure(.malformedNetwork("missing 'event' string field"))
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        guard let capture = NetworkCapture(payload, fallbackMillis: now) else {
            return .failure(.malformedNetwork("payload is not a JSON object with a string 'url'"))
        }
        return .success(.network(capture))
    }

    // MARK: - Client handshake

    /// Every field is optional; an empty string counts as missing. A
    /// `deviceId` equal to `model` is the SDK's fallback when it has no
    /// installation id — identical simulators would share it (D77), so
    /// it counts as missing too.
    private static func decodeHandshake(envelope: [String: Any]) -> ClientHandshake {
        func str(_ key: String) -> String? {
            (envelope[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let model = str("model")
        let deviceId = str("deviceId").flatMap { $0 == model ? nil : $0 }
        return ClientHandshake(deviceId: deviceId, deviceName: str("deviceName"), model: model,
                               platform: str("platform"), appPackage: str("appPackage"), version: str("version"))
    }

    /// zapp-support's `register` (PROTOCOL.md §4.6, D89): the fields in
    /// `event`, a JSON string (or in `data`, an object), as zapp-support's
    /// server reads them. A bad payload still registers, with nothing known.
    /// Logs-only only for a DevTools bridge (`platform: tv-cdp`), which ignores
    /// every inbound frame. Any other `register` client (zapp-xray-companion)
    /// reads commands.
    private static func decodeRegister(envelope: [String: Any]) -> ClientHandshake {
        let info = (envelope["event"] as? String)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            ?? envelope["data"] as? [String: Any] ?? [:]
        func str(_ key: String) -> String? {
            (info[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let platform = str("platform")
        // A TV bridged over the Chrome DevTools Protocol names no model.
        let model = str("deviceModel") ?? (platform == "tv-cdp" ? "TV (DevTools)" : nil)
        let platformLine = [platform, str("osVersion")].compactMap { $0 }.joined(separator: " ")
        return ClientHandshake(deviceId: str("deviceId"), deviceName: str("deviceName"), model: model,
                               platform: platformLine.isEmpty ? nil : platformLine,
                               version: str("versionName"),
                               appName: str("appName") ?? str("deviceName"),
                               logsOnly: platform == "tv-cdp")
    }

    // MARK: - MCP

    /// `payload` is a JSON-RPC object, or that object as a string.
    private static func decodeMCP(_ payload: Any?) -> Result<InboundPacket, DecodeError> {
        let data: Data? = if let s = payload as? String {
            s.data(using: .utf8)
        } else if let p = payload, JSONSerialization.isValidJSONObject(p) {
            try? JSONSerialization.data(withJSONObject: p)
        } else {
            nil
        }
        guard let data, let message = try? JSON.parse(data), message.object != nil else {
            return .failure(.malformedMCP("payload is not a JSON-RPC object"))
        }
        return .success(.mcp(message))
    }

    // MARK: - Helpers

    /// A wire timestamp, or `nil` when it can't be one.
    ///
    /// The value comes from whoever reaches the port, so a negative, huge
    /// or fractional number must be rejected, not converted: `UInt64(-1)`
    /// traps. The upper bound is `Int64.max` because the store keeps
    /// timestamps in a signed INTEGER column and converts with `Int(_:)`.
    static func timestampMillis(_ value: Any?) -> UInt64? {
        if let v = value as? Int64 { return v >= 0 ? UInt64(v) : nil }
        if let v = value as? Double, v >= 0, v < Double(Int64.max) { return UInt64(v) }
        return nil
    }

    private static func reencodeJSON(_ value: Any) -> String? {
        // `isValidJSONObject` walks the whole object graph, so it is
        // asked once and the answer reused — this runs per event, and
        // the payload is the largest part of one.
        let isContainer = JSONSerialization.isValidJSONObject(value)
        guard isContainer || value is String || value is NSNumber || value is NSNull
        else { return nil }
        // Wrap scalars so JSONSerialization accepts them.
        let wrapped: Any = isContainer ? value : ["v": value]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapped) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Outbound

public enum ProtocolEncoder {

    /// Encode a server-to-client `command` frame.
    public static func encodeCommand(_ command: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "command",
            "command": command
        ])
    }

    /// Encode the server-to-client `handshake` frame sent on accept.
    public static func encodeHandshake(id: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "handshake",
            "id": id.uuidString
        ])
    }
}
