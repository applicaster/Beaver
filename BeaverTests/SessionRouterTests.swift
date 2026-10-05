import Testing
import Foundation
@testable import BeaverCore

/// AppEnvironment's part in routing, recorded.
@MainActor
final class RouterHost: SessionRouterHost {
    var live: LiveDevices {
        get {
            // Delete all lands just before the router's `n`-th look at `live`.
            if let n = deleteAllBeforeRead { deleteAllBeforeRead = n > 1 ? n - 1 : nil; if n == 1 { _ = stored.detach { _ in true } } }
            return stored
        }
        set {
            stored = newValue
            // Runs once, the moment a connection starts waiting for a replacement.
            if !stored.waiting.isEmpty, let hook = onDetach { onDetach = nil; hook(&stored) }
        }
    }
    private var stored = LiveDevices()
    var onDetach: ((inout LiveDevices) -> Void)?
    var deleteAllBeforeRead: Int?
    var viewingSessionId: Int64?
    var defaultDevice: DefaultDevice?
    var spoke: [Int64] = []
    var closed: [UUID] = []
    var onClose: (UUID) async -> Void = { _ in }

    func didSpeak(session: Int64) {
        spoke.append(session)
        if !live.isLive(viewingSessionId) { viewingSessionId = session }
    }

    func closeConnection(_ connection: UUID) async {
        closed.append(connection)
        await onClose(connection)
    }
}

func handshakeFrame(launch: String?, device: String? = nil) -> Data {
    var o: [String: String] = ["type": "handshake"]
    o["launchId"] = launch
    o["deviceId"] = device
    return try! JSONSerialization.data(withJSONObject: o)
}

func eventFrame(_ message: String, ts: Int = 1) -> Data {
    let inner = try! JSONSerialization.data(withJSONObject: [
        "subsystem": "t", "timestamp": ts, "level": "info", "message": message,
    ])
    return try! JSONSerialization.data(withJSONObject: [
        "type": "event", "id": "x", "event": String(decoding: inner, as: UTF8.self),
    ])
}

@Suite("Connections to sessions (SessionRouter)")
@MainActor
struct SessionRouterTests {
    let store: LogStore
    let host = RouterHost()
    let router: SessionRouter

    init() throws {
        store = try LogStore(source: .inMemory)
        router = SessionRouter(store: store, host: host)
    }

    /// Connects and sends a handshake as the first frame, as the inbound loop does.
    private func connect(launch: String?, device: String? = nil) async throws -> (UUID, Int64) {
        let c = UUID()
        await router.connected(c)
        let session = try #require(await router.route(handshakeFrame(launch: launch, device: device), from: c))
        let handshake = ClientHandshake(deviceId: device, launchId: launch)
        host.live.setHandshake(handshake, for: c)
        try await store.applyHandshake(handshake, to: session)
        return (c, session)
    }

    @Test("A reconnect while the old socket is still open takes its session over; the old connection is closed")
    func takeover() async throws {
        let (a, s) = try await connect(launch: "L-1")
        let (b, s2) = try await connect(launch: "L-1")

        #expect(s2 == s)
        #expect(host.closed == [a])
        #expect(host.live.sessionIds == [s])
        #expect(host.live.session(for: b) == s)
        #expect(try await store.sessions().map(\.id) == [s])

        // The old socket's close, later, doesn't end the session.
        await router.disconnected(a)
        #expect(try await store.sessions().first?.endedAt == nil)
        #expect(host.live.isLive(s))
        await router.disconnected(b)
        #expect(try await store.sessions().first?.endedAt != nil)
    }

    @Test("A session default ends with its session, not when a takeover closes the old socket (D76)")
    func sessionDefault() async throws {
        let (a, s) = try await connect(launch: "L-1")
        host.defaultDevice = .session(s)
        let (b, _) = try await connect(launch: "L-1")
        await router.disconnected(a)
        #expect(host.defaultDevice == .session(s))
        await router.disconnected(b)
        #expect(host.defaultDevice == nil)

        let (c, _) = try await connect(launch: "L-2", device: "U")
        host.defaultDevice = .uid("U")
        await router.disconnected(c)
        #expect(host.defaultDevice == .uid("U"), "a device-id default follows the app into its next session")
    }

