# Network Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Network" tab to Beaver. It shows the HTTP requests an iOS app captures, with the same content and filtering as the zapp-support web logger's Network tab.

**Architecture:** The iOS SDK (quick-brick-xray ≥ #2676) already sends one `{"type":"network","id":…,"event":"<NetworkEntry JSON string>"}` frame per completed request. Today Beaver treats that type as unknown and adds an "unknown packet type: network" line to the Log feed for every request. This plan:
- decodes the frame into a `NetworkEntry`,
- saves the raw payload in a new `network_entry` table (so past sessions keep their traffic),
- broadcasts `.networkAppended`,
- renders the entries in a new tab built from a `Table`, a detail pane and filters. The filter logic is pure and lives in `BeaverCore`, so it can be unit-tested.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), GRDB 7, Swift Testing (`make test` = `swift test`).

**Spec:** This plan is the spec. It was written from the research below.

## Research summary (why this plan exists)

| Source | Finding |
|---|---|
| quick-brick-xray iOS, `apple/Universal/Sinks/WebSocketSink/WebSocketSink+NetworkEvent.swift` | Maps `native_application/network_requests` events to a NetworkEntry JSON. `status` is an Int, times are epoch **ms**, bodies are strings capped at 100 000 chars plus `"... [TRUNCATED]"`, and `authorization`/`cookie`/`x-api-key` request headers are sent as `"[REDACTED]"`. |
| same, `WebSocketSink.swift:146-151` | Each request is sent **twice**: once as a `network` frame and once as a normal `event`. The Log feed keeps its copy. |
| same, `WebSocketSinkData.swift:50` | Envelope `WebSocketMessageNetwork { type = "network", id: UUID, event: String }`. |
| quick-brick-xray Android, `sinks/WebSocketSink.kt:27` | `MessageType` = event/handshake/command/storage/mcp. There is **no `network`**, so Android is out of scope for this plan (see "Not in this plan"). |
| zapp-support `src/types/index.ts:150`, `src/workers/logIngestionWorker.ts:323` | Consumer contract: `requestId, url, method, requestHeaders?, requestBody?, status?, statusText?, responseHeaders?, responseBody?, timing{startTime, endTime?, duration?}, error?, timestamp`. There is no request/response pairing: one frame is one row. |
| zapp-support UI (`xrayNetworkTable.ts`, `xrayNetworkFilterBar.ts`) | Columns: Method, Status, Domain, Path, Duration, Time. Filters: method, status range, domain, free-text search, exclusions. Stats: shown/total, 2xx rate, average duration. Detail: request (URL, headers, body), response (status, headers, body, error), timing. Copy buttons. |
| Beaver `Beaver/BeaverApp.swift:192-201` | Unknown `type` becomes a synthetic info event, which is the current noise described above. |

## Global Constraints

- macOS 26 deployment target and Swift 6 strict concurrency, as in the rest of the app.
- No new dependencies. GRDB 7 is the only one allowed (`Package.swift`).
- Schema changes go in a **new** migration `v5_network_entry`. Never edit `v1`–`v4` (`Schema.swift:11-13`).
- Wire contract: frame `type` is `"network"`. The payload is a **JSON string** in the `event` field (double-encoded, like `event` frames).
- `status` may arrive as a number or a numeric string. Accept both. Anything else counts as "no status".
- Times are epoch **milliseconds**.
- Pure logic (decoding, filtering, stats) goes in `BeaverCore` (`Beaver/Domain`, `Beaver/Support`, `Beaver/Transport`) so `swift test` covers it. Views and view models go in `Beaver/Features/` and are checked by hand.

## Review Focus

1. **Search on URLs containing `/`**: iOS encodes with `JSONSerialization`, which writes `/` as `\/`. Searching the raw payload for `api/v1` would find nothing. Search must use the decoded fields. Test: `NetworkFilterTests.searchMatchesDecodedURLNotRawJSON` (Task 4).
2. **Transport failure with no status** (timeout, `NSURLErrorDomain -1001`): the row must still appear, show `—` for status, and be selectable with the "Failed" status filter. Tests: `NetworkEntryTests.parsesTransportFailureWithoutStatus` (Task 1) and `NetworkFilterTests.failedClassMatchesErrorWithoutStatus` (Task 4).
3. **Missing `timing` object**: zapp-support crashes here. Beaver must fall back to `timestamp`, then to the receive time, and show no duration. Test: `NetworkEntryTests.missingTimingFallsBackToTimestamp` (Task 1).
4. **Reopening a past session**: entries must load from the DB with the same fields and order as when they arrived live. Test: `LogStoreNetworkTests.roundTripPreservesEntryAndOrder` (Task 3).
5. **A `network` frame must no longer add a line to the Log feed**, and a malformed one must give a warning that says what is wrong instead of being dropped silently. Tests: `ProtocolDecoderTests.networkFrameDecodes` and `ProtocolDecoderTests.networkFrameWithoutURLFails` (Task 2).

---

### Task 1: `NetworkEntry` domain type and parser

**Files:**
- Create: `Beaver/Domain/NetworkEntry.swift`
- Test: `BeaverTests/NetworkEntryTests.swift`

**Interfaces:**
- Produces:
  - `public struct NetworkEntry: Identifiable, Hashable, Sendable` with fields `id: Int64`, `requestId: String`, `url: String`, `method: String`, `status: Int?`, `statusText: String?`, `requestHeaders: [String: String]`, `responseHeaders: [String: String]`, `requestBody: String?`, `responseBody: String?`, `startMillis: UInt64`, `durationMillis: Int?`, `error: String?`, `payloadJSON: String`.
  - Computed: `host: String`, `path: String`, `statusClass: NetworkEntry.StatusClass`.
  - `public enum StatusClass: String, CaseIterable, Sendable { case success, redirect, clientError, serverError, failed, other }`
  - `public static func parse(_ payloadJSON: String, id: Int64 = 0, fallbackMillis: UInt64) -> NetworkEntry?`. Returns nil when the payload is not a JSON object or has no string `url`.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  NetworkEntryTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("NetworkEntry")
