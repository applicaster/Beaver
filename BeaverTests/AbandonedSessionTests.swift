import Testing
import Foundation
@testable import BeaverCore

@Suite("Sessions left open by an earlier run")
struct AbandonedSessionTests {

    @Test("Reopening the store ends live sessions a quit or crash left open, at their last event")
    func endedOnOpen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abandoned-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try LogStore(source: .onDisk(url))
        let open = try await first.createSession(source: .live)
        let quiet = try await first.createSession(source: .live)
        let ended = try await first.createSession(source: .live)
        try await first.endSession(ended.id)
        let imported = try await first.createSession(source: .imported)
        try await first.appendBulk([DecodedEvent(timestampMillis: 1_800_000_000_000, level: .info, subsystem: "s",
                                                 category: "", message: "last", dataJSON: nil, contextJSON: nil)],
                                   to: open.id)

        let second = try LogStore(source: .onDisk(url))
        let byId = Dictionary(uniqueKeysWithValues: try await second.sessions().map { ($0.id, $0) })
        #expect(byId[open.id]?.endedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(byId[quiet.id]?.endedAt == byId[quiet.id]?.startedAt)
        #expect(byId[ended.id]?.endedAt != nil)
        #expect(byId[imported.id]?.endedAt == nil)
        #expect(byId.values.allSatisfy { !$0.isActive })
    }
}
