import Foundation
@testable import BeaverCore

struct FakeUI: AgentUI {
    var value: HostSnapshot
    func snapshot() async -> HostSnapshot { value }
}

func makeContext(_ store: LogStore, ui: HostSnapshot = HostSnapshot(),
                 now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ToolContext {
    ToolContext(store: store, ui: FakeUI(value: ui), now: { now })
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
