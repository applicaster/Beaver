import Testing
import Foundation
import Network
@testable import BeaverCore

@Suite("MCP HTTP listener", .serialized)
struct MCPHTTPListenerTests {

    private func post(_ port: UInt16, _ body: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    @Test("Round trip over loopback")
    func roundTrip() async throws {
        let listener = MCPHTTPListener { body, headers in
            Data("{\"got\":\(String(decoding: body, as: UTF8.self)),\"ua\":\"\(headers["user-agent"] != nil)\"}".utf8)
        }
        let port = try await listener.start(port: 0)
        defer { Task { await listener.stop() } }
        let (status, text) = try await post(port, "{\"a\":1}")
        #expect(status == 200)
        #expect(text.contains("\"got\":{\"a\":1}"))
    }

    @Test("Review focus: a slow call does not block another")
    func concurrent() async throws {
        let listener = MCPHTTPListener { body, _ in
            if body == Data("slow".utf8) { try? await Task.sleep(for: .seconds(3)) }
            return body
        }
        let port = try await listener.start(port: 0)
        defer { Task { await listener.stop() } }
        async let slow = post(port, "slow")
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        let (status, _) = try await post(port, "fast")
        #expect(status == 200)
        #expect(ContinuousClock.now - started < .seconds(1))
        _ = try await slow
    }

    @Test("Review focus: a taken port fails to start")
    func portTaken() async throws {
        let first = MCPHTTPListener { body, _ in body }
        let port = try await first.start(port: 0)
        defer { Task { await first.stop() } }
        let second = MCPHTTPListener { body, _ in body }
        await #expect(throws: (any Error).self) { try await second.start(port: port) }
    }

    @Test("Review focus: a chunked body gets 411, and the listener keeps serving")
    func chunked() async throws {
        let listener = MCPHTTPListener { body, _ in body }
        let port = try await listener.start(port: 0)
        defer { Task { await listener.stop() } }
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
        let reply = try await rawExchange(port, raw)
        #expect(reply.hasPrefix("HTTP/1.1 411"))
        let (status, _) = try await post(port, "{}")
        #expect(status == 200)
    }

    @Test("Stopped means closed")
    func stop() async throws {
        let listener = MCPHTTPListener { body, _ in body }
        let port = try await listener.start(port: 0)
        await listener.stop()
        await #expect(throws: (any Error).self) { try await post(port, "{}") }
    }

    /// Sends raw bytes and reads until the server closes.
    private func rawExchange(_ port: UInt16, _ text: String) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                connection.cancel()
                if let error { cont.resume(throwing: error) } else {
                    cont.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
                }
            }
        }
    }
}
