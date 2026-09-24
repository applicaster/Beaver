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

    @Test("Review focus: stop() releases the port before returning", .timeLimit(.minutes(1)))
    func restartSamePortRepeatedly() async throws {
        let listener = MCPHTTPListener { body, _ in body }
        var port = try await listener.start(port: 0)
        await listener.stop()
        for _ in 0..<50 {
            port = try await listener.start(port: port)
            await listener.stop()
        }
    }

    @Test("Review focus: two overlapping starts leave only one listener alive")
    func overlappingStarts() async throws {
        let listener = MCPHTTPListener { body, _ in body }
        // Both calls race the same actor: whichever finishes first claims
        // `self.listener`; the other must be told it lost (throw) rather
        // than silently leaving its own listener alive with nothing
        // referencing it (the actor-reentrancy bug under test).
        async let first: UInt16? = try? await listener.start(port: 0)
        async let second: UInt16? = try? await listener.start(port: 0)
        let ports = [await first, await second].compactMap { $0 }
        defer { Task { await listener.stop() } }
        #expect(ports.count == 1)
        let (status, _) = try await post(ports[0], "{}")
        #expect(status == 200)
    }

    @Test("Review focus: three overlapping starts never leak a listener nothing can reach")
    func threeOverlappingStartsDoNotLeak() async throws {
        let listener = MCPHTTPListener { body, _ in body }
        // The two-way race above only guards the claim *after* `stop()`
        // returns; a third caller can still claim and ready a listener of
        // its own while a second caller's own `await stop()` (inside its
        // `start()`) is still suspended waiting for the first's
        // cancellation to be confirmed. Without looping that away before
        // claiming, the second caller would clobber the third's listener
        // without ever cancelling it, leaking a listener nothing
        // references and nothing can ever stop again. (A transient
        // "success" for a call that a later one still ends up
        // superseding is expected under 3-way contention — same as
        // calling start() again always supersedes an earlier one — the
        // invariant that must hold is that nothing is left running once
        // every call has settled and we've stopped for good.)
        // The exact interleaving that leaks is timing-dependent, so repeat
        // it a number of times to make a regression here reliably show up.
        for _ in 0..<20 {
            async let first: UInt16? = try? await listener.start(port: 0)
            async let second: UInt16? = try? await listener.start(port: 0)
            async let third: UInt16? = try? await listener.start(port: 0)
            let ports = [await first, await second, await third].compactMap { $0 }
            await listener.stop()
            for port in ports {
                await #expect(throws: (any Error).self) { try await self.post(port, "{}") }
            }
        }
    }

    @Test("Review focus: stop() stays responsive racing a start() that's failing", .timeLimit(.minutes(1)))
    func stopStaysResponsiveRacingAFailingStart() async throws {
        // Occupies a real port so every `contender.start(port:)` below is
        // guaranteed to fail with EADDRINUSE: its handler cancels the
        // listener itself (case .failed/.waiting), independently of
        // `stop()`. Racing `stop()` against that failing `start()` many
        // times — with and without a tiny head start for the failure —
        // exercises `stop()`/`wait()` under general contention with a
        // listener that's in the middle of failing on its own; if it ever
        // hangs, `.timeLimit` turns that into a failure instead of
        // blocking the suite forever.
        //
        // This does NOT reach the specific ordering finding 1 named
        // (`.cancelled` fully recorded *before* `wait()` is ever called):
        // in this actor, whatever clears `self.listener` — `start()`'s own
        // `catch` right after its continuation resumes, or `stop()` itself
        // right before it calls `cancel()` — always runs, and `wait()` is
        // always reached, before the network stack actually delivers
        // `.cancelled` for that listener, because delivering it needs a
        // real queue hop slower than the handful of synchronous
        // actor-isolated statements in between. That ordering needs a
        // listener that reaches `.ready`, returns successfully, and only
        // *later* fails with nothing racing it — not reproducible here
        // without forcing a real network fault. `CancelState`'s
        // "already cancelled" short-circuit is exercised directly instead,
        // below (`cancelStateMarkedBeforeWaitResolvesImmediately`).
        let occupied = MCPHTTPListener { body, _ in body }
        let port = try await occupied.start(port: 0)
        defer { Task { await occupied.stop() } }
        for i in 0..<100 {
            let contender = MCPHTTPListener { body, _ in body }
            async let attempt: UInt16? = try? await contender.start(port: port)
            if i.isMultiple(of: 2) { try? await Task.sleep(for: .microseconds(200)) }
            await contender.stop()
            #expect(await attempt == nil)
        }
    }

    @Test("Review focus: CancelState — marked before wait() resolves immediately", .timeLimit(.minutes(1)))
    func cancelStateMarkedBeforeWaitResolvesImmediately() async throws {
        // The exact ordering finding 1 was about: cancellation is already
        // recorded by the time anyone asks. Network.framework won't
        // redeliver `.cancelled` to a handler attached afterwards, so
        // `wait()` must already know rather than depend on ever being told
        // again — this is the "already cancelled" short-circuit in
        // `CancelState.wait()`. If that short-circuit is missing, this
        // hangs (verified in the report by temporarily removing it).
        let state = MCPHTTPListener.CancelState()
        state.markCancelled()
        await state.wait()
    }

    @Test("Review focus: CancelState — wait() first, then marked, still resolves", .timeLimit(.minutes(1)))
    func cancelStateWaitFirstThenMarkedResolves() async throws {
        let state = MCPHTTPListener.CancelState()
        async let waited: Void = state.wait()
        // Give wait() a chance to register itself as the waiter first.
        try await Task.sleep(for: .milliseconds(10))
        state.markCancelled()
        await waited
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
