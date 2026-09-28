# Several Devices at Once — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several apps stay connected to Beaver at once, each in its own live session, with a toolbar dropdown that switches the window between them.

**Architecture:** `WSServer` keeps a dictionary of connections keyed by `UUID` and tags every inbound item with it. A new core value type `LiveDevices` maps connection → live session and holds each session's `cmdlist` answer; `AppEnvironment` wraps it and implements `DeviceLink.send(command:to:)`. The live session id is the device's identity everywhere (UI selection = `viewingSessionId`, MCP `deviceId`). A new `DeviceFollower` replaces the three copies of "follow the device across a reconnect" in the MCP layer.

**Tech Stack:** Swift 6, SwiftUI (macOS 15+), Network.framework (`NWListener`), GRDB 7, Swift Testing.

**Spec:** `plans/2026-09-28-multi-device-design.md`

## Global Constraints

- Commit prefix `feat:` for every commit (CLAUDE.md: a feature, or one step of one, is +0.1.0). End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests: `swift test` (Swift Testing, `BeaverTests/`, module `BeaverCore`). App build: `make build`.
- `AppEnvironment.swift`, `BeaverApp.swift` and `Beaver/Features/` are **not** in the `BeaverCore` package target — logic that needs tests goes in `Beaver/Domain/` or `Beaver/MCP/`.
- The app target stops compiling after Task 3 (interfaces change) and compiles again at the end of Task 5. `swift test` must pass at the end of every task.
- WebSocket state string reported to agents stays `clientConnected` (agents already rely on it).
- The dropdown's *Recent* section shows **5** sessions.
- MCP tools never activate the app (CLAUDE.md MCP rule 4); every tool result keeps its one-line `summary` and `Next:`.
- No change to `PROTOCOL.md` wire frames or `SESSION_FILE_FORMAT.md`.

## Review Focus

1. **A second device connects while the first is viewed** → the window stays on the first; Task 1 `connect` tests pin it.
2. **Device A restarts while device B stays connected** → an MCP wait on A follows A's new session, never B; Task 4 test `followsTheRightDevice`.
3. **A pinned wait while another device connects** → the wait is not reported as ended; Task 4 test `otherDeviceDoesNotEndPinned`.
4. **Two devices, a tool call without `deviceId`** → a `ToolError` listing both ids with app names and an example; Task 3 test `severalDevicesNeedDeviceId`.
5. **The last of two clients disconnects** → WebSocket state goes to `clientDisconnected` only then, and the other client still receives commands; Task 2 test `twoClients`.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Beaver/Domain/LiveDevices.swift` | **Create** | connection → live session map, per-session commands, the "switch view?" rule, the device-menu sections |
| `Beaver/Transport/WSServer.swift` | Modify | many connections; `Inbound` and `send` carry a connection `UUID`; `State.clientConnected(count:)` |
| `Beaver/MCP/ToolContext.swift` | Modify | `HostSnapshot.liveSessionIds`, `commandsBySession`; `DeviceLink.send(command:to:)` |
| `Beaver/MCP/DeviceWait.swift` | Modify | `requireDevice` for several devices; `DeviceFollower`; waits and disconnect watcher use it |
| `Beaver/MCP/Watches.swift` | Modify | following watch uses `DeviceFollower` |
| `Beaver/MCP/ToolInput.swift` | Modify | `resolveSession` picks among several live sessions; `liveSession(_:)` |
| `Beaver/MCP/Tools/{Command,State,Storage,Session,Status}Tools.swift` | Modify | route by device |
| `Beaver/MCP/MCPTool.swift`, `MCPServer.swift` | Modify | `deviceId` description, instructions |
| `Beaver/Domain/StorageCommand.swift`, `Session.swift` | Modify | send to a session; comment |
| `Beaver/AppEnvironment.swift` | Modify | `live: LiveDevices`, `DeviceLink` conformance |
| `Beaver/BeaverApp.swift` | Modify | per-connection bootstrap |
| `Beaver/Features/...` (AgentUI, Storages, Sessions, CommandBar, MainWindow) | Modify | use `env.isLive`, `env.send`; device menu; pill |
| `BeaverTests/LiveDevicesTests.swift`, `MultiDeviceToolsTests.swift` | **Create** | new tests |
| `BeaverTests/WSServer*Tests.swift`, `MCPTestSupport.swift`, `FollowDeviceTests.swift`, others | Modify | new shapes |
| `DECISIONS.md`, `ARCHITECTURE.md`, `Beaver/Resources/MCP.md`, `CHANGELOG.md` | Modify | D73, docs |

---

### Task 1: `LiveDevices` core type

**Files:**
- Create: `Beaver/Domain/LiveDevices.swift`
- Test: `BeaverTests/LiveDevicesTests.swift`

**Interfaces:**
- Consumes: `CommandHint` (`Beaver/Domain/CommandHint.swift`), `Session`.
- Produces:
  - `public struct LiveDevices: Sendable, Equatable` with `public private(set) var sessions: [UUID: Int64]`, `public private(set) var commands: [Int64: [CommandHint]]`, `public var sessionIds: [Int64]` (sorted ascending), `public func isLive(_ sessionId: Int64?) -> Bool`, `public func connection(for sessionId: Int64) -> UUID?`, `public func session(for connection: UUID) -> Int64?`, `public mutating func connect(_ connection: UUID, session: Int64, viewing: Int64?) -> Bool` (returns "switch the window to it"), `@discardableResult public mutating func disconnect(_ connection: UUID) -> Int64?`, `public mutating func replace(session old: Int64, with new: Int64)`, `public mutating func setCommands(_ hints: [CommandHint], for sessionId: Int64)`.
  - `public enum DeviceMenu { public static func sections(sessions: [Session], live: [Int64], recent limit: Int = 5) -> (connected: [Session], recent: [Session]) }`

- [ ] **Step 1: Write the failing tests**

`BeaverTests/LiveDevicesTests.swift`:

```swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Live devices (D73)")
struct LiveDevicesTests {

    @Test("The first device takes the window; a second one doesn't while a live one is viewed")
    func connect() {
        var live = LiveDevices()
        let a = UUID(), b = UUID()
        #expect(live.connect(a, session: 1, viewing: nil))
        #expect(!live.connect(b, session: 2, viewing: 1))
        #expect(live.sessionIds == [1, 2])
        #expect(live.isLive(2))
        #expect(live.connection(for: 2) == b)
        #expect(live.session(for: a) == 1)
    }

    @Test("A new device takes the window over a past or imported session")
    func connectOverPast() {
        var live = LiveDevices()
        #expect(live.connect(UUID(), session: 7, viewing: 3))
    }

    @Test("Disconnect forgets the session and its commands")
    func disconnect() {
        var live = LiveDevices()
        let a = UUID()
        _ = live.connect(a, session: 1, viewing: nil)
        live.setCommands([CommandHint(name: "cmdlist", syntax: nil, description: nil)], for: 1)
        #expect(live.disconnect(a) == 1)
        #expect(!live.isLive(1))
        #expect(live.commands[1] == nil)
        #expect(live.disconnect(a) == nil)
        #expect(!live.isLive(nil))
    }

    @Test("A replaced session keeps its connection")
    func replace() {
        var live = LiveDevices()
        let a = UUID()
        _ = live.connect(a, session: 1, viewing: nil)
        live.replace(session: 1, with: 9)
        #expect(live.session(for: a) == 9)
        #expect(!live.isLive(1))
    }