struct NetworkEntryTests {

    // Shape emitted by quick-brick-xray iOS (WebSocketSink+NetworkEvent.swift).
    // Note the `\/` — JSONSerialization escapes slashes.
    static let ios = """
    {"requestId":"R1","url":"https:\\/\\/api.example.com\\/v1\\/feed?page=2","method":"GET",
     "timing":{"startTime":1715784000000,"endTime":1715784000250,"duration":250},
     "timestamp":1715784000000,"status":200,"statusText":"no error",
     "requestHeaders":{"Authorization":"[REDACTED]","Accept":"application\\/json"},
     "responseHeaders":{"Content-Type":"application\\/json"},
     "responseBody":"{\\"items\\":[1,2]}"}
    """

    @Test
    func parsesIOSPayload() throws {
        let e = try #require(NetworkEntry.parse(Self.ios, fallbackMillis: 0))
        #expect(e.requestId == "R1")
        #expect(e.url == "https://api.example.com/v1/feed?page=2")
        #expect(e.method == "GET")
        #expect(e.status == 200)
        #expect(e.statusText == "no error")
        #expect(e.startMillis == 1715784000000)
        #expect(e.durationMillis == 250)
        #expect(e.requestHeaders["Authorization"] == "[REDACTED]")
        #expect(e.responseBody == "{\"items\":[1,2]}")
        #expect(e.host == "api.example.com")
        #expect(e.path == "/v1/feed?page=2")
        #expect(e.statusClass == .success)
        #expect(e.payloadJSON == Self.ios)
    }

    @Test
    func parsesTransportFailureWithoutStatus() throws {
        let json = #"{"url":"https://x.io/a","method":"post","timing":{"startTime":5,"duration":60000},"error":"The request timed out."}"#
        let e = try #require(NetworkEntry.parse(json, fallbackMillis: 0))
        #expect(e.status == nil)
        #expect(e.method == "POST")
        #expect(e.error == "The request timed out.")
        #expect(e.statusClass == .failed)
    }

    @Test
    func missingTimingFallsBackToTimestamp() throws {
        let withTs = try #require(NetworkEntry.parse(#"{"url":"https://x.io","timestamp":42}"#, fallbackMillis: 7))
        #expect(withTs.startMillis == 42)
        #expect(withTs.durationMillis == nil)
        #expect(withTs.method == "GET")

        let bare = try #require(NetworkEntry.parse(#"{"url":"https://x.io"}"#, fallbackMillis: 7))
        #expect(bare.startMillis == 7)
    }

    @Test
    func durationComputedFromEndWhenMissing() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","timing":{"startTime":100,"endTime":130}}"#, fallbackMillis: 0))
        #expect(e.durationMillis == 30)
    }

    @Test(arguments: [
        (#""404""#, 404),     // numeric string (lenient, e.g. future Android)
        ("503", 503),
    ])
    func statusAcceptsNumberOrNumericString(raw: String, expected: Int) throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","status":\#(raw)}"#, fallbackMillis: 0))
        #expect(e.status == expected)
    }

    @Test(arguments: [
        (200, NetworkEntry.StatusClass.success), (301, .redirect),
        (404, .clientError), (500, .serverError), (101, .other),
    ])
    func statusClassBuckets(status: Int, expected: NetworkEntry.StatusClass) throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","status":\#(status)}"#, fallbackMillis: 0))
        #expect(e.statusClass == expected)
    }

    @Test(arguments: [#"{"method":"GET"}"#, "[]", "not json", #"{"url":42}"#])
    func rejectsPayloadWithoutURL(json: String) {
        #expect(NetworkEntry.parse(json, fallbackMillis: 0) == nil)
    }

    @Test
    func nonStringHeaderValuesAreStringified() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","responseHeaders":{"Content-Length":123}}"#, fallbackMillis: 0))
        #expect(e.responseHeaders["Content-Length"] == "123")
    }
}
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `swift test --filter NetworkEntryTests`
Expected: compile error `cannot find 'NetworkEntry' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
//
//  NetworkEntry.swift
//  Beaver
//

import Foundation

/// One captured HTTP request/response, as sent by the SDK in a `network`
/// frame (PROTOCOL.md §4.3). One frame is one finished request; there is no
/// request/response pairing on the wire.
///
/// `payloadJSON` is the payload as received. The store saves it and reads
/// it back through `parse`, so live and reopened sessions go through the
/// same code.
public struct NetworkEntry: Identifiable, Hashable, Sendable {

    public enum StatusClass: String, CaseIterable, Sendable {
        case success, redirect, clientError, serverError, failed, other

        public var displayName: String {
            switch self {
            case .success:     "2xx"
            case .redirect:    "3xx"
            case .clientError: "4xx"
            case .serverError: "5xx"
            case .failed:      "Failed"
            case .other:       "Other"
            }
        }
    }

    public let id: Int64
    public let requestId: String
    public let url: String
    public let method: String
    public let status: Int?
    public let statusText: String?
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBody: String?
    public let responseBody: String?
    public let startMillis: UInt64
    public let durationMillis: Int?
    public let error: String?
    public let payloadJSON: String

    public var host: String { URLComponents(string: url)?.host ?? "" }

    /// Path plus query, the "Path" column. Falls back to the whole URL
    /// when it doesn't parse, so the row is never blank.
    public var path: String {
        guard let c = URLComponents(string: url), c.host != nil else { return url }
        let p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        return c.percentEncodedQuery.map { "\(p)?\($0)" } ?? p
    }

    public var statusClass: StatusClass {
        guard let status else { return .failed }
        switch status {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default:        return .other
        }
    }

    /// `fallbackMillis` is used when the payload has neither `timing.startTime`
    /// nor `timestamp`. The decoder passes "now"; the store passes the row's
    /// saved `timestamp_ms`, so a reopened entry keeps its time.
    public static func parse(_ payloadJSON: String, id: Int64 = 0, fallbackMillis: UInt64) -> NetworkEntry? {
        guard let data = payloadJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = o["url"] as? String
        else { return nil }

        let timing = o["timing"] as? [String: Any]
        let start = ProtocolDecoder.timestampMillis(timing?["startTime"])
            ?? ProtocolDecoder.timestampMillis(o["timestamp"])
            ?? fallbackMillis
        let duration: Int? = int(timing?["duration"]) ?? {
            guard let end = int(timing?["endTime"]), let s = int(timing?["startTime"]) else { return nil }
            return end - s
        }()

        return NetworkEntry(
            id: id,
            requestId: o["requestId"] as? String ?? "",
            url: url,
            method: (o["method"] as? String ?? "GET").uppercased(),
            status: int(o["status"]),
            statusText: o["statusText"] as? String,
            requestHeaders: headers(o["requestHeaders"]),
            responseHeaders: headers(o["responseHeaders"]),
            requestBody: o["requestBody"] as? String,
            responseBody: o["responseBody"] as? String,
            startMillis: start,
            durationMillis: duration,
            error: o["error"] as? String,
            payloadJSON: payloadJSON
        )
    }

    private static func int(_ value: Any?) -> Int? {
        if let s = value as? String { return Int(s) }
        if let n = value as? NSNumber, !(value is Bool) { return n.intValue }
        return nil
    }

    private static func headers(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.mapValues { ($0 as? String) ?? "\($0)" }
    }
}
```

