import Testing
import Foundation
@testable import BeaverCore

/// D98: a person's or agent's Disconnect closes with code 4000, which tells
/// the SDK to stop reconnecting. Every other close must not, or the app
/// would stay away after a mere timeout.
// Ports away from every other suite (19080-19091): with several clients
// allowed (D73), a client landing on another suite's server shows up there.
@Suite("WSServer disconnect close code", .timeLimit(.minutes(1)))
struct WSServerDisconnectTests {

    private func listening(port: UInt16, silenceTimeout: Duration = .seconds(15)) async throws -> WSServer {
        let server = WSServer(port: port, silenceTimeout: silenceTimeout)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        return server
    }

    /// Reads until the server closes; the close code is set by then.
    private func readUntilClosed(_ client: URLSessionWebSocketTask) async {
        while (try? await client.receive()) != nil {}
    }

    @Test("Disconnect sends close code 4000 and ends the session")
    func disconnectSends4000() async throws {
        let server = try await listening(port: 19_093)
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19093")!)
        client.resume()
        _ = try await client.receive() // handshake

        let id: UUID? = await race(timeout: .seconds(10)) {
            for await case .connected(let id) in server.inbound { return id }
            return nil
        } ?? nil
        let connection = try #require(id)
        await server.disconnect(connection)
        await readUntilClosed(client)

        #expect(client.closeCode.rawValue == 4000)
        #expect(client.closeReason.map { String(decoding: $0, as: UTF8.self) } == "disconnected by Beaver")
        let ended = await race(timeout: .seconds(10)) {
            for await case .disconnected(let gone) in server.inbound where gone == connection { return true }
            return false
        }
        #expect(ended == true)
        await server.stop()
    }

    @Test("The silence timeout does not close with 4000")
    func silenceCloseIsNot4000() async throws {
        let server = try await listening(port: 19_094, silenceTimeout: .milliseconds(300))
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19094")!)
        client.resume()
        _ = try await client.receive() // handshake
        await readUntilClosed(client)

        #expect(client.closeCode.rawValue != 4000)
        await server.stop()
    }
}