    @Test("The device menu: connected first, then the 5 newest other live sessions, no imports")
    func menu() {
        func s(_ id: Int64, _ source: Session.Source = .live) -> Session {
            Session(id: id, startedAt: Date(timeIntervalSince1970: Double(id)), source: source)
        }
        let newestFirst = (1...9).reversed().map { s(Int64($0)) } + [s(0, .imported)]
        let m = DeviceMenu.sections(sessions: newestFirst, live: [9, 4])
        #expect(m.connected.map(\.id) == [9, 4])
        #expect(m.recent.map(\.id) == [8, 7, 6, 5, 3])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter LiveDevicesTests`
Expected: compile error, `cannot find 'LiveDevices' in scope`.

- [ ] **Step 3: Implement**

`Beaver/Domain/LiveDevices.swift`:

```swift
//
//  LiveDevices.swift
//  Beaver
//

import Foundation

/// Which WebSocket connection writes to which live session, and what each
/// live app answered to `cmdlist` (D73). A device is known by its live
/// session id everywhere else: the toolbar menu, the command bar, MCP's
/// `deviceId`.
public struct LiveDevices: Sendable, Equatable {
    public private(set) var sessions: [UUID: Int64] = [:]
    public private(set) var commands: [Int64: [CommandHint]] = [:]

    public init() {}

    /// Oldest first.
    public var sessionIds: [Int64] { sessions.values.sorted() }

    public func isLive(_ sessionId: Int64?) -> Bool {
        sessionId.map { sessions.values.contains($0) } ?? false
    }

    public func connection(for sessionId: Int64) -> UUID? {
        sessions.first { $0.value == sessionId }?.key
    }

    public func session(for connection: UUID) -> Int64? { sessions[connection] }

    /// Records a new device. Returns whether the window should switch to
    /// it: only when the user isn't already looking at a live device.
    public mutating func connect(_ connection: UUID, session: Int64, viewing: Int64?) -> Bool {
        let takesWindow = !isLive(viewing)
        sessions[connection] = session
        return takesWindow
    }

    @discardableResult
    public mutating func disconnect(_ connection: UUID) -> Int64? {
        guard let sessionId = sessions.removeValue(forKey: connection) else { return nil }
        commands[sessionId] = nil
        return sessionId
    }

    /// A live session was deleted; its device writes to `new` from now on.
    public mutating func replace(session old: Int64, with new: Int64) {
        guard let connection = connection(for: old) else { return }
        sessions[connection] = new
        commands[new] = commands.removeValue(forKey: old)
    }

    public mutating func setCommands(_ hints: [CommandHint], for sessionId: Int64) {
        commands[sessionId] = hints
    }
}

/// The toolbar device menu (D73).
public enum DeviceMenu {
    /// Connected devices, then the most recent other live sessions.
    /// `sessions` is newest first, as `LogStore.sessions()` returns it.
    public static func sections(sessions: [Session], live: [Int64],
                                recent limit: Int = 5) -> (connected: [Session], recent: [Session]) {
        let connected = sessions.filter { live.contains($0.id) }
        let recent = sessions.filter { $0.source == .live && !live.contains($0.id) }.prefix(limit)
        return (connected, Array(recent))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter LiveDevicesTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Domain/LiveDevices.swift BeaverTests/LiveDevicesTests.swift
git commit -m "feat: track several live devices by connection

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `WSServer` accepts several connections

**Files:**
- Modify: `Beaver/Transport/WSServer.swift`
- Modify: `BeaverTests/WSServerInboundTests.swift`, `BeaverTests/WSServerControlFrameTests.swift`
- Test: `BeaverTests/WSServerInboundTests.swift` (new test `twoClients`)

**Interfaces:**
- Produces:
  - `WSServer.State.clientConnected(count: Int)` (other cases unchanged)
  - `WSServer.Inbound`: `.connected(UUID)`, `.frame(UUID, Data)`, `.disconnected(UUID)`
  - `public func send(command: String, to connection: UUID)` (replaces `send(command:)`)
- Note: after this task the app target does not compile (callers of `send(command:)`); fixed in Task 5.

- [ ] **Step 1: Update the existing tests to the new shape and add the failing two-client test**

In `WSServerInboundTests.swift` replace the expectation block in `framesAreBracketedByConnectAndDisconnect`:

```swift
            let items = await race(timeout: .seconds(10)) {
                var items: [WSServer.Inbound] = []
                for await item in server.inbound {
                    items.append(item)
                    if case .disconnected = item { break }
                }
                return items
            }
            guard case .connected(let id)? = items?.first else {
                Issue.record("round \(round): no .connected first: \(String(describing: items))")
                break
            }
            #expect(items == [
                .connected(id),
                .frame(id, Data("first".utf8)),
                .frame(id, Data("second".utf8)),
                .disconnected(id),
            ], "round \(round)")
