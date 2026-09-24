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
                    if item == .disconnected { break }
                }
                return items
            }
            #expect(items == [
                .connected,
                .frame(Data("first".utf8)),
                .frame(Data("second".utf8)),
                .disconnected,
            ], "round \(round)")
            if items?.first != .connected { break }
        }
        await server.stop()
    }
}