`ProtocolDecoder.timestampMillis` is `static` with internal access (`ProtocolDecoder.swift:134`), so the same module can call it. Don't duplicate it.

- [ ] **Step 4: Run the tests and check they pass**

Run: `swift test --filter NetworkEntryTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Domain/NetworkEntry.swift BeaverTests/NetworkEntryTests.swift
git commit -m "feat(network): NetworkEntry model and payload parser"
```

---

### Task 2: Decode `network` frames

**Files:**
- Modify: `Beaver/Transport/ProtocolDecoder.swift:13-24` (packet and error enums), `:38-45` (switch)
- Test: `BeaverTests/ProtocolDecoderTests.swift` (append)

**Interfaces:**
- Consumes: `NetworkEntry.parse(_:id:fallbackMillis:)` (Task 1).
- Produces: `ProtocolDecoder.InboundPacket.network(NetworkEntry)` and `ProtocolDecoder.DecodeError.malformedNetwork(String)`.

- [ ] **Step 1: Write the failing tests** (append inside `ProtocolDecoderTests`)

```swift
    // MARK: - Network frames

    @Test
    func networkFrameDecodes() throws {
        let envelope: [String: Any] = [
            "type": "network",
            "id": UUID().uuidString,
            "event": #"{"url":"https://a.io/x","method":"GET","status":200,"timing":{"startTime":10,"duration":5}}"#,
        ]
        let result = ProtocolDecoder.decode(try JSONSerialization.data(withJSONObject: envelope))
        guard case .success(.network(let entry)) = result else {
            Issue.record("expected .network, got \(result)"); return
        }
        #expect(entry.url == "https://a.io/x")
        #expect(entry.status == 200)
        #expect(entry.startMillis == 10)
    }

    @Test(arguments: [
        ["type": "network", "id": "1"],                                  // no event string
        ["type": "network", "id": "1", "event": #"{"method":"GET"}"#],   // no url
        ["type": "network", "id": "1", "event": "nope"],                 // not JSON
    ] as [[String: String]])
    func networkFrameWithoutURLFails(envelope: [String: String]) throws {
        let result = ProtocolDecoder.decode(try JSONSerialization.data(withJSONObject: envelope))
        guard case .failure(.malformedNetwork) = result else {
            Issue.record("expected .malformedNetwork, got \(result)"); return
        }
    }
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `swift test --filter ProtocolDecoderTests`
Expected: compile error `type 'ProtocolDecoder.InboundPacket' has no member 'network'`.

- [ ] **Step 3: Implement it**

In `InboundPacket` add `case network(NetworkEntry)`. In `DecodeError` add `case malformedNetwork(String)`. In the switch add, before `default:`:

```swift
        case "network":
            return decodeNetwork(envelope: envelope)
```

Then add this section after `// MARK: - Storage`:

```swift
    // MARK: - Network

    private static func decodeNetwork(envelope: [String: Any]) -> Result<InboundPacket, DecodeError> {
        // PROTOCOL.md §4.3: same double encoding as `event`.
        guard let payload = envelope["event"] as? String else {
            return .failure(.malformedNetwork("missing 'event' string field"))
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        guard let entry = NetworkEntry.parse(payload, fallbackMillis: now) else {
            return .failure(.malformedNetwork("payload is not a JSON object with a string 'url'"))
        }
        return .success(.network(entry))
    }
```

- [ ] **Step 4: Run all tests and check they pass**

Run: `swift test`
Expected: all PASS. The existing unknown-type test, if there is one, must use a type other than `network`. Check with `grep -n '"network"' BeaverTests/ProtocolDecoderTests.swift`: only the `category` fixtures and the new tests should match.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Transport/ProtocolDecoder.swift BeaverTests/ProtocolDecoderTests.swift
git commit -m "feat(protocol): decode network frames"
```

---

### Task 3: Store network entries (migration, write, read, clear, change)

**Files:**
- Modify: `Beaver/Store/Schema.swift`. Add `v5_network_entry` after `v4_filter_facets`, before `return migrator` (line 193).
- Modify: `Beaver/Store/LogStore.swift`:
  - `Change` enum (lines 17-31): add a case.
  - `clearEvents` (line 294): also delete network rows.
  - New `// MARK: - Network entries` section after the storage-snapshot section (before `// MARK: - Helpers`, ~line 908).
