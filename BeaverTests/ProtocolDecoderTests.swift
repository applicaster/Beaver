//
//  ProtocolDecoderTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("ProtocolDecoder")
struct ProtocolDecoderTests {

    // MARK: - Event frames

    @Test
    func decodesEventWithStringLevel() throws {
        let inner = """
        {
            "subsystem": "com.example.auth",
            "timestamp": 1715784000000,
            "level": "info",
            "message": "login OK",
            "category": "network",
            "data": {"userId": "abc"},
            "context": {"build": "1.2.3"}
        }
        """
        let envelope: [String: Any] = [
            "type":  "event",
            "id":    UUID().uuidString,
            "event": inner
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = ProtocolDecoder.decode(data)
        guard case .success(.event(let event)) = result else {
            Issue.record("expected .event, got \(result)")
            return
        }
        #expect(event.subsystem == "com.example.auth")
        #expect(event.timestampMillis == 1715784000000)
        #expect(event.level == .info)
        #expect(event.message == "login OK")
        #expect(event.category == "network")
        #expect(event.dataJSON?.contains("\"userId\"") == true)
        #expect(event.contextJSON?.contains("\"build\"") == true)
    }

    @Test(arguments: [
        (0, LogLevel.verbose),
        (1, LogLevel.debug),
        (2, LogLevel.info),
        (3, LogLevel.warning),
        (4, LogLevel.error),
    ])
    func decodesEventWithIntegerLevel(numeric: Int, expected: LogLevel) throws {
        let inner = """
        {
            "subsystem": "x",
            "timestamp": 1,
            "level": \(numeric),
            "message": "y"
        }
        """
        let envelope: [String: Any] = [
            "type":  "event",
            "id":    UUID().uuidString,
            "event": inner
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = ProtocolDecoder.decode(data)
        guard case .success(.event(let event)) = result else {
            Issue.record("expected .event, got \(result)")
            return
        }
        #expect(event.level == expected)
    }

    @Test
    func rejectsEventMissingSubsystem() throws {
        let inner = """
        { "timestamp": 1, "level": "info", "message": "no sub" }
        """
        let envelope: [String: Any] = [
            "type":  "event",
            "id":    UUID().uuidString,
            "event": inner
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: Never.self) { _ = ProtocolDecoder.decode(data) }
        if case .failure = ProtocolDecoder.decode(data) {
            // expected
        } else {
            Issue.record("expected failure")
        }
    }

    /// Anyone who reaches the port picks the timestamp. Each of these used
    /// to trap in `UInt64(_:)` or later in the store's `Int(_:)`.
    @Test(arguments: ["-1", "-2.5", "1e20", "18446744073709551615", "9223372036854775808"])
    func rejectsTimestampThatCannotBeStored(raw: String) throws {
        let inner = #"{ "subsystem": "s", "timestamp": \#(raw), "level": "info", "message": "m" }"#
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "event", "id": UUID().uuidString, "event": inner,
        ])
        guard case .failure(.malformedEvent) = ProtocolDecoder.decode(data) else {
            Issue.record("expected malformedEvent for timestamp \(raw)")
            return
        }
        // The file importer shares the rule.
        #expect(try EventJSON.decode(Data("[\(inner)]".utf8)).isEmpty)
    }

    @Test
    func acceptsFractionalTimestamp() throws {
        #expect(ProtocolDecoder.timestampMillis(NSNumber(value: 1715784000000.7)) == 1715784000000)
        #expect(ProtocolDecoder.timestampMillis(NSNumber(value: Int64.max)) == UInt64(Int64.max))
    }

    // MARK: - Storage frames

    @Test
    func decodesStorageSnapshot() throws {
        let envelope: [String: Any] = [
            "type": "storage",
            "id":   UUID().uuidString,
            "data": [
                "session": ["currentUserId": "abc"],
                "local":   ["lastLoginAt": "1715784000"],
                "secure":  ["authToken": "redacted"],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = ProtocolDecoder.decode(data)
        guard case .success(.storage(let namespaces)) = result else {
            Issue.record("expected .storage, got \(result)")
            return
        }
        #expect(namespaces[.session]?.contains("currentUserId") == true)
        #expect(namespaces[.local]?.contains("lastLoginAt") == true)
        #expect(namespaces[.keychain]?.contains("authToken") == true)
    }

    // MARK: - Unknown / malformed

    @Test
    func unknownTypePassesThrough() throws {
        let envelope: [String: Any] = ["type": "future_message"]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let result = ProtocolDecoder.decode(data)
        guard case .success(.unknown(let raw)) = result else {
            Issue.record("expected .unknown, got \(result)")
            return
        }
        #expect(raw == "future_message")
    }

    @Test
    func invalidJSONFails() {
        let result = ProtocolDecoder.decode(Data("not json".utf8))
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
    }
}
