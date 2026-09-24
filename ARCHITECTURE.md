# Beaver — Architecture

This document describes the target architecture for Beaver, the rewrite
of the existing macOS Logger app. It synthesizes the decisions captured in
`DECISIONS.md` (D1–D13) into a coherent layered design and serves as the
reference contract for implementation.

If a decision here conflicts with `DECISIONS.md`, `DECISIONS.md` wins and
this document gets updated.

---

## 1. Design principles

1. **Storage-as-source-of-truth.** Every event the WebSocket receives is
   written to disk before any UI sees it. The UI is a virtualized view
   over the store, not a copy of it. This is the lever that fixes the
   freeze at 3k+ events (D1).
2. **Push UI work out of the hot path.** Decoding, parsing, filtering,
   sorting, and highlight pre-computation happen off the main actor. The
   main actor only renders.
3. **One actor per resource.** Network listener, log store, and SwiftUI
   views each have a clear thread-of-control. Actors mediate; nothing
   shares mutable state across boundaries.
4. **Wire format is sacrosanct.** The mobile SDK is the source of truth
   for what comes over the socket. Beaver adapts; the SDK does not
   change.
5. **No singletons.** Dependencies travel through SwiftUI's `Environment`
   and constructor injection. Testability is non-negotiable.
6. **SPM only, GRDB only.** Every other line of code is ours. We don't
   take dependencies without a strong reason (D11).

---

## 2. Layer diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                            SwiftUI Views                             │
│   MainWindow • SidebarView • LogFeedView • StoragesView •            │
│   DetailPaneView • CommandBarView                                    │
└──────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │  @Observable view models read
                                  │  AsyncStream snapshots
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          View Models (@Observable)                   │
│   LogFeedViewModel • StoragesViewModel • SessionsViewModel •         │
│   CommandBarViewModel                                                │
└──────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │  query(filter) → AsyncStream<Page>
                                  │  events()      → AsyncStream<Event>
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       LogStore (actor, GRDB)                         │
│   • append(event, session)   • query(filter, range)                  │
│   • createSession()          • storagesSnapshot(session)             │
│   • savedFilters CRUD        • commandHistory CRUD                   │
└──────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │  decoded EventRecord values
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       ProtocolDecoder (struct)                       │
│   Pure: Data → WirePacket → EventRecord | StorageSnapshot | ...      │
└──────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │  raw Data frames
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     WSServer (actor, Network.fwk)                    │
│   • start(port:)   • accept(client) (single-client policy from D2)   │
│   • send(command:) • inbound: AsyncStream<Inbound>                   │
└──────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │  WebSocket frames (mobile SDK)
                                  ▼
                          Mobile client SDK
