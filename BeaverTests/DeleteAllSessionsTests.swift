import Testing
import Foundation
@testable import BeaverCore

@Suite("Delete all sessions")
struct DeleteAllSessionsTests {
    @Test("The store file shrinks back: Sessions on disk follows the delete")
    func shrinks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("delete-all-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let store = try LogStore(source: .onDisk(url))
        let s = try await store.createSession(source: .live)
        let big = String(repeating: "x", count: 2_000)
        try await store.appendBulk((0..<2_000).map {
            DecodedEvent(timestampMillis: UInt64($0), level: .info, subsystem: "s", category: "", message: big,
                         dataJSON: nil, contextJSON: nil)
        }, to: s.id)
        let before = try await store.databaseSize()
        try await store.deleteAllSessions()
        let after = try await store.databaseSize()
        #expect(before > 2_000_000)
        #expect(after < before / 10)
        #expect(try await store.sessions().isEmpty)
    }
}
