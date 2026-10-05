import Testing
import Foundation
@testable import BeaverCore

/// BeaverApp's inbound loop, minus the window: the real server, store and router.
@MainActor
private final class Inbound {
    let store: LogStore
    let server: WSServer
    let host = RouterHost()
    let router: SessionRouter
    var disconnected = 0
    private var tasks: [Task<Void, Never>] = []

    init(port: UInt16) throws {
        store = try LogStore(source: .inMemory)
        server = WSServer(port: port)
        router = SessionRouter(store: store, host: host)
        host.onClose = { [server] in await server.disconnect($0) }
    }

    func start() async throws {
        try await server.start()
        let ready = AsyncStream<Void>.makeStream()
        tasks.append(Task { @MainActor in
            for await state in self.server.state { if case .listening = state { ready.continuation.yield() } }
        })
        tasks.append(Task { @MainActor in
            for await item in self.server.inbound {
                switch item {
                case .connected(let c):
                    await self.router.connected(c)
                case .frame(let c, let frame):
                    guard let session = await self.router.route(frame, from: c) else { continue }
                    switch ProtocolDecoder.decode(frame) {
                    case .success(.event(let e)):
                        await self.store.append(e, to: session)
                    case .success(.clientHandshake(let h)):
                        self.host.live.setHandshake(h, for: c)
                        try? await self.store.applyHandshake(h, to: session)
                    default:
                        break
                    }
                case .disconnected(let c):
                    self.disconnected += 1
                    await self.router.disconnected(c)
                }
            }
        })
        _ = await race(timeout: .seconds(10)) { for await _ in ready.stream { return } }
    }

    func stop() async {
        await server.stop()
        tasks.forEach { $0.cancel() }
    }

    /// Every stored message but Beaver's own reconnect notes, by session.
    func messages() async throws -> [Int64: [String]] {
        var out: [Int64: [String]] = [:]
        for s in try await store.sessions() {
            out[s.id] = try await store.events(sessionId: s.id, filter: .none, offset: 0, limit: 10_000,
                                               includePayloads: false)
                .filter { $0.subsystem != "loggernext.session" }.map(\.message)
        }
        return out
    }
}

@MainActor
private func eventually(_ timeout: Duration = .seconds(10),
                        _ condition: @MainActor () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return try await condition()
}

/// Its own session: `URLSession.shared` allows 6 connections per host, and a
/// socket over the limit waits for a slot for ever.
private let wsSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpMaximumConnectionsPerHost = 64
    return URLSession(configuration: config)
}()

private struct SocketDidNotOpen: Error {}

private func socket(_ port: UInt16) async throws -> URLSessionWebSocketTask {
    let c = wsSession.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
    c.resume()
    // Beaver's handshake. A socket that never opens fails the test, not hangs it.
    guard await race(timeout: .seconds(10), { (try? await c.receive()) != nil }) == true else {
        c.cancel()
        throw SocketDidNotOpen()
    }
    return c
}

/// Ports 19600-19609 are this suite's; other WS suites use 19080-19098, 19400s, 19500s.
@Suite("One app launch, one session, over a socket (D97)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct LaunchTakeoverSocketTests {

    @Test("Same launch reconnects while the old socket is still open: one session, the old socket closed")
    func reconnectWhileOldOpen() async throws {
        let port: UInt16 = 19_600
        let p = try Inbound(port: port)
        try await p.start()
        let a = try await socket(port)
        try await a.send(.data(handshakeFrame(launch: "L1", device: "D1")))
        try await a.send(.data(eventFrame("a1")))
        #expect(await eventually { p.host.live.sessionIds.count == 1 })
        let session = try #require(p.host.live.sessionIds.first)
        try await waitForEvents(1, session: session, in: p.store)

        // A is still open (half-open in real life: a Wi-Fi blip).
        let b = try await socket(port)
        try await b.send(.data(handshakeFrame(launch: "L1", device: "D1")))
        try await b.send(.data(eventFrame("b1")))
        #expect(await eventually { p.disconnected == 1 }, "Beaver closes the old socket")
        #expect(p.host.live.sessionIds == [session])
        try await waitForEvents(3, session: session, in: p.store)  // a1, the note, b1

        // B drops too and the app reconnects once more.
        b.cancel(with: .goingAway, reason: nil)
        #expect(await eventually { p.disconnected == 2 })
        let c = try await socket(port)
        try await c.send(.data(handshakeFrame(launch: "L1", device: "D1")))
        try await c.send(.data(eventFrame("c1")))
        try await waitForEvents(5, session: session, in: p.store)

        #expect(try await p.messages() == [session: ["a1", "b1", "c1"]])
        c.cancel(with: .goingAway, reason: nil)
        a.cancel()
        await p.stop()
    }

    @Test("20 overlapping reconnects of one launch stay one session with every event")
    func overlappingReconnects() async throws {
        let port: UInt16 = 19_601
        let p = try Inbound(port: port)
        try await p.start()
        var sockets: [URLSessionWebSocketTask] = []
        for i in 0..<20 {
            let c = try await socket(port)
            try await c.send(.data(handshakeFrame(launch: "L1")))
            try await c.send(.data(eventFrame("e\(i)", ts: i)))
            // Beaver closes the previous socket itself; the app never does.
            #expect(await eventually { p.disconnected == i && p.host.live.handshakes.count == 1 })
            let session = try #require(p.host.live.sessionIds.first)
            try await waitForEvents(2 * i + 1, session: session, in: p.store)  // i notes
            // Beaver already closed the previous one; free the client's end too.
            sockets.last?.cancel()
            sockets.append(c)
        }
        let session = try #require(p.host.live.sessionIds.first)
        #expect(p.host.live.sessionIds == [session])
        #expect(try await p.messages() == [session: (0..<20).map { "e\($0)" }])

        sockets.last?.cancel(with: .goingAway, reason: nil)
        #expect(await eventually { p.disconnected == 20 })
        #expect(try await p.store.sessions().first?.endedAt != nil)
        sockets.forEach { $0.cancel() }
        await p.stop()
    }
}
