import Testing
import Foundation
@testable import BeaverCore

/// An exported file is what gets attached to a ticket, so two things
/// have to hold: it carries the storage half a bug report needs, and
/// every file written before it did still opens.
@Suite("EventJSON export")
struct EventJSONExportTests {

    private func event(_ message: String, data: String? = nil) -> EventRecord {
        EventRecord(
            id: 1, sessionId: 1, timestampMillis: 1_700_000_000_000,
            level: .info, subsystem: "player", category: "net",
            message: message, dataJSON: data, contextJSON: nil
        )
    }

    private let storage: [StorageSnapshot.Namespace: String] = [
        .session:  #"{"applicaster.v2":{"app_name":"Demo"}}"#,
        .local:    #"{"flag":"true"}"#,
        .keychain: #"{"authToken":"abc"}"#,
    ]

    private func networkEntry(url: String, status: Int) -> NetworkEntry {
        let json = #"{"url":"\#(url)","method":"GET","status":\#(status),"timestamp":1700000000000}"#
        return NetworkEntry.parse(json, fallbackMillis: 0)!
    }

    // MARK: Round trip

    @Test("Events and storage survive a round trip")
    func roundTripCarriesBothHalves() throws {
        let data = try EventJSON.encode([event("hello")], storage: storage)
        let back = try EventJSON.decodeExport(data)

        #expect(back.events.count == 1)
        #expect(back.events.first?.message == "hello")
        #expect(back.storage.count == 3)
        #expect(back.storage[.local]?.contains("flag") == true)
    }

    @Test("Events, storage and network all survive a round trip")
    func roundTripCarriesNetworkToo() throws {
        let entries = [
            networkEntry(url: "https://a.example/one", status: 200),
            networkEntry(url: "https://a.example/two", status: 404),
        ]
        let data = try EventJSON.encode([event("hello")], storage: storage, network: entries)
        let back = try EventJSON.decodeExport(data)

        #expect(back.network.count == 2)
        #expect(back.network.map(\.url) == ["https://a.example/one", "https://a.example/two"])
        #expect(back.network.map(\.status) == [200, 404])
    }

    @Test("Network elements are JSON objects in the file")
    func networkPayloadsStayStructured() throws {
        let entries = [networkEntry(url: "https://a.example/one", status: 200)]
        let data = try EventJSON.encode([event("hello")], storage: storage, network: entries)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let network = try #require(root["network"] as? [[String: Any]])

        #expect(network.first?["url"] as? String == "https://a.example/one")
    }

    @Test("A network-only file decodes")
    func networkWithoutEventsOrStorageDecodes() throws {
        let entries = [networkEntry(url: "https://a.example/one", status: 200)]
        let data = try EventJSON.encode([], storage: [:], network: entries)
        let back = try EventJSON.decodeExport(data)

        #expect(back.events.isEmpty)
        #expect(back.storage.isEmpty)
        #expect(back.network.count == 1)
    }

    @Test("With no network entries there is no network key")
    func encodingWithoutNetworkOmitsTheKey() throws {
        let data = try EventJSON.encode([event("hello")], storage: storage)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(root["network"] == nil)
    }

    @Test("Keychain travels under its wire name")
    func keychainUsesTheWireKey() throws {
        // The device says `secure`; the UI says Keychain. A file has to
        // speak the device's vocabulary or it won't survive a trip
        // through anything else that reads this format.
        let data = try EventJSON.encode([event("hello")], storage: storage)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let storageObject = try #require(root["storage"] as? [String: Any])

        #expect(storageObject["secure"] != nil)
        #expect(storageObject["keychain"] == nil)
    }

