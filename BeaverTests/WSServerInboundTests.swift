import Testing
import Foundation
import Network
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

    /// NWConnection stays `.ready` when the peer's stream ends; only the
    /// receive sees it. A device whose socket closes with a FIN and no
    /// close frame must still end its session.
    @Test("A client that ends its stream without a close frame is disconnected")
    func endOfStreamDisconnects() async throws {
        let server = WSServer(port: 19_087)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }

        let client = NWConnection(host: "127.0.0.1", port: 19_087, using: .tcp)
        client.start(queue: .global())
        let upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        client.send(content: Data(upgrade.utf8), completion: .idempotent)

        let items = await race(timeout: .seconds(10)) {
            var items: [WSServer.Inbound] = []
            for await item in server.inbound {
                items.append(item)
                // FIN only: a full close with the 101 unread would send RST.
                if case .connected = item {
                    client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }
                if case .disconnected = item { break }
            }
            return items
        }
        if case .connected(let id)? = items?.first {
            #expect(items == [.connected(id), .disconnected(id)])
        } else {
            Issue.record("expected connect then disconnect, got \(String(describing: items))")
        }
        client.cancel()
        await server.stop()
    }

    /// Network.framework can hand over a frame together with the error for
    /// the peer's close while later frames are still buffered; reading had
    /// to go on until a callback brought no data.
    @Test("Frames that arrive with the client's close are all kept, before .disconnected")
    func framesBeforeCloseAreKept() async throws {
        let server = WSServer(port: 19_088)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        let upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        // Client frames are masked; a zero key leaves the payload as is.
        func frame(_ opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [0x80 | opcode, 0x80 | UInt8(payload.count), 0, 0, 0, 0] + payload
        }
        let frames = frame(0x1, Array("first".utf8)) + frame(0x1, Array("second".utf8)) + frame(0x8, [0x03, 0xE8])

        for round in 0..<1_000 {
            let client = NWConnection(host: "127.0.0.1", port: 19_088, using: .tcp)
            client.start(queue: .global())
            client.send(content: Data(upgrade.utf8), completion: .idempotent)
            // The 101: from here on the bytes are WebSocket frames.
            await withCheckedContinuation { done in
                client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in done.resume() }
            }
            // Both frames, the close frame and the FIN in one go.
            client.send(content: Data(frames), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            @Sendable func drain() {
                client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, done, error in
                    if !done, error == nil { drain() }
                }
            }
            drain()

            let items = await race(timeout: .seconds(10)) { () -> [WSServer.Inbound] in
                var items: [WSServer.Inbound] = []
                for await item in server.inbound {
                    items.append(item)
                    if case .disconnected = item { break }
                }
                return items
            } ?? []
            client.cancel()
            guard case .connected(let id)? = items.first else {
                Issue.record("round \(round): no .connected first: \(items)")
                break
            }
            #expect(items == [
                .connected(id),
                .frame(id, Data("first".utf8)),
                .frame(id, Data("second".utf8)),
                .disconnected(id),
            ], "round \(round): \(items)")
            if items.count != 4 { break }
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