```

**Direction of data flow:**
- Inbound (mobile → UI): WSServer → Decoder → LogStore → ViewModels → Views
- Outbound (UI → mobile): CommandBarViewModel → WSServer.send
- Storage commands (UI → mobile → UI): StoragesViewModel issues
  `storage.list` / `storage.set` via WSServer; responses come back through
  the same Decoder pipeline.

---

## 3. Threading model

| Component             | Isolation                | Notes                                  |
|-----------------------|--------------------------|----------------------------------------|
| `WSServer`            | `actor`                  | Owns `NWListener` + current `NWConnection`. Inbound frames published as `AsyncStream<Inbound>`, bracketed by `.connected` / `.disconnected`. |
| `ProtocolDecoder`     | Free function / struct   | Pure. Stateless. Called from WSServer's consumer task. |
| `LogStore`            | `actor`                  | Owns a single GRDB `DatabaseQueue`. All reads and writes go through it. Publishes `AsyncStream<StoreChange>` notifications. |
| `LogFeedViewModel`    | `@MainActor @Observable` | Subscribes to `LogStore` snapshots, owns visible-window state, manages follow-tail/auto-pause. Owned by `MainWindow` (see D32), keyed by `env.viewingSessionId`. |
| `StoragesViewModel`   | `@MainActor @Observable` | Owns selected tab + current snapshot. Triggers `storage.list` on activation. Same ownership model as `LogFeedViewModel` — lives on `MainWindow`, not on `StoragesView`. |
| `SessionsViewModel`   | `@MainActor @Observable` | Sidebar list of sessions. |
| `CommandBarViewModel` | `@MainActor @Observable` | History + autocomplete; calls `WSServer.send`. |
| `ToastCenter`         | `@MainActor @Observable` | Window-level confirmation surface (see D33). Injected via `.environment(_:)` from `BeaverApp`. |
| SwiftUI views         | `@MainActor`             | Render only. No business logic, no async work. |

**Rules.**
- No `DispatchQueue.main.async`. Everything that needs the main actor uses
  `@MainActor` annotation or `await MainActor.run` at boundaries.
- No `Task.detached` unless the work is genuinely root-of-tree (e.g., the
  WSServer's accept loop). Otherwise `Task { … }` inheriting actor context.
- Cancellation: every long-running task is owned by an actor that cancels
  it on teardown (`deinit` or explicit `stop()` method).
- Strict concurrency mode = `complete`. Swift 6 baseline (D10).

---

## 4. The LogStore in detail

GRDB-backed SQLite. One file at
`~/Library/Application Support/LoggerNext/store.sqlite`.

**Tables (initial schema).**

```sql
CREATE TABLE session (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at   INTEGER NOT NULL,       -- ms since epoch
  ended_at     INTEGER,                -- nullable, set on disconnect
  source       TEXT NOT NULL,          -- 'live' | 'imported'
  client_label TEXT,                   -- optional identifier from handshake

  -- Device fingerprint, added in migration v3 (see D34). Captured
  -- from applicaster.v2 the first time it arrives for a session.
  -- All nullable: older rows and SDKs that don't write
  -- applicaster.v2 just leave them blank.
  app_name     TEXT,
  app_version  TEXT,
  device_model TEXT,
  platform     TEXT,
  os_version   TEXT
);

CREATE TABLE event (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  timestamp_ms INTEGER NOT NULL,
  level        TEXT NOT NULL,          -- 'verbose' | 'debug' | 'info' | 'warning' | 'error'
  subsystem    TEXT NOT NULL,
  category     TEXT NOT NULL,
  message      TEXT NOT NULL,
  data_json    TEXT,                   -- nullable; raw JSON blob
  context_json TEXT                    -- nullable; raw JSON blob
);

CREATE INDEX idx_event_session_ts ON event(session_id, timestamp_ms);
CREATE INDEX idx_event_level      ON event(session_id, level);
CREATE INDEX idx_event_subsystem  ON event(session_id, subsystem);

-- No full-text index. v1 created event_fts + triggers; nothing ever
-- read them (D15), and v7 dropped them. Substring search is LIKE,
-- optionally over data_json too (D40). A trigram FTS5 over payloads was
-- measured and rejected: ~2.5x the payload bytes on disk, minutes to
-- build on a real store.

CREATE TABLE storage_snapshot (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  taken_at     INTEGER NOT NULL,
  namespace    TEXT NOT NULL,          -- 'session' | 'local' | 'keychain'
  data_json    TEXT NOT NULL
);

CREATE TABLE saved_filter (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL UNIQUE,
  level       TEXT,
  search      TEXT,
  search_rx   INTEGER NOT NULL DEFAULT 0,
  exclude     TEXT,
  exclude_rx  INTEGER NOT NULL DEFAULT 0,
  search_payloads INTEGER NOT NULL DEFAULT 0   -- v8, D40
);

CREATE TABLE command_history (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  command     TEXT NOT NULL,
  issued_at   INTEGER NOT NULL
);

-- Added in migration v5 (see D39). One row per `network` frame
-- (PROTOCOL.md §4.3). payload_json is the frame's payload verbatim;
-- NetworkEntry.parse re-derives every field from it on read, so a new
-- optional wire field needs no migration. timestamp_ms is a fallback
-- source for the entry's start time; rows are read back ordered by
-- `id` (arrival order), not timestamp_ms.
CREATE TABLE network_entry (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id   INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  timestamp_ms INTEGER NOT NULL,
  payload_json TEXT    NOT NULL
);

CREATE INDEX idx_network_session_ts ON network_entry(session_id, timestamp_ms);