```

(and delete the old `if items?.first != .connected { break }` line).

In `WSServerControlFrameTests.swift` change `for await case .frame(let data) in server.inbound` to `for await case .frame(_, let data) in server.inbound`.

Add to `WSServerInboundTests`:

```swift
    @Test("Two clients stay connected, frames say who sent them, commands reach the right one")
    func twoClients() async throws {
        let server = WSServer(port: 19_084)
        try await server.start()
        _ = await race(timeout: .seconds(10)) {
            for await state in server.state { if case .listening = state { return } }
        }
        func connect() async throws -> URLSessionWebSocketTask {
            let c = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:19084")!)
            c.resume()
            _ = try await c.receive() // handshake
            return c
        }
        let a = try await connect()
        let b = try await connect()
        try await a.send(.string("from a"))
        try await b.send(.string("from b"))

        let items = await race(timeout: .seconds(10)) {
            var items: [WSServer.Inbound] = []
            for await item in server.inbound {
                items.append(item)
                if items.filter({ if case .frame = $0 { true } else { false } }).count == 2 { break }
            }
            return items
        } ?? []
        let connected = items.compactMap { if case .connected(let id) = $0 { id } else { nil } }
        #expect(connected.count == 2)
        let senders = Dictionary(uniqueKeysWithValues: items.compactMap {
            if case .frame(let id, let data) = $0 { (String(decoding: data, as: UTF8.self), id) } else { nil }
        })
        #expect(senders["from a"] == connected.first)
        #expect(senders["from b"] == connected.last)

        a.cancel(with: .normalClosure, reason: nil)
        let gone = await race(timeout: .seconds(10)) {
            for await case .disconnected(let id) in server.inbound { return id }
            return nil
        } ?? nil
        #expect(gone == connected.first)

        await server.send(command: "cmdlist", to: connected[1])
        let got = try await b.receive()
        if case .string(let text) = got { #expect(text.contains("cmdlist")) } else { Issue.record("expected text, got \(got)") }

        b.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WSServer`
Expected: compile errors (`.connected` has no associated value, no `send(command:to:)`).

- [ ] **Step 3: Implement in `WSServer.swift`**

Replace the `State` and `Inbound` enums:

```swift
    public enum State: Sendable {
        case stopped
        case listening
        /// `count` devices are connected (D73).
        case clientConnected(count: Int)
        case clientDisconnected(reason: String)
        case failed(reason: String)
    }

    /// Every item says which connection it came from (D73).
    public enum Inbound: Sendable, Equatable {
        case connected(UUID)
        case frame(UUID, Data)
        case disconnected(UUID)
    }
```

Replace `private var current: NWConnection?` with:

```swift
    private var connections: [UUID: NWConnection] = [:]
    /// Connections past the handshake; `State.clientConnected` counts these.
    private var ready = Set<UUID>()
```

In `stop()` replace `current?.cancel()` / `current = nil` with:

```swift
        for connection in connections.values { connection.cancel() }
        connections = [:]
        ready = []
```

Replace `handleNewConnection`, `handleConnectionState` and `receive(on:)`, and `send(command:)`:

```swift
    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        print("[WSServer] new connection \(id) (endpoint=\(connection.endpoint))")
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnectionState(state, id: id) }
        }
        connection.start(queue: networkQueue)
    }

    private func handleConnectionState(_ state: NWConnection.State, id: UUID) async {
        // A connection that already failed can still report `.cancelled`.
        guard let connection = connections[id] else { return }
        print("[WSServer] connection \(id): \(state)")
        switch state {
        case .ready:
            if let payload = try? ProtocolEncoder.encodeHandshake(id: UUID()) {
                send(payload, on: connection)
            }
            ready.insert(id)
            stateContinuation.yield(.clientConnected(count: ready.count))
            inboundContinuation.yield(.connected(id))
            receive(on: connection, id: id)
        case .failed(let error):
            connection.cancel()
            drop(id, reason: error.localizedDescription)
        case .cancelled:
            drop(id, reason: "cancelled")
        case .waiting(let error):
            stateContinuation.yield(.failed(reason: "waiting: \(error.localizedDescription)"))
        case .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    private func drop(_ id: UUID, reason: String) {
        connections[id] = nil
        guard ready.remove(id) != nil else { return }
        stateContinuation.yield(ready.isEmpty
            ? .clientDisconnected(reason: reason)
            : .clientConnected(count: ready.count))
        inboundContinuation.yield(.disconnected(id))
    }

    private nonisolated func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode
            if let data, !data.isEmpty, opcode == .text || opcode == .binary {
                self.inboundContinuation.yield(.frame(id, data))
            }
            if error == nil {
                self.receive(on: connection, id: id)
            }
        }
    }

    /// No-op when that connection is gone.
    public func send(command: String, to connection: UUID) {
        guard let target = connections[connection],
              let payload = try? ProtocolEncoder.encodeCommand(command) else { return }
        send(payload, on: target)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build --build-tests 2>&1 | grep error:` — the only errors must be in `Beaver/MCP/ToolContext.swift` (`extension WSServer: DeviceLink {}` no longer satisfies the protocol). Delete that line now; Task 3 gives `DeviceLink` its new shape.
Run: `swift test --filter WSServer`
Expected: all WSServer tests pass (the inbound test runs 200 rounds; allow ~30 s).

- [ ] **Step 5: Commit**

```bash
git add Beaver/Transport/WSServer.swift Beaver/MCP/ToolContext.swift BeaverTests/WSServerInboundTests.swift BeaverTests/WSServerControlFrameTests.swift
git commit -m "feat: accept several WebSocket clients at once

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: MCP host shape — several live sessions, commands routed by device

**Files:**
- Modify: `Beaver/MCP/ToolContext.swift`, `Beaver/MCP/DeviceWait.swift` (`requireDevice` only), `Beaver/MCP/ToolInput.swift`, `Beaver/MCP/MCPTool.swift` (`deviceId` text), `Beaver/Domain/StorageCommand.swift`, `Beaver/MCP/Tools/CommandTools.swift`, `StateTools.swift`, `StorageTools.swift`, `SessionTools.swift`, `StatusTools.swift`
- Modify: `BeaverTests/MCPTestSupport.swift` and every test using `deviceConnected` / `liveSessionId:` (sed below)
- Test: `BeaverTests/MultiDeviceToolsTests.swift` (create)

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces:
  - `HostSnapshot.liveSessionIds: [Int64]`, `HostSnapshot.commandsBySession: [Int64: [CommandHint]]`, computed `HostSnapshot.deviceConnected: Bool`. `init(serverState:liveSessionIds:viewingSessionId:commandsBySession:deviceURL:beaverVersion:mcpPort:ui:windowOpen:frontmost:notifications:)` — same defaults as today, `liveSessionIds: [] `, `commandsBySession: [:]`.
  - `protocol DeviceLink: Sendable { func send(command: String, to sessionId: Int64) async }`
  - `ToolContext.requireDevice(_:doing:) -> (host: HostSnapshot, liveSessionId: Int64)` (same signature; `deviceId` is the live session id as a string)
  - `ToolContext.liveSession(_ id: Int64) async throws -> ResolvedSession` (how: `.live`)
  - `ToolContext.describeDevices(_ ids: [Int64]) async throws -> String`
  - `FakeDevice.targets: [Int64]`

- [ ] **Step 1: Reshape `HostSnapshot` and `DeviceLink`**

In `Beaver/MCP/ToolContext.swift` replace the two stored properties `deviceConnected` / `liveSessionId` and `commands` and the init:

```swift
public struct HostSnapshot: Sendable, Equatable {
    public var serverState: String
    /// One per connected device, oldest first (D73). A device's MCP
    /// `deviceId` is its live session id.
    public var liveSessionIds: [Int64]
    /// Each live app's `cmdlist` answer.
    public var commandsBySession: [Int64: [CommandHint]]
    public var deviceURL: String?
    public var beaverVersion: String
    public var mcpPort: UInt16
    public var ui: UIState
    public var windowOpen: Bool
    public var frontmost: Bool

    public var deviceConnected: Bool { !liveSessionIds.isEmpty }

    public var viewingSessionId: Int64? {
        get { ui.sessionId }
        set { ui.sessionId = newValue }
    }
    public var notifications: AgentNotifications.State

    public init(serverState: String = "listening", liveSessionIds: [Int64] = [],
                viewingSessionId: Int64? = nil, commandsBySession: [Int64: [CommandHint]] = [:],
                deviceURL: String? = "ws://192.168.1.5:9080",
                beaverVersion: String = "dev", mcpPort: UInt16 = 9081,
                ui: UIState = UIState(), windowOpen: Bool = true, frontmost: Bool = false,
                notifications: AgentNotifications.State = .allowed) {
        self.serverState = serverState
        self.liveSessionIds = liveSessionIds
        self.commandsBySession = commandsBySession
        self.deviceURL = deviceURL
        self.beaverVersion = beaverVersion; self.mcpPort = mcpPort
        self.ui = ui; self.windowOpen = windowOpen; self.frontmost = frontmost
        if let viewingSessionId { self.ui.sessionId = viewingSessionId }
        self.notifications = notifications
    }
}

public protocol DeviceLink: Sendable {
    /// Sends to the device whose live session is `sessionId`; no-op once it's gone.
    func send(command: String, to sessionId: Int64) async
}
```

- [ ] **Step 2: Update the test fakes and existing tests mechanically**

`BeaverTests/MCPTestSupport.swift`, replace `FakeDevice`:

```swift
final class FakeDevice: DeviceLink {
    private let log = Mutex<[(command: String, sessionId: Int64)]>([])
    private let onSend: @Sendable (String) async -> Void

    init(onSend: @escaping @Sendable (String) async -> Void = { _ in }) { self.onSend = onSend }

    var sent: [String] { log.withLock { $0.map(\.command) } }
    var targets: [Int64] { log.withLock { $0.map(\.sessionId) } }

    func send(command: String, to sessionId: Int64) async {
        log.withLock { $0.append((command, sessionId)) }
        await onSend(command)
    }
}
```

Rewrite the single-device fields in every test file:

```bash
sed -i '' -E \
  -e 's/\$0\.deviceConnected = false; \$0\.liveSessionId = nil/$0.liveSessionIds = []/g' \
  -e 's/\$0\.deviceConnected = true; \$0\.liveSessionId = ([a-zA-Z.]+)/$0.liveSessionIds = [\1]/g' \
  -e 's/\$0\.liveSessionId = ([a-zA-Z.]+)/$0.liveSessionIds = [\1]/g' \
  -e 's/deviceConnected: true, liveSessionId: ([a-zA-Z.]+)/liveSessionIds: [\1]/g' \
  -e 's/HostSnapshot\(liveSessionId: ([a-zA-Z.]+)/HostSnapshot(liveSessionIds: [\1]/g' \
  -e 's/deviceConnected: true,[[:space:]]*//g' \
  BeaverTests/*.swift
```

Then fix by hand:
- `BeaverTests/StorageToolsTests.swift` `fixture`: `HostSnapshot(liveSessionIds: [s.id], commands: commands)` → `HostSnapshot(liveSessionIds: [s.id], commandsBySession: [s.id: commands])`.
- `BeaverTests/StateToolsTests.swift` `commands()`: `HostSnapshot(commands: hints)` → `HostSnapshot(liveSessionIds: [1], commandsBySession: [1: hints])`.
- `BeaverTests/FollowDeviceTests.swift` `requireDevice()`: `["deviceId": "current"]` → `["deviceId": JSON(String(a.id))]`.
- `BeaverTests/StatusToolsTests.swift`: any expectation on `devices[0].id == "current"` → `JSON(String(s.id))`.

Run `swift build --build-tests 2>&1 | grep error: | grep BeaverTests` and fix what remains the same way. Errors in `Beaver/MCP` are next.

- [ ] **Step 3: Write the failing multi-device tests**

`BeaverTests/MultiDeviceToolsTests.swift`:

```swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Several devices (D73)")
struct MultiDeviceToolsTests {

    /// Two live sessions: a = "Alpha" on an iPhone, b = "Beta" on a Pixel.
    private func twoDevices(viewing: Int64? = nil) async throws -> (LogStore, Session, Session, FakeUI) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: "1.0",
                                             deviceModel: "iPhone 15", platform: "iOS", osVersion: "18.0")
        try await store.setSessionDeviceInfo(id: b.id, appName: "Beta", appVersion: "2.0",
                                             deviceModel: "Pixel 8", platform: "Android", osVersion: "15")
        let ui = FakeUI(value: HostSnapshot(serverState: "clientConnected", liveSessionIds: [a.id, b.id],
                                            viewingSessionId: viewing))
        return (store, a, b, ui)
    }

    @Test("Review focus: with two devices, a call without deviceId lists both")
    func severalDevicesNeedDeviceId() async throws {
        let (store, a, b, ui) = try await twoDevices()
        let device = FakeDevice()
        do {
            _ = try await CommandTools.send.run(ToolArguments(["command": "cmdlist"]),
                                                makeContext(store, fakeUI: ui, device: device))
            Issue.record("expected a ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("\"\(a.id)\" (Alpha"))
            #expect(error.message.contains("\"\(b.id)\" (Beta"))
            #expect(error.message.contains("deviceId"))
        }
        #expect(device.sent.isEmpty)
    }

    @Test("commands_send with deviceId reaches that device")
    func routesByDeviceId() async throws {
        let (store, _, b, ui) = try await twoDevices()
        let device = FakeDevice()
        let r = try await CommandTools.send.run(ToolArguments(["command": "cmdlist", "deviceId": JSON(b.id)]),
                                                makeContext(store, fakeUI: ui, device: device))
        #expect(device.targets == [b.id])
        #expect(r.structured["sessionId"] == JSON(b.id))
    }

    @Test("An unknown deviceId fails with the list")
    func unknownDeviceId() async throws {
        let (store, _, _, ui) = try await twoDevices()
        await #expect(throws: ToolError.self) {
            try await makeContext(store, fakeUI: ui).requireDevice(ToolArguments(["deviceId": "999"]), doing: "send a command")
        }
    }

    @Test("beaver_status lists every device")
    func status() async throws {
        let (store, a, _, ui) = try await twoDevices()
        let r = try await StatusTools.status.run(ToolArguments(), makeContext(store, fakeUI: ui))
        #expect(r.structured["devices"]?.array?.count == 2)
        #expect(r.structured["devices"]?.array?.first?["id"] == JSON(String(a.id)))
        #expect(r.summary.contains("2 devices"))
        #expect(r.summary.contains("Beta"))
    }

    @Test("commands_list answers for the chosen device")
    func commandsPerDevice() async throws {
        let (store, a, b, ui) = try await twoDevices()
        ui.update { $0.commandsBySession = [a.id: [CommandHint(name: "alpha.only", syntax: nil, description: nil)],
                                            b.id: [CommandHint(name: "beta.only", syntax: nil, description: nil)]] }
        let r = try await StateTools.commandsList.run(ToolArguments(["deviceId": JSON(b.id)]), makeContext(store, fakeUI: ui))
        #expect(r.body.contains("beta.only"))
        #expect(!r.body.contains("alpha.only"))
    }

    @Test("Without sessionId, reads use the viewed live device, else the newest")
    func resolveAmongSeveral() async throws {
        let (store, a, b, ui) = try await twoDevices(viewing: nil)
        let ctx = makeContext(store, fakeUI: ui)
        #expect(try await ctx.resolveSession(ToolArguments()).id == b.id)
        ui.update { $0.viewingSessionId = a.id }
        #expect(try await ctx.resolveSession(ToolArguments()).id == a.id)
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `swift test --filter MultiDeviceToolsTests`
Expected: compile errors in `Beaver/MCP` (uses of `liveSessionId`, `send(command:)`), then — once compiling — failures.

- [ ] **Step 5: Implement**

`Beaver/MCP/DeviceWait.swift` — replace `requireDevice`:

```swift
    /// Design M25 / D73: tools that talk to a device take an optional
    /// deviceId — the device's live session id, as beaver_status lists it.
    /// With one device it may be omitted; with several it may not.
    public func requireDevice(_ args: ToolArguments, doing what: String) async throws
        -> (host: HostSnapshot, liveSessionId: Int64) {
        let host = await ui.snapshot()
        let live = host.liveSessionIds
        guard !live.isEmpty else {
            throw ToolError("No device is connected, so Beaver can't \(what). Ask the user to open the app with "
                + "remote assistance pointed at \(host.deviceURL ?? "Beaver"), then call beaver_status().")
        }
        let wanted = try args.string("deviceId")
        // args.string turns a number into text; accept "12", 12 and 12.0.
        if let wanted, let id = Int64(wanted) ?? Double(wanted).flatMap({ Int64(exactly: $0) }),
           live.contains(id) { return (host, id) }
        if wanted == nil, live.count == 1 { return (host, live[0]) }
        let list = try await describeDevices(live)
        let lead = wanted.map { "No connected device \"\($0)\"." }
            ?? "\(live.count) devices are connected; say which one with deviceId."
        throw ToolError("\(lead) Connected: \(list). Example: deviceId: \"\(live[0])\".")
    }

    /// `"12" (Alpha 1.0 · iPhone 15, iOS 18.0), "14" (…)`.
    public func describeDevices(_ ids: [Int64]) async throws -> String {
        let sessions = try await store.sessions()
        return ids.map { id in
            "\"\(id)\"" + (sessions.first { $0.id == id }.map { " (\(StatusTools.describeDevice($0)))" } ?? "")
        }.joined(separator: ", ")
    }
```

In the same file, in `waitForEvents` and `watchForDisconnect`, make them compile for now by replacing `ui.snapshot().liveSessionId` with `ui.snapshot().liveSessionIds.last` (all four occurrences). Task 4 replaces this logic.

`Beaver/MCP/Watches.swift` line with `ui.snapshot().liveSessionId` → `ui.snapshot().liveSessionIds.last` (Task 4 replaces it).

`Beaver/MCP/ToolInput.swift` — in `resolveSession`, replace the `host.liveSessionId` step:

```swift
        let host = await ui.snapshot()
        // D73: with several devices, the one the user is viewing, else the newest.
        let liveId = host.viewingSessionId.flatMap { host.liveSessionIds.contains($0) ? $0 : nil }
            ?? host.liveSessionIds.max()
        if let id = liveId, let s = sessions.first(where: { $0.id == id }) {
            return ResolvedSession(id: id, session: s, how: .live)
        }
```

and add after `resolveSession`:

```swift
    /// The live session of the device `requireDevice` picked. Marked
    /// `.live`, so a wait on it follows the device across a restart.
    public func liveSession(_ id: Int64) async throws -> ResolvedSession {
        guard let s = try await store.sessions().first(where: { $0.id == id }) else {
            throw ToolError("Session #\(id) is gone. Example: beaver_status() shows what is connected now.")
        }
        return ResolvedSession(id: id, session: s, how: .live)
    }
```

`Beaver/MCP/MCPTool.swift`:

```swift
    public static let deviceId = string(
        "Which connected device: its id from beaver_status (e.g. \"12\"). Omit it when only one device is connected.")
```

`Beaver/Domain/StorageCommand.swift` — in `sendAndVerify` and `refresh`, each `await device.send(command: X)` becomes `await device.send(command: X, to: sessionId)` (three calls).

`Beaver/MCP/Tools/CommandTools.swift`:

```swift
        let (_, live) = try await ctx.requireDevice(args, doing: "send a command")
        let session = try await ctx.liveSession(live)
```

and `await ctx.device.send(command: command)` → `await ctx.device.send(command: command, to: live)`.

`Beaver/MCP/Tools/StateTools.swift` — `commandsList`:

```swift
        inputSchema: ToolSchema.object(["deviceId": ToolSchema.deviceId])
    ) { args, ctx in
        let none = ToolResult(summary: "No command list yet: no device is connected, or it hasn't answered cmdlist.",
                              structured: ["commands": []], next: ["beaver_status()"])
        guard await ctx.ui.snapshot().deviceConnected else { return none }
        let (host, live) = try await ctx.requireDevice(args, doing: "list its commands")
        let hints = host.commandsBySession[live] ?? []
        guard !hints.isEmpty else { return none }
```

(the rest of the closure is unchanged).

`Beaver/MCP/Tools/StorageTools.swift`:
- `let isLive = host.deviceConnected && host.liveSessionId == s.id` → `let isLive = host.liveSessionIds.contains(s.id)`
- in `refreshIfLive`:

```swift
        guard host.liveSessionIds.contains(s.id) else {
            return host.deviceConnected
                ? " Not refreshed: session #\(s.id) isn't live."
                : " Not refreshed: no device is connected; this is the last stored snapshot."
        }
```
- in `edit`: `by: host.commands.map(\.name)` → `by: (host.commandsBySession[live] ?? []).map(\.name)`.

`Beaver/MCP/Tools/SessionTools.swift`: `if id == (await ctx.ui.snapshot().liveSessionId)` → `if await ctx.ui.snapshot().liveSessionIds.contains(id)`.

`Beaver/MCP/Tools/StatusTools.swift` — replace the device block and summary/next:

```swift
        var devices: [JSON] = []
        var described: [String] = []
        var lines: [String] = []
        for live in host.liveSessionIds {
            guard let session = sessions.first(where: { $0.id == live }) else { continue }
            let latest = try await ctx.store.latestEventId(sessionId: live)
            devices.append([
                "id": .string(String(live)),
                "app": JSON(session.appName), "appVersion": JSON(session.appVersion),
                "model": JSON(session.deviceModel), "platform": JSON(session.platform),
                "osVersion": JSON(session.osVersion),
                "liveSessionId": JSON(live), "latestEventId": JSON(latest),
            ])
            described.append("\(describeDevice(session)) (deviceId \"\(live)\")")
            lines.append("Device \"\(live)\": \(describeDevice(session)) — live session #\(live)"
                + (latest.map { ", latest event #\($0)" } ?? ", no events yet"))
        }
```

```swift
        let summary = switch devices.count {
        case 0: "No device is connected. \(sessions.isEmpty ? "No sessions are stored yet." : "Past sessions can still be read.")"
        case 1: "A device is connected: \(described[0])."
        default: "\(devices.count) devices are connected: \(described.joined(separator: "; ")). Pass deviceId to commands and storage changes."
        }
        let first = host.liveSessionIds.first
        let next: [String] = devices.isEmpty
            ? (sessions.isEmpty
                ? ["ask the user to connect the app to \(host.deviceURL ?? "Beaver") with remote assistance, then beaver_status()"]
                : ["sessions_list()", "logs_facets(sessionId: \(sessions[0].id))"])
            : devices.count == 1
                ? ["logs_facets(since: \"10m\")", "logs_query(filter: {minLevel: \"warning\"}, since: \"10m\")"]
                : ["commands_list(deviceId: \"\(first ?? 0)\")", "logs_facets(sessionId: \(first ?? 0), since: \"10m\")"]
```

and `sessionId: host.liveSessionId` → `sessionId: host.liveSessionIds.max()`. In `sessionsList`: `let liveNow = session.id == host.liveSessionId` → `let liveNow = host.liveSessionIds.contains(session.id)`.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: all pass, including `MultiDeviceToolsTests` (6) and the drift tests in `MCPDocTests`. If a StatusTools expectation checks the old single-device summary text ("A device is connected: …"), update it to the new text.

- [ ] **Step 7: Commit**

```bash
git add Beaver/MCP Beaver/Domain/StorageCommand.swift BeaverTests
git commit -m "feat: MCP tools address one of several connected devices

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `DeviceFollower` — follow the right device across a restart

**Files:**
- Modify: `Beaver/MCP/DeviceWait.swift` (`waitForEvents`, `watchForDisconnect`, new `DeviceFollower`)
- Modify: `Beaver/MCP/Watches.swift` (`startNotifyTask`)
- Test: `BeaverTests/FollowDeviceTests.swift` (add tests)

**Interfaces:**
- Consumes: `HostSnapshot.liveSessionIds` (Task 3).
- Produces: `struct DeviceFollower: Sendable` with `enum Step: Equatable { case same, moved(Int64), gone }`, `init(start: Int64, live: [Int64])`, `private(set) var current: Int64`, `mutating func step(live: [Int64], store: LogStore) async -> Step?`, `static func successor(of ended: Session, live: [Session], appeared: Set<Int64>) -> Int64?`; `extension Session { var fingerprint: [String]? }`.

- [ ] **Step 1: Write the failing tests** (append to `FollowDeviceTests`)

```swift
    private func session(_ id: Int64, app: String? = nil, model: String? = nil) -> Session {
        Session(id: id, startedAt: Date(), source: .live, appName: app, deviceModel: model, platform: "iOS")
    }

    @Test("successor: same fingerprint wins; a different one is never followed")
    func successorByFingerprint() {
        let a = session(1, app: "Alpha", model: "iPhone")
        #expect(DeviceFollower.successor(of: a, live: [session(2, app: "Beta", model: "Pixel"),
                                                       session(3, app: "Alpha", model: "iPhone")],
                                         appeared: [3]) == 3)
        #expect(DeviceFollower.successor(of: a, live: [session(2, app: "Beta", model: "Pixel")],
                                         appeared: [2]) == nil)
    }

    @Test("successor: unknown fingerprint follows only the one session that just came up")
    func successorWithoutFingerprint() {
        let a = session(1, app: "Alpha", model: "iPhone")
        #expect(DeviceFollower.successor(of: a, live: [session(4)], appeared: [4]) == 4)
        #expect(DeviceFollower.successor(of: a, live: [session(4), session(5)], appeared: [4, 5]) == nil)
        // Connected before A dropped: not A's restart.
        #expect(DeviceFollower.successor(of: a, live: [session(2)], appeared: []) == nil)
    }

    @Test("Review focus: A restarts while B stays connected — the wait follows A, not B")
    func followsTheRightDevice() async throws {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: nil, deviceModel: "iPhone",
                                             platform: "iOS", osVersion: nil)
        try await store.setSessionDeviceInfo(id: b.id, appName: "Beta", appVersion: nil, deviceModel: "Pixel",
                                             platform: "Android", osVersion: nil)
        let ui = FakeUI(value: HostSnapshot(liveSessionIds: [a.id, b.id], viewingSessionId: a.id))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            ui.update { $0.liveSessionIds = [b.id] }
            await store.append(event("App started"), to: b.id)   // B's log must not count
            try? await Task.sleep(for: .milliseconds(400))
            guard let a2 = try? await store.createSession(source: .live) else { return }
            ui.update { $0.liveSessionIds = [b.id, a2.id] }
            try? await Task.sleep(for: .milliseconds(300))
            await store.append(event("App started"), to: a2.id)
        }
        let r = try await LogTools.wait.run(
            ToolArguments(["filter": ["search": "App started"], "timeoutMs": 5000]),
            makeContext(store, fakeUI: ui))
        #expect(r.structured["timedOut"] == false)
        #expect(r.structured["sessionChanged"]?["from"] == JSON(a.id))
        #expect(r.structured["sessionChanged"]?["to"] != JSON(b.id))
        #expect(r.structured["sessionId"] != JSON(b.id))
    }

    @Test("Review focus: another device connecting doesn't end a pinned wait")
    func otherDeviceDoesNotEndPinned() async throws {
        let (store, a, ui) = try await liveFixture()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard let b = try? await store.createSession(source: .live) else { return }
            ui.update { $0.liveSessionIds = [a.id, b.id] }
        }
        let r = try await LogTools.wait.run(ToolArguments(["sessionId": JSON(a.id), "timeoutMs": 1500]),
                                            makeContext(store, fakeUI: ui))
        #expect(r.structured["sessionEnded"] == false)
        #expect(r.structured["timedOut"] == true)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter FollowDeviceTests`
Expected: compile error `cannot find 'DeviceFollower'`.

- [ ] **Step 3: Implement `DeviceFollower`** (in `Beaver/MCP/DeviceWait.swift`, after `WaitSegment`)

```swift
/// Follows one device across reconnects (D66). With several devices (D73)
/// a new live session continues the device when its fingerprint matches;
/// when either fingerprint is still unknown, only if it is the one session
/// that came up since the last look.
// ponytail: fingerprint heuristic — two identical builds on two simulators
// look alike. A stable device id from the SDK would replace it.
struct DeviceFollower: Sendable {
    enum Step: Equatable { case same, moved(Int64), gone }

    private(set) var current: Int64
    private var lastLive: Set<Int64>

    init(start: Int64, live: [Int64]) {
        current = start
        lastLive = Set(live)
    }

    /// nil while the set of live sessions hasn't changed since the last call.
    mutating func step(live: [Int64], store: LogStore) async -> Step? {
        let now = Set(live)
        guard now != lastLive else { return nil }
        let appeared = now.subtracting(lastLive)
        lastLive = now
        if now.contains(current) { return .same }
        let sessions = (try? await store.sessions()) ?? []
        guard let ended = sessions.first(where: { $0.id == current }),
              let next = Self.successor(of: ended, live: sessions.filter { now.contains($0.id) },
                                        appeared: appeared)
        else { return .gone }
        current = next
        return .moved(next)
    }

    static func successor(of ended: Session, live: [Session], appeared: Set<Int64>) -> Int64? {
        let newer = live.filter { $0.id > ended.id }
        if let print = ended.fingerprint,
           let same = newer.filter({ $0.fingerprint == print }).map(\.id).max() {
            return same
        }
        let unknown = newer.filter {
            appeared.contains($0.id) && (ended.fingerprint == nil || $0.fingerprint == nil)
        }
        return unknown.count == 1 ? unknown[0].id : nil
    }
}

extension Session {
    /// Which app on which device, to tell devices apart; nil until the SDK reports it.
    var fingerprint: [String]? {
        guard let appName else { return nil }
        return [appName, deviceModel ?? "", platform ?? ""]
    }
}
```

- [ ] **Step 4: Rewrite `waitForEvents`** (same file)

```swift
    public func waitForEvents(from start: ResolvedSession, afterId: Int64, filter: Filter, limit: Int,
                              timeout: Duration, untilFirst: Bool) async throws -> WaitResult {
        let follows = start.how != .given
        var segments = [WaitSegment(sessionId: start.id, afterId: afterId)]
        let liveAtStart = await ui.snapshot().liveSessionIds
        var device = DeviceFollower(start: start.id, live: liveAtStart)
        let pinnedWasLive = !follows && liveAtStart.contains(start.id)
        var result = WaitResult(sessionId: start.id)
        result.liveSessionId = liveAtStart.contains(start.id) ? start.id : nil
        let deadline = ContinuousClock.now + timeout

        while true {
            (result.events, result.total) = try await read(segments, filter: filter, limit: limit)
            let done = (untilFirst && result.total > 0) || result.sessionEnded
            if done || ContinuousClock.now >= deadline || Task.isCancelled {
                result.sessionId = segments[segments.count - 1].sessionId
                result.timedOut = untilFirst && result.total == 0 && !result.sessionEnded
                return result
            }
            try? await Task.sleep(for: Self.pollInterval)
            guard let step = await device.step(live: await ui.snapshot().liveSessionIds, store: store) else { continue }
            switch step {
            case .same:
                result.deviceDisconnected = false
            case .moved(let next):
                result.liveSessionId = next
                result.deviceDisconnected = false
                if follows, !segments.contains(where: { $0.sessionId == next }) {
                    segments.append(WaitSegment(sessionId: next, afterId: 0))
                    result.sessionChanged = SessionChange(from: start.id, to: next)
                } else if pinnedWasLive {
                    result.sessionEnded = true
                }
            case .gone:
                result.liveSessionId = nil
                if follows {
                    result.deviceDisconnected = true
                } else if pinnedWasLive {
                    result.sessionEnded = true
                    result.deviceDisconnected = true
                }
            }
        }
    }
```

- [ ] **Step 5: Rewrite `watchForDisconnect`** (same file)

```swift
    func watchForDisconnect(after command: String, sessionId: Int64, window: Duration = .seconds(30)) async {
        let liveNow = await ui.snapshot().liveSessionIds
        await watches.setDisconnectWatcher(Task { [self] in
            var device = DeviceFollower(start: sessionId, live: liveNow)
            let dropDeadline = ContinuousClock.now + window
            while ContinuousClock.now < dropDeadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                guard let step = await device.step(live: await ui.snapshot().liveSessionIds, store: store),
                      step != .same else { continue }
                var back: Int64?
                if case .moved(let id) = step { back = id }
                let backDeadline = ContinuousClock.now + window
                while back == nil, ContinuousClock.now < backDeadline {
                    try? await Task.sleep(for: Self.pollInterval)
                    guard !Task.isCancelled else { return }
                    if case .moved(let id)? = await device.step(live: await ui.snapshot().liveSessionIds, store: store) {
                        back = id
                    }
                }
                guard !Task.isCancelled else { return }
                let outcome = back.map { " → session #\($0)" } ?? "; not back after \(window.components.seconds) s"
                await AgentJournal(store: store).post(.system, "Device disconnected after \"\(command)\"\(outcome)",
                                                      sessionId: back ?? sessionId)
                return
            }
        })
    }
```

- [ ] **Step 6: Follow in watches** (`Beaver/MCP/Watches.swift`, `startNotifyTask`)

After `var first: EventRecord?` add:

```swift
            var device = DeviceFollower(start: w.sessionId, live: await ui.snapshot().liveSessionIds)
```

and replace the `if w.follows, let live = … liveSessionIds.last …` block with:

```swift
                if w.follows,
                   case .moved(let next)? = await device.step(live: await ui.snapshot().liveSessionIds, store: store),
                   !segments.contains(where: { $0.sessionId == next }) {
                    segments.append(WaitSegment(sessionId: next, afterId: 0))
                }
```

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: all pass — the new `FollowDeviceTests` cases, the existing ones (`follows`, `pinnedEnds`, `disconnected`, …), `WatchTests`, `CommandToolsTests`. Also `grep -n "liveSessionIds.last" Beaver/MCP` must print nothing.

- [ ] **Step 8: Commit**

```bash
git add Beaver/MCP BeaverTests/FollowDeviceTests.swift
git commit -m "feat: follow the right device across a restart when several are connected

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Wire the app — per-connection sessions, routing, live checks

**Files:**
- Modify: `Beaver/AppEnvironment.swift`, `Beaver/BeaverApp.swift`, `Beaver/Features/AgentActivity/AppEnvironment+AgentUI.swift`, `Beaver/Features/Storages/StoragesView.swift`, `Beaver/Features/Storages/StoragesViewModel.swift`, `Beaver/Features/Sessions/SessionsView.swift`, `Beaver/Features/CommandBar/CommandBarView.swift`, `Beaver/Features/CommandBar/CommandBarViewModel.swift`, `Beaver/Domain/Session.swift` (comment)

**Interfaces:**
- Consumes: `LiveDevices` (Task 1), `WSServer.Inbound`/`send(command:to:)`/`State` (Task 2), `DeviceLink`, `HostSnapshot` (Task 3).
- Produces: `AppEnvironment.live: LiveDevices`, `AppEnvironment.isLive(_:)`, `AppEnvironment.availableCommands` (computed), `AppEnvironment.didConnect(_:session:)`, `AppEnvironment.didDisconnect(_:) -> Int64?`, `AppEnvironment: DeviceLink`.

These files are outside `BeaverCore`; the check is `make build` plus the manual run in Task 8.

- [ ] **Step 1: `AppEnvironment`**

Replace `public var currentSessionId: Int64?` (and its doc comment) with:

```swift
    /// Connected devices: which connection writes which live session (D73).
    public var live = LiveDevices()

    public func isLive(_ sessionId: Int64?) -> Bool { live.isLive(sessionId) }
```

Replace the stored `public var availableCommands: [CommandHint] = []` with:

```swift
    /// The viewed device's `cmdlist` answer.
    public var availableCommands: [CommandHint] {
        viewingSessionId.flatMap { live.commands[$0] } ?? []
    }
```

Replace `didConnectSession` / `didDisconnectSession` with:

```swift
    public func didConnect(_ connection: UUID, session: Int64) {
        if live.connect(connection, session: session, viewing: viewingSessionId) {
            viewingSessionId = session
        }
    }

    @discardableResult
    public func didDisconnect(_ connection: UUID) -> Int64? {
        live.disconnect(connection)
    }
```

Add at the end of the file:

```swift
extension AppEnvironment: DeviceLink {
    nonisolated public func send(command: String, to sessionId: Int64) async {
        guard let connection = await MainActor.run(body: { self.live.connection(for: sessionId) }) else { return }
        await server.send(command: command, to: connection)
    }
}
```

- [ ] **Step 2: `BeaverApp.bootstrap`**

Replace the state loop body with just `env.serverState = state` (the `cmdlist` request moves to `.connected`). Replace the inbound loop:

```swift
        Task { @MainActor in
            for await item in env.server.inbound {
                switch item {
                case .connected(let connection):
                    guard let session = try? await env.store.createSession(source: .live) else { continue }
                    env.didConnect(connection, session: session.id)
                    // Ask for the command list; brief delay so the SDK has
                    // finished registering its handlers.
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        await env.send(command: "cmdlist", to: session.id)
                    }
                case .frame(let connection, let frame):
                    guard let sessionId = env.live.session(for: connection) else { continue }
                    await Self.handleInbound(frame: frame, sessionId: sessionId, env: env)
                case .disconnected(let connection):
                    if let sessionId = env.didDisconnect(connection) {
                        try? await env.store.endSession(sessionId)
                    }
                }
            }
        }
