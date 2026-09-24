import Foundation
import Synchronization
@testable import BeaverCore

/// The app's side of AgentUI. Changeable mid-test (the device dropping
/// during a wait), and it records what tools asked the app to do.
final class FakeUI: AgentUI {
    struct Clear: Equatable, Sendable { let sessionId: Int64; let through: Int64 }
    private struct Calls: Sendable {
        var commands: [String] = []
        var clears: [Clear] = []
        var notes: [AgentNote] = []
        var outcome = NotifyOutcome(notified: true)
    }

    private let state: Mutex<HostSnapshot>
    private let calls = Mutex(Calls())

    init(value: HostSnapshot = HostSnapshot()) { state = Mutex(value) }

    var value: HostSnapshot { state.withLock { $0 } }
    func update(_ change: (inout HostSnapshot) -> Void) { state.withLock { change(&$0) } }

    var sentCommands: [String] { calls.withLock { $0.commands } }
    var clears: [Clear] { calls.withLock { $0.clears } }
    var notes: [AgentNote] { calls.withLock { $0.notes } }
    func setNotifyOutcome(_ outcome: NotifyOutcome) { calls.withLock { $0.outcome = outcome } }

    func snapshot() async -> HostSnapshot { value }
    func didSendCommand(_ command: String) async { calls.withLock { $0.commands.append(command) } }
    func clearLogView(sessionId: Int64, through eventId: Int64) async {
        calls.withLock { $0.clears.append(Clear(sessionId: sessionId, through: eventId)) }
    }
    func notify(_ note: AgentNote) async -> NotifyOutcome {
        calls.withLock { $0.notes.append(note); return $0.outcome }
    }
}

/// The app on the other end of the WebSocket. `onSend` plays its part:
/// log a line, answer storage.list.
final class FakeDevice: DeviceLink {
    private let log = Mutex<[String]>([])
    private let onSend: @Sendable (String) async -> Void

    init(onSend: @escaping @Sendable (String) async -> Void = { _ in }) { self.onSend = onSend }

    var sent: [String] { log.withLock { $0 } }

    func send(command: String) async {
        log.withLock { $0.append(command) }
        await onSend(command)
    }
}

func makeContext(_ store: LogStore, ui: HostSnapshot = HostSnapshot(), device: FakeDevice = FakeDevice(),
                 now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ToolContext {
    makeContext(store, fakeUI: FakeUI(value: ui), device: device, now: now)
}

func makeContext(_ store: LogStore, fakeUI: FakeUI, device: FakeDevice = FakeDevice(),
                 now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ToolContext {
    ToolContext(store: store, ui: fakeUI, device: device, now: { now })
}

func seed(_ store: LogStore, session: Int64,
          _ rows: [(LogLevel, String, String, String)],
          startMillis: UInt64 = 1_000,
          data: String? = nil) async throws {
    let before = try await store.eventCount(sessionId: session, filter: .none)
    for (i, row) in rows.enumerated() {
        await store.append(
            DecodedEvent(timestampMillis: startMillis + UInt64(i), level: row.0,
                         subsystem: row.1, category: row.2, message: row.3,
                         dataJSON: data, contextJSON: nil),
            to: session)
    }
    try await waitForEvents(before + rows.count, session: session, in: store)
}

func event(_ message: String, level: LogLevel = .info, subsystem: String = "app") -> DecodedEvent {
    DecodedEvent(timestampMillis: 2_000, level: level, subsystem: subsystem, category: "",
                 message: message, dataJSON: nil, contextJSON: nil)
}