-- Added in migration v9 (D59 / spec M17). The agent activity journal.
-- Not part of any session export; session_id is SET NULL on delete.
CREATE TABLE agent_activity (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
  client TEXT, tool TEXT, kind TEXT NOT NULL, summary TEXT NOT NULL,
  level TEXT, is_error INTEGER NOT NULL DEFAULT 0, error TEXT,
  links_json TEXT,
  session_id INTEGER REFERENCES session(id) ON DELETE SET NULL,
  seen INTEGER NOT NULL DEFAULT 0
);
```

**Operations.**

- `append(_ event: EventRecord, sessionId: Int64) async throws`
  Batched. Caller may submit one event at a time; LogStore coalesces inserts
  inside a debounced transaction (configurable, default 50 ms). This keeps
  fsync cost low on bursty streams.

- `query(filter: Filter, sessionId: Int64, range: Range<Int>) async throws -> [EventRecord]`
  Pagination by row range. The view model requests the visible window plus
  a configurable overscan (e.g., 100 rows above/below).

- `events(sessionId: Int64, filter: Filter) -> AsyncStream<StoreChange>`
  Pushes change notifications: `.appended(count)`, `.replaced` (on filter
  change), `.deleted(ids)`. The view model uses these to invalidate its
  window cache.

- `createSession(source: Source, label: String?) async -> Int64`
  Returns new session id.

- `endSession(_ id: Int64) async`
  Marks `ended_at = now()`.

- `recordNetworkEntry(_ capture: NetworkCapture, sessionId: Int64) async throws`
  / `networkEntries(sessionId: Int64, afterId: Int64 = 0) async throws -> [NetworkEntry]`
  / `networkPayload(id: Int64)` / `networkPayloads(sessionId: Int64)`
  Insert and re-read `network_entry` rows. Unlike `append`, not batched —
  one frame is one insert — since `network` frames arrive far less often
  than `event` frames. Rows are read back `ORDER BY id`, i.e. arrival
  (insertion) order — which is completion order, since the SDK sends a
  `network` frame only once a request finishes (PROTOCOL.md §4.3). Live
  and reopened sessions therefore show the same order; see D39.
  Entries hold parsed fields only; the payload as received stays in
  the row and is read by id for Copy JSON, and in bulk for Export.
  `clearEvents` keeps `network_entry` rows: they go only with their
  session, through the cascade.

**Why GRDB over SwiftData.** Predictable performance under high-throughput
append load; mature FTS5 integration; explicit migrations; explicit
transaction control; battle-tested over a decade. SwiftData is improving
fast but doesn't yet match GRDB on these axes for this kind of workload.

---

## 5. Filtering and the visible window

The view model never holds the full event set. It holds:
- A `Filter` value (level, search string + regex flag, exclude string +
  regex flag).
- A `visibleRange: Range<Int>` representing the row indices currently
  needed by the UI (driven by the SwiftUI table's onAppear / scroll).
- A `cache: [Int: EventRecord]` mapping row index → record, evicted on
  filter change or LRU policy.

When the filter changes, the view model:
1. Sets `visibleRange = 0..<initial`.
2. Calls `LogStore.query(filter:, range:)` for that window.
3. Subscribes to `LogStore.events(filter:)` for the new filter.
4. Clears the cache.

When the user scrolls, the view model:
1. Updates `visibleRange`.
2. Fetches any missing rows in that range.

When a new event arrives that matches the filter:
1. `LogStore` emits `.appended(1)`.
2. View model updates its row-count and (if following tail) shifts the
   visible range.

Highlight pre-computation: when a new visible range is fetched, the view
model maps records to `DisplayRow { record, highlightedMessage,
highlightedSubsystem, highlightedCategory }`. This happens off the main
actor.

---

## 6. WebSocket transport (WSServer)

Built on `Network.framework` (`NWListener`, `NWProtocolWebSocket`).

**Single-client policy (D2).**
```swift
actor WSServer {
  private var listener: NWListener?
  private var current: NWConnection?
  let inbound: AsyncStream<Inbound>  // .connected, .frame(Data), .disconnected

  // New connection while current != nil → cancel with close code 1008
  // ("policy violation") plus a short reason payload.
}
```

**IPv4 + IPv6.** Today's listener forces IPv4. We accept both; the
"Copy URL" command picks the best available address (IPv6 if reachable,
IPv4 otherwise).

**Inbound flow.**
1. `NWConnection.receiveMessage` → `Data` → published to `inbound` as
   `.frame`, between the connection's `.connected` and `.disconnected`.
   Reading starts only after `.connected` is yielded.
2. One consumer task (in `BeaverApp`) opens the live session on
   `.connected`, decodes each frame via `ProtocolDecoder` into it, and
   ends it on `.disconnected`. One ordered stream is what guarantees the
   session exists before the first frame; `state` is for the UI only.

**Outbound flow.**
- `send(command: String) async throws` encodes a `WSCommand` and writes
  to the current connection. No-op (or specific error) if no connection
  is active.

**Error handling.**
- Listener `.failed` → publish to a `serverState: AsyncStream<ServerState>`
  the UI subscribes to for the connection indicator.
- Connection drops are logged to the store as a synthetic event (level:
  info, subsystem: "loggernext.transport") so the developer sees them in
  context.

---

## 7. Wire protocol (consumer view)

Beaver is a consumer of the mobile SDK's protocol. We do not redefine
it. The contract — what we decode, what we send — is captured separately
in `PROTOCOL.md` (next deliverable). Architecturally, the relevant point
is:

- Inbound payloads are typed via `enum WirePacket: Codable` with cases
  for each message type the SDK sends (`event`, `storage`, `handshake`,
  command responses, etc.).
- The decoder is a pure function: `Data → Result<WirePacket, DecodeError>`.
  Decode errors do not crash; they're logged to the store as a synthetic
  event and the connection stays open.
- We never modify what the SDK sends. If the SDK sends levels as integers
  in some cases, we map them. We do not require the SDK to change.

---

## 8. Project structure

Single-target Xcode project, single SPM package.

```
Beaver/
├── Package.swift
├── README.md
├── ARCHITECTURE.md              (this file)
├── DECISIONS.md
├── PROTOCOL.md                  (wire-protocol contract, to be written)
├── scripts/
│   └── release.sh               (D13: scripted .pkg pipeline)
├── Beaver.xcodeproj/
├── Beaver/
│   ├── BeaverApp.swift      (App + scene)
│   ├── AppEnvironment.swift     (DI container)
│   ├── Domain/
│   │   ├── Bookmark.swift
│   │   ├── CommandHint.swift
│   │   ├── CommandRegistry.swift   (D17 scaffold)
│   │   ├── EventRecord.swift
│   │   ├── Filter.swift
│   │   ├── JSONKind.swift          (D18 typed tree)
│   │   ├── LogLevel.swift
│   │   ├── Session.swift
│   │   ├── StorageRecord.swift
│   │   └── StorageSnapshot.swift
│   ├── Store/
│   │   ├── LogStore.swift
│   │   ├── Schema.swift
│   │   ├── Migrations.swift
│   │   └── Queries.swift
│   ├── Transport/
│   │   ├── WSServer.swift
│   │   └── ProtocolDecoder.swift
│   ├── Features/
│   │   ├── LogFeed/
│   │   │   ├── LogFeedView.swift
│   │   │   ├── LogFeedViewModel.swift
│   │   │   └── LogFeedTable.swift
│   │   ├── Storages/
│   │   │   ├── StoragesView.swift
│   │   │   └── StoragesViewModel.swift
│   │   ├── Sessions/
│   │   │   ├── SessionsView.swift
│   │   │   └── SessionsViewModel.swift
│   │   ├── CommandBar/
│   │   │   ├── CommandBarView.swift
│   │   │   └── CommandBarViewModel.swift
│   │   ├── DetailPane/
│   │   │   └── DetailPaneView.swift
│   │   └── Shared/
│   │       ├── JSONSyntaxText.swift   (D18 colour palette + row builder)
│   │       └── Toast.swift            (D33 ToastCenter + ToastPresenter)
│   └── Support/
│       ├── Highlighting.swift
│       └── NetworkInterface.swift
├── BeaverTests/             (Swift Testing)
│   ├── ProtocolDecoderTests.swift
│   ├── LogStoreTests.swift
│   └── FilterTests.swift
└── BeaverUITests/           (XCTest)
    └── LogFeedUITests.swift
