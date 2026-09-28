import Testing
import Foundation
@testable import BeaverCore

@Suite("WSServer inbound order")
struct WSServerInboundTests {

    /// The app opens the live session on `.connected` and stores frames
    /// into it, from one loop. A frame ahead of `.connected` (or behind
    /// `.disconnected`) has no session and is lost.
    @Test("Frames sent the moment a client connects arrive after .connected")
    func framesAreBracketedByConnectAndDisconnect() async throws {
        let server = WSServer(port: 19_081)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }

        // The race is narrow on loopback: with reading started before
        // `.connected` is yielded, only a few rounds in 200 reorder.
        for round in 0..<200 {
            let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19081")!)
            client.resume()
            // Sent without waiting for the handshake, like an SDK flushing
            // what it buffered while disconnected.
            try await client.send(.string("first"))
            try await client.send(.string("second"))
            _ = try await client.receive() // handshake
            client.cancel(with: .normalClosure, reason: nil)

            let items = await race(timeout: .seconds(10)) {
                var items: [WSServer.Inbound] = []
                for await item in server.inbound {
                    items.append(item)
                    if case .disconnected = item { break }
                }
                return items
            }
            guard case .connected(let id)? = items?.first else {
                Issue.record("round \(round): no .connected first: \(String(describing: items))")
                break
            }
            #expect(items == [
                .connected(id),
                .frame(id, Data("first".utf8)),
                .frame(id, Data("second".utf8)),
                .disconnected(id),
            ], "round \(round)")
        }
        await server.stop()
    }

    @Test("Two clients stay connected, frames say who sent them, commands reach the right one")
    func twoClients() async throws {
        let server = WSServer(port: 19_084)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        func connect() async throws -> URLSessionWebSocketTask {
            let c = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19084")!)
            c.resume()
            _ = try await c.receive() // handshake
            return c
        }
        let a = try await connect()
        let b = try await connect()
        try await a.send(.string("from a"))
        try await b.send(.string("from b"))

        // Both connections, then both frames, in arrival order.
        let seen = await race(timeout: .seconds(10)) { () -> ([UUID], [String: UUID]) in
            var connected: [UUID] = []
            var senders: [String: UUID] = [:]
            for await item in server.inbound {
                switch item {
                case .connected(let id): connected.append(id)
                case .frame(let id, let data): senders[String(decoding: data, as: UTF8.self)] = id
                case .disconnected: break
                }
                if senders.count == 2 { break }
            }
            return (connected, senders)
        }
        let (connected, senders) = seen ?? ([], [:])
        #expect(connected.count == 2)
        #expect(senders["from a"] == connected.first)
        #expect(senders["from b"] == connected.last)

        a.cancel(with: .normalClosure, reason: nil)
        let gone: UUID? = await race(timeout: .seconds(10)) { () -> UUID? in
            for await item in server.inbound {
                if case .disconnected(let id) = item { return id }
            }
            return nil
        } ?? nil
        #expect(gone == connected.first)

        guard connected.count == 2 else { return }
        await server.send(command: "cmdlist", to: connected[1])
        let got = try await b.receive()
        if case .string(let text) = got { #expect(text.contains("cmdlist")) } else { Issue.record("expected text, got \(got)") }

        b.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }

    @Test("disconnect(_:) closes one client and leaves the other connected")
    func disconnectOne() async throws {
        let server = WSServer(port: 19_085)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        func connect() async throws -> URLSessionWebSocketTask {
            let c = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19085")!)
            c.resume()
            _ = try await c.receive() // handshake
            return c
        }
        let a = try await connect()
        let b = try await connect()
        let ids = await race(timeout: .seconds(10)) { () -> [UUID] in
            var ids: [UUID] = []
            for await item in server.inbound {
                if case .connected(let id) = item { ids.append(id) }
                if ids.count == 2 { break }
            }
            return ids
        } ?? []
        guard ids.count == 2 else { Issue.record("expected two connections, got \(ids)"); return }

        await server.disconnect(ids[0])
        let gone: UUID? = await race(timeout: .seconds(10)) { () -> UUID? in
            for await item in server.inbound {
                if case .disconnected(let id) = item { return id }
            }
            return nil
        } ?? nil
        #expect(gone == ids[0])
        await #expect(throws: (any Error).self) { _ = try await a.receive() }

        await server.send(command: "cmdlist", to: ids[1])
        if case .string(let text) = try await b.receive() { #expect(text.contains("cmdlist")) }
        b.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }
}
