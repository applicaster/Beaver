import Testing
import Foundation
@testable import BeaverCore

@Suite("Command history (D9)")
struct CommandHistoryTests {

    @Test("Newest first; a repeat moves to the top instead of doubling")
    func order() async throws {
        let store = try LogStore(source: .inMemory)
        try await store.recordCommand("cmdlist")
        try await store.recordCommand("storage.list")
        try await store.recordCommand("cmdlist")
        #expect(try await store.commandHistory() == ["cmdlist", "storage.list"])
    }

    @Test("Keeps only the newest entries")
    func capped() async throws {
        let store = try LogStore(source: .inMemory)
        for i in 0..<60 { try await store.recordCommand("c\(i)") }
        let history = try await store.commandHistory()
        #expect(history.count == LogStore.commandHistoryLimit)
        #expect(history.first == "c59")
        #expect(history.last == "c10")
    }
}