    @Test("The launch id alone matches: no device id, an ended session is reopened")
    func launchIdOnly() async throws {
        let (a, s) = try await connect(launch: "L-1")
        await router.disconnected(a)
        let (_, s2) = try await connect(launch: "L-1")
        #expect(s2 == s)
        #expect(try await store.sessions().map(\.id) == [s])
        #expect(try await store.sessions().first?.endedAt == nil)
    }

    @Test("A logs-only client (a TV, D89) is never a launch to continue")
    func logsOnlyNotMatched() {
        var live = LiveDevices()
        let tv = UUID(), app = UUID()
        _ = live.connect(tv, session: 1, viewing: nil)
        _ = live.connect(app, session: 2, viewing: nil)
        live.setHandshake(ClientHandshake(launchId: "L-1", logsOnly: true), for: tv)
        #expect(live.connection(launchId: "L-1", other: app) == nil)
        live.setHandshake(ClientHandshake(launchId: "L-1"), for: tv)
        #expect(live.connection(launchId: "L-1", other: app) == tv)
        #expect(live.connection(launchId: "L-1", other: tv) == nil)
    }

    @Test("Another launch is a session of its own, and the first device keeps the window")
    func otherLaunch() async throws {
        let (_, s) = try await connect(launch: "L-1")
        let (_, s2) = try await connect(launch: "L-2")
        #expect(s != s2)
        #expect(host.live.sessionIds == [s, s2])
        #expect(host.viewingSessionId == s)
    }

    @Test("When the viewed device reconnects the view and its filter stay: the window isn't told of a new device")
    func viewStays() async throws {
        let (a, s) = try await connect(launch: "L-1")
        #expect(host.spoke == [s])
        #expect(host.viewingSessionId == s)

        // Its socket drops and comes back.
        await router.disconnected(a)
        let (b, s2) = try await connect(launch: "L-1")
        #expect(s2 == s)
        #expect(host.viewingSessionId == s)
        #expect(host.spoke == [s], "didSpeak would restart the Log feed from the Default filter")

        // Or comes back before the old socket noticed.
        _ = try await connect(launch: "L-1")
        #expect(host.closed == [b])
        #expect(host.viewingSessionId == s)
        #expect(host.spoke == [s])
    }

