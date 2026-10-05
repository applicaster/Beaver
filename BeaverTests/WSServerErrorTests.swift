import Testing
import Foundation
import Network
@testable import BeaverCore

/// Listener health stays apart from what single connections do, and the
/// connections that go wrong are reported instead of dropped silently.
@Suite("WSServer errors", .timeLimit(.minutes(1)))
struct WSServerErrorTests {

    private func listening(port: UInt16, handshakeTimeout: Duration = .seconds(10)) async throws -> WSServer {
        let server = WSServer(port: port, handshakeTimeout: handshakeTimeout)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        return server
    }

    /// Polls until `condition` holds or `timeout` passes.
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func isListening(_ state: WSServer.State) -> Bool {
        if case .listening = state { return true }
        return false
    }

    private func isFailed(_ state: WSServer.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test("A connection that fails before the handshake leaves the listener's state alone and is recorded")
    func failedConnectionIsNotAListenerFailure() async throws {
        let server = try await listening(port: 19_500)
        let raw = NWConnection(host: "127.0.0.1", port: 19_500, using: .tcp)
        raw.start(queue: .global())
        raw.send(content: Data("not a websocket upgrade\r\n\r\n".utf8), completion: .idempotent)

        #expect(await eventually { await !server.recentProblems.isEmpty })
        let state = await server.currentState
        #expect(isListening(state), "\(state)")
        raw.cancel()

        // A connection that gets through clears the old failures.
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19500")!)
        client.resume()
        _ = try await client.receive() // handshake
        #expect(await eventually { await server.recentProblems.isEmpty })
        client.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }

    @Test("A device leaving while the listener is down doesn't hide the failure")
    func disconnectKeepsListenerFailure() async throws {
        let server = try await listening(port: 19_501)
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19501")!)
        client.resume()
        _ = try await client.receive() // handshake
        _ = await race(timeout: .seconds(10)) {
            for await item in server.inbound { if case .connected = item { return } }
        }

        await server.failListener("test failure")
        client.cancel(with: .normalClosure, reason: nil)
        _ = await race(timeout: .seconds(10)) {
            for await item in server.inbound { if case .disconnected = item { return } }
        }
        let state = await server.currentState
        guard case .failed(let reason) = state else {
            Issue.record("expected .failed after the device left, got \(state)")
            await server.stop()
            return
        }
        #expect(reason.contains("test failure"))
        // It re-binds by itself.
        #expect(await eventually { await !isFailed(server.currentState) })
        await server.stop()
    }

    @Test("A first start that can't create the listener retries instead of staying deaf")
    func failedStartRetries() async throws {
        let server = WSServer(port: 19_502)
        await server.failNextBind(NWError.posix(.EADDRINUSE))
        try await server.start()
        let state = await server.currentState
        guard case .failed(let reason) = state else {
            Issue.record("expected .failed, got \(state)")
            await server.stop()
            return
        }
        #expect(reason.contains("19502 is in use"))
        #expect(reason.contains("retrying"))
        #expect(await eventually { await isListening(server.currentState) })
        await server.stop()
    }

    @Test("A connection that never finishes the WebSocket upgrade is closed and recorded")
    func unfinishedUpgradeIsClosed() async throws {
        let server = try await listening(port: 19_503, handshakeTimeout: .milliseconds(300))
        let raw = NWConnection(host: "127.0.0.1", port: 19_503, using: .tcp)
        raw.start(queue: .global())
        // TCP only: no upgrade request.
        #expect(await eventually {
            await server.recentProblems.contains { $0.reason.contains("didn't finish the WebSocket handshake") }
        })
        let state = await server.currentState
        #expect(isListening(state), "\(state)")
        raw.cancel()
        await server.stop()
    }

    @Test("stop() ends every connected client's session")
    func stopEndsSessions() async throws {
        let server = try await listening(port: 19_504)
        var clients: [URLSessionWebSocketTask] = []
        for _ in 0..<3 {
            let c = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19504")!)
            c.resume()
            _ = try await c.receive() // handshake
            clients.append(c)
        }
        let connected = await race(timeout: .seconds(10)) { () -> Set<UUID> in
            var ids = Set<UUID>()
            for await item in server.inbound {
                if case .connected(let id) = item { ids.insert(id) }
                if ids.count == 3 { break }
            }
            return ids
        } ?? []
        #expect(connected.count == 3)

        await server.stop()
        let disconnected = await race(timeout: .seconds(5)) { () -> Set<UUID> in
            var ids = Set<UUID>()
            for await item in server.inbound {
                if case .disconnected(let id) = item { ids.insert(id) }
                if ids.count == 3 { break }
            }
            return ids
        } ?? []
        #expect(disconnected == connected)
        let state = await server.currentState
        guard case .stopped = state else {
            Issue.record("expected .stopped, got \(state)")
            return
        }
        clients.forEach { $0.cancel() }
    }

    @Test("A binary frame is delivered like a text one")
    func binaryFrame() async throws {
        let server = try await listening(port: 19_505)
        let client = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19505")!)
        client.resume()
        _ = try await client.receive() // handshake
        let payload = Data(#"{"type":"handshake"}"#.utf8)
        try await client.send(.data(payload))
        let got = await race(timeout: .seconds(10)) { () -> Data? in
            for await item in server.inbound { if case .frame(_, let data) = item { return data } }
            return nil
        } ?? nil
        #expect(got == payload)
        client.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }
}

@Suite("Network addresses for devices")
struct NetworkInterfaceTests {
    typealias I = NetworkInterface.Interface

    @Test("The primary interface comes first; loopback, link-local, tunnels and down interfaces are skipped")
    func picksUsableIPv4() {
        let interfaces = [
            I(name: "lo0", family: AF_INET, address: "127.0.0.1"),
            I(name: "en0", family: AF_INET, address: "169.254.10.2"),
            I(name: "en0", family: AF_INET6, address: "fe80::1%en0"),
            I(name: "en1", family: AF_INET, address: "10.0.0.5", isUp: false),
            I(name: "utun3", family: AF_INET, address: "100.64.0.2"),
            I(name: "bridge100", family: AF_INET, address: "192.168.64.1"),
            I(name: "awdl0", family: AF_INET, address: "10.1.1.1"),
            I(name: "en7", family: AF_INET, address: "192.168.1.20"),
            I(name: "en8", family: AF_INET, address: "172.20.10.3"),
        ]
        #expect(NetworkInterface.usableAddresses(interfaces, primary: "en8") == ["172.20.10.3", "192.168.1.20"])
        #expect(NetworkInterface.usableAddresses(interfaces, primary: nil) == ["192.168.1.20", "172.20.10.3"])
    }

    @Test("No usable address is nothing, not localhost or a link-local IPv6")
    func nothingUsable() {
        let interfaces = [
            I(name: "lo0", family: AF_INET, address: "127.0.0.1"),
            I(name: "en0", family: AF_INET6, address: "fe80::1%en0"),
            I(name: "en0", family: AF_INET, address: "169.254.3.4"),
        ]
        #expect(NetworkInterface.usableAddresses(interfaces, primary: "en0").isEmpty)
    }
}
