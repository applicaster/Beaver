import Testing
import Foundation
@testable import BeaverCore

@Suite("WSServer silent connections", .timeLimit(.minutes(1)))
struct WSServerSilenceTests {

    private func listening(port: UInt16) async throws -> WSServer {
        let server = WSServer(port: port, silenceTimeout: .milliseconds(300))
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        return server
    }

    @Test("A client that sends nothing after the handshake is closed")
    func silentClientIsClosed() async throws {
        let server = try await listening(port: 19_088)
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19088")!)
        client.resume()
        _ = try await client.receive() // handshake

        let items = await race(timeout: .seconds(10)) {
            var items: [WSServer.Inbound] = []
            for await item in server.inbound {
                items.append(item)
                if case .disconnected = item { break }
            }
            return items
        }
        guard case .connected(let id)? = items?.first else {
            Issue.record("no .connected first: \(String(describing: items))")
            return
        }
        #expect(items == [.connected(id), .disconnected(id)])
        #expect(await server.recentProblems.last?.reason.contains("sent nothing") == true)
        client.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }

    @Test("A client that sends one frame stays connected")
    func talkingClientStays() async throws {
        let server = try await listening(port: 19_089)
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19089")!)
        client.resume()
        _ = try await client.receive()
        try await client.send(.string("hello"))

        let items = await race(timeout: .seconds(1)) {
            var items: [WSServer.Inbound] = []
            for await item in server.inbound {
                items.append(item)
                if case .disconnected = item { break }
            }
            return items
        }
        #expect(items == nil, "disconnected a client that had spoken: \(String(describing: items))")
        client.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }
}

@Suite("Ending a session that never heard from its device")
struct EmptySessionTests {

    @Test("A session with no frames is dropped when its connection ends")
    func silentSessionIsDropped() async throws {
        let store = try LogStore(source: .inMemory)
        let silent = try await store.createSession(source: .live)
        let talked = try await store.createSession(source: .live)

        try await store.endSession(silent.id, receivedFrames: false)
        try await store.endSession(talked.id)

        let sessions = try await store.sessions()
        #expect(sessions.map(\.id) == [talked.id])
        #expect(sessions.first?.endedAt != nil)
    }
}
