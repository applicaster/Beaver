import Testing
import Foundation
@testable import BeaverCore

@Suite("commands_send")
struct CommandToolsTests {

    private func live() async throws -> (LogStore, Session, FakeUI) {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        return (store, s, FakeUI(value: HostSnapshot(deviceConnected: true, liveSessionId: s.id)))
    }

    @Test("Sends the command, adds it to the command bar's history, says where to look")
    func sends() async throws {
        let (store, _, ui) = try await live()
        let device = FakeDevice()
        let r = try await CommandTools.send.run(ToolArguments(["command": "  debug.flag.on newPlayer "]),
                                                makeContext(store, fakeUI: ui, device: device))
        #expect(device.sent == ["debug.flag.on newPlayer"])
        #expect(ui.sentCommands == ["debug.flag.on newPlayer"])
        #expect(r.summary.hasPrefix("Sent \"debug.flag.on newPlayer\""))
        #expect(r.next.contains { $0.hasPrefix("logs_wait(afterId:") })
    }

    @Test("No device: nothing is sent, and the error says what to do")
    func noDevice() async throws {
        let store = try LogStore(source: .inMemory)
        let device = FakeDevice()
        do {
            _ = try await CommandTools.send.run(ToolArguments(["command": "cmdlist"]), makeContext(store, device: device))
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("No device is connected"))
        }
        #expect(device.sent.isEmpty)
        await #expect(throws: ToolError.self) {
            try await CommandTools.send.run(ToolArguments(), makeContext(store, device: device))
        }
    }

    @Test("collectLogsMs returns what the app logged after the command, not before")
    func collects() async throws {
        let (store, s, ui) = try await live()
        try await seed(store, session: s.id, [(.info, "app", "", "old line")])
        let device = FakeDevice { command in await store.append(event("flag \(command)"), to: s.id) }
        let r = try await CommandTools.send.run(ToolArguments(["command": "debug.flag.on x", "collectLogsMs": 800]),
                                                makeContext(store, fakeUI: ui, device: device))
        #expect(r.body.contains("flag debug.flag.on x"))
        #expect(!r.body.contains("old line"))
        #expect(r.structured["total"] == 1)
    }

    @Test("Review focus: a command that restarts the app collects from the new session")
    func collectsAcrossRestart() async throws {
        let (store, s, ui) = try await live()
        let device = FakeDevice { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                ui.update { $0.deviceConnected = false; $0.liveSessionId = nil }
                try? await Task.sleep(for: .milliseconds(300))
                guard let b = try? await store.createSession(source: .live) else { return }
                ui.update { $0.deviceConnected = true; $0.liveSessionId = b.id }
                await store.append(event("App started"), to: b.id)
            }
        }
        let r = try await CommandTools.send.run(ToolArguments(["command": "app.restart", "collectLogsMs": 2000]),
                                                makeContext(store, fakeUI: ui, device: device))
        #expect(r.body.contains("App started"))
        #expect(r.structured["sessionChanged"]?["from"] == JSON(s.id))
        #expect(r.summary.contains("reconnected"))
    }

    @Test("A drop after an agent's command becomes one system entry, with the session it came back in")
    func disconnectEntry() async throws {
        let (store, a, ui) = try await live()
        let ctx = makeContext(store, fakeUI: ui)
        await ctx.watchForDisconnect(after: "restart", sessionId: a.id, window: .seconds(3))
        try await Task.sleep(for: .milliseconds(300))
        ui.update { $0.deviceConnected = false; $0.liveSessionId = nil }
        try await Task.sleep(for: .milliseconds(400))
        let b = try await store.createSession(source: .live)
        ui.update { $0.deviceConnected = true; $0.liveSessionId = b.id }
        var rows: [AgentActivity] = []
        for _ in 0..<40 where rows.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            rows = try await store.agentActivity().filter { $0.kind == .system }
        }
        #expect(rows.count == 1)
        #expect(rows.first?.summary == "Device disconnected after \"restart\" → session #\(b.id)")
        #expect(rows.first?.sessionId == b.id)
    }

    @Test("Two quick commands before a drop make one entry, naming the latest command")
    func disconnectEntryLatestWins() async throws {
        let (store, a, ui) = try await live()
        let ctx = makeContext(store, fakeUI: ui)
        await ctx.watchForDisconnect(after: "prepare", sessionId: a.id, window: .seconds(3))
        await ctx.watchForDisconnect(after: "restart", sessionId: a.id, window: .seconds(3))
        try await Task.sleep(for: .milliseconds(300))
        ui.update { $0.deviceConnected = false; $0.liveSessionId = nil }
        try await Task.sleep(for: .milliseconds(400))
        let b = try await store.createSession(source: .live)
        ui.update { $0.deviceConnected = true; $0.liveSessionId = b.id }
        try await Task.sleep(for: .milliseconds(1000))
        let rows = try await store.agentActivity().filter { $0.kind == .system }
        #expect(rows.map(\.summary) == ["Device disconnected after \"restart\" → session #\(b.id)"])
    }
}