```

In the changes loop replace the two deletion cases:

```swift
                case .sessionDeleted(let id):
                    if env.viewingSessionId == id { env.viewingSessionId = nil }
                    await replaceDeletedLiveSessions(env: env) { $0 == id }
                    await env.refreshViewingEventCount()
                case .sessionsCleared:
                    env.viewingSessionId = nil
                    await replaceDeletedLiveSessions(env: env) { _ in true }
                    await env.refreshViewingEventCount()
```

Change `handleInbound(frame:env:)` to `handleInbound(frame: Data, sessionId: Int64, env: AppEnvironment)`: delete its first two lines (the `currentSessionId` read and guard), and replace the `cmdlist` side-channel with:

```swift
            if let names = CommandHints.cmdListNames(in: event) {
                await MainActor.run {
                    env.live.setCommands(CommandHints.merge(sdkNames: names), for: sessionId)
                }
            }
```

Replace `ensureLiveSessionIfConnected` (function and its doc comment) with:

```swift
/// A deleted live session leaves its device with nowhere to write: give each
/// such connection a fresh live session, and show it if nothing is viewed.
@MainActor
private func replaceDeletedLiveSessions(env: AppEnvironment, deleted: (Int64) -> Bool) async {
    for sessionId in env.live.sessionIds where deleted(sessionId) {
        guard let fresh = try? await env.store.createSession(source: .live) else { continue }
        env.live.replace(session: sessionId, with: fresh.id)
        if env.viewingSessionId == nil { env.viewingSessionId = fresh.id }
    }
}
```

`AgentAccess(store: store, ui: environment, device: server)` → `device: environment`.

- [ ] **Step 3: Agent snapshot** (`AppEnvironment+AgentUI.swift`)

```swift
            let state: String = switch serverState {
            case .stopped: "stopped"
            case .listening: "listening"
            case .clientConnected: "clientConnected"
            case .clientDisconnected(let reason): "clientDisconnected: \(reason)"
            case .failed(let reason): "failed: \(reason)"
            }
            return HostSnapshot(
                serverState: state,
                liveSessionIds: live.sessionIds,
                commandsBySession: live.commands,
```

(remove the `deviceConnected:`, `liveSessionId:`, `commands:` arguments; keep the rest). In `open(_:reveal:)` `device: server` → `device: self`.

- [ ] **Step 4: Storages**

`StoragesViewModel.swift`:
- `func apply(_ edit: Edit, via server: WSServer)` → `func apply(_ edit: Edit, via device: any DeviceLink)`, and `device: server)` → `device: device)` in the `sendAndVerify` call.
- `func requestRefresh(via server: WSServer)` → `func requestRefresh(via device: any DeviceLink)`; inside: `Task { [weak self, sessionId = self.sessionId] in await device.send(command: "storage.list", to: sessionId)` (keep the rest). Update its doc comment: "No-op if this session's device isn't connected."

`StoragesView.swift`:
- `sendStorageEdit(... server: WSServer, ...)` → `device: any DeviceLink`; inside `vm.apply(edit, via: device)` and the undo call `sendStorageEdit(undo, vm: vm, device: device, …)`.
- call site line ~151: `server: env.server` → `device: env`.
- `vm.requestRefresh(via: env.server)` (3 places) → `vm.requestRefresh(via: env)`.
- `env.currentSessionId == vm.sessionId` (4 places) → `env.isLive(vm.sessionId)`; the one at ~651 becomes `return env.isLive(vm.sessionId) ? nil : "Past session"`.

- [ ] **Step 5: Sessions and command bar**

`SessionsView.swift` `isLiveSession`: body → `env.isLive(item.id)`; comment "Live = the session a connected device is writing to."

`CommandBarViewModel.swift`: `private let server: WSServer` / `init(server:)` → `private let device: any DeviceLink` / `init(device: any DeviceLink)`; `submit()` → `submit(to sessionId: Int64?)`:

```swift
    func submit(to sessionId: Int64?) {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, let sessionId else { return }
        remember(command)
        Task { [device, command] in
            await device.send(command: command, to: sessionId)
        }
        input = ""
        historyCursor = nil
    }
```

Update the type's doc comment: "dispatches to the viewed device via `DeviceLink.send(command:to:)`".

`CommandBarView.swift`: `CommandBarViewModel(server: env.server)` → `CommandBarViewModel(device: env)`; both `vm.submit()` → `vm.submit(to: env.viewingSessionId)`; `onRefresh` → `Task { if let sid = env.viewingSessionId { await env.send(command: "cmdlist", to: sid) } }`; `isClientConnected` body → `env.isLive(env.viewingSessionId)`.

`Beaver/Domain/Session.swift` doc comment: "Per D2 (one client at a time) each accepted connection starts a new session row." → "Each accepted connection starts a new session row; several can be live at once (D73)."

- [ ] **Step 6: Build and test**

Run: `grep -rn "currentSessionId\|server.send(command: \|didConnectSession\|ensureLiveSession" Beaver` — expect no output.
Run: `make build` — expect success.
Run: `swift test` — expect all pass.

- [ ] **Step 7: Commit**

```bash
git add Beaver
git commit -m "feat: give every connected device its own live session

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Device menu in the toolbar, device count in the pill

**Files:**
- Modify: `Beaver/Features/MainWindow.swift` (toolbar leading item, `ToolbarDeviceBadge` → `DeviceMenuButton`, `ConnectionIndicator`)

**Interfaces:**
- Consumes: `DeviceMenu.sections` (Task 1), `env.live`, `env.isLive`, `env.viewingSessionId`, `env.selectedTab`, `LogStore.changes()` / `sessions()`.

`DeviceMenu.sections` is covered by Task 1's test; this task is view code, checked by `make build` and Task 8.

- [ ] **Step 1: Replace the leading toolbar item**

```swift
        ToolbarItem(placement: .navigation) {
            DeviceMenuButton()
        }
```

- [ ] **Step 2: Replace `ToolbarDeviceBadge` with `DeviceMenuButton`** (same place in the file; keeps the capsule chrome)

```swift
/// The device menu (D73): what the window shows, and a switch to any
/// connected device or a recent one.
private struct DeviceMenuButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var sessions: [Session] = []

    private var viewed: Session? { sessions.first { $0.id == env.viewingSessionId } }
    private var sections: (connected: [Session], recent: [Session]) {
        DeviceMenu.sections(sessions: sessions, live: env.live.sessionIds)
    }
    private var selection: Binding<Int64?> {
        Binding(get: { env.viewingSessionId }, set: { env.viewingSessionId = $0 })
    }

    var body: some View {
        Group {
            if !sessions.isEmpty {
                Menu {
                    Section("Connected") {
                        if sections.connected.isEmpty {
                            Text("No device connected")
                        } else {
                            Picker("Connected", selection: selection) {
                                ForEach(sections.connected) { s in
                                    Text(Self.title(s) + Self.detail(s)).tag(Optional(s.id))
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                    if !sections.recent.isEmpty {
                        Section("Recent") {
                            Picker("Recent", selection: selection) {
                                ForEach(sections.recent) { s in
                                    Text(Self.title(s) + Self.ended(s)).tag(Optional(s.id))
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                    Divider()
                    Button("All Sessions…") { env.selectedTab = .sessions }
                } label: {
                    label
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(viewed.map(Self.fingerprint) ?? "Choose a device")
                .contextMenu {
                    if let viewed {
                        Button("Copy device fingerprint") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.fingerprint(viewed), forType: .string)
                            toasts.success("Copied device fingerprint")
                        }
                    }
                }
            }
        }
        .task {
            sessions = (try? await env.store.sessions()) ?? []
            for await change in await env.store.changes() {
                switch change {
                case .sessionStarted, .sessionEnded, .sessionDeleted, .sessionUpdated, .sessionsCleared:
                    sessions = (try? await env.store.sessions()) ?? []
                default:
                    break
                }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if env.isLive(env.viewingSessionId) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                    }
                    Text(viewed.map(Self.title) ?? "No device")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Text(viewed.map(Self.subtitle) ?? "\(env.live.sessionIds.count) connected")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(.controlBackgroundColor)))
        .contentShape(Capsule())
    }

    static func title(_ s: Session) -> String {
        s.appName ?? s.clientLabel ?? (s.source == .imported ? "Imported #\(s.id)" : "Device #\(s.id)")
    }

    /// `<version> · <device> · <OS> <ver>`, each piece skipped if missing.
    static func subtitle(_ s: Session) -> String {
        var parts: [String] = []
        if let v = s.appVersion { parts.append(v) }
        if let d = s.deviceModel { parts.append(d) }
        if let os = s.osVersion { parts.append((s.platform ?? "OS") + " " + os) }
        return parts.joined(separator: " · ")
    }

    static func detail(_ s: Session) -> String {
        let sub = subtitle(s)
        return sub.isEmpty ? "" : " — " + sub
    }

    static func ended(_ s: Session) -> String {
        s.endedAt.map { " — ended " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }

    static func fingerprint(_ s: Session) -> String {
        var parts: [String] = []
        if let n = s.appName { parts.append(n + (s.appVersion.map { " \($0)" } ?? "")) }
        if let d = s.deviceModel { parts.append(d) }
        if let os = s.osVersion { parts.append((s.platform ?? "OS") + " " + os) }
        return parts.joined(separator: " · ")
    }
}
```

`StoragesViewModel.appContext`, `appContext(in:)` and the `AppContext` type were used only by the old badge: delete them (`grep -rn "appContext\|AppContext" Beaver` must print nothing afterwards).

- [ ] **Step 3: Pill shows the device count** (`ConnectionIndicator.label`)

```swift
        case .clientConnected(let count): count > 1 ? "Connected · \(count)" : "Connected"
```

- [ ] **Step 4: Build**

Run: `make build` — expect success. Run: `swift test` — expect all pass.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Features/MainWindow.swift Beaver/Features/Storages/StoragesViewModel.swift
git commit -m "feat: switch between connected devices from the toolbar

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Docs, agent instructions, changelog

**Files:**
- Modify: `DECISIONS.md`, `ARCHITECTURE.md`, `Beaver/Resources/MCP.md`, `Beaver/MCP/MCPServer.swift`, `CHANGELOG.md`

- [ ] **Step 1: `DECISIONS.md`**

In D2 change `**Status:** Accepted (2026-05-15)` to `**Status:** Superseded by D73 (2026-09-28)`. In D65 append a line: `- **Done:** D73 lifted D2; the tool API stayed as is.` Append at the end:

```markdown
---

## D73. Several devices at once

**Status:** Accepted (2026-09-28). Spec: plans/2026-09-28-multi-device-design.md.

- **Decision:** the WebSocket listener keeps every connection; each gets its
  own live session. The live session id is the device's identity: the
  toolbar device menu sets `viewingSessionId`, commands go to the viewed
  session's connection, and MCP's `deviceId` is that id as a string.
- **Why:** the user debugs several apps side by side, like zapp-support's
  emitter switcher. The session was already the unit of viewing, so no second
  "selected device" state.
- **A new device** takes the window only when the viewed session isn't live.
- **Following a restart (D66)** with several devices: same fingerprint (app,
  model, platform), else the one session that just came up. Two identical
  builds look alike until the SDK sends a device id.
- **Alternatives:** a separate selected-device state (two states to sync); a
  merged feed (rejected in D2).
```

- [ ] **Step 2: `ARCHITECTURE.md`**

Line ~76: `accept(client) (single-client policy from D2)` → `accept(clients) (several at once, D73)`. Replace the paragraph starting `**Single-client policy (D2).**` with:

```markdown
**Several clients (D73).** `WSServer` keeps `[UUID: NWConnection]` and tags
every `Inbound` item with the connection's id. `AppEnvironment.live`
(`LiveDevices`) maps each connection to its live session; frames are written
there, and `AppEnvironment.send(command:to:)` routes a command to the
connection of a session. The toolbar device menu switches `viewingSessionId`.
```

- [ ] **Step 3: `MCPServer.instructions`**

Replace the opening sentence `Beaver is a macOS log viewer. One mobile app connects to it over WebSocket, and Beaver \` with:

```swift
        Beaver is a macOS log viewer. Mobile apps connect to it over WebSocket, several at once, and Beaver \
```

and after the `Start with beaver_status.` sentence insert:

```swift
        With more than one device connected, pass deviceId (from beaver_status) to commands_send, \
        commands_list and storage changes. \
```

- [ ] **Step 4: `Beaver/Resources/MCP.md`**

- In the Tools table, the `beaver_status` row: say `devices` lists every connected app, each `id` usable as `deviceId`; `commands_list` row: add the `deviceId` argument.
- Add a recipe (next to the existing command recipes):

```markdown
### Two apps connected at once

1. `beaver_status()` — `devices` lists both, e.g. `"12"` (Alpha on iPhone) and `"14"` (Beta on Pixel).
2. `commands_list(deviceId: "14")` — Beta's commands.
3. `commands_send(deviceId: "14", command: "<command>", collectLogsMs: 5000)`.
4. `logs_query(sessionId: 12, since: "5m")` — reads take a sessionId; a device's live session id is its deviceId.
```

- In "Testing without Xcode" add a step: `Connect two apps (two simulators, or a simulator and a phone): both appear in the toolbar device menu, and beaver_status lists both.`

- [ ] **Step 5: `CHANGELOG.md` `[Unreleased]`**

Add above `### Fixed`:

```markdown
### Added
- Several devices can be connected at once. The device menu on the left of
  the toolbar switches between them and shows recent sessions; a device that
  connects doesn't take the window while you're looking at another live one.
- Agents: `beaver_status` lists every connected device; with more than one,
  `commands_send`, `commands_list` and storage changes take `deviceId`.
```

- [ ] **Step 6: Drift tests**

Run: `swift test --filter MCPDocTests` — expect pass (no tool was added or removed). Then `swift test` — all pass.

- [ ] **Step 7: Commit**

```bash
git add DECISIONS.md ARCHITECTURE.md Beaver/Resources/MCP.md Beaver/MCP/MCPServer.swift CHANGELOG.md
git commit -m "feat: document several devices at once (D73)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: End-to-end check with two fake devices

**Files:** none in the repo — the client script lives in the session scratchpad.

- [ ] **Step 1: Write a fake device** (`<scratchpad>/fake-device.mjs`, Node 22 has `WebSocket` built in)

```js
// usage: node fake-device.mjs <AppName> <Model>
const [app, model] = process.argv.slice(2);
const ws = new WebSocket("ws://127.0.0.1:9080");
ws.onopen = () => {
  ws.send(JSON.stringify({ type: "storage", data: { session: { "applicaster.v2": { app_name: app, version_name: "1.0", device_model: model, platform: "iOS", os_version: "18.0" } } } }));
  setInterval(() => ws.send(JSON.stringify({ type: "event", level: 2, subsystem: app, category: "tick", message: `${app} tick ${Date.now()}` })), 1000);
};
ws.onmessage = (m) => console.log(app, "got", String(m.data).slice(0, 120));
```

Before running, check the real frame shapes in `PROTOCOL.md` (§ event and storage frames) and adjust the two `JSON.stringify` payloads to match exactly.

- [ ] **Step 2: Run Beaver and both devices**

Launch the built app (`make build`, then open the product it reports). Start the two clients in the background, capturing PIDs, and stop them at the end:

```bash
node <scratchpad>/fake-device.mjs Alpha iPhone & A=$!
node <scratchpad>/fake-device.mjs Beta Pixel & B=$!
trap 'kill $A $B' EXIT
```

- [ ] **Step 3: Verify, with screenshots of the toolbar**

- The pill reads `Connected · 2`; the device menu lists Alpha and Beta under *Connected*; the window stayed on Alpha when Beta connected.
- Choosing Beta shows only `Beta tick` events; sending `cmdlist` from the command bar is printed by the Beta client only.
- MCP: `curl -s -X POST http://127.0.0.1:9081/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"beaver_status","arguments":{}}}'` lists two devices; `commands_send` without `deviceId` returns the error listing both.
- `kill $A`: Alpha moves to *Recent*, the pill reads `Connected`, Beta keeps streaming.

- [ ] **Step 4: Clean up**

`kill $B` (if still running), then `pgrep -f fake-device.mjs` — expect no output; if anything is left, kill it and say so.
