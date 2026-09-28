import Foundation
import Synchronization
@testable import BeaverCore

/// The app's side of AgentUI. Changeable mid-test (the device dropping
/// during a wait), and it records what tools asked the app to do; `show`
/// applies window changes the way `AppEnvironment` does.
final class FakeUI: AgentUI {
    struct Clear: Equatable, Sendable { let sessionId: Int64; let through: Int64 }
    private struct Calls: Sendable {
        var commands: [String] = []
        var clears: [Clear] = []
        var notes: [AgentNote] = []
        var changes: [UIChange] = []
        var copied: [String] = []
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
    var changes: [UIChange] { calls.withLock { $0.changes } }
    var copied: [String] { calls.withLock { $0.copied } }
    func setNotifyOutcome(_ outcome: NotifyOutcome) { calls.withLock { $0.outcome = outcome } }

    func snapshot() async -> HostSnapshot { value }
    func show(_ change: UIChange) async {
        calls.withLock { $0.changes.append(change) }
        state.withLock { $0.ui = $0.ui.applying(change) }
    }
    func didSendCommand(_ command: String) async { calls.withLock { $0.commands.append(command) } }
    func clearLogView(sessionId: Int64, through eventId: Int64) async {
        calls.withLock { $0.clears.append(Clear(sessionId: sessionId, through: eventId)) }
    }
    func notify(_ note: AgentNote) async -> NotifyOutcome {
        calls.withLock { $0.notes.append(note); return $0.outcome }
    }
    func copyToClipboard(_ text: String) async { calls.withLock { $0.copied.append(text) } }
    func setDefaultDevice(_ device: DefaultDevice?) async { state.withLock { $0.defaultDevice = device } }
}

/// The app on the other end of the WebSocket. `onSend` plays its part:
/// log a line, answer storage.list.
final class FakeDevice: DeviceLink {
    private let log = Mutex<[(command: String, sessionId: Int64)]>([])
    private let onSend: @Sendable (String) async -> Void
    private let onMCP: @Sendable (String, JSON) async throws -> JSON
    private let mcpLog = Mutex<[(method: String, params: JSON, sessionId: Int64)]>([])

    init(onSend: @escaping @Sendable (String) async -> Void = { _ in },
         onMCP: @escaping @Sendable (String, JSON) async throws -> JSON = { _, _ in throw DeviceMCPError.unsupported }) {
        self.onSend = onSend
        self.onMCP = onMCP
    }

    var sent: [String] { log.withLock { $0.map(\.command) } }
    var targets: [Int64] { log.withLock { $0.map(\.sessionId) } }
    private let drops = Mutex<[Int64]>([])
    var disconnected: [Int64] { drops.withLock { $0 } }
    var mcpCalls: [(method: String, params: JSON, sessionId: Int64)] { mcpLog.withLock { $0 } }

    func disconnect(_ sessionId: Int64) async { drops.withLock { $0.append(sessionId) } }

    func send(command: String, to sessionId: Int64) async {
        log.withLock { $0.append((command, sessionId)) }
        await onSend(command)
    }

    func mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration) async throws -> JSON {
        mcpLog.withLock { $0.append((method, params, sessionId)) }
        return try await onMCP(method, params)
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

/// A context whose fake UI the test can read back.
func makeUIContext(_ store: LogStore, ui: HostSnapshot = HostSnapshot()) -> (ToolContext, FakeUI) {
    let fake = FakeUI(value: ui)
    return (makeContext(store, fakeUI: fake), fake)
}

/// Appends `rows` (level, subsystem, category, message) 1 ms apart and
/// waits for the batched write to land.
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
