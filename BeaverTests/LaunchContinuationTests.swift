import Testing
import Foundation
@testable import BeaverCore

@Suite("One app launch, one session (D97)")
struct LaunchContinuationTests {

    private func ended(_ store: LogStore, launch: String?, uid: String? = "UID-1") async throws -> Int64 {
        let session = try await store.createSession(source: .live)
        try await store.applyHandshake(ClientHandshake(deviceId: uid, launchId: launch), to: session.id)
        try await store.endSession(session.id)
        return session.id
    }

    @Test("The handshake's launchId is decoded; an empty one counts as missing")
    func decodes() throws {
        func decode(_ launch: String) throws -> ClientHandshake? {
            let data = try JSONSerialization.data(withJSONObject: ["type": "handshake", "launchId": launch])
            guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(data) else { return nil }
            return h
        }
        #expect(try decode("L-1")?.launchId == "L-1")
        #expect(try decode("")?.launchId == nil)
    }

    @Test("A reconnect of the same launch reopens its ended session")
    func reopensSameLaunch() async throws {
        let store = try LogStore(source: .inMemory)
        let old = try await ended(store, launch: "L-1")
        let fresh = try await store.createSession(source: .live)

        let id = try await store.reopenSession(launchId: "L-1", deviceUID: "UID-1", replacing: fresh.id)

        #expect(id == old)
        #expect(try await store.sessions().first { $0.id == old }?.endedAt == nil)
    }

    @Test("Another launch, another device, or no match gets a session of its own")
    func otherLaunchIsNew() async throws {
        let store = try LogStore(source: .inMemory)
        _ = try await ended(store, launch: "L-1")
        let fresh = try await store.createSession(source: .live)

        #expect(try await store.reopenSession(launchId: "L-2", deviceUID: "UID-1", replacing: fresh.id) == nil)
        #expect(try await store.reopenSession(launchId: "L-1", deviceUID: "UID-2", replacing: fresh.id) == nil)
    }

    @Test("A launch whose session is still live is not taken over")
    func liveSessionStays() async throws {
        let store = try LogStore(source: .inMemory)
        let live = try await store.createSession(source: .live)
        try await store.applyHandshake(ClientHandshake(deviceId: "UID-1", launchId: "L-1"), to: live.id)
        let fresh = try await store.createSession(source: .live)

        #expect(try await store.reopenSession(launchId: "L-1", deviceUID: "UID-1", replacing: fresh.id) == nil)
    }

    @Test("A new session that already holds rows is kept")
    func nonEmptyFreshStays() async throws {
        let store = try LogStore(source: .inMemory)
        _ = try await ended(store, launch: "L-1")
        let fresh = try await store.createSession(source: .live)
        try await store.appendBulk([
            DecodedEvent(timestampMillis: 1, level: .info, subsystem: "s", category: "",
                         message: "m", dataJSON: nil, contextJSON: "{}"),
        ], to: fresh.id)

        #expect(try await store.reopenSession(launchId: "L-1", deviceUID: "UID-1", replacing: fresh.id) == nil)
    }

    @Test("The connection moves onto the session it continues")
    func rebind() {
        var live = LiveDevices()
        let c = UUID()
        _ = live.connect(c, session: 9, viewing: nil)
        live.rebind(c, to: 4)
        #expect(live.session(for: c) == 4)
        #expect(live.sessionIds == [4])
        #expect(live.connection(for: 9) == nil)
    }
}