    @Test("Events of the continued launch go to its session, with a note of the gap")
    func eventsFollow() async throws {
        let (a, s) = try await connect(launch: "L-1")
        _ = await router.route(eventFrame("a1"), from: a)
        try await store.append(event("a1"), to: #require(host.live.session(for: a)))
        let (b, _) = try await connect(launch: "L-1")
        #expect(await router.route(eventFrame("b1"), from: b) == s)
        // The closed connection's late frames go nowhere.
        #expect(await router.route(eventFrame("late"), from: a) == nil)
        try await waitForEvents(2, session: s, in: store)
        let messages = try await store.events(sessionId: s, filter: .none, offset: 0, limit: 10, includePayloads: false)
            .map(\.message)
        #expect(messages.contains { $0.hasPrefix("Reconnected: same app launch") })
    }

    @Test("A connection that leaves before its replacement session is attached leaves no empty session")
    func replaceAfterLeaving() async throws {
        let (c, s) = try await connect(launch: "L-1")
        try await store.deleteSession(id: s)
        // Detached, its replacement not yet created: the device leaves (the
        // `LiveDevices` half of `disconnected`, which can't run mid-mutation).
        host.onDetach = { $0.disconnect(c) }
        #expect(await router.replaceDeleted(viewed: nil, where: { $0 == s }).isEmpty)
        await router.disconnected(c)
        #expect(host.live.sessionIds.isEmpty)
        #expect(try await store.sessions().isEmpty)
    }

    @Test("A Delete all while a reconnect reopens its session: the row is ended again and the frame waits (D75)")
    func deleteAllDuringReopen() async throws {
        let (a, old) = try await connect(launch: "L-1")
        await router.disconnected(a)
        let b = UUID()
        await router.connected(b)
        let fresh = try #require(host.live.session(for: b))
        // route reads `live` for b's session (1) and for a live holder of the
        // launch (2), awaits the reopen, then checks b's session (3): Delete
        // all detaches every connection (BeaverApp's changes loop) right then.
        host.deleteAllBeforeRead = 3

        #expect(await router.route(handshakeFrame(launch: "L-1"), from: b) == nil)
        #expect(host.deleteAllBeforeRead == nil, "the race ran")
        #expect(!host.spoke.contains(fresh), "the window isn't sent to the deleted session")
        #expect(try await store.sessions().first { $0.id == old }?.endedAt != nil)
        #expect(host.live.waiting == [b])
    }

    @Test("A connection waiting for its replacement whose app launch came back on another connection is closed")
    func replaceAfterLaunchCameBack() async throws {
        let (x, s) = try await connect(launch: "L-1")
        try await store.deleteSession(id: s)
        let y = UUID()
        // While X waits, the app reconnects as Y (its own session: X's is gone).
        host.onDetach = {
            _ = $0.connect(y, session: 99, viewing: nil)
            $0.setHandshake(ClientHandshake(launchId: "L-1"), for: y)
        }
        #expect(await router.replaceDeleted(viewed: nil, where: { $0 == s }).isEmpty)
        #expect(host.closed == [x])
        #expect(host.live.sessionIds == [99])
        #expect(try await store.sessions().isEmpty, "no replacement row is left behind")
        await router.disconnected(x)
        #expect(host.live.sessionIds == [99])
    }

    @Test("A replacement session gets the handshake and the window")
    func replace() async throws {
        let (_, s) = try await connect(launch: "L-1", device: "D-1")
        host.viewingSessionId = nil
        try await store.deleteSession(id: s)
        let fresh = await router.replaceDeleted(viewed: s, where: { $0 == s })
        #expect(fresh.count == 1)
        #expect(host.live.sessionIds == fresh)
        #expect(host.viewingSessionId == fresh.first)
        #expect(try await store.sessions().first?.deviceUID == "D-1")
    }
}

@Suite("Queued events and session changes")
struct FlushTests {

    @Test("Ending a session stores its queued events first (PROTOCOL.md §6.4)")
    func endStoresPending() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        await store.append(event("last"), to: s.id)
        try await store.endSession(s.id)
        #expect(try await store.eventCount(sessionId: s.id, filter: .none) == 1)
    }

    @Test("A deleted session's queued events don't take other sessions' events with them")
    func deletedInBatch() async throws {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        let changes = await store.changes()
        let failed = Task {
            for await change in changes { if case .writeFailed = change { return true } }
            return false
        }

        // Queued, then deleted: stored first, then gone with the session.
        await store.append(event("a0"), to: a.id)
        await store.append(event("b0"), to: b.id)
        try await store.deleteSession(id: a.id)
        // Queued after the delete (a device not yet moved off it).
        await store.append(event("a1"), to: a.id)
        await store.append(event("b1"), to: b.id)

        try await waitForEvents(2, session: b.id, in: store)
        #expect(try await store.eventCount(sessionId: a.id, filter: .none) == 0)
        try await Task.sleep(for: .milliseconds(100))
        failed.cancel()
        #expect(await failed.value == false)
    }

    @Test("The startup sweep never ends a session before it started (a device clock behind)")
    func sweepSkewedClock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skewed-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let first = try LogStore(source: .onDisk(url))
        let s = try await first.createSession(source: .live)
        try await first.appendBulk([event("from a device whose clock says 1970")], to: s.id)

        let second = try LogStore(source: .onDisk(url))
        let session = try #require(try await second.sessions().first)
        #expect(try #require(session.endedAt) >= session.startedAt)
    }
}
