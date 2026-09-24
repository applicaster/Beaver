// BeaverTests/AgentAccessTests.swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Agent Access", .serialized)
struct AgentAccessTests {

    private func post(_ port: UInt16, _ body: String) async throws -> JSON {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSON.parse(data)
    }

    @Test("Start serves every tool; stop closes the port")
    func startStop() async throws {
        let store = try LogStore(source: .inMemory)
        let access = AgentAccess(store: store, ui: FakeUI(value: HostSnapshot()))
        let port = try await access.start(port: 0)
        let list = try await post(port, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(list["result"]?["tools"]?.array?.count == BeaverTools.all.count)
        let status = try await post(port, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"beaver_status"}}"#)
        #expect(status["result"]?["isError"] == false)
        #expect(try await store.agentActivity().first?.tool == "beaver_status")
        await access.stop()
        await #expect(throws: (any Error).self) { try await post(port, "{}") }
    }

    @Test("Port from defaults, with a sane fallback")
    func port() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentAccessTests"))
        defaults.removePersistentDomain(forName: "AgentAccessTests")
        defer { defaults.removePersistentDomain(forName: "AgentAccessTests") }
        #expect(AgentAccess.configuredPort(defaults) == 9081)
        defaults.set(9090, forKey: AgentAccess.portKey)
        #expect(AgentAccess.configuredPort(defaults) == 9090)
        defaults.set(70_000, forKey: AgentAccess.portKey)
        #expect(AgentAccess.configuredPort(defaults) == 9081)
        defaults.set(0, forKey: AgentAccess.portKey)
        #expect(AgentAccess.configuredPort(defaults) == 9081)
        defaults.set(-1, forKey: AgentAccess.portKey)
        #expect(AgentAccess.configuredPort(defaults) == 9081)
    }

    @Test("Setup command installs at user scope, for every project")
    func setup() {
        #expect(AgentAccess.setupCommand(port: 9081) == "claude mcp add --scope user --transport http beaver http://127.0.0.1:9081/mcp")
    }

    @Test("Setup instructions carry the real port, every client, a smoke test and a first prompt")
    func setupInstructions() {
        let text = AgentAccess.setupInstructions(port: 9091)
        #expect(text.contains(AgentAccess.setupCommand(port: 9091)))
        #expect(text.contains("http://127.0.0.1:9091/mcp"))
        #expect(!text.contains("9081"))
        #expect(text.contains("Cursor"))
        #expect(text.contains("curl"))
        #expect(text.contains("Use beaver:"))
    }

    @Test("Setup steps: one card per client, each with something to copy")
    func setupSteps() {
        let steps = AgentAccess.setupSteps(port: 9091)
        #expect(steps.map(\.title) == ["Claude Code", "Cursor", "Perplexity (Mac app)",
                                      "Other MCP clients", "Check it answers", "First prompt"])
        #expect(steps.allSatisfy { !$0.code.isEmpty && !$0.note.isEmpty })
        #expect(steps[0].code == AgentAccess.setupCommand(port: 9091))
        #expect(steps[2].code == "npx -y mcp-remote http://127.0.0.1:9091/mcp")
        // The copyable text and the cards come from the same steps.
        let text = AgentAccess.setupInstructions(port: 9091)
        #expect(steps.allSatisfy { text.contains($0.code) })
    }

    @Test("Review focus: overlapping starts, then stop, leave nothing serving")
    func overlappingStartsThenStop() async throws {
        // Mirrors MCPHTTPListenerTests.overlappingStarts, one level up: two
        // concurrent start()s race AgentAccess's own claim-before-await
        // guard, so at most one survives to be `self.listener` — the loser
        // must cancel its own orphaned listener rather than leak it.
        let store = try LogStore(source: .inMemory)
        let access = AgentAccess(store: store, ui: FakeUI(value: HostSnapshot()))
        async let first: UInt16? = try? await access.start(port: 0)
        async let second: UInt16? = try? await access.start(port: 0)
        let ports = [await first, await second].compactMap { $0 }
        #expect(!ports.isEmpty)
        await access.stop()
        for port in ports {
            await #expect(throws: (any Error).self) { try await post(port, "{}") }
        }
    }

    /// Runs `body`, turning a thrown error into `.failure` instead of
    /// propagating it, so a racing `start()` can be awaited and inspected
    /// without `try?` throwing away which error it was.
    private func attempt(_ body: () async throws -> UInt16) async -> Result<UInt16, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    @Test("Review focus: stop() racing an in-flight start() wins", .timeLimit(.minutes(1)))
    func stopWhileStartInFlightWins() async throws {
        // Deterministic handshake instead of a sleep: `beforeBind` pauses
        // start() right after it has claimed its listener (so `stop()`
        // has something to find) and right before the bind. We wait for
        // that signal, call stop() (bumping the generation start() is
        // about to check), then release start() to prove the race is
        // decided by the generation counter, not by timing.
        let store = try LogStore(source: .inMemory)
        let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let access = AgentAccess(store: store, ui: FakeUI(value: HostSnapshot())) {
            reachedContinuation.yield(())
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }

        async let outcome = attempt { try await access.start(port: 0) }
        var reachedIterator = reached.makeAsyncIterator()
        _ = await reachedIterator.next()

        await access.stop()
        gateContinuation.yield(())

        switch await outcome {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success(let port):
            Issue.record("start() should have lost the race to the concurrent stop()")
            await #expect(throws: (any Error).self) { try await post(port, "{}") }
        }
    }

    @Test("Review focus: stop() racing a second start()'s in-flight prelude wins", .timeLimit(.minutes(1)))
    func stopDuringSecondStartWins() async throws {
        // Finding 1's exact shape: a listener is already serving, and a
        // second start() — mid-flight, past the point where it has
        // drained the first listener and claimed its own — races a
        // stop(). The old bug was that a stop() landing during that
        // drain could see nothing to stop and return believing the
        // server was off, while the in-flight start() went on to serve
        // anyway.
        let store = try LogStore(source: .inMemory)
        let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let calls = Counter()
        let access = AgentAccess(store: store, ui: FakeUI(value: HostSnapshot())) {
            guard await calls.increment() == 2 else { return }
            reachedContinuation.yield(())
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }

        let firstPort = try await access.start(port: 0)
        _ = try await post(firstPort, "{}")

        async let secondOutcome = attempt { try await access.start(port: 0) }
        var reachedIterator = reached.makeAsyncIterator()
        _ = await reachedIterator.next()

        await access.stop()
        gateContinuation.yield(())

        switch await secondOutcome {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success(let port):
            Issue.record("the second start() should have lost the race to the concurrent stop()")
            await #expect(throws: (any Error).self) { try await post(port, "{}") }
        }
        await #expect(throws: (any Error).self) { try await post(firstPort, "{}") }
    }

    @Test("Review focus: stop() racing a second start()'s drain (not just its prelude-claim) wins",
          .timeLimit(.minutes(1)))
    func stopDuringSecondStartsDrainWins() async throws {
        // The precise "finding 1" trace: a listener is already serving,
        // and the second start() is paused inside drain() itself — right
        // after it has cleared `self.listener` for the first listener but
        // before that listener is actually told to stop — not merely
        // after it has gone on to claim a replacement (as
        // `stopDuringSecondStartWins` above exercises via `beforeBind`).
        // A concurrent stop() lands in that exact window.
        let store = try LogStore(source: .inMemory)
        let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let calls = Counter()
        let access = AgentAccess(store: store, ui: FakeUI(value: HostSnapshot()), duringDrain: {
            guard await calls.increment() == 1 else { return }
            reachedContinuation.yield(())
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        })

        let firstPort = try await access.start(port: 0)
        _ = try await post(firstPort, "{}")

        async let secondOutcome = attempt { try await access.start(port: 0) }
        var reachedIterator = reached.makeAsyncIterator()
        _ = await reachedIterator.next()

        await access.stop()
        gateContinuation.yield(())

        switch await secondOutcome {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success(let port):
            Issue.record("the second start() should have lost the race to the concurrent stop()")
            await #expect(throws: (any Error).self) { try await post(port, "{}") }
        }
        await #expect(throws: (any Error).self) { try await post(firstPort, "{}") }
    }

    @Test("Review focus: a stop() suspended mid-drain does not undo a later start() (last call wins)",
          .timeLimit(.minutes(1)))
    func staleDrainDoesNotUndoLaterStart() async throws {
        // The "stale-drain" shape finding 1 named: stop() is the one that
        // gets paused mid-drain (after clearing `self.listener` for the
        // first listener, before telling it to stop) — not start(). A
        // start() then runs to completion and starts serving while the
        // stop() is still parked. Releasing the stop() must not let it
        // resume, find the *new* listener now sitting in `self.listener`,
        // and tear that down too: last call was start(), so it must still
        // be serving once everything has settled.
        let store = try LogStore(source: .inMemory)
        let (reached, reachedContinuation) = AsyncStream<Void>.makeStream()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let calls = Counter()
        let access = AgentAccess(store: store, ui: FakeUI(value: HostSnapshot()), duringDrain: {
            guard await calls.increment() == 1 else { return }
            reachedContinuation.yield(())
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        })

        let firstPort = try await access.start(port: 0)
        _ = try await post(firstPort, "{}")

        async let stopTask: Void = access.stop()
        var reachedIterator = reached.makeAsyncIterator()
        _ = await reachedIterator.next()

        // The stop() above is now parked mid-drain, holding only a local
        // reference to the first listener. A start() run to completion
        // here does not race it at all (its own drain finds nothing,
        // `self.listener` already having been cleared) — it just binds.
        let secondPort = try await access.start(port: 0)
        _ = try await post(secondPort, "{}")

        gateContinuation.yield(())
        await stopTask

        // Last call was the second start(): it must still be serving.
        _ = try await post(secondPort, "{}")
        // And the stop() must still have retired the first listener.
        await #expect(throws: (any Error).self) { try await post(firstPort, "{}") }
    }
}

private actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}
