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
        #expect(AgentAccess.configuredPort(defaults) == 9081)
        defaults.set(9090, forKey: AgentAccess.portKey)
        #expect(AgentAccess.configuredPort(defaults) == 9090)
        defaults.set(70_000, forKey: AgentAccess.portKey)
        #expect(AgentAccess.configuredPort(defaults) == 9081)
    }

    @Test("Setup command")
    func setup() {
        #expect(AgentAccess.setupCommand(port: 9081) == "claude mcp add --transport http beaver http://127.0.0.1:9081/mcp")
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

    @Test("Review focus: stop() racing an in-flight start() wins", .timeLimit(.minutes(1)))
    func stopWhileStartInFlightWins() async throws {
        // A stop() landing while start() is still awaiting its bind must
        // not be lost (the controller-ruling bug this test guards
        // against): whichever port start() ends up returning, once both
        // calls have settled nothing may still be listening on it.
        // The 1ms head start is only to give the async-let task a chance
        // to actually claim `self.listener` before we call stop() —
        // without it, stop() sometimes runs before start() has begun at
        // all, which is a benign ordering (start() then legitimately
        // keeps serving), not the race this test targets. Repeated
        // because the exact interleaving beyond that point is
        // timing-dependent.
        let store = try LogStore(source: .inMemory)
        for _ in 0..<20 {
            let access = AgentAccess(store: store, ui: FakeUI(value: HostSnapshot()))
            async let started: UInt16? = try? await access.start(port: 0)
            try? await Task.sleep(for: .milliseconds(1))
            await access.stop()
            if let port = await started {
                await #expect(throws: (any Error).self) { try await post(port, "{}") }
            }
        }
    }
}