    @Test("Payloads are not re-escaped into strings")
    func payloadsStayStructured() throws {
        let data = try EventJSON.encode(
            [event("hello", data: #"{"n":1}"#)],
            storage: storage
        )
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try #require(root["events"] as? [[String: Any]])

        #expect(events.first?["data"] as? [String: Any] != nil)
    }

    // MARK: Backwards compatibility

    @Test("A bare array of events still opens")
    func legacyFlatArrayStillDecodes() throws {
        // What every file written before this change looks like, and
        // what the old Logger app produced.
        let legacy = Data(#"""
        [{"subsystem":"player","timestamp":1700000000000,
          "level":"info","message":"legacy","category":"net"}]
        """#.utf8)

        let back = try EventJSON.decodeExport(legacy)

        #expect(back.events.count == 1)
        #expect(back.events.first?.message == "legacy")
        #expect(back.storage.isEmpty)
    }

    @Test("An events-only object still opens")
    func wrappedEventsWithoutStorageDecode() throws {
        let file = Data(#"{"events":[{"subsystem":"a","timestamp":1,"level":"info","message":"m"}]}"#.utf8)

        let back = try EventJSON.decodeExport(file)

        #expect(back.events.count == 1)
        #expect(back.storage.isEmpty)
    }

    @Test("With no storage the file stays a bare array")
    func encodingWithoutStorageKeepsTheOldShape() throws {
        // Nothing gains from wrapping an events-only export, and the
        // flat shape is what other tools already read.
        let data = try EventJSON.encode([event("hello")], storage: [:])

        #expect(try JSONSerialization.jsonObject(with: data) as? [[String: Any]] != nil)
    }

    @Test("A storage-only file opens too")
    func storageWithoutEventsDecodes() throws {
        let data = try EventJSON.encode([], storage: storage)
        let back = try EventJSON.decodeExport(data)

        #expect(back.events.isEmpty)
        #expect(back.storage.count == 3)
    }
}

/// The builder both Export buttons call. The promise is that either
/// button, on either screen, writes the same self-contained file.
@Suite("SessionExport")
struct SessionExportTests {

    private func seeded() async throws -> (LogStore, Int64) {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        for (i, subsystem) in ["player", "auth"].enumerated() {
            await store.append(
                DecodedEvent(
                    timestampMillis: UInt64(1_000_000 + i),
                    level: .info, subsystem: subsystem, category: "net",
                    message: "\(subsystem) says hello",
                    dataJSON: nil, contextJSON: nil
                ),
                to: session.id
            )
        }
        try await waitForEvents(2, session: session.id, in: store)

        try await store.recordStorageSnapshot(
            sessionId: session.id, namespace: .local,
            dataJSON: #"{"flag":"true"}"#
        )
        return (store, session.id)
    }

    @Test("Exporting everything carries the storage")
    func everythingIncludesStorage() async throws {
        let (store, sessionId) = try await seeded()

        let data = try #require(
            await SessionExport.make(store: store, sessionId: sessionId, scope: .everything)
        )
        let back = try EventJSON.decodeExport(data)

        #expect(back.events.count == 2)
        #expect(back.storage[.local]?.contains("flag") == true)
    }

    @Test("Exporting filtered narrows the events but never the storage")
    func filteredKeepsStorageWhole() async throws {
        let (store, sessionId) = try await seeded()

        let data = try #require(
            await SessionExport.make(
                store: store,
                sessionId: sessionId,
                scope: .filtered(Filter(subsystems: ["player"]))
            )
        )
        let back = try EventJSON.decodeExport(data)

        // Events obey the filter...
        #expect(back.events.map(\.subsystem) == ["player"])
        // ...storage does not: there is no partial snapshot to mean.
        #expect(back.storage[.local]?.contains("flag") == true)
    }

    @Test("A session with nothing in it produces no file")
    func emptySessionExportsNothing() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        let data = await SessionExport.make(
            store: store, sessionId: session.id, scope: .everything
        )

        #expect(data == nil, "an empty file would just waste the user's click")
    }

    @Test("Exporting everything carries the recorded network entries")
    func everythingIncludesNetwork() async throws {
        let (store, sessionId) = try await seeded()
        try await store.recordNetworkEntry(
            NetworkEntry.parse(#"{"url":"https://a.example","status":200}"#, fallbackMillis: 0)!,
            sessionId: sessionId
        )

        let data = try #require(
            await SessionExport.make(store: store, sessionId: sessionId, scope: .everything)
        )
        let back = try EventJSON.decodeExport(data)

        #expect(back.network.count == 1)
        #expect(back.network.first?.url == "https://a.example")
    }

    @Test("Exporting filtered still carries every network entry")
    func filteredKeepsNetworkWhole() async throws {
        let (store, sessionId) = try await seeded()
        try await store.recordNetworkEntry(
            NetworkEntry.parse(#"{"url":"https://a.example","status":200}"#, fallbackMillis: 0)!,
            sessionId: sessionId
        )

        let data = try #require(
            await SessionExport.make(
                store: store,
                sessionId: sessionId,
                scope: .filtered(Filter(subsystems: ["player"]))
            )
        )
        let back = try EventJSON.decodeExport(data)

        // The filter narrows events only, same as storage.
        #expect(back.network.count == 1)
    }

    @Test("A session with only network entries produces a file")
    func networkOnlySessionExportsAFile() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        try await store.recordNetworkEntry(
            NetworkEntry.parse(#"{"url":"https://a.example","status":200}"#, fallbackMillis: 0)!,
            sessionId: session.id
        )

        let data = await SessionExport.make(
            store: store, sessionId: session.id, scope: .everything
        )

        #expect(data != nil)
    }
}
