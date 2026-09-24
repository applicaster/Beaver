import Foundation
@testable import BeaverCore

/// The app's `AgentUI` stand-in: applies changes the way `AppEnvironment`
/// does, and keeps them for the test to read.
actor FakeUI: AgentUI {
    var value: HostSnapshot
    private(set) var changes: [UIChange] = []

    init(value: HostSnapshot) { self.value = value }

    func snapshot() -> HostSnapshot { value }

    func show(_ change: UIChange) {
        changes.append(change)
        value.ui = value.ui.applying(change)
    }
}

func makeContext(_ store: LogStore, ui: HostSnapshot = HostSnapshot(),
                 now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ToolContext {
    ToolContext(store: store, ui: FakeUI(value: ui), now: { now })
}

/// A context whose fake UI the test can read back.
func makeUIContext(_ store: LogStore, ui: HostSnapshot = HostSnapshot()) -> (ToolContext, FakeUI) {
    let fake = FakeUI(value: ui)
    return (ToolContext(store: store, ui: fake, now: { Date(timeIntervalSince1970: 1_000_000) }), fake)
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
