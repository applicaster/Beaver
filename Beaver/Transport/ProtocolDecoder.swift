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
        case unknown(typeRaw: String)
    }

    public enum DecodeError: Error, Sendable {
        case notJSON
        case noTypeField
        case malformedEvent(String)        // human-readable reason
        case malformedStorage(String)
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
            return .failure(.noTypeField)
        }

        switch typeRaw {
        case "event":
            return decodeEvent(envelope: envelope)
        case "storage":
            return decodeStorage(envelope: envelope)
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
        guard let timestamp = inner["timestamp"] as? UInt64
            ?? (inner["timestamp"] as? Int).map(UInt64.init)
            ?? (inner["timestamp"] as? Double).map({ UInt64($0) }) else {
            return .failure(.malformedEvent("missing or non-numeric 'timestamp'"))
        }
        guard let message = inner["message"] as? String else {
            return .failure(.malformedEvent("missing 'message'"))
        }

        // Level: string OR integer per protocol.
        let level: LogLevel
        if let levelString = inner["level"] as? String,
           let parsed = LogLevel(rawValue: levelString) {
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

    // MARK: - Helpers

    private static func reencodeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value)
                || value is String || value is NSNumber || value is NSNull
        else { return nil }
        // Wrap scalars so JSONSerialization accepts them.
        let wrapped: Any = JSONSerialization.isValidJSONObject(value)
            ? value
            : ["v": value]
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