```

Rationale for single target: at this scope, splitting into modules is
premature. If `LogStore` or `Transport` later need to be reused (e.g., a
companion CLI tool), they can graduate to separate SPM packages without
restructuring callers — the actor boundaries are already explicit.

---

## 9. Dependency injection

A single `AppEnvironment` struct holds the live dependencies:

```swift
struct AppEnvironment {
  let store: LogStore
  let server: WSServer
}
```

Wired at app launch:

```swift
@main
struct BeaverApp: App {
  @State private var env: AppEnvironment

  init() {
    let store  = LogStore(databaseURL: …)
    let server = WSServer(port: 9080)
    _env = State(initialValue: AppEnvironment(store: store, server: server))
    Task { await wire(server: server, store: store) }
  }

  var body: some Scene {
    WindowGroup { MainWindow().environment(env) }
  }
}
```

Tests construct a `LogStore(databaseURL: .inMemory)` and a fake
`WSServer`. No singletons.

---

## 10. Error handling and diagnostics

Three classes of error, each with a clear destination:

1. **Decode errors** (malformed inbound frame). Logged to the store as a
   synthetic event with subsystem `loggernext.protocol`. Connection
   stays open.
2. **Store errors** (DB write failed, schema migration failed). Surfaced
   to the UI via a non-dismissable banner; the app remains usable for
   read-only operations.
3. **Transport errors** (listener failed, connection dropped). Surfaced
   via the connection indicator and as synthetic events.

No `print()` for anything user-visible. `os_log` for developer-facing
logs from Beaver itself.

---

## 11. Performance targets

These are budget numbers, not promises — used to guide implementation
and to write tests against.

| Metric                                          | Budget          |
|-------------------------------------------------|-----------------|
| Append one event end-to-end (frame → store)     | < 2 ms p99      |
| Filter change → first visible page              | < 50 ms p99 @ 100k events |
| Scroll to arbitrary row                         | < 30 ms p99     |
| Memory after 100k events                        | < 200 MB        |
| Main-actor blocked time during 1000-event burst | < 50 ms total   |

The decision review (D1, D5, D8) gives us the design margin to hit these.
Performance regression tests live under `BeaverTests/` and run in CI.

---

## 12. Open architectural questions

These are deliberately deferred until first running build:

- **Liquid Glass adoption.** macOS 26 ships the new design language.
  Should we adopt it everywhere or stay close to current native styling?
  Decide after first UI pass.
- **Crash-safe append batching.** Default 50 ms transaction window; if
  the app crashes mid-window we lose those events. Acceptable for a
  debug tool, revisit if it bites.
- **Backup/restore.** Should sessions be exportable as a single archive
  (sqlite + metadata) for sharing? Likely yes, but not in v1.
- **Multi-window.** Today the app is single-window. SwiftUI supports
  multi-window cleanly with the session model. Decide if the UX benefit
  justifies the additional state management.

---

## 12a. Agent Access (MCP)

An MCP server inside the app lets AI agents read what Beaver collected
(D43–D71, `Beaver/Resources/MCP.md`):

    MCP client ──HTTP POST 127.0.0.1:9081/mcp──► MCPHTTPListener (NWListener)
        ► MCPServer (JSON-RPC, stateless) ► BeaverTools (MCPTool values)
        ► LogStore actor + AgentUI (read-only view of AppEnvironment)
        ► every call journaled to agent_activity ► Agent panel

`AgentAccess` is the only entry point the app uses. All of it except the
`AgentUI` conformance and the panel lives in BeaverCore and is covered by
`swift test`.

---

## 13. What this rewrite explicitly walks away from

Listed so we don't accidentally drag the old design forward:

- `NotificationManager` singleton bus → replaced by `AsyncStream`s.
- `LoggerAppManager.shared`, `UserDefaultManager` static API → replaced
  by `AppEnvironment`.
- `FilterTask` linked-list filter chain → replaced by SQL `WHERE`.
- `DataModelHelper.quickSortByTimestamp` hand-rolled sort → use stdlib.
- `getGlobalOccurrenceIndex` / Prev-Next navigation → dropped (D5).
- `convertStringToDictionary` Foundation parsing of JSON-in-JSON →
  replaced by typed `Codable` decoder.
- CocoaPods → SPM (D11).
- `altool` → `notarytool` (D13).
- Manual 12-step README → `scripts/release.sh` (D13).