- Test: `BeaverTests/LogStoreNetworkTests.swift`

**Interfaces:**
- Consumes: `NetworkEntry` (Task 1).
- Produces:
  - `LogStore.Change.networkAppended(sessionId: Int64)`
  - `public func recordNetworkEntry(_ entry: NetworkEntry, sessionId: Int64) async throws`
  - `public func networkEntries(sessionId: Int64, afterId: Int64 = 0) async throws -> [NetworkEntry]`, ordered by `(timestamp_ms, id)` ascending. `afterId` lets the view model load only new rows.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  LogStoreNetworkTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("LogStore network entries")
struct LogStoreNetworkTests {

    private func entry(_ url: String, at ms: UInt64) -> NetworkEntry {
        NetworkEntry.parse(#"{"url":"\#(url)","status":200,"timing":{"startTime":\#(ms),"duration":3}}"#,
                           fallbackMillis: 0)!
    }

    @Test
    func roundTripPreservesEntryAndOrder() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        try await store.recordNetworkEntry(entry("https://b.io", at: 20), sessionId: session.id)
        try await store.recordNetworkEntry(entry("https://a.io", at: 10), sessionId: session.id)

        let all = try await store.networkEntries(sessionId: session.id)
        #expect(all.map(\.url) == ["https://a.io", "https://b.io"])
        #expect(all.allSatisfy { $0.id > 0 })
        #expect(all[0].durationMillis == 3)
        #expect(all[0].status == 200)
    }

    @Test
    func afterIdReturnsOnlyNewerRows() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        try await store.recordNetworkEntry(entry("https://a.io", at: 1), sessionId: session.id)
        let first = try await store.networkEntries(sessionId: session.id)
        try await store.recordNetworkEntry(entry("https://b.io", at: 2), sessionId: session.id)

        let newer = try await store.networkEntries(sessionId: session.id, afterId: first.last!.id)
        #expect(newer.map(\.url) == ["https://b.io"])
    }

    @Test
    func entriesAreScopedToSessionAndClearedWithEvents() async throws {
        let store = try LogStore(source: .inMemory)
        let s1 = try await store.createSession(source: .live)
        let s2 = try await store.createSession(source: .live)
        try await store.recordNetworkEntry(entry("https://a.io", at: 1), sessionId: s1.id)
        try await store.recordNetworkEntry(entry("https://b.io", at: 1), sessionId: s2.id)

        try await store.clearEvents(sessionId: s1.id)

        #expect(try await store.networkEntries(sessionId: s1.id).isEmpty)
        #expect(try await store.networkEntries(sessionId: s2.id).count == 1)
    }

    @Test
    func recordBroadcastsNetworkAppended() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let stream = await store.changes()

        try await store.recordNetworkEntry(entry("https://a.io", at: 1), sessionId: session.id)

        for await change in stream {
            if case .networkAppended(let sid) = change {
                #expect(sid == session.id)
                break
            }
        }
    }
}
```

Before writing `recordBroadcastsNetworkAppended`, check how `appendedChangeIsBroadcast` in `LogStoreTests.swift` consumes the stream (around line 297). If it uses a timeout or a `Task` wrapper, copy that pattern exactly, so the test can't hang when the broadcast is missing.

- [ ] **Step 2: Run the tests and check they fail**

Run: `swift test --filter LogStoreNetworkTests`
Expected: compile error `value of type 'LogStore' has no member 'recordNetworkEntry'`.

- [ ] **Step 3: Implement it**

`Schema.swift`, a new migration:

```swift
        migrator.registerMigration("v5_network_entry") { db in
            // One row per `network` frame (PROTOCOL.md §4.3). The payload is
            // kept verbatim and re-parsed by NetworkEntry.parse on read, so
            // there is a single parser and new optional wire fields need no
            // migration. timestamp_ms is a column only for ordering.
            try db.execute(sql: """
                CREATE TABLE network_entry (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id   INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    timestamp_ms INTEGER NOT NULL,
                    payload_json TEXT    NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_network_session_ts
                    ON network_entry(session_id, timestamp_ms);
            """)
        }
```

`LogStore.swift`:
- Add `case networkAppended(sessionId: Int64)` to `Change`.
- In `clearEvents`, inside the same write block, add:

```swift
            try db.execute(
                sql: "DELETE FROM network_entry WHERE session_id = ?",
                arguments: [sessionId]
            )
```

Then add the new section:

```swift
    // MARK: - Network entries

    public func recordNetworkEntry(_ entry: NetworkEntry, sessionId: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO network_entry (session_id, timestamp_ms, payload_json)
                    VALUES (?, ?, ?)
                """,
                arguments: [sessionId, Int(entry.startMillis), entry.payloadJSON]
            )
        }
        broadcast(.networkAppended(sessionId: sessionId))
    }

    public func networkEntries(sessionId: Int64, afterId: Int64 = 0) async throws -> [NetworkEntry] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, timestamp_ms, payload_json
                    FROM network_entry
                    WHERE session_id = ? AND id > ?
                    ORDER BY timestamp_ms, id
                """,
                arguments: [sessionId, afterId]
            ).compactMap { row in
                NetworkEntry.parse(
                    row["payload_json"],
                    id: row["id"],
                    fallbackMillis: UInt64(row["timestamp_ms"] as Int)
                )
            }
        }
    }
```

In debug builds `eraseDatabaseOnSchemaChange = true` (`Schema.swift:20-22`), so a local debug DB is wiped on first launch after this change. That is expected. Release builds migrate in place.

- [ ] **Step 4: Run all tests and check they pass**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Store/Schema.swift Beaver/Store/LogStore.swift BeaverTests/LogStoreNetworkTests.swift
git commit -m "feat(store): persist network entries per session"
```

