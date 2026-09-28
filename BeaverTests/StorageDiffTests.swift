import Testing
import Foundation
@testable import BeaverCore

@Suite("Storage diff (D80)")
struct StorageDiffTests {

    @Test("Added, removed and changed keys, by namespace then key")
    func keyLevel() {
        let old = #"{"applicaster.v2":{"guest":"true","lang":"en","token":"a"},"other":{"x":1}}"#
        let new = #"{"applicaster.v2":{"lang":"en","token":"b","user":"u1"},"other":{"x":1}}"#
        let changes = StorageDiff.changes(from: old, to: new)
        #expect(changes.map(\.path) == ["applicaster.v2/guest", "applicaster.v2/token", "applicaster.v2/user"])
        #expect(changes.map(\.kind) == [.removed, .changed, .added])
        #expect(changes[0].old == "true" && changes[0].new == nil)
        #expect(changes[1].old == "a" && changes[1].new == "b")
        #expect(changes[2].old == nil && changes[2].new == "u1")
        #expect(changes.allSatisfy { $0.fields.isEmpty })
    }

    @Test("Same content is no change; a new namespace lists each of its keys")
    func unchangedAndNewNamespace() {
        let json = #"{"a":{"k":"v"}}"#
        #expect(StorageDiff.changes(from: json, to: json).isEmpty)
        let grown = StorageDiff.changes(from: json, to: #"{"a":{"k":"v"},"b":{"x":"1","y":"2"}}"#)
        #expect(grown.map(\.path) == ["b/x", "b/y"])
        #expect(grown.allSatisfy { $0.kind == .added })
    }

    @Test("JSON text in a string lists the fields that changed inside it")
    func jsonInString() throws {
        let old = #"{"ns":{"user":"{\"id\":1,\"name\":\"Ann\",\"roles\":[\"a\"],\"meta\":\"{\\\"v\\\":1}\"}"}}"#
        let new = #"{"ns":{"user":"{\"id\":2,\"name\":\"Ann\",\"roles\":[\"a\",\"b\"],\"meta\":\"{\\\"v\\\":2}\"}"}}"#
        let change = try #require(StorageDiff.changes(from: old, to: new).first)
        #expect(change.kind == .changed)
        #expect(change.old?.hasPrefix(#"{"id":1"#) == true)  // the stored string, as is
        #expect(change.fields.map(\.path) == ["id", "meta.v", "roles[1]"])
        #expect(change.fields.map(\.kind) == [.changed, .changed, .added])
        #expect(change.fields[0].old == "1" && change.fields[0].new == "2")
        #expect(change.fields[2].new == "b")
    }

    @Test("A plain value turning into JSON has no fields; the SDK's undefined wrapper is a plain key")
    func plainValues() {
        let changes = StorageDiff.changes(
            from: #"{"ns":{"k":"plain"},"player-storage":{"undefined":"1"}}"#,
            to: #"{"ns":{"k":"{\"a\":1}"},"player-storage":{"undefined":"2"}}"#)
        #expect(changes.map(\.path) == ["ns/k", "player-storage"])
        #expect(changes[0].fields.isEmpty)
        #expect(changes[1].key == nil && changes[1].old == "1" && changes[1].new == "2")
    }

    @Test("Store: history per layer, one by id, and the one as of a time")
    func storeHistory() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        for json in [#"{"a":{"k":"1"}}"#, #"{"a":{"k":"1"}}"#, #"{"a":{"k":"2"}}"#] {
            try await store.recordStorageSnapshot(sessionId: s.id, namespace: .local, dataJSON: json)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await store.recordStorageSnapshot(sessionId: s.id, namespace: .session, dataJSON: "{}")

        let history = try await store.storageSnapshotHistory(sessionId: s.id, namespace: .local)
        #expect(history.count == 2)  // the unchanged report only moved the first row's time
        #expect(history[0].takenAt < history[1].takenAt)

        let first = try #require(try await store.storageSnapshot(id: history[0].id))
        #expect(first.dataJSON == #"{"a":{"k":"1"}}"# && first.namespace == .local)
        #expect(try await store.storageSnapshot(id: 9_999) == nil)

        let between = history[0].takenAt.addingTimeInterval(0.001)
        #expect(try await store.storageSnapshot(sessionId: s.id, namespace: .local, asOf: between)?.id == history[0].id)
        #expect(try await store.storageSnapshot(sessionId: s.id, namespace: .local, asOf: .now)?.id == history[1].id)
        #expect(try await store.storageSnapshot(sessionId: s.id, namespace: .local,
                                                asOf: history[0].takenAt.addingTimeInterval(-60)) == nil)
    }
}
