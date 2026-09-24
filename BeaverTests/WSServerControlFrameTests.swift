import Testing
import Foundation
@testable import BeaverCore

/// The SDK pings every 20 seconds to spot a dead socket. A ping is a
/// control frame, not a message: it must never reach the decoder, where
/// it used to surface as a "decode failed: notJSON" warning each time.
// A missing pong leaves `sendPing` waiting forever; fail instead of hanging.
@Suite("WSServer control frames", .timeLimit(.minutes(1)))
struct WSServerControlFrameTests {

    /// Away from 9080 (a running Beaver) and 19080 (the rebind suite).
    private static let port: UInt16 = 19_081

    @Test("Pings from the client are answered, not forwarded as messages")
    func pingIsNotForwarded() async throws {
        let server = WSServer(port: Self.port)
        try await server.start()
        let listening = await race(timeout: .seconds(10)) {
            for await state in server.state {
                if case .listening = state { return true }
            }
            return false
        }
        #expect(listening == true)

        let client = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(Self.port)")!
        )
        client.resume()

        // The handshake the server sends on connect proves the socket is up.
        _ = try await client.receive()

        // Like the SDK, keep a receive pending: URLSession only surfaces
        // a pong while one is.
        @Sendable func drain() { client.receive { if case .success = $0 { drain() } } }
        drain()

        // A pong comes back only once the server has read its ping, so
        // anything a ping yielded is already on `inbound` before the text.
        // Several, as the SDK keeps pinging: each must still be answered.
        for _ in 1...3 {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                client.sendPing { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        }
        try await client.send(.string(#"{"type":"marker"}"#))

        let first: Data? = await race(timeout: .seconds(10)) {
            for await case .frame(let data) in server.inbound { return data }
            return nil
        } ?? nil
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == #"{"type":"marker"}"#)

        client.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }
}
