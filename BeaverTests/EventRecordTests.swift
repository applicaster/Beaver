import Testing
import Foundation
@testable import BeaverCore

/// The Size column answers "which log is expensive?", so its thresholds
/// and formatting have to match the web viewer's — otherwise the same
/// event reads differently in the two apps.
@Suite("EventRecord size")
struct EventRecordSizeTests {

    private func event(message: String, data: String? = nil) -> EventRecord {
        EventRecord(
            id: 1,
            sessionId: 1,
            timestampMillis: 1_700_000_000_000,
            level: .info,
            subsystem: "",
            category: "",
            message: message,
            dataJSON: data,
            contextJSON: nil
        )
    }

    @Test("Size counts UTF-8 bytes, not characters")
    func sizeIsMeasuredInBytes() {
        // Cyrillic is two bytes per character in UTF-8 — counting
        // characters would understate the wire cost by half.
        let record = event(message: "привет")

        #expect(record.message.count == 6)
        #expect(record.sizeBytes == 12)
    }

    @Test("The payload counts toward the size")
    func payloadIsIncluded() {
        let bare = event(message: "hello")
        let withData = event(message: "hello", data: #"{"a":1}"#)

        #expect(withData.sizeBytes == bare.sizeBytes + 7)
    }

    @Test("Thresholds match the web viewer")
    func sizeClassBoundaries() {
        #expect(event(message: String(repeating: "a", count: 1023)).sizeClass == .normal)
        #expect(event(message: String(repeating: "a", count: 1024)).sizeClass == .average)
        #expect(event(message: String(repeating: "a", count: 8191)).sizeClass == .average)
        #expect(event(message: String(repeating: "a", count: 8192)).sizeClass == .oversized)
    }

    @Test("Size reads as bytes, KB or MB")
    func sizeTextFormatting() {
        #expect(event(message: String(repeating: "a", count: 512)).sizeText == "512 B")
        // Under 10 KB keeps one decimal; above it rounds.
        #expect(event(message: String(repeating: "a", count: 3277)).sizeText == "3.2 KB")
        #expect(event(message: String(repeating: "a", count: 20 * 1024)).sizeText == "20 KB")
        #expect(event(message: String(repeating: "a", count: 1_468_006)).sizeText == "1.4 MB")
    }
}
