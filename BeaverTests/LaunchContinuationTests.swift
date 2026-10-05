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

        let id = try await store.reopenSession(launchId: "L-1", replacing: fresh.id)

        #expect(id == old)
        #expect(try await store.sessions().first { $0.id == old }?.endedAt == nil)
    }

    @Test("Another launch gets a session of its own")
    func otherLaunchIsNew() async throws {
        let store = try LogStore(source: .inMemory)
        _ = try await ended(store, launch: "L-1")
        let fresh = try await store.createSession(source: .live)

        #expect(try await store.reopenSession(launchId: "L-2", replacing: fresh.id) == nil)
    }

    @Test("The launch id alone matches: no device id, or the model sent as one")
    func launchIdAlone() async throws {
        let store = try LogStore(source: .inMemory)
        let old = try await ended(store, launch: "L-1", uid: nil)
        let fresh = try await store.createSession(source: .live)

        #expect(try await store.reopenSession(launchId: "L-1", replacing: fresh.id) == old)
    }

    @Test("A launch whose session is still live on another connection is taken over, and that connection closed")
    @MainActor
    func liveSessionTakenOver() async throws {
        let store = try LogStore(source: .inMemory)
        let host = RouterHost()
        let router = SessionRouter(store: store, host: host)
        let a = UUID(), b = UUID()
        await router.connected(a)
        let live = try #require(await router.route(handshakeFrame(launch: "L-1", device: "UID-1"), from: a))
        host.live.setHandshake(ClientHandshake(deviceId: "UID-1", launchId: "L-1"), for: a)
        await router.connected(b)

        #expect(await router.route(handshakeFrame(launch: "L-1", device: "UID-1"), from: b) == live)
        #expect(host.closed == [a])
        #expect(try await store.sessions().map(\.id) == [live])
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

        #expect(try await store.reopenSession(launchId: "L-1", replacing: fresh.id) == nil)
    }

    @Test("The connection moves onto the session it continues")
    func rebind() {
        var live = LiveDevices()
        let c = UUID()
        _ = live.connect(c, session: 9, viewing: nil)
        #expect(live.rebind(c, to: 4) == nil)
        #expect(live.session(for: c) == 4)
        #expect(live.sessionIds == [4])
        #expect(live.connection(for: 9) == nil)
    }

    @Test("Moving onto a session another connection holds lets that one go")
    func rebindTakesOver() {
        var live = LiveDevices()
        let old = UUID(), new = UUID()
        _ = live.connect(old, session: 4, viewing: nil)
        live.setHandshake(ClientHandshake(launchId: "L-1"), for: old)
        live.setCommands([], for: 4)
        _ = live.connect(new, session: 9, viewing: nil)
        live.expectQuietCmdlist(for: 9)

        #expect(live.rebind(new, to: 4) == old)
        #expect(live.sessionIds == [4])
        #expect(live.session(for: old) == nil)
        #expect(live.handshake(for: old) == nil)
        #expect(live.commands[4] != nil, "the same app's commands carry over")
        #expect(live.disconnect(old) == nil, "the old socket's close ends nothing")
        let quiet = live.receiveCmdlist([], for: 4)
        #expect(quiet, "a cmdlist Beaver sent before the move stays quiet")
    }
}