---

### Task 4: Pure filter and stats (`NetworkFilter`)

**Files:**
- Create: `Beaver/Support/NetworkFilter.swift`
- Test: `BeaverTests/NetworkFilterTests.swift`

**Interfaces:**
- Consumes: `NetworkEntry` and `NetworkEntry.StatusClass` (Task 1).
- Produces:
  - `public struct NetworkFilter: Equatable, Sendable`, with `var search: String`, `var methods: Set<String>`, `var statusClasses: Set<NetworkEntry.StatusClass>`, `var hosts: Set<String>`, `var excludedHosts: Set<String>`, `var isEmpty: Bool`, and `func matches(_ e: NetworkEntry) -> Bool`.
  - `public struct NetworkStats: Equatable, Sendable`, with `let count: Int`, `let successRate: Double?`, `let averageDurationMillis: Int?`, and `init(_ entries: [NetworkEntry])`.

An empty set in `methods`, `statusClasses` or `hosts` means "no restriction". Search is case-insensitive over the decoded url, method, status, header names and values, bodies and error. The raw payload is not searched (Review Focus #1).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  NetworkFilterTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("NetworkFilter")
struct NetworkFilterTests {

    private func e(_ json: String) -> NetworkEntry { NetworkEntry.parse(json, fallbackMillis: 0)! }

    private var ok: NetworkEntry {
        e(#"{"url":"https:\/\/api.io\/v1\/feed","method":"GET","status":200,"timing":{"startTime":1,"duration":100},"responseHeaders":{"X-Trace":"abc123"}}"#)
    }
    private var notFound: NetworkEntry {
        e(#"{"url":"https://cdn.io/img.png","method":"GET","status":404,"timing":{"startTime":2,"duration":300}}"#)
    }
    private var timeout: NetworkEntry {
        e(#"{"url":"https://api.io/login","method":"POST","error":"The request timed out."}"#)
    }

    @Test
    func emptyFilterMatchesEverything() {
        let f = NetworkFilter()
        #expect(f.isEmpty)
        #expect([ok, notFound, timeout].allSatisfy(f.matches))
    }

    @Test
    func searchMatchesDecodedURLNotRawJSON() {
        var f = NetworkFilter(); f.search = "API.IO/v1"
        #expect(f.matches(ok))
        #expect(!f.matches(notFound))
    }

    @Test
    func searchCoversHeadersBodiesAndError() {
        var f = NetworkFilter()
        f.search = "abc123";    #expect(f.matches(ok))
        f.search = "timed out"; #expect(f.matches(timeout))
    }

    @Test
    func failedClassMatchesErrorWithoutStatus() {
        var f = NetworkFilter(); f.statusClasses = [.failed]
        #expect(f.matches(timeout))
        #expect(!f.matches(ok))
    }

    @Test
    func facetsCombineWithAnd() {
        var f = NetworkFilter()
        f.methods = ["GET"]; f.hosts = ["cdn.io"]
        #expect(f.matches(notFound))
        #expect(!f.matches(ok))
        #expect(!f.matches(timeout))
    }

    @Test
    func excludedHostsWin() {
        var f = NetworkFilter(); f.excludedHosts = ["api.io"]
        #expect(!f.matches(ok))
        #expect(f.matches(notFound))
    }

    @Test
    func statsCountSuccessRateAndAverage() {
        let s = NetworkStats([ok, notFound, timeout])
        #expect(s.count == 3)
        #expect(s.successRate == 1.0 / 3.0)
        #expect(s.averageDurationMillis == 200)   // timeout has no duration: excluded
        #expect(NetworkStats([]).successRate == nil)
    }
}
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `swift test --filter NetworkFilterTests`
Expected: compile error `cannot find 'NetworkFilter' in scope`.

- [ ] **Step 3: Implement it**

```swift
//
//  NetworkFilter.swift
//  Beaver
//

import Foundation

/// Filter state of the Network tab. Empty sets mean "no restriction";
/// facets combine with AND.
public struct NetworkFilter: Equatable, Sendable {
    public var search = ""
    public var methods: Set<String> = []
    public var statusClasses: Set<NetworkEntry.StatusClass> = []
    public var hosts: Set<String> = []
    public var excludedHosts: Set<String> = []

    public init() {}

    public var isEmpty: Bool {
        search.isEmpty && methods.isEmpty && statusClasses.isEmpty
            && hosts.isEmpty && excludedHosts.isEmpty
    }

    public func matches(_ e: NetworkEntry) -> Bool {
        if !methods.isEmpty, !methods.contains(e.method) { return false }
        if !statusClasses.isEmpty, !statusClasses.contains(e.statusClass) { return false }
        let host = e.host
        if excludedHosts.contains(host) { return false }
        if !hosts.isEmpty, !hosts.contains(host) { return false }
        guard !search.isEmpty else { return true }
        // Decoded fields, not payloadJSON: JSONSerialization writes `/` as `\/`.
        let haystack: [String?] = [
            e.url, e.method, e.status.map(String.init), e.statusText, e.error,
            e.requestBody, e.responseBody,
        ] + e.requestHeaders.flatMap { [$0.key, $0.value] }
          + e.responseHeaders.flatMap { [$0.key, $0.value] }
        return haystack.contains { $0?.localizedCaseInsensitiveContains(search) == true }
    }
}

/// Summary line under the filter bar.
public struct NetworkStats: Equatable, Sendable {
    public let count: Int
    public let successRate: Double?
    public let averageDurationMillis: Int?

    public init(_ entries: [NetworkEntry]) {
        count = entries.count
        successRate = entries.isEmpty ? nil
            : Double(entries.filter { $0.statusClass == .success }.count) / Double(entries.count)
        let durations = entries.compactMap(\.durationMillis)
        averageDurationMillis = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
    }
}
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `swift test --filter NetworkFilterTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Support/NetworkFilter.swift BeaverTests/NetworkFilterTests.swift
git commit -m "feat(network): filter and stats for the Network tab"
```

---

### Task 5: Route frames to the store

**Files:**
- Modify: `Beaver/BeaverApp.swift:171-210` (`handleInbound`)

**Interfaces:**
- Consumes: `.network(NetworkEntry)` (Task 2) and `LogStore.recordNetworkEntry` (Task 3).

`handleInbound` is in the app target, outside `BeaverCore`, so it has no unit test. Tasks 2 and 3 cover the logic; Task 7 has the end-to-end check.

- [ ] **Step 1: Add the case** after `.success(.storage…)`:

```swift
        case .success(.network(let entry)):
            try? await env.store.recordNetworkEntry(entry, sessionId: sessionId)
```

A `.failure(.malformedNetwork)` already falls through to the existing `.failure` branch, which shows a `loggernext.protocol` warning. No change is needed there.

- [ ] **Step 2: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`. The switch is exhaustive; the compiler flags a missed case.

- [ ] **Step 3: Commit**

```bash
git add Beaver/BeaverApp.swift
git commit -m "feat(network): store network frames instead of logging them as unknown"
```

---

### Task 6: Network tab UI (view model, table, detail, filters, MainWindow wiring)

**Files:**
- Create: `Beaver/Features/Network/NetworkViewModel.swift`
- Create: `Beaver/Features/Network/NetworkView.swift`
- Modify: `Beaver/Features/MainWindow.swift`:
  - `@State` VMs (lines 34-35)
  - `Tab` (37-41)
  - `.task(id: env.viewingSessionId)` (~101-128)
  - sidebar (142-150)
  - detail switch (158-190)
  - `navigationTitle` (402-406)

**Interfaces:**
- Consumes: `LogStore.networkEntries(sessionId:afterId:)`, `.networkAppended`, `.cleared`, `NetworkFilter`, `NetworkStats` and `NetworkEntry`. Also existing: `JSONTreeView(record:)`, `StorageRecord.parse(_:rootKey:)`, `ConnectionPlaceholder(state:)`.
- Produces: `@MainActor @Observable final class NetworkViewModel` with `init(store: LogStore, sessionId: Int64)`, `let sessionId`, `func bootstrap() async`, `var entries: [NetworkEntry]`, `var filter: NetworkFilter`, `var filtered: [NetworkEntry]`, `var stats: NetworkStats`, `var selection: NetworkEntry.ID?`, `var selected: NetworkEntry?`, `var allMethods: [String]`, `var allHosts: [String]`.

- [ ] **Step 1: View model.** Follow `StoragesViewModel`: subscribe before the first fetch (`StoragesViewModel.swift:222-236`) and use the `nonisolated(unsafe)` subscription plus `deinit` (`:200-219`).

```swift
//
//  NetworkViewModel.swift
//  Beaver
//

import Foundation
import Observation

@MainActor
@Observable
final class NetworkViewModel {
    let sessionId: Int64
    private let store: LogStore

    private(set) var entries: [NetworkEntry] = []
    var filter = NetworkFilter()
    var selection: NetworkEntry.ID?

    // ponytail: filters the whole array on every change. Fine for a few
    // thousand requests per session; move to SQL / incremental if a
    // session ever gets much bigger.
    var filtered: [NetworkEntry] { filter.isEmpty ? entries : entries.filter(filter.matches) }
    var stats: NetworkStats { NetworkStats(filtered) }
    var selected: NetworkEntry? { selection.flatMap { id in entries.first { $0.id == id } } }
    var allMethods: [String] { Array(Set(entries.map(\.method))).sorted() }
    var allHosts: [String] { Array(Set(entries.map(\.host))).sorted() }

    /// See StoragesViewModel.subscription for why this is nonisolated(unsafe).
    private nonisolated(unsafe) var subscription: Task<Void, Never>?

    init(store: LogStore, sessionId: Int64) {
        self.store = store
        self.sessionId = sessionId
    }

    deinit { subscription?.cancel() }

    /// Subscribe first, then load. Same race as StoragesViewModel.bootstrap().
    func bootstrap() async {
        let stream = await store.changes()
        subscription = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                switch change {
                case .networkAppended(let sid) where sid == self.sessionId:
                    await self.loadNew()
                case .cleared(let sid) where sid == self.sessionId:
                    self.entries = []
                    self.selection = nil
                default:
                    break
                }
            }
        }
        await loadNew()
    }

    /// Only rows after the last loaded id, so a burst of requests doesn't
    /// re-read the whole session each time.
    private func loadNew() async {
        let fresh = (try? await store.networkEntries(sessionId: sessionId,
                                                     afterId: entries.last?.id ?? 0)) ?? []
        guard !fresh.isEmpty else { return }
        entries.append(contentsOf: fresh)
    }
}
```

`loadNew` only appends, so rows are kept in arrival order. The SDK sends a frame when a request *finishes*, so this is completion order, the same order zapp-support shows. Sorting by column is out of scope (see the end of this plan).

- [ ] **Step 2: View.** `HSplitView` with the table on the left and the detail on the right, the same layout as `LogFeedView.swift:38`. The table uses a SwiftUI `Table` like `LogFeedView.swift:853`.

```swift
//
//  NetworkView.swift
//  Beaver
//

import SwiftUI
import AppKit

struct NetworkView: View {
    @Bindable var vm: NetworkViewModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            HSplitView {
                table.frame(minWidth: 420)
                NetworkDetailView(entry: vm.selected).frame(minWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("Search URLs, headers, bodies…", text: $vm.filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            facetMenu("Method", all: vm.allMethods, selected: $vm.filter.methods)
            facetMenu("Status", all: NetworkEntry.StatusClass.allCases,
                      selected: $vm.filter.statusClasses, label: \.displayName)
            facetMenu("Host", all: vm.allHosts, selected: $vm.filter.hosts)
            if !vm.filter.isEmpty {
                Button("Clear") { vm.filter = NetworkFilter() }
            }
            Spacer()
            Text(statsLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(8)
    }

    private var statsLine: String {
        let s = vm.stats
        var parts = ["\(s.count) of \(vm.entries.count)"]
        if let r = s.successRate { parts.append("\(Int((r * 100).rounded()))% 2xx") }
        if let d = s.averageDurationMillis { parts.append("avg \(d) ms") }
        return parts.joined(separator: " · ")
    }

    private func facetMenu<T: Hashable>(
        _ title: String, all: [T], selected: Binding<Set<T>>, label: KeyPath<T, String>? = nil
    ) -> some View {
        Menu(selected.wrappedValue.isEmpty ? title : "\(title) (\(selected.wrappedValue.count))") {
            ForEach(all, id: \.self) { value in
                Toggle(label.map { value[keyPath: $0] } ?? "\(value)", isOn: Binding(
                    get: { selected.wrappedValue.contains(value) },
                    set: { on in
                        if on { selected.wrappedValue.insert(value) }
                        else { selected.wrappedValue.remove(value) }
                    }
                ))
            }
        }
        .fixedSize()
    }

    // MARK: Table

    private var table: some View {
        Table(vm.filtered, selection: $vm.selection) {
            TableColumn("Method") { Text($0.method).font(.caption.monospaced().bold()) }
                .width(min: 50, ideal: 60, max: 80)
            TableColumn("Status") { e in
                Text(e.status.map(String.init) ?? "—")
                    .foregroundStyle(color(e.statusClass)).monospacedDigit()
            }
            .width(min: 44, ideal: 50, max: 60)
            TableColumn("Host") { Text($0.host).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("Path") { Text($0.path).lineLimit(1).truncationMode(.middle) }
            TableColumn("Duration") { e in
                Text(e.durationMillis.map { "\($0) ms" } ?? "—")
                    .foregroundStyle(durationColor(e.durationMillis)).monospacedDigit()
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn("Time") { Text(Self.time($0.startMillis)).monospacedDigit() }
                .width(min: 90, ideal: 100, max: 110)
        }
        .contextMenu(forSelectionType: NetworkEntry.ID.self) { ids in
            if let id = ids.first, let e = vm.entries.first(where: { $0.id == id }) {
                Button("Only \(e.host)") { vm.filter.hosts = [e.host] }
                Button("Hide \(e.host)") { vm.filter.excludedHosts.insert(e.host) }
                Divider()
                Button("Copy URL") { copy(e.url) }
            }
        }
        .overlay {
            if vm.filtered.isEmpty {
                ContentUnavailableView("No network requests", systemImage: "network",
                                       description: Text(vm.entries.isEmpty
                                           ? "Requests appear here as the app makes them (iOS X-Ray SDK)."
                                           : "Nothing matches the current filters."))
            }
        }
    }

    private func color(_ c: NetworkEntry.StatusClass) -> Color {
        switch c {
        case .success: .green
        case .redirect: .blue
        case .clientError: .orange
        case .serverError, .failed: .red
        case .other: .secondary
        }
    }

    private func durationColor(_ ms: Int?) -> Color {
        guard let ms else { return .secondary }
        return ms < 100 ? .green : ms < 500 ? .orange : .red
    }

    static func time(_ ms: UInt64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Detail

struct NetworkDetailView: View {
    let entry: NetworkEntry?

    var body: some View {
        if let e = entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Request") {
                        row("URL", e.url, copyable: true)
                        row("Method", e.method)
                        headers(e.requestHeaders)
                        bodyView(e.requestBody)
                    }
                    section("Response") {
                        row("Status", [e.status.map(String.init), e.statusText].compactMap { $0 }.joined(separator: " "))
                        if let err = e.error {
                            Text(err).foregroundStyle(.red).textSelection(.enabled)
                        }
                        headers(e.responseHeaders)
                        bodyView(e.responseBody)
                    }
                    section("Timing") {
                        row("Started", NetworkView.time(e.startMillis))
                        row("Duration", e.durationMillis.map { "\($0) ms" } ?? "—")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No request selected", systemImage: "network")
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ k: String, _ v: String, copyable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(v).textSelection(.enabled).font(.body.monospaced())
            if copyable { Button { copy(v) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless) }
        }
    }

    @ViewBuilder
    private func headers(_ h: [String: String]) -> some View {
        if !h.isEmpty {
            DisclosureGroup("Headers (\(h.count))") {
                ForEach(h.keys.sorted(), id: \.self) { k in row(k, h[k] ?? "") }
            }
        }
    }

    /// JSON bodies render as a tree (same component as the Log feed detail);
    /// anything else as selectable monospaced text.
    @ViewBuilder
    private func bodyView(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            DisclosureGroup("Body") {
                HStack { Spacer(); Button("Copy") { copy(text) } }
                if let tree = StorageRecord.parse(text, rootKey: "body"), tree.children != nil {
                    JSONTreeView(record: tree)
                } else {
                    Text(text).font(.body.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}
```

Parsing in `body` runs on every render. `DetailPaneView` says "never parse in `body`" (`DetailPaneView.swift:14`). If the detail pane is slow with large bodies (the SDK caps them at 100 KB), cache the parsed trees in the view model keyed by `selection`, following `StoragesViewModel.parsedCache`. Do this only if you see the slowness, not in advance.

If `func copy` clashes with an existing symbol when you compile, make it a `private static` on `NetworkView` and call it as `NetworkView.copy` from the detail view.

- [ ] **Step 3: Wire it into MainWindow**

```swift
    @State private var networkVM: NetworkViewModel?          // next to storagesVM

    enum Tab: Hashable {
        case logFeed
        case storages
        case network
        case sessions
    }
```

In `.task(id: env.viewingSessionId)`: add `networkVM = nil` to the `guard … else` branch, and after the storages block add:

```swift
            if networkVM?.sessionId != sid {
                let fresh = NetworkViewModel(store: env.store, sessionId: sid)
                await fresh.bootstrap()
                networkVM = fresh
            }
```

In the sidebar, after Storages:

```swift
            Label("Network",   systemImage: "network")
                .tag(Tab.network)
```

In the detail switch:

```swift
            case .network:
                if let vm = networkVM {
                    NetworkView(vm: vm)
                } else {
                    ConnectionPlaceholder(state: env.serverState)
                }
```

In `navigationTitle`, add `case .network:  "Network"`.

- [ ] **Step 4: Build**

Run: `make build`
Expected: `** BUILD SUCCEEDED **`, with no new warnings except the known `nonisolated(unsafe)` false positive described in `StoragesViewModel.swift:206-209`.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Features/Network Beaver/Features/MainWindow.swift
git commit -m "feat(network): Network tab with table, filters and request detail"
```

---

### Task 7: End-to-end check, protocol docs, decision record

**Files:**
- Modify: `PROTOCOL.md`. Add §4.3 `network` after §4.2 (ends ~line 252). Update §7 so it no longer says `network` is unknown.
- Modify: `DECISIONS.md`. Append `## D39. Network tab: store raw network payloads, filter in memory`.
- Modify: `CHANGELOG.md`. Add an entry in the file's existing style.
- Modify: `ARCHITECTURE.md §4` (schema reference). Add the `network_entry` table.

- [ ] **Step 1: Smoke test against the real app.** Run the built Beaver, then from a scratch file (not committed) run the script below. Node ≥ 22 has a global `WebSocket`; this machine has v22.17.

```js
// send-network.mjs — node send-network.mjs
const ws = new WebSocket("ws://127.0.0.1:9080");
const entry = (i, extra) => JSON.stringify({
  requestId: `r${i}`, url: `https:\/\/api.example.com\/v1\/items\/${i}?q=a`, method: i % 2 ? "POST" : "GET",
  timing: { startTime: Date.now(), duration: 40 * i }, timestamp: Date.now(),
  requestHeaders: { Authorization: "[REDACTED]", Accept: "application/json" },
  responseHeaders: { "Content-Type": "application/json" },
  responseBody: JSON.stringify({ id: i, nested: { ok: true } }), ...extra });
ws.onopen = () => {
  ws.send(JSON.stringify({ type: "network", id: crypto.randomUUID(), event: entry(1, { status: 200 }) }));
  ws.send(JSON.stringify({ type: "network", id: crypto.randomUUID(), event: entry(2, { status: 404 }) }));
  ws.send(JSON.stringify({ type: "network", id: crypto.randomUUID(), event: entry(3, { error: "The request timed out." }) }));
  ws.send(JSON.stringify({ type: "network", id: crypto.randomUUID(), event: "{}" }));   // malformed
  setTimeout(() => ws.close(), 500);
};
```

Check:
- Network tab shows 3 rows. Statuses are 200 (green), 404 (orange) and `—` (red).
- Selecting row 1 shows headers, and the body as a JSON tree.
- Status → Failed leaves only row 3.
- Searching `v1/items/2` leaves row 2.
- "Hide api.example.com" empties the table and the overlay says nothing matches.
- The Log feed has **no** "unknown packet type: network" line, and has **one** `decode failed: malformedNetwork(...)` warning for the `{}` frame.
- Reopen the session from Sessions: all 3 rows come back.
- Clear the log feed: the Network tab empties.

Then with a real iOS app: connect a Zapp iOS debug build with quick-brick-xray ≥ #2676 to `ws://<mac-ip>:9080`. Browse a few screens and check the requests appear. Each request also appears once in the Log feed under `native_application/network_requests`; that is expected.

- [ ] **Step 2: PROTOCOL.md §4.3**. Document the envelope, the NetworkEntry field table (names, types, required/optional, ms units, 100 KB body cap and header redaction done by the SDK), "one frame = one finished request, no pairing", and a sample frame (payload from Task 1's `ios` fixture). In §7, remove `network` from the unknown-type behaviour.

- [ ] **Step 3: DECISIONS.md D39**. Record:
  - raw payload saved and re-parsed on read, so there is one parser and no migration for new optional fields;
  - filtering happens in memory (ceiling: a few thousand rows per session);
  - network rows are deleted by `clearEvents`, unlike storage snapshots;
  - the Log feed keeps the SDK's duplicate `event` on purpose;
  - Android has no `network` frame yet.

- [ ] **Step 4: Run the full check**

Run: `make build && make test`
Expected: build succeeds and all tests pass.

- [ ] **Step 5: Commit**

```bash
git add PROTOCOL.md DECISIONS.md CHANGELOG.md ARCHITECTURE.md
git commit -m "docs: network frame protocol, D39, changelog"
```

---

## Not in this plan (add when needed)

- **Android.** Needs a quick-brick-xray Android change: a `network` value in `MessageType` and a mapper from `NetworkRequestLogger` events to the same NetworkEntry JSON, mirroring iOS #2676. Beaver needs no change for it. A Beaver-side adapter that parses Android log events is possible, but it would give Beaver a second contract to maintain.
- **`mcp` frames from Android** (`WebSocketSink.kt:42`) still appear as "unknown packet type: mcp" in the Log feed. That is a separate question.
- **Copy as cURL / HAR export / session JSON export of network rows.** zapp-support's Network tab has none of these either. Add them when someone asks: cURL is ~15 lines on `NetworkEntry`, and HAR is an exporter next to `SessionExport.swift`.
- **Sorting by column.** zapp-support has none. Add a `sortOrder` binding on the `Table` if needed.
- **Request/response pairing.** The wire sends only finished requests, so there is nothing to pair.
