# Device toolboxes over MCP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents reach the toolboxes of every app connected to Beaver through three gateway MCP tools (Beaver itself is device `"beaver"`), can pick a default device that survives restarts, and people see the app, a Disconnect button, the default toggle and the toolboxes in a popover on the device badge.

**Architecture:** The SDK already speaks MCP (JSON-RPC 2.0) over the log WebSocket in a `{"type":"mcp","payload":…}` envelope and sends a client `handshake` with a stable `deviceId`. Beaver adds a per-connection `DeviceMCPClient` actor (id correlation, timeouts, lazy `initialize`), stores the handshake on the session (`device_uid`, `app_package`), resolves a default device by uid, and exposes `devices_set_default` / `toolboxes_list` / `tools_call`. The UI reuses the same core pieces (`ToolboxLoad`, `DefaultDevice`).

**Tech Stack:** Swift 6, SwiftUI (macOS 26), GRDB 7, Swift Testing, Network.framework.

**Spec:** `plans/2026-09-28-device-toolboxes-design.md` (read it first; decisions D74–D76).

## Global Constraints

- Tests: `swift test` (Swift Testing, `BeaverTests/`). `Beaver/Features/`, `BeaverApp.swift`, `AppEnvironment.swift` are **not** in the SPM target — logic that needs a test goes in core (`Beaver/Domain`, `Beaver/Transport`, `Beaver/MCP`, `Beaver/Store`). App-target code is checked with `make build`.
- The Xcode project uses synchronized folders: a new `.swift` file under `Beaver/` is picked up without editing `project.pbxproj`.
- No new dependencies. No SDK changes. No export/import format change (`SESSION_FILE_FORMAT.md` untouched).
- MCP rules (CLAUDE.md → MCP): every tool is in `BeaverTools.all`, in `Beaver/Resources/MCP.md`'s Tools table and in at least one recipe (drift tests enforce it); descriptions start with "Use"; every result has a one-line `summary` and `Next:`; errors say what to do with an example call; tools never take focus.
- Device timeouts: `initialize` 5 s, `tools/list` 5 s, `tools/call` 20 s.
- `deviceId` for an app stays its live session id as a string (D73); `"beaver"` names Beaver.
- Commit prefix: every commit on this branch is `feat:` or `docs:`/`test:`; the merge title is `feat: device toolboxes over MCP, default device, device popover`.
- `rtk` hides comment lines in `cat`/`git diff` output: use the Read tool or `rtk proxy cat` before editing a block that has comments.

## Review Focus

- A device answers `tools/call` **after** Beaver's 20 s timeout — the late reply must be ignored, not crash or resume a finished call (test in Task 4).
- The device disconnects while the popover is loading toolboxes — the popover must show "disconnected", not spin forever (test in Task 6, `ToolboxLoad`).
- A weak agent passes `tools_call(arguments: "{\"key\":\"x\"}")` as a JSON **string** — Beaver must parse it and send an object (test in Task 7).
- The user deletes the live session of the default device — the replacement session must get the same `device_uid`, so the default still resolves (test in Task 1, `LiveDevices` keeps the handshake).
- An app with an empty `tools/list` or a dotless tool name — "no toolboxes" / toolbox `other`, never an empty summary (tests in Tasks 3 and 7).

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `Beaver/Domain/ClientHandshake.swift` | create | The client handshake value (D76) |
| `Beaver/Transport/ProtocolDecoder.swift` | modify | Decode `handshake` and `mcp` frames |
| `Beaver/Store/Schema.swift` | modify | Migration `v10_device_identity` |
| `Beaver/Domain/Session.swift` | modify | `deviceUID`, `appPackage` |
| `Beaver/Store/LogStore.swift` | modify | Read/write the new columns; `applyHandshake` |
| `Beaver/Domain/LiveDevices.swift` | modify | Keep each connection's handshake |
| `Beaver/BeaverApp.swift` | modify | Wire handshake, `mcp` frames, clients |
| `Beaver/MCP/DeviceWait.swift` | modify | Follow a restart by `device_uid` |
| `Beaver/Domain/Toolbox.swift` | create | `DeviceTool`, `ToolParameter`, `Toolbox`, `Toolboxes`, `ToolboxLoad` |
| `Beaver/Transport/DeviceMCPClient.swift` | create | JSON-RPC to one app over its socket |
| `Beaver/Transport/WSServer.swift` | modify | `send(data:to:)` |
| `Beaver/MCP/ToolContext.swift` | modify | `DeviceLink.mcp`, `AgentUI.setDefaultDevice`, `HostSnapshot.defaultDevice` |
| `Beaver/AppEnvironment.swift` | modify | `mcpClients`, `defaultDevice`, `DeviceLink.mcp` |
| `Beaver/Features/AgentActivity/AppEnvironment+AgentUI.swift` | modify | Snapshot + `setDefaultDevice` |
| `Beaver/Domain/DefaultDevice.swift` | create | The default device and how it resolves (D75) |
| `Beaver/MCP/Tools/ToolboxTools.swift` | create | `devices_set_default`, `toolboxes_list`, `tools_call` |
| `Beaver/MCP/Tools/StatusTools.swift` | modify | `default`, `uid`, `appPackage`, `beaver.deviceId` |
| `Beaver/MCP/MCPTool.swift` | modify | `ToolSchema.deviceId` text |
| `Beaver/MCP/MCPServer.swift` | modify | `instructions` |
| `Beaver/MCP/BeaverTools.swift` | modify | Register `ToolboxTools.all` |
| `Beaver/Resources/MCP.md` | modify | Tools rows, recipe, Testing without Xcode |
| `Beaver/Features/Devices/DevicePopover.swift` | create | The popover |
| `Beaver/Features/MainWindow.swift` | modify | Badge opens the popover; default label in the device menu |
| `BeaverTests/MCPTestSupport.swift` | modify | `FakeDevice.mcp`, `FakeUI.setDefaultDevice` |
| `BeaverTests/ClientHandshakeTests.swift` | create | Decoder + store + LiveDevices |
| `BeaverTests/DeviceMCPClientTests.swift` | create | The client |
| `BeaverTests/ToolboxTests.swift` | create | Grouping, parameters, `ToolboxLoad` |
| `BeaverTests/DefaultDeviceTests.swift` | create | Resolution in `requireDevice` |
| `BeaverTests/ToolboxToolsTests.swift` | create | The three tools, `beaver_status` |
| `BeaverTests/FollowDeviceTests.swift` | modify | Follow by uid |
| `PROTOCOL.md`, `DECISIONS.md`, `ARCHITECTURE.md`, `CHANGELOG.md` | modify | Docs |

---

### Task 1: Read the client handshake and keep it on the session (D76)

**Files:**
- Create: `Beaver/Domain/ClientHandshake.swift`
- Modify: `Beaver/Transport/ProtocolDecoder.swift` (`InboundPacket`, `decode`)
- Modify: `Beaver/Store/Schema.swift` (after `v9_agent_activity`)
- Modify: `Beaver/Domain/Session.swift`
- Modify: `Beaver/Store/LogStore.swift` (`setSessionDeviceInfo` ~line 210, `sessionColumns` ~1261, `makeSession` ~1285)
- Modify: `Beaver/Domain/LiveDevices.swift`
- Modify: `Beaver/BeaverApp.swift` (`handleInbound` ~251, `replaceDeletedLiveSessions` ~307)
- Test: `BeaverTests/ClientHandshakeTests.swift`

**Interfaces:**
- Produces: `public struct ClientHandshake: Sendable, Equatable { deviceId, deviceName, model, platform, appPackage, version: String?; var platformParts: (name: String?, version: String?) }`
- Produces: `ProtocolDecoder.InboundPacket.clientHandshake(ClientHandshake)`
- Produces: `Session.deviceUID: String?`, `Session.appPackage: String?` (init params with default `nil`, after `osVersion`)
- Produces: `LogStore.setSessionDeviceInfo(id:appName:appVersion:deviceModel:platform:osVersion:deviceUID: String? = nil, appPackage: String? = nil)`
- Produces: `LogStore.applyHandshake(_ h: ClientHandshake, to sessionId: Int64) async throws`
- Produces: `LiveDevices.setHandshake(_:for:)`, `LiveDevices.handshake(for:) -> ClientHandshake?`

- [ ] **Step 1: Write the failing tests**

`BeaverTests/ClientHandshakeTests.swift`:

```swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Client handshake (D76)")
struct ClientHandshakeTests {

    private func frame(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test("The SDK's handshake is decoded with every field")
    func decodesAllFields() throws {
        let data = try frame(["type": "handshake", "deviceId": "8F2C-A", "deviceName": "Apple iPhone15,2",
                              "model": "iPhone15,2", "platform": "iOS 18.6",
                              "appPackage": "com.example.app", "version": "11.0.1"])
        guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(data) else {
            Issue.record("expected .clientHandshake"); return
        }
        #expect(h.deviceId == "8F2C-A")
        #expect(h.model == "iPhone15,2")
        #expect(h.appPackage == "com.example.app")
        #expect(h.version == "11.0.1")
        #expect(h.platformParts.name == "iOS")
        #expect(h.platformParts.version == "18.6")
    }

    @Test("A handshake with no fields, empty strings or extra keys still decodes")
    func decodesSparse() throws {
        let data = try frame(["type": "handshake", "deviceId": "", "somethingNew": 1])
        guard case .success(.clientHandshake(let h)) = ProtocolDecoder.decode(data) else {
            Issue.record("expected .clientHandshake"); return
        }
        #expect(h == ClientHandshake())
        #expect(h.platformParts.name == nil)
    }

    @Test("A platform without a version keeps the name")
    func platformWithoutVersion() {
        #expect(ClientHandshake(platform: "tvOS").platformParts.name == "tvOS")
        #expect(ClientHandshake(platform: "tvOS").platformParts.version == nil)
    }

    @Test("The handshake fills the session; applicaster.v2, arriving later, wins where it has a value")
    func storeKeepsHarvestFirst() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await store.applyHandshake(ClientHandshake(deviceId: "UID-1", model: "iPhone15,2", platform: "iOS 18.6",
                                                       appPackage: "com.example.app", version: "11.0.1"), to: s.id)
        try await store.recordStorageSnapshot(
            sessionId: s.id, namespace: .session,
            dataJSON: #"{"applicaster.v2":{"app_name":"Miami Heat","deviceModel":"iPhone 15 Pro"}}"#)
        let row = try #require(try await store.sessions().first { $0.id == s.id })
        #expect(row.deviceUID == "UID-1")
        #expect(row.appPackage == "com.example.app")
        #expect(row.appName == "Miami Heat")
        #expect(row.deviceModel == "iPhone 15 Pro")
        #expect(row.appVersion == "11.0.1")
        #expect(row.platform == "iOS")
        #expect(row.osVersion == "18.6")
    }

    @Test("Review focus: LiveDevices keeps a connection's handshake across a deleted session, drops it on disconnect")
    func liveDevicesKeepHandshake() {
        var live = LiveDevices()
        let c = UUID()
        _ = live.connect(c, session: 1, viewing: nil)
        live.setHandshake(ClientHandshake(deviceId: "UID-1"), for: c)
        _ = live.detach { $0 == 1 }
        #expect(live.handshake(for: c)?.deviceId == "UID-1")
        _ = live.attach(c, session: 2)
        #expect(live.handshake(for: c)?.deviceId == "UID-1")
        live.disconnect(c)
        #expect(live.handshake(for: c) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClientHandshakeTests`
Expected: compile errors — `ClientHandshake`, `.clientHandshake`, `applyHandshake`, `deviceUID`, `setHandshake` don't exist.

- [ ] **Step 3: Create `ClientHandshake`**

`Beaver/Domain/ClientHandshake.swift`:

```swift
//
//  ClientHandshake.swift
//  Beaver
//
//  D76: the handshake the SDK sends right after the socket opens
//  (PROTOCOL.md §4.4). `deviceId` is stable per installation, so it
//  identifies a device across reconnects.

import Foundation

public struct ClientHandshake: Sendable, Equatable {
    public var deviceId: String?
    public var deviceName: String?
    public var model: String?
    /// `"iOS 18.6"`, `"Android 15"`.
    public var platform: String?
    public var appPackage: String?
    public var version: String?

    public init(deviceId: String? = nil, deviceName: String? = nil, model: String? = nil,
                platform: String? = nil, appPackage: String? = nil, version: String? = nil) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.model = model
        self.platform = platform; self.appPackage = appPackage; self.version = version
    }

    /// `"iOS 18.6"` → `("iOS", "18.6")`; `"tvOS"` → `("tvOS", nil)`.
    public var platformParts: (name: String?, version: String?) {
        guard let platform else { return (nil, nil) }
        let parts = platform.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }
}
```

- [ ] **Step 4: Decode it**

In `ProtocolDecoder.swift`, add to `InboundPacket` (after `network`):

```swift
        /// PROTOCOL.md §4.4 (D76).
        case clientHandshake(ClientHandshake)
```

In `decode(_:)`'s `switch typeRaw`, before `default:`:

```swift
        case "handshake":
            return .success(.clientHandshake(decodeHandshake(envelope: envelope)))
```

Add below `decodeNetwork`:

```swift
    // MARK: - Client handshake

    /// Every field is optional; an empty string counts as missing.
    private static func decodeHandshake(envelope: [String: Any]) -> ClientHandshake {
        func str(_ key: String) -> String? {
            (envelope[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return ClientHandshake(deviceId: str("deviceId"), deviceName: str("deviceName"), model: str("model"),
                               platform: str("platform"), appPackage: str("appPackage"), version: str("version"))
    }
```

Then find every exhaustive switch over `InboundPacket`: `grep -rn "case .success(.unknown" Beaver BeaverTests`. The only one is `BeaverApp.handleInbound`; Step 7 adds its case.

- [ ] **Step 5: Store the new columns**

`Schema.swift`, after the `v9_agent_activity` migration:

```swift
        // D76: the SDK's stable device id and bundle id, from its handshake.
        migrator.registerMigration("v10_device_identity", foreignKeyChecks: .immediate) { db in
            try db.execute(sql: """
                ALTER TABLE session ADD COLUMN device_uid TEXT;
                ALTER TABLE session ADD COLUMN app_package TEXT;
            """)
        }
```

`Session.swift`: add after `osVersion`:

```swift
    /// From the SDK's client handshake (D76): stable per installation,
    /// so it tells a device apart across reconnects. Nil for SDKs without
    /// a client handshake and for imported sessions.
    public var deviceUID: String?
    /// The app's bundle id / package name, from the same handshake.
    public var appPackage: String?
```

and extend the init: add parameters `deviceUID: String? = nil, appPackage: String? = nil` after `osVersion: String? = nil`, and assign `self.deviceUID = deviceUID; self.appPackage = appPackage`.

`LogStore.swift`:
- `setSessionDeviceInfo`: add parameters `deviceUID: String? = nil, appPackage: String? = nil` after `osVersion`; SQL gets two more lines before `WHERE`:
  ```sql
                        os_version   = COALESCE(?, os_version),
                        device_uid   = COALESCE(?, device_uid),
                        app_package  = COALESCE(?, app_package)
  ```
  (note the comma added after the `os_version` line), and `arguments: [appName, appVersion, deviceModel, platform, osVersion, deviceUID, appPackage, id]`.
- `sessionColumns`: append `, device_uid, app_package` to the second line.
- `makeSession`: pass `deviceUID: row["device_uid"], appPackage: row["app_package"]`.
- Add after `setSessionDeviceInfo`:

```swift
    /// Writes the SDK's client handshake onto a session (D76). Same
    /// COALESCE rule: the applicaster.v2 harvest, which arrives later,
    /// overwrites the model, version and platform where it has them.
    public func applyHandshake(_ h: ClientHandshake, to sessionId: Int64) async throws {
        let platform = h.platformParts
        try await setSessionDeviceInfo(id: sessionId, appName: nil, appVersion: h.version, deviceModel: h.model,
                                       platform: platform.name, osVersion: platform.version,
                                       deviceUID: h.deviceId, appPackage: h.appPackage)
    }
```

- [ ] **Step 6: Keep the handshake per connection**

`LiveDevices.swift`, add a property after `waiting`:

```swift
    /// Each connection's client handshake (D76). The SDK sends it once per
    /// connection, so a replacement session (the live one was deleted)
    /// gets it from here.
    public private(set) var handshakes: [UUID: ClientHandshake] = [:]
```

In `disconnect(_:)`, add `handshakes[connection] = nil` as the first line after `waiting.remove(connection)`. Add methods:

```swift
    public mutating func setHandshake(_ handshake: ClientHandshake, for connection: UUID) {
        handshakes[connection] = handshake
    }

    public func handshake(for connection: UUID) -> ClientHandshake? { handshakes[connection] }
```

- [ ] **Step 7: Wire it in the app**

`BeaverApp.swift`: change `handleInbound` to take the connection — signature `handleInbound(frame: Data, connection: UUID, sessionId: Int64, env: AppEnvironment)` and the call site in `.frame(let connection, let frame)` to pass `connection: connection`. Add a case before `.unknown`:

```swift
        case .success(.clientHandshake(let handshake)):
            await MainActor.run { env.live.setHandshake(handshake, for: connection) }
            try? await env.store.applyHandshake(handshake, to: sessionId)
```

In `replaceDeletedLiveSessions`, after the `guard env.live.attach(...)` block:

```swift
        if let handshake = env.live.handshake(for: connection) {
            try? await env.store.applyHandshake(handshake, to: fresh.id)
        }
```

- [ ] **Step 8: Run tests and build**

Run: `swift test --filter ClientHandshakeTests` → PASS. Then `swift test` → all PASS. Then `make build` → succeeds.

- [ ] **Step 9: Commit**

```bash
git add Beaver/Domain/ClientHandshake.swift Beaver/Transport/ProtocolDecoder.swift Beaver/Store/Schema.swift Beaver/Domain/Session.swift Beaver/Store/LogStore.swift Beaver/Domain/LiveDevices.swift Beaver/BeaverApp.swift BeaverTests/ClientHandshakeTests.swift
git commit -m "feat: read the SDK's client handshake; sessions keep device id and bundle id"
```

---

### Task 2: Follow a restart by device id

**Files:**
- Modify: `Beaver/MCP/DeviceWait.swift` (`DeviceFollower`, `successor(of:live:appeared:)` ~line 97)
- Test: `BeaverTests/FollowDeviceTests.swift`

**Interfaces:**
- Consumes: `Session.deviceUID` (Task 1)
- Produces: unchanged signature `DeviceFollower.successor(of: Session, live: [Session], appeared: Set<Int64>) -> Int64?`

- [ ] **Step 1: Write the failing tests** (append inside the `FollowDeviceTests` suite)

```swift
    private func twin(_ id: Int64, uid: String?) -> Session {
        Session(id: id, startedAt: .distantPast, source: .live, appName: "Alpha",
                deviceModel: "iPhone 15", platform: "iOS", deviceUID: uid)
    }

    @Test("successor: identical builds are told apart by device id")
    func successorByUID() {
        let ended = twin(1, uid: "A")
        #expect(DeviceFollower.successor(of: ended, live: [twin(5, uid: "B"), twin(4, uid: "A")],
                                         appeared: [4, 5]) == 4)
    }

    @Test("successor: a known different device id is never followed, even with the same fingerprint")
    func successorRejectsOtherUID() {
        #expect(DeviceFollower.successor(of: twin(1, uid: "A"), live: [twin(4, uid: "B")], appeared: [4]) == nil)
    }

    @Test("successor: without device ids the fingerprint rule still applies")
    func successorFallsBack() {
        #expect(DeviceFollower.successor(of: twin(1, uid: nil), live: [twin(4, uid: nil)], appeared: [4]) == 4)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FollowDeviceTests`
Expected: `successorByUID` FAILS (returns 5, the newest same fingerprint); `successorRejectsOtherUID` FAILS (returns 4).

- [ ] **Step 3: Implement**

Replace the first line of `successor` (`let newer = live.filter { $0.id > ended.id }`) with:

```swift
        // D76: a known device id decides; a different known one is another device.
        let newer = live.filter {
            $0.id > ended.id && (ended.deviceUID == nil || $0.deviceUID == nil || $0.deviceUID == ended.deviceUID)
        }
        if let uid = ended.deviceUID, let same = newer.filter({ $0.deviceUID == uid }).map(\.id).max() {
            return same
        }
```

Update the `DeviceFollower` doc comment's `ponytail:` lines to:

```swift
// ponytail: the fingerprint heuristic is now the fallback for SDKs without a
// client handshake (D76). A session whose handshake lands after the 250 ms
// poll that sees it appear is judged by fingerprint on that poll.
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter FollowDeviceTests` → PASS; `swift test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Beaver/MCP/DeviceWait.swift BeaverTests/FollowDeviceTests.swift
git commit -m "feat: follow an app across a restart by its device id"
```

---

### Task 3: Toolbox model

**Files:**
- Create: `Beaver/Domain/Toolbox.swift`
- Test: `BeaverTests/ToolboxTests.swift`

**Interfaces:**
- Produces:
  - `public struct DeviceTool: Sendable, Equatable { name: String; description: String; inputSchema: JSON; var parameters: [ToolParameter]; var signature: String; var exampleArguments: String }`
  - `public struct ToolParameter: Sendable, Equatable { name, type: String; required: Bool; description: String; enumValues: [String]; var line: String }`
  - `public struct Toolbox: Sendable, Equatable { name: String; tools: [DeviceTool] }`
  - `public enum Toolboxes { static let otherName = "other"; static func name(of: String) -> String; static func group(_: [DeviceTool]) -> [Toolbox]; static func tools(fromListResult: JSON) -> [DeviceTool]; static func beaverName(_: String) -> String; static func beaverToolName(_: String) -> String }`

- [ ] **Step 1: Write the failing tests**

`BeaverTests/ToolboxTests.swift`:

```swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Toolboxes (D74)")
struct ToolboxTests {

    static let list: JSON = ["tools": [
        ["name": "storage.set", "description": "Set a key",
         "inputSchema": ["type": "object",
                         "properties": ["value": ["type": "string"],
                                        "key": ["type": "string", "description": "The key"],
                                        "namespace": ["type": "string"],
                                        "layer": ["type": "string", "enum": ["session", "local"]]],
                         "required": ["key", "value"]]],
        ["name": "app.restart", "description": "Restart", "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "ping"],
        ["description": "no name"],
    ]]

    @Test("tools/list becomes tools; an entry without a name is skipped")
    func parse() {
        let tools = Toolboxes.tools(fromListResult: Self.list)
        #expect(tools.map(\.name) == ["storage.set", "app.restart", "ping"])
        #expect(tools[2].description == "")
    }

    @Test("Review focus: grouped by prefix, sorted; a dotless name goes to other; nothing gives nothing")
    func group() {
        let boxes = Toolboxes.group(Toolboxes.tools(fromListResult: Self.list))
        #expect(boxes.map(\.name) == ["app", "other", "storage"])
        #expect(Toolboxes.group([]).isEmpty)
        #expect(Toolboxes.name(of: ".odd") == "other")
    }

    @Test("Parameters: required first, then by name; one line each")
    func parameters() throws {
        let set = try #require(Toolboxes.tools(fromListResult: Self.list).first)
        #expect(set.parameters.map(\.name) == ["key", "value", "layer", "namespace"])
        #expect(set.parameters[0].line == "key: string (required) — The key")
        #expect(set.parameters[2].line == "layer: string, one of session|local")
        #expect(set.signature == "storage.set(key: string, value: string, layer?: string, namespace?: string)")
        #expect(set.exampleArguments == "{key: …, value: …}")
    }

    @Test("Beaver's own tools: first _ becomes . and back")
    func beaverNames() {
        #expect(Toolboxes.beaverName("logs_query") == "logs.query")
        #expect(Toolboxes.beaverName("devices_set_default") == "devices.set_default")
        #expect(Toolboxes.beaverToolName("devices.set_default") == "devices_set_default")
        #expect(Toolboxes.beaverToolName("status") == "status")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ToolboxTests` → compile error, `Toolboxes` undefined.

- [ ] **Step 3: Implement**

`Beaver/Domain/Toolbox.swift`:

```swift
//
//  Toolbox.swift
//  Beaver
//
//  D74: a connected app's tools, from its MCP `tools/list`, grouped into
//  toolboxes by the name's prefix (`storage.set` → `storage`). Beaver's
//  own tools are device "beaver", its toolboxes named the same way
//  (`logs_query` → `logs.query`).

import Foundation

public struct ToolParameter: Sendable, Equatable {
    public let name: String
    public let type: String
    public let required: Bool
    public let description: String
    public let enumValues: [String]

    /// `key: string (required) — The key`, `layer: string, one of a|b`.
    public var line: String {
        var s = "\(name): \(type)"
        if required { s += " (required)" }
        if !enumValues.isEmpty { s += ", one of " + enumValues.joined(separator: "|") }
        if !description.isEmpty { s += " — " + description }
        return s
    }
}

public struct DeviceTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSON

    public init(name: String, description: String, inputSchema: JSON) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }

    /// From `inputSchema.properties`: required first, then by name.
    public var parameters: [ToolParameter] {
        let props = inputSchema["properties"]?.object ?? [:]
        let required = Set(inputSchema["required"]?.array?.compactMap(\.string) ?? [])
        func rank(_ key: String) -> (Int, String) { (required.contains(key) ? 0 : 1, key) }
        return props.keys.sorted { rank($0) < rank($1) }.map { key in
            let p = props[key] ?? .null
            return ToolParameter(name: key, type: p["type"]?.string ?? "any", required: required.contains(key),
                                 description: p["description"]?.string ?? "",
                                 enumValues: p["enum"]?.array?.compactMap(\.string) ?? [])
        }
    }

    /// `storage.set(key: string, value: string, namespace?: string)`.
    public var signature: String {
        name + "(" + parameters.map { $0.name + ($0.required ? "" : "?") + ": " + $0.type }
            .joined(separator: ", ") + ")"
    }

    /// `{key: …, value: …}`, the required arguments, for a `Next:` line.
    public var exampleArguments: String {
        "{" + parameters.filter(\.required).map { "\($0.name): …" }.joined(separator: ", ") + "}"
    }
}

public struct Toolbox: Sendable, Equatable {
    public let name: String
    public let tools: [DeviceTool]
}

public enum Toolboxes {
    /// Where a tool name without a prefix goes.
    public static let otherName = "other"

    public static func name(of tool: String) -> String {
        guard let dot = tool.firstIndex(of: "."), dot != tool.startIndex else { return otherName }
        return String(tool[..<dot])
    }

    /// Sorted by toolbox, then by tool name.
    public static func group(_ tools: [DeviceTool]) -> [Toolbox] {
        Dictionary(grouping: tools, by: { name(of: $0.name) })
            .map { Toolbox(name: $0.key, tools: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    /// A `tools/list` result; entries without a name are skipped.
    public static func tools(fromListResult result: JSON) -> [DeviceTool] {
        (result["tools"]?.array ?? []).compactMap { entry in
            guard let name = entry["name"]?.string, !name.isEmpty else { return nil }
            return DeviceTool(name: name, description: entry["description"]?.string ?? "",
                              inputSchema: entry["inputSchema"] ?? ["type": "object"])
        }
    }

    /// `logs_query` → `logs.query`.
    public static func beaverName(_ tool: String) -> String { replacingFirst("_", with: ".", in: tool) }

    /// `logs.query` → `logs_query`.
    public static func beaverToolName(_ dotted: String) -> String { replacingFirst(".", with: "_", in: dotted) }

    private static func replacingFirst(_ a: Character, with b: Character, in s: String) -> String {
        guard let i = s.firstIndex(of: a) else { return s }
        var out = s
        out.replaceSubrange(i...i, with: String(b))
        return out
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ToolboxTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Domain/Toolbox.swift BeaverTests/ToolboxTests.swift
git commit -m "feat: toolbox model — an app's tools grouped by prefix"
```

---

### Task 4: `DeviceMCPClient` and the `mcp` frames

**Files:**
- Create: `Beaver/Transport/DeviceMCPClient.swift`
- Modify: `Beaver/Transport/ProtocolDecoder.swift` (`InboundPacket`, `DecodeError`, `decode`)
- Modify: `Beaver/Transport/WSServer.swift` (Outbound section ~line 298)
- Modify: `Beaver/MCP/ToolContext.swift` (`DeviceLink`)
- Modify: `Beaver/AppEnvironment.swift`
- Modify: `Beaver/BeaverApp.swift` (`bootstrap` inbound loop, `handleInbound`)
- Modify: `BeaverTests/MCPTestSupport.swift` (`FakeDevice`)
- Test: `BeaverTests/DeviceMCPClientTests.swift`

**Interfaces:**
- Consumes: `JSON` (`Beaver/MCP/JSON.swift`: `.object`, `.string`, `.number`, `subscript(String)`, `.int`, `JSON.parse(Data)`, `Codable`)
- Produces:
  - `public enum DeviceMCPError: Error, Sendable, Equatable { case unsupported, timeout, disconnected, rpc(code: Int, message: String) }`
  - `public actor DeviceMCPClient { static let listTimeout: Duration; static let callTimeout: Duration; init(setupTimeout: Duration = .seconds(5), send: @escaping @Sendable (Data) async -> Void); func request(_ method: String, params: JSON = [:], timeout: Duration) async throws -> JSON; func receive(_ message: JSON); func close() }`
  - `ProtocolDecoder.InboundPacket.mcp(JSON)`; `DecodeError.malformedMCP(String)`
  - `WSServer.send(data: Data, to connection: UUID)`
  - `DeviceLink.mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration) async throws -> JSON`
  - `FakeDevice(onSend:onMCP:)`, `FakeDevice.mcpCalls: [(method: String, params: JSON, sessionId: Int64)]`

- [ ] **Step 1: Write the failing tests**

`BeaverTests/DeviceMCPClientTests.swift`:

```swift
import Testing
import Foundation
import Synchronization
@testable import BeaverCore

/// The app's MCP server on the other end of the socket. `answer` returns
/// a result, `["error": …]` for a JSON-RPC error, or nil to stay silent.
final class ScriptedDevice: Sendable {
    let frames = Mutex<[JSON]>([])
    let client = Mutex<DeviceMCPClient?>(nil)
    let answer: @Sendable (String, JSON) async -> JSON?

    init(answer: @escaping @Sendable (String, JSON) async -> JSON?) { self.answer = answer }

    var methods: [String] { frames.withLock { $0.compactMap { $0["method"]?.string } } }

    func handle(_ data: Data) async {
        guard let frame = try? JSON.parse(data), frame["type"] == "mcp", let payload = frame["payload"] else { return }
        frames.withLock { $0.append(payload) }
        guard let id = payload["id"], let method = payload["method"]?.string else { return }
        let params = payload["params"] ?? .null
        Task {
            guard let result = await answer(method, params) else { return }
            let reply: JSON = if let error = result["error"] {
                ["jsonrpc": "2.0", "id": id, "error": error]
            } else {
                ["jsonrpc": "2.0", "id": id, "result": result]
            }
            await client.withLock { $0 }?.receive(reply)
        }
    }
}

@Suite("DeviceMCPClient (D74)")
struct DeviceMCPClientTests {

    private func connect(_ answer: @escaping @Sendable (String, JSON) async -> JSON?) -> (DeviceMCPClient, ScriptedDevice) {
        let device = ScriptedDevice(answer: answer)
        let client = DeviceMCPClient(setupTimeout: .milliseconds(200)) { await device.handle($0) }
        device.client.withLock { $0 = client }
        return (client, device)
    }

    private static let tools: JSON = ["tools": [["name": "app.restart"]]]

    @Test("Initializes once, then answers by id")
    func initializesOnce() async throws {
        let (client, device) = connect { method, _ in method == "tools/list" ? Self.tools : [:] }
        let first = try await client.request("tools/list", timeout: .seconds(1))
        let second = try await client.request("tools/list", timeout: .seconds(1))
        #expect(first == Self.tools)
        #expect(second == Self.tools)
        #expect(device.methods == ["initialize", "notifications/initialized", "tools/list", "tools/list"])
    }

    @Test("Concurrent requests get their own replies, even out of order")
    func outOfOrder() async throws {
        let (client, _) = connect { method, params in
            guard method == "tools/call" else { return [:] }
            if params["name"] == "slow" { try? await Task.sleep(for: .milliseconds(150)) }
            return ["echo": params["name"] ?? .null]
        }
        async let slow = client.request("tools/call", params: ["name": "slow"], timeout: .seconds(1))
        async let fast = client.request("tools/call", params: ["name": "fast"], timeout: .seconds(1))
        let (s, f) = try await (slow, fast)
        #expect(s["echo"] == "slow")
        #expect(f["echo"] == "fast")
    }

    @Test("A JSON-RPC error becomes .rpc")
    func rpcError() async {
        let (client, _) = connect { method, _ in
            method == "initialize" ? [:] : ["error": ["code": -32601, "message": "Method not found: x"]]
        }
        await #expect(throws: DeviceMCPError.rpc(code: -32601, message: "Method not found: x")) {
            try await client.request("x", timeout: .seconds(1))
        }
    }

    @Test("Review focus: a reply after the timeout is ignored")
    func lateReply() async throws {
        let (client, _) = connect { method, _ in
            if method == "tools/call" { try? await Task.sleep(for: .milliseconds(300)); return ["late": true] }
            return [:]
        }
        await #expect(throws: DeviceMCPError.timeout) {
            try await client.request("tools/call", timeout: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(400))   // the late reply lands; nothing to resume
        let next = try await client.request("ping", timeout: .seconds(1))
        #expect(next == [:])
    }

    @Test("No answer to initialize: unsupported, and later calls fail at once without sending")
    func unsupported() async {
        let (client, device) = connect { _, _ in nil }
        await #expect(throws: DeviceMCPError.unsupported) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
        let start = ContinuousClock.now
        await #expect(throws: DeviceMCPError.unsupported) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .milliseconds(100))
        #expect(device.methods == ["initialize"])
    }

    @Test("Closing fails the waiting call with .disconnected, and later ones too")
    func closeWhileWaiting() async throws {
        let (client, _) = connect { method, _ in method == "initialize" ? [:] : nil }
        _ = try? await client.request("ping", timeout: .milliseconds(50))  // initialized; ping times out
        let waiting = Task { try await client.request("tools/call", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await client.close()
        await #expect(throws: DeviceMCPError.disconnected) { try await waiting.value }
        await #expect(throws: DeviceMCPError.disconnected) {
            try await client.request("tools/list", timeout: .seconds(1))
        }
    }

    @Test("mcp frames decode, as an object, a string, or bare JSON-RPC")
    func decodesFrames() throws {
        let object = try JSONSerialization.data(withJSONObject: ["type": "mcp", "payload": ["jsonrpc": "2.0", "id": 3, "result": [:]]])
        let string = try JSONSerialization.data(withJSONObject: ["type": "mcp", "payload": #"{"jsonrpc":"2.0","id":4,"result":{}}"#])
        let bare = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 5, "result": [:]])
        for (data, id) in [(object, 3), (string, 4), (bare, 5)] {
            guard case .success(.mcp(let message)) = ProtocolDecoder.decode(data) else {
                Issue.record("expected .mcp for id \(id)"); continue
            }
            #expect(message["id"]?.int == id)
        }
        let broken = try JSONSerialization.data(withJSONObject: ["type": "mcp", "payload": 7])
        guard case .failure(.malformedMCP) = ProtocolDecoder.decode(broken) else {
            Issue.record("expected .malformedMCP"); return
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DeviceMCPClientTests` → compile errors (`DeviceMCPClient`, `.mcp`, `.malformedMCP`).

- [ ] **Step 3: Implement the client**

`Beaver/Transport/DeviceMCPClient.swift`:

```swift
//
//  DeviceMCPClient.swift
//  Beaver
//
//  D74: JSON-RPC to one connected app's MCP server over the same WebSocket
//  as its logs (PROTOCOL.md §3.3, §4.5). One per connection; the envelope
//  is {"type":"mcp","payload":…} and replies are matched by JSON-RPC id.

import Foundation

public enum DeviceMCPError: Error, Sendable, Equatable {
    /// The app never answered `initialize`: it has no toolboxes (the
    /// JS-only socket sink, an older SDK). Stays so until it reconnects.
    case unsupported
    /// No answer in time. The device may still have run the call.
    case timeout
    /// The connection closed, or was already gone.
    case disconnected
    /// The app's JSON-RPC error reply.
    case rpc(code: Int, message: String)
}

public actor DeviceMCPClient {
    public static let listTimeout: Duration = .seconds(5)
    /// The device gives up on a React tool after 15 s; this leaves it room to say so.
    public static let callTimeout: Duration = .seconds(20)

    private enum Setup { case idle, running(Task<Void, Error>), ready, unsupported }

    private let sendFrame: @Sendable (Data) async -> Void
    private let setupTimeout: Duration
    private var setup: Setup = .idle
    private var nextId = 1
    private var waiters: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var closed = false

    public init(setupTimeout: Duration = .seconds(5), send: @escaping @Sendable (Data) async -> Void) {
        self.setupTimeout = setupTimeout
        self.sendFrame = send
    }

    /// Initializes the session first, once per connection.
    public func request(_ method: String, params: JSON = [:], timeout: Duration) async throws -> JSON {
        guard !closed else { throw DeviceMCPError.disconnected }
        try await ensureInitialized()
        return try await call(method, params: params, timeout: timeout)
    }

    /// A JSON-RPC response from the app. Unknown ids (a reply after its
    /// timeout) are ignored.
    public func receive(_ message: JSON) {
        guard let id = message["id"]?.int, let waiter = waiters.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            waiter.resume(throwing: DeviceMCPError.rpc(code: error["code"]?.int ?? 0,
                                                       message: error["message"]?.string ?? "error"))
        } else {
            waiter.resume(returning: message["result"] ?? .null)
        }
    }

    /// The connection closed: every waiting call fails with `.disconnected`.
    public func close() {
        closed = true
        let pending = waiters
        waiters = [:]
        for waiter in pending.values { waiter.resume(throwing: DeviceMCPError.disconnected) }
    }

    private func ensureInitialized() async throws {
        let task: Task<Void, Error>
        switch setup {
        case .ready: return
        case .unsupported: throw DeviceMCPError.unsupported
        case .running(let running): task = running
        case .idle:
            task = Task { try await self.initialize() }
            setup = .running(task)
        }
        do {
            try await task.value
            setup = .ready
        } catch DeviceMCPError.disconnected {
            throw DeviceMCPError.disconnected
        } catch {
            setup = .unsupported
            throw DeviceMCPError.unsupported
        }
    }

    private func initialize() async throws {
        _ = try await call("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Beaver", "version": "1"],
        ], timeout: setupTimeout)
        await sendFrame(Self.frame(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    private func call(_ method: String, params: JSON, timeout: Duration) async throws -> JSON {
        guard !closed else { throw DeviceMCPError.disconnected }
        let id = nextId
        nextId += 1
        let frame = Self.frame(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.fail(id, .timeout)
        }
        defer { timer.cancel() }
        let send = sendFrame
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            Task { await send(frame) }
        }
    }

    private func fail(_ id: Int, _ error: DeviceMCPError) {
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private static func frame(_ payload: JSON) -> Data {
        let envelope: JSON = ["type": "mcp", "payload": payload]
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }
}
```

- [ ] **Step 4: Decode `mcp` frames**

`ProtocolDecoder.swift`:
- `InboundPacket`: add `case mcp(JSON)` with doc `/// A JSON-RPC message from the app's MCP server (PROTOCOL.md §4.5, D74).`
- `DecodeError`: add `case malformedMCP(String)`.
- In `decode(_:)`, replace the `guard let typeRaw = envelope["type"] as? String else { return .failure(.noTypeField) }` with:

```swift
        guard let typeRaw = envelope["type"] as? String else {
            // The SDK also accepts bare JSON-RPC; Beaver never sends it,
            // but a bare reply is still an MCP message, not an unknown frame.
            if envelope["jsonrpc"] != nil { return decodeMCP(envelope) }
            return .failure(.noTypeField)
        }
```

- In the `switch typeRaw`, before `default:`: `case "mcp": return decodeMCP(envelope["payload"])`.
- Add:

```swift
    // MARK: - MCP

    /// `payload` is a JSON-RPC object, or that object as a string.
    private static func decodeMCP(_ payload: Any?) -> Result<InboundPacket, DecodeError> {
        let data: Data? = if let s = payload as? String {
            s.data(using: .utf8)
        } else if let p = payload, JSONSerialization.isValidJSONObject(p) {
            try? JSONSerialization.data(withJSONObject: p)
        } else {
            nil
        }
        guard let data, let message = try? JSON.parse(data), message.object != nil else {
            return .failure(.malformedMCP("payload is not a JSON-RPC object"))
        }
        return .success(.mcp(message))
    }
```

- [ ] **Step 5: Raw send in `WSServer`**

In the `// MARK: - Outbound` section, after `send(command:to:)`:

```swift
    /// Send a ready-made frame (an `mcp` request, D74) to one client.
    /// No-op when that connection is gone.
    public func send(data: Data, to connection: UUID) {
        guard let target = connections[connection] else { return }
        send(data, on: target)
    }
```

- [ ] **Step 6: `DeviceLink.mcp` and the fake**

`ToolContext.swift`, in `protocol DeviceLink`:

```swift
    /// One MCP request to the app whose live session is `sessionId` (D74).
    /// Throws `DeviceMCPError`; `.disconnected` once it's gone.
    func mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration) async throws -> JSON
```

`MCPTestSupport.swift`, `FakeDevice`: replace its `init` and add the MCP half:

```swift
    private let onMCP: @Sendable (String, JSON) async throws -> JSON
    private let mcpLog = Mutex<[(method: String, params: JSON, sessionId: Int64)]>([])

    init(onSend: @escaping @Sendable (String) async -> Void = { _ in },
         onMCP: @escaping @Sendable (String, JSON) async throws -> JSON = { _, _ in throw DeviceMCPError.unsupported }) {
        self.onSend = onSend
        self.onMCP = onMCP
    }

    var mcpCalls: [(method: String, params: JSON, sessionId: Int64)] { mcpLog.withLock { $0 } }

    func mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration) async throws -> JSON {
        mcpLog.withLock { $0.append((method, params, sessionId)) }
        return try await onMCP(method, params)
    }
```

- [ ] **Step 7: Wire the clients in the app**

`AppEnvironment.swift`, add a property after `live`:

```swift
    /// Each connection's MCP client (D74). Keyed by connection, not session:
    /// a deleted live session's replacement keeps talking to the same app.
    @ObservationIgnored public var mcpClients: [UUID: DeviceMCPClient] = [:]
```

and in `extension AppEnvironment: DeviceLink`:

```swift
    nonisolated public func mcp(_ method: String, params: JSON, to sessionId: Int64,
                                timeout: Duration) async throws -> JSON {
        let client = await MainActor.run { self.live.connection(for: sessionId).flatMap { self.mcpClients[$0] } }
        guard let client else { throw DeviceMCPError.disconnected }
        return try await client.request(method, params: params, timeout: timeout)
    }
```

`BeaverApp.swift`, in the inbound loop:
- `.connected(let connection)`: as the first line
  ```swift
                    env.mcpClients[connection] = DeviceMCPClient { [server = env.server] data in
                        await server.send(data: data, to: connection)
                    }
  ```
- `.disconnected(let connection)`: as the first line
  ```swift
                    await env.mcpClients.removeValue(forKey: connection)?.close()
  ```
- `handleInbound`, before `.unknown`:
  ```swift
        case .success(.mcp(let message)):
            // D74: an answer to Beaver's request; not a log line.
            let client = await MainActor.run { env.mcpClients[connection] }
            await client?.receive(message)
  ```

- [ ] **Step 8: Run tests and build**

Run: `swift test --filter DeviceMCPClientTests` → PASS; `swift test` → PASS; `make build` → succeeds.

- [ ] **Step 9: Commit**

```bash
git add Beaver/Transport/DeviceMCPClient.swift Beaver/Transport/ProtocolDecoder.swift Beaver/Transport/WSServer.swift Beaver/MCP/ToolContext.swift Beaver/AppEnvironment.swift Beaver/BeaverApp.swift BeaverTests/MCPTestSupport.swift BeaverTests/DeviceMCPClientTests.swift
git commit -m "feat: talk MCP to each connected app over its WebSocket"
```

---

### Task 5: Default device (D75)

**Files:**
- Create: `Beaver/Domain/DefaultDevice.swift`
- Modify: `Beaver/MCP/ToolContext.swift` (`AgentUI`, `HostSnapshot`)
- Modify: `Beaver/MCP/DeviceWait.swift` (`requireDevice` ~line 190)
- Modify: `Beaver/AppEnvironment.swift`
- Modify: `Beaver/Features/AgentActivity/AppEnvironment+AgentUI.swift`
- Modify: `BeaverTests/MCPTestSupport.swift` (`FakeUI`)
- Test: `BeaverTests/DefaultDeviceTests.swift`

**Interfaces:**
- Consumes: `Session.deviceUID` (Task 1), `StatusTools.describeDevice(_ s: Session) -> String` (existing)
- Produces:
  - `public enum DefaultDevice: Sendable, Equatable { case uid(String), session(Int64); init(session: Session); func liveSession(in: [Session], live: [Int64]) -> Int64?; func matches(_: Session) -> Bool }`
  - `HostSnapshot.defaultDevice: DefaultDevice?` (init param `defaultDevice: DefaultDevice? = nil`, last)
  - `AgentUI.setDefaultDevice(_ device: DefaultDevice?) async`
  - `ToolContext.describeDefault(_: DefaultDevice) async throws -> String`
  - `AppEnvironment.defaultDevice: DefaultDevice?`, `AppEnvironment.setDefaultDeviceByUser(_:name:sessionId:)`

- [ ] **Step 1: Write the failing tests**

`BeaverTests/DefaultDeviceTests.swift`:

```swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Default device (D75)")
struct DefaultDeviceTests {

    /// Alpha (uid A) and Beta (uid B), both live.
    private func twoDevices(default device: DefaultDevice?) async throws -> (LogStore, Session, Session, ToolContext) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        let b = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: "1.0", deviceModel: "iPhone 15",
                                             platform: "iOS", osVersion: "18.0", deviceUID: "A")
        try await store.setSessionDeviceInfo(id: b.id, appName: "Beta", appVersion: "2.0", deviceModel: "Pixel 8",
                                             platform: "Android", osVersion: "15", deviceUID: "B")
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [a.id, b.id], defaultDevice: device))
        return (store, a, b, ctx)
    }

    private let call = "commands_send(command: \"cmdlist\")"

    @Test("Without deviceId, the default is used")
    func usesDefault() async throws {
        let (_, _, b, ctx) = try await twoDevices(default: .uid("B"))
        let (_, id) = try await ctx.requireDevice(ToolArguments(), doing: "send a command", call: call)
        #expect(id == b.id)
    }

    @Test("An explicit deviceId beats the default")
    func explicitWins() async throws {
        let (_, a, _, ctx) = try await twoDevices(default: .uid("B"))
        let (_, id) = try await ctx.requireDevice(ToolArguments(["deviceId": JSON(a.id)]), doing: "send", call: call)
        #expect(id == a.id)
    }

    @Test("A default by device id follows the app into its new session")
    func followsRestart() async throws {
        let store = try LogStore(source: .inMemory)
        let old = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: old.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                             platform: nil, osVersion: nil, deviceUID: "A")
        try await store.endSession(old.id)
        let new = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: new.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                             platform: nil, osVersion: nil, deviceUID: "A")
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [new.id], defaultDevice: .uid("A")))
        let (_, id) = try await ctx.requireDevice(ToolArguments(), doing: "send", call: call)
        #expect(id == new.id)
    }

    @Test("A default that isn't connected fails, naming it — never another device")
    func defaultGone() async throws {
        let store = try LogStore(source: .inMemory)
        let gone = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: gone.id, appName: "Alpha", appVersion: nil, deviceModel: nil,
                                             platform: nil, osVersion: nil, deviceUID: "A")
        let other = try await store.createSession(source: .live)
        let ctx = makeContext(store, ui: HostSnapshot(liveSessionIds: [other.id], defaultDevice: .uid("A")))
        do {
            _ = try await ctx.requireDevice(ToolArguments(), doing: "send a command", call: call)
            Issue.record("expected a ToolError")
        } catch let error as ToolError {
            #expect(error.message.contains("default device Alpha"))
            #expect(error.message.contains("devices_set_default(deviceId: null)"))
            #expect(error.message.contains("commands_send(deviceId: \"\(other.id)\""))
        }
    }

    @Test("A session default (no handshake) resolves only while that session is live")
    func sessionDefault() {
        let s = Session(id: 7, startedAt: .distantPast, source: .live)
        #expect(DefaultDevice(session: s) == .session(7))
        #expect(DefaultDevice.session(7).liveSession(in: [s], live: [7]) == 7)
        #expect(DefaultDevice.session(7).liveSession(in: [s], live: [8]) == nil)
        #expect(DefaultDevice(session: Session(id: 8, startedAt: .distantPast, source: .live, deviceUID: "U")) == .uid("U"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DefaultDeviceTests` → compile errors (`DefaultDevice`, `defaultDevice:`).

- [ ] **Step 3: Implement `DefaultDevice`**

`Beaver/Domain/DefaultDevice.swift`:

```swift
//
//  DefaultDevice.swift
//  Beaver
//
//  D75: the app agents' device tools use when a call names no device.
//  One for all of Beaver, in memory. Kept by the SDK's device id so it
//  survives the app restarting (a new live session each time).

import Foundation

public enum DefaultDevice: Sendable, Equatable {
    /// The SDK's handshake `deviceId` (D76).
    case uid(String)
    /// An app that sent no handshake: only this live session, lost on reconnect.
    case session(Int64)

    public init(session: Session) {
        self = session.deviceUID.map(DefaultDevice.uid) ?? .session(session.id)
    }

    /// Its live session now; the newest if one uid has several.
    public func liveSession(in sessions: [Session], live: [Int64]) -> Int64? {
        switch self {
        case .session(let id): live.contains(id) ? id : nil
        case .uid(let uid): sessions.filter { live.contains($0.id) && $0.deviceUID == uid }.map(\.id).max()
        }
    }

    public func matches(_ session: Session) -> Bool {
        switch self {
        case .session(let id): session.id == id
        case .uid(let uid): session.deviceUID == uid
        }
    }
}
```

- [ ] **Step 4: Carry it through `HostSnapshot` and `AgentUI`**

`ToolContext.swift`:
- `AgentUI`: add
  ```swift
      /// Sets or clears the default device (D75). Doesn't change the window.
      func setDefaultDevice(_ device: DefaultDevice?) async
  ```
- `HostSnapshot`: add `public var defaultDevice: DefaultDevice?` (doc: `/// The agents' default device (D75), if set.`), an init parameter `defaultDevice: DefaultDevice? = nil` after `notifications`, and `self.defaultDevice = defaultDevice`.

`MCPTestSupport.swift`, `FakeUI`: add

```swift
    func setDefaultDevice(_ device: DefaultDevice?) async { state.withLock { $0.defaultDevice = device } }
```

`AppEnvironment.swift`, after `mcpClients`:

```swift
    /// The device agents' device tools use without a deviceId (D75).
    /// In memory until Beaver quits.
    public var defaultDevice: DefaultDevice?

    /// The device popover's toggle: set it, and say so in the Agent panel.
    public func setDefaultDeviceByUser(_ device: DefaultDevice?, name: String, sessionId: Int64) {
        defaultDevice = device
        let text = device == nil ? "You cleared the default device for agents"
                                 : "You made \(name) the default device for agents"
        Task { await AgentJournal(store: store).post(.system, text, sessionId: sessionId) }
    }
```

`AppEnvironment+AgentUI.swift`: in `snapshot()` pass `defaultDevice: defaultDevice` to `HostSnapshot(...)` (last argument); add

```swift
    nonisolated public func setDefaultDevice(_ device: DefaultDevice?) async {
        await MainActor.run { defaultDevice = device }
    }
```

- [ ] **Step 5: Resolve it in `requireDevice`**

In `DeviceWait.swift`, replace the line
`if wanted == nil || wanted == "current", live.count == 1 { return (host, live[0]) }` with:

```swift
        if wanted == nil || wanted == "current" {
            // D75: the default, when set, is the only fallback — never another device.
            if let preferred = host.defaultDevice {
                if let id = preferred.liveSession(in: try await store.sessions(), live: live) { return (host, id) }
                let list = try await describeDevices(live)
                throw ToolError("The default device \(try await describeDefault(preferred)) isn't connected. "
                    + "Connected: \(list). Example: \(Self.withDeviceId(call, live[0])), "
                    + "or devices_set_default(deviceId: null) to clear the default.")
            }
            if live.count == 1 { return (host, live[0]) }
        }
```

Update the doc comment above `requireDevice` to: `/// … With one device it may be omitted (or be "current", as before D73); with a default set (D75) an omitted one means the default; otherwise with several it may not. …`

Add after `describeDevices`:

```swift
    /// `Alpha 1.0 · iPhone 15, iOS 18.0`, or `"12" (…)` for a session default.
    public func describeDefault(_ device: DefaultDevice) async throws -> String {
        let sessions = try await store.sessions()
        switch device {
        case .session(let id):
            return "\"\(id)\"" + (sessions.first { $0.id == id }.map { " (\(StatusTools.describeDevice($0)))" } ?? "")
        case .uid(let uid):
            return sessions.first { $0.deviceUID == uid }.map(StatusTools.describeDevice) ?? "with device id \(uid)"
        }
    }
```

- [ ] **Step 6: Run tests and build**

Run: `swift test --filter DefaultDeviceTests` → PASS. If `describeDevice` prints `Alpha` differently from `"default device Alpha"`, read `StatusTools.describeDevice` and adjust only the test's expected substring. Then `swift test` → PASS; `make build` → succeeds.

- [ ] **Step 7: Commit**

```bash
git add Beaver/Domain/DefaultDevice.swift Beaver/MCP/ToolContext.swift Beaver/MCP/DeviceWait.swift Beaver/AppEnvironment.swift Beaver/Features/AgentActivity/AppEnvironment+AgentUI.swift BeaverTests/MCPTestSupport.swift BeaverTests/DefaultDeviceTests.swift
git commit -m "feat: a default device for agents, kept across app restarts"
```

---

### Task 6: `ToolboxLoad` — the popover's loading logic in core

**Files:**
- Modify: `Beaver/Domain/Toolbox.swift`
- Test: `BeaverTests/ToolboxTests.swift`

**Interfaces:**
- Consumes: `DeviceLink.mcp` (Task 4), `DeviceMCPClient.listTimeout` (Task 4), `Toolboxes` (Task 3)
- Produces: `public enum ToolboxLoad: Sendable, Equatable { case loading, loaded([Toolbox]), unsupported, failed(String); static func fetch(from: any DeviceLink, sessionId: Int64) async -> ToolboxLoad }`

- [ ] **Step 1: Write the failing tests** (append to `ToolboxTests`)

```swift
    @Test("ToolboxLoad: loaded, empty, unsupported")
    func loadStates() async {
        let listing = FakeDevice(onMCP: { _, _ in ToolboxTests.list })
        guard case .loaded(let boxes) = await ToolboxLoad.fetch(from: listing, sessionId: 1) else {
            Issue.record("expected .loaded"); return
        }
        #expect(boxes.map(\.name) == ["app", "other", "storage"])
        #expect(listing.mcpCalls.map(\.method) == ["tools/list"])
        #expect(await ToolboxLoad.fetch(from: FakeDevice(onMCP: { _, _ in ["tools": []] }), sessionId: 1) == .loaded([]))
        #expect(await ToolboxLoad.fetch(from: FakeDevice(), sessionId: 1) == .unsupported)
    }

    @Test("Review focus: ToolboxLoad ends on a timeout or a disconnect instead of spinning")
    func loadFailures() async {
        let slow = FakeDevice(onMCP: { _, _ in throw DeviceMCPError.timeout })
        let gone = FakeDevice(onMCP: { _, _ in throw DeviceMCPError.disconnected })
        #expect(await ToolboxLoad.fetch(from: slow, sessionId: 1) == .failed("The app didn't answer in time."))
        #expect(await ToolboxLoad.fetch(from: gone, sessionId: 1) == .failed("The app disconnected."))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ToolboxTests` → compile error, `ToolboxLoad` undefined.

- [ ] **Step 3: Implement** (append to `Toolbox.swift`)

```swift
/// What the device popover shows under Toolboxes (D74).
public enum ToolboxLoad: Sendable, Equatable {
    case loading
    case loaded([Toolbox])
    /// The app doesn't answer MCP (JS-only sink, older SDK).
    case unsupported
    case failed(String)

    /// Asks the app for its tools now; React toolboxes come and go, so nothing is cached.
    public static func fetch(from device: any DeviceLink, sessionId: Int64) async -> ToolboxLoad {
        do {
            let result = try await device.mcp("tools/list", params: [:], to: sessionId,
                                              timeout: DeviceMCPClient.listTimeout)
            return .loaded(Toolboxes.group(Toolboxes.tools(fromListResult: result)))
        } catch DeviceMCPError.unsupported {
            return .unsupported
        } catch DeviceMCPError.timeout {
            return .failed("The app didn't answer in time.")
        } catch DeviceMCPError.disconnected {
            return .failed("The app disconnected.")
        } catch DeviceMCPError.rpc(_, let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ToolboxTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Beaver/Domain/Toolbox.swift BeaverTests/ToolboxTests.swift
git commit -m "feat: load an app's toolboxes, with its failure states"
```

---

### Task 7: MCP tools — `devices_set_default`, `toolboxes_list`, `tools_call`, `beaver_status`

**Files:**
- Create: `Beaver/MCP/Tools/ToolboxTools.swift`
- Modify: `Beaver/MCP/BeaverTools.swift`
- Modify: `Beaver/MCP/Tools/StatusTools.swift` (`status` run closure)
- Modify: `Beaver/MCP/MCPTool.swift` (`ToolSchema.deviceId`)
- Modify: `Beaver/MCP/MCPServer.swift` (`instructions`)
- Modify: `Beaver/Resources/MCP.md`
- Test: `BeaverTests/ToolboxToolsTests.swift`

**Interfaces:**
- Consumes: `DeviceLink.mcp`, `DeviceMCPError`, `DeviceMCPClient.listTimeout/callTimeout` (Task 4); `DefaultDevice`, `AgentUI.setDefaultDevice`, `HostSnapshot.defaultDevice`, `ToolContext.describeDefault` (Task 5); `Toolboxes`, `DeviceTool` (Task 3); `ToolContext.requireDevice(_:doing:call:)`, `ToolContext.describeDevices(_:)`, `ToolContext.trimmedNonEmpty`, `StatusTools.describeDevice` (existing)
- Produces: `ToolboxTools.all: [MCPTool]` = `[setDefault, toolboxesList, toolsCall]`; `ToolboxTools.gatewayNames: Set<String>`

- [ ] **Step 1: Write the failing tests**

`BeaverTests/ToolboxToolsTests.swift`:

```swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Toolbox tools (D74, D75)")
struct ToolboxToolsTests {

    static let toolsList: JSON = ["tools": [
        ["name": "storage.set", "description": "Set a key",
         "inputSchema": ["type": "object", "properties": ["key": ["type": "string"], "value": ["type": "string"]],
                         "required": ["key", "value"]]],
        ["name": "storage.get", "description": "Get a key",
         "inputSchema": ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]]],
        ["name": "app.restart", "description": "Restart the app", "inputSchema": ["type": "object", "properties": [:]]],
    ]]

    static let ok: @Sendable (String, JSON) async throws -> JSON = { method, params in
        if method == "tools/list" { return ToolboxToolsTests.toolsList }
        return ["content": [["type": "text", "text": "set volume\nsecond line"]], "isError": false,
                "structuredContent": ["echo": params]]
    }

    /// One live app, Alpha (uid A); `answer` plays its MCP server.
    private func alpha(_ answer: @escaping @Sendable (String, JSON) async throws -> JSON = ToolboxToolsTests.ok)
        async throws -> (LogStore, Session, FakeUI, FakeDevice) {
        let store = try LogStore(source: .inMemory)
        let a = try await store.createSession(source: .live)
        try await store.setSessionDeviceInfo(id: a.id, appName: "Alpha", appVersion: "1.0", deviceModel: "iPhone 15",
                                             platform: "iOS", osVersion: "18.0", deviceUID: "A")
        let ui = FakeUI(value: HostSnapshot(serverState: "clientConnected", liveSessionIds: [a.id]))
        return (store, a, ui, FakeDevice(onMCP: answer))
    }

    private func run(_ tool: MCPTool, _ args: [String: JSON], _ store: LogStore, _ ui: FakeUI,
                     _ device: FakeDevice) async throws -> ToolResult {
        try await tool.run(ToolArguments(args), makeContext(store, fakeUI: ui, device: device))
    }

    private func message(_ body: () async throws -> Void) async -> String {
        do { try await body(); Issue.record("expected a ToolError"); return "" }
        catch let e as ToolError { return e.message }
        catch { Issue.record("unexpected \(error)"); return "" }
    }

    // MARK: toolboxes_list

    @Test("toolboxes_list: each toolbox with its tools")
    func listToolboxes() async throws {
        let (store, a, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolboxesList, [:], store, ui, device)
        #expect(r.summary.contains("app (1)"))
        #expect(r.summary.contains("storage (2)"))
        #expect(r.structured["toolboxes"]?.array?.compactMap { $0["name"]?.string } == ["app", "storage"])
        #expect(device.mcpCalls.map(\.method) == ["tools/list"])
        #expect(device.mcpCalls.first?.sessionId == a.id)
        #expect(r.next.first?.contains("toolboxes_list(deviceId: \"\(a.id)\", toolbox: \"app\")") == true)
    }

    @Test("toolboxes_list(toolbox:): tools with schemas and a ready tools_call")
    func listOneToolbox() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolboxesList, ["toolbox": "storage"], store, ui, device)
        #expect(r.body.contains("storage.set(key: string, value: string) — Set a key"))
        #expect(r.structured["tools"]?.array?.count == 2)
        #expect(r.structured["tools"]?.array?.first?["inputSchema"]?["required"] == ["key"])
        #expect(r.next.contains { $0.contains("tools_call(") && $0.contains("{key: …}") })
    }

    @Test("toolboxes_list: an unknown toolbox lists the real ones")
    func unknownToolbox() async throws {
        let (store, _, ui, device) = try await alpha()
        let m = await message { _ = try await run(ToolboxTools.toolboxesList, ["toolbox": "player"], store, ui, device) }
        #expect(m.contains("app, storage"))
    }

    @Test("Review focus: an app with no tools says so")
    func noToolboxes() async throws {
        let (store, _, ui, device) = try await alpha { _, _ in ["tools": []] }
        let r = try await run(ToolboxTools.toolboxesList, [:], store, ui, device)
        #expect(r.summary.contains("no toolboxes"))
    }

    @Test("An app that doesn't answer MCP: says why")
    func unsupported() async throws {
        let (store, _, ui, device) = try await alpha { _, _ in throw DeviceMCPError.unsupported }
        let m = await message { _ = try await run(ToolboxTools.toolboxesList, [:], store, ui, device) }
        #expect(m.contains("native WebSocket sink"))
    }

    // MARK: tools_call

    @Test("tools_call forwards name and arguments, returns the app's text and structuredContent")
    func call() async throws {
        let (store, a, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolsCall,
                              ["name": "storage.set", "arguments": ["key": "volume", "value": "3"]], store, ui, device)
        let sent = try #require(device.mcpCalls.last)
        #expect(sent.method == "tools/call")
        #expect(sent.params == ["name": "storage.set", "arguments": ["key": "volume", "value": "3"]])
        #expect(r.summary.hasPrefix("storage.set on Alpha"))
        #expect(r.summary.hasSuffix("set volume"))
        #expect(r.body == "set volume\nsecond line")
        #expect(r.structured["structuredContent"]?["echo"]?["name"] == "storage.set")
        #expect(r.sessionId == a.id)
    }

    @Test("Review focus: arguments sent as a JSON string are parsed")
    func stringArguments() async throws {
        let (store, _, ui, device) = try await alpha()
        _ = try await run(ToolboxTools.toolsCall,
                          ["name": "storage.get", "arguments": #"{"key":"volume"}"#], store, ui, device)
        #expect(device.mcpCalls.last?.params["arguments"] == ["key": "volume"])
    }

    @Test("The app's isError becomes a ToolError pointing at the toolbox")
    func appError() async throws {
        let (store, _, ui, device) = try await alpha { method, _ in
            method == "tools/list" ? ToolboxToolsTests.toolsList
                : ["content": [["type": "text", "text": "missing value"]], "isError": true]
        }
        let m = await message { _ = try await run(ToolboxTools.toolsCall, ["name": "storage.set"], store, ui, device) }
        #expect(m.contains("storage.set failed on Alpha"))
        #expect(m.contains("missing value"))
        #expect(m.contains("toolbox: \"storage\""))
    }

    @Test("An unknown tool lists the toolbox's tools")
    func unknownTool() async throws {
        let (store, _, ui, device) = try await alpha { method, _ in
            method == "tools/list" ? ToolboxToolsTests.toolsList
                : ["content": [["type": "text", "text": "Unknown tool 'storage.sett'"]], "isError": true]
        }
        let m = await message { _ = try await run(ToolboxTools.toolsCall, ["name": "storage.sett"], store, ui, device) }
        #expect(m.contains("storage.get, storage.set"))
    }

    @Test("A timeout says the call may still have run")
    func timeout() async throws {
        let (store, _, ui, device) = try await alpha { _, _ in throw DeviceMCPError.timeout }
        let m = await message { _ = try await run(ToolboxTools.toolsCall, ["name": "app.restart"], store, ui, device) }
        #expect(m.contains("may still have run"))
    }

    // MARK: "beaver"

    @Test("Beaver as a device: its tools as toolboxes, without the gateway")
    func beaverToolboxes() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolboxesList, ["deviceId": "beaver", "toolbox": "logs"], store, ui, device)
        let names = r.structured["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(names.contains("logs.query"))
        let all = try await run(ToolboxTools.toolboxesList, ["deviceId": "beaver"], store, ui, device)
        #expect(!all.body.contains("tools.call"))
        #expect(!all.body.contains("toolboxes.list"))
        #expect(device.mcpCalls.isEmpty)
    }

    @Test("tools_call on beaver runs Beaver's tool; the gateway can't be called through it")
    func beaverCall() async throws {
        let (store, _, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "beaver.status"], store, ui, device)
        #expect(r.summary.hasPrefix("A device is connected"))
        let m = await message {
            _ = try await run(ToolboxTools.toolsCall, ["deviceId": "beaver", "name": "tools.call"], store, ui, device)
        }
        #expect(m.contains("toolboxes_list(deviceId: \"beaver\")"))
    }

    // MARK: devices_set_default

    @Test("devices_set_default sets by device id, clears with null, refuses beaver and a missing deviceId")
    func setDefault() async throws {
        let (store, a, ui, device) = try await alpha()
        let r = try await run(ToolboxTools.setDefault, ["deviceId": JSON(a.id)], store, ui, device)
        #expect(ui.value.defaultDevice == .uid("A"))
        #expect(r.summary.contains("Alpha"))
        _ = try await run(ToolboxTools.setDefault, ["deviceId": .null], store, ui, device)
        #expect(ui.value.defaultDevice == nil)
        let beaver = await message { _ = try await run(ToolboxTools.setDefault, ["deviceId": "beaver"], store, ui, device) }
        #expect(beaver.contains("apps"))
        let missing = await message { _ = try await run(ToolboxTools.setDefault, [:], store, ui, device) }
        #expect(missing.contains("deviceId: null"))
    }

    // MARK: beaver_status

    @Test("beaver_status marks the default and shows device id, bundle id and Beaver's deviceId")
    func status() async throws {
        let (store, a, ui, device) = try await alpha()
        try await store.setSessionDeviceInfo(id: a.id, appName: nil, appVersion: nil, deviceModel: nil, platform: nil,
                                             osVersion: nil, appPackage: "com.example.alpha")
        ui.update { $0.defaultDevice = .uid("A") }
        let r = try await run(StatusTools.status, [:], store, ui, device)
        let first = try #require(r.structured["devices"]?.array?.first)
        #expect(first["default"] == true)
        #expect(first["uid"] == "A")
        #expect(first["appPackage"] == "com.example.alpha")
        #expect(r.structured["devices"]?.array?.count == 1)
        #expect(r.structured["beaver"]?["deviceId"] == "beaver")
        #expect(r.summary.contains("Default device: Alpha"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ToolboxToolsTests` → compile error, `ToolboxTools` undefined.

- [ ] **Step 3: Implement the tools**

`Beaver/MCP/Tools/ToolboxTools.swift`:

```swift
//
//  ToolboxTools.swift
//  Beaver
//
//  D74/D75: the connected apps' toolboxes through one gateway, Beaver's
//  own tools as device "beaver", and the default device.

import Foundation

enum ToolboxTools {
    static let all = [setDefault, toolboxesList, toolsCall]

    /// Not reachable through "beaver": no recursion.
    static let gatewayNames: Set<String> = ["devices_set_default", "toolboxes_list", "tools_call"]

    static let beaverId = "beaver"

    // MARK: devices_set_default

    static let setDefault = MCPTool(
        name: "devices_set_default",
        title: "Set the default device",
        description: "Use when several apps are connected and you will work with one of them: device tools (commands_send, storage_set, toolboxes_list, tools_call, …) then use it when you omit deviceId. It follows the app when it restarts. Pass deviceId: null to clear it. The user can set it too, in the device popover.",
        kind: .change,
        idempotent: true,
        inputSchema: ToolSchema.object([
            "deviceId": ToolSchema.string("The app's deviceId from beaver_status, or null to clear the default."),
        ])
    ) { args, ctx in
        guard let raw = args.values["deviceId"] else {
            throw ToolError("deviceId is required. Example: devices_set_default(deviceId: \"12\"), or devices_set_default(deviceId: null) to clear it.")
        }
        if raw == .null {
            await ctx.ui.setDefaultDevice(nil)
            return ToolResult(summary: "No default device: with several apps connected, device tools need deviceId.",
                              structured: ["default": .null], next: ["beaver_status()"])
        }
        if try args.string("deviceId") == beaverId {
            throw ToolError("The default is for apps; Beaver is always deviceId \"beaver\". Example: devices_set_default(deviceId: \"12\") with an id from beaver_status().")
        }
        let (_, id) = try await ctx.requireDevice(args, doing: "make it the default", call: "devices_set_default()")
        guard let session = try await ctx.store.sessions().first(where: { $0.id == id }) else {
            throw ToolError("Session #\(id) is gone. Example: beaver_status(), then devices_set_default(deviceId: …).")
        }
        let device = DefaultDevice(session: session)
        await ctx.ui.setDefaultDevice(device)
        let lasts = if case .uid = device { "it stays the default when the app restarts" }
                    else { "this app sends no device id, so the default ends when it reconnects" }
        return ToolResult(
            summary: "Default device: \(StatusTools.describeDevice(session)) (deviceId \"\(id)\"); \(lasts).",
            structured: ["default": .string(String(id)), "uid": JSON(session.deviceUID)],
            next: ["toolboxes_list() for its toolboxes", "commands_list() for its commands"],
            sessionId: id
        )
    }

    // MARK: toolboxes_list

    static let toolboxesList = MCPTool(
        name: "toolboxes_list",
        title: "List an app's toolboxes",
        description: "Use to see what a connected app lets you do beyond commands: its toolboxes (storage, app, logs, debugfeatures, React ones…) and, with toolbox, each tool's arguments. deviceId \"beaver\" lists Beaver's own tools the same way. Then call one with tools_call.",
        kind: .read,
        inputSchema: ToolSchema.object([
            "deviceId": ToolSchema.deviceId,
            "toolbox": ToolSchema.string("One toolbox's tools with their arguments, e.g. \"storage\"."),
        ])
    ) { args, ctx in
        let (deviceId, label, tools) = try await tools(args, ctx)
        let boxes = Toolboxes.group(tools)
        let on = deviceId == beaverId ? "Beaver" : label
        guard let wanted = try args.string("toolbox").flatMap(ToolContext.trimmedNonEmpty) else {
            guard let first = boxes.first else {
                return ToolResult(summary: "\(on) has no toolboxes.",
                                  structured: ["deviceId": .string(deviceId), "toolboxes": []],
                                  next: ["commands_list(deviceId: \"\(deviceId)\") for its commands"])
            }
            return ToolResult(
                summary: "\(on) has \(boxes.count) toolbox(es): "
                    + boxes.map { "\($0.name) (\($0.tools.count))" }.joined(separator: ", ") + ".",
                body: boxes.map { "\($0.name) — " + $0.tools.map(\.name).joined(separator: ", ") }.joined(separator: "\n"),
                structured: ["deviceId": .string(deviceId), "toolboxes": .array(boxes.map { box in
                    ["name": .string(box.name), "tools": .array(box.tools.map { .string($0.name) })]
                })],
                next: ["toolboxes_list(deviceId: \"\(deviceId)\", toolbox: \"\(first.name)\") for its arguments"]
            )
        }
        guard let box = boxes.first(where: { $0.name == wanted }) else {
            throw ToolError("\(on) has no toolbox \"\(wanted)\". Toolboxes: "
                + boxes.map(\.name).joined(separator: ", ")
                + ". Example: toolboxes_list(deviceId: \"\(deviceId)\", toolbox: \"\(boxes.first?.name ?? "storage")\").")
        }
        let first = box.tools[0]
        return ToolResult(
            summary: "\(box.name) on \(on): \(box.tools.count) tool(s).",
            body: box.tools.map { $0.signature + ($0.description.isEmpty ? "" : " — " + $0.description) }
                .joined(separator: "\n"),
            structured: ["deviceId": .string(deviceId), "toolbox": .string(box.name), "tools": .array(box.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            })],
            next: ["tools_call(deviceId: \"\(deviceId)\", name: \"\(first.name)\", arguments: \(first.exampleArguments))"]
        )
    }

    // MARK: tools_call

    static let toolsCall = MCPTool(
        name: "tools_call",
        title: "Call an app's tool",
        description: "Use to run one tool from toolboxes_list on a connected app (e.g. storage.set, app.restart) and get its answer. deviceId \"beaver\" runs Beaver's own tool by its dotted name (logs.query). Omit deviceId for the default device, or the only connected one.",
        kind: .change,
        inputSchema: ToolSchema.object([
            "deviceId": ToolSchema.deviceId,
            "name": ToolSchema.string("The tool's full name from toolboxes_list, e.g. \"storage.set\"."),
            "arguments": ["type": "object", "description": "The tool's arguments, as its inputSchema in toolboxes_list says."],
        ], required: ["name"])
    ) { args, ctx in
        guard let name = try args.string("name").flatMap(ToolContext.trimmedNonEmpty) else {
            throw ToolError("name is required. Example: tools_call(name: \"storage.get\", arguments: {key: \"volume\"}) — toolboxes_list() shows the names.")
        }
        let arguments = try argumentsObject(args["arguments"])
        if try args.string("deviceId") == beaverId {
            let local = Toolboxes.beaverToolName(name)
            guard !gatewayNames.contains(local), let tool = BeaverTools.all.first(where: { $0.name == local }) else {
                throw ToolError("Beaver has no tool \"\(name)\" here. Example: toolboxes_list(deviceId: \"beaver\") for its tools.")
            }
            return try await tool.run(ToolArguments(arguments), ctx)
        }
        let (_, id) = try await ctx.requireDevice(args, doing: "call \(name)", call: "tools_call(name: \"\(name)\")")
        let label = try await appLabel(ctx, id)
        let before = try await ctx.store.latestEventId(sessionId: id) ?? 0
        let reply = try await device(ctx, "tools/call", ["name": .string(name), "arguments": .object(arguments)],
                                     sessionId: id, timeout: DeviceMCPClient.callTimeout, what: name, label: label)
        let text = (reply["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        let box = Toolboxes.name(of: name)
        if reply["isError"]?.bool == true {
            var hint = ""
            if text.hasPrefix("Unknown tool"),
               let listed = try? await device(ctx, "tools/list", [:], sessionId: id, timeout: DeviceMCPClient.listTimeout,
                                              what: "tools/list", label: label) {
                let tools = Toolboxes.tools(fromListResult: listed)
                let same = tools.filter { Toolboxes.name(of: $0.name) == box }.map(\.name).sorted()
                hint = same.isEmpty
                    ? " Toolboxes: " + Toolboxes.group(tools).map(\.name).joined(separator: ", ") + "."
                    : " Tools in \(box): " + same.joined(separator: ", ") + "."
            }
            throw ToolError("\(name) failed on \(label): \(text).\(hint) Example: toolboxes_list(deviceId: \"\(id)\", toolbox: \"\(box)\") for its arguments.")
        }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var structured: [String: JSON] = ["deviceId": .string(String(id)), "name": .string(name),
                                          "isError": false, "text": .string(text), "afterId": JSON(before)]
        if let content = reply["structuredContent"] { structured["structuredContent"] = content }
        return ToolResult(
            summary: "\(name) on \(label): " + String(firstLine.prefix(200)),
            body: text,
            structured: .object(structured),
            next: ["logs_wait(afterId: \(before), timeoutMs: 15000) for what the app logged"],
            sessionId: id
        )
    }

    // MARK: Helpers

    /// The device's tools, or Beaver's own for "beaver".
    private static func tools(_ args: ToolArguments, _ ctx: ToolContext) async throws
        -> (deviceId: String, label: String, tools: [DeviceTool]) {
        if try args.string("deviceId") == beaverId {
            let own = BeaverTools.all.filter { !gatewayNames.contains($0.name) }.map {
                DeviceTool(name: Toolboxes.beaverName($0.name), description: $0.description, inputSchema: $0.inputSchema)
            }
            return (beaverId, "Beaver", own)
        }
        let (_, id) = try await ctx.requireDevice(args, doing: "list its toolboxes", call: "toolboxes_list()")
        let label = try await appLabel(ctx, id)
        let result = try await device(ctx, "tools/list", [:], sessionId: id, timeout: DeviceMCPClient.listTimeout,
                                      what: "tools/list", label: label)
        return (String(id), label, Toolboxes.tools(fromListResult: result))
    }

    /// `Alpha 1.0 (iPhone 15, iOS 18.0)`: how summaries and errors name the app.
    private static func appLabel(_ ctx: ToolContext, _ id: Int64) async throws -> String {
        try await ctx.store.sessions().first { $0.id == id }.map(StatusTools.describeDevice) ?? "Device \"\(id)\""
    }

    /// One MCP request; `DeviceMCPError` becomes a ToolError that says what to do.
    private static func device(_ ctx: ToolContext, _ method: String, _ params: JSON, sessionId: Int64,
                               timeout: Duration, what: String, label: String) async throws -> JSON {
        do {
            return try await ctx.device.mcp(method, params: params, to: sessionId, timeout: timeout)
        } catch let error as DeviceMCPError {
            switch error {
            case .unsupported:
                throw ToolError("\(label) doesn't answer MCP, so it has no toolboxes: the app needs quick-brick-xray's native WebSocket sink. Its commands still work. Example: commands_list(deviceId: \"\(sessionId)\").")
            case .timeout:
                throw ToolError("\(label) didn't answer \(what) in time. It may still have run it — app.restart, for one, drops the connection before answering. Example: beaver_status(), then logs_query(sessionId: \(sessionId), since: \"1m\").")
            case .disconnected:
                throw ToolError("\(label) disconnected before answering \(what). Example: beaver_status() to see whether it came back.")
            case .rpc(_, let message):
                throw ToolError("\(label) refused \(what): \(message). Example: toolboxes_list(deviceId: \"\(sessionId)\").")
            }
        }
    }

    /// An object, or a weak client's JSON string of one.
    private static func argumentsObject(_ value: JSON?) throws -> [String: JSON] {
        guard let value else { return [:] }
        if let object = value.object { return object }
        if let s = value.string, let data = s.data(using: .utf8), let object = (try? JSON.parse(data))?.object {
            return object
        }
        throw ToolError("arguments must be an object. Example: tools_call(name: \"storage.get\", arguments: {key: \"volume\"}).")
    }
}
```

- [ ] **Step 4: Register, status, schema text, instructions**

`BeaverTools.swift`: add `ToolboxTools.all` to `groups` after `CommandTools.all`.

`StatusTools.swift`, in `status`:
- in the device dictionary add
  ```swift
                "default": .bool(host.defaultDevice?.matches(session) ?? false),
                "uid": JSON(session.deviceUID), "appPackage": JSON(session.appPackage),
  ```
- in the `lines.append("Device \"\(live)\": …")` add ` + (host.defaultDevice?.matches(session) == true ? " (default)" : "")` at the end.
- after the `let summary = …` switch, add:
  ```swift
        let defaultNote: String
        if let preferred = host.defaultDevice {
            defaultNote = " Default device: " + (try await ctx.describeDefault(preferred))
                + (preferred.liveSession(in: sessions, live: host.liveSessionIds) == nil ? " (not connected)." : ".")
        } else {
            defaultNote = ""
        }
  ```
  and return `summary: summary + defaultNote`.
- `structured["beaver"]`: `["version": …, "mcpPort": …, "deviceId": "beaver"]`.

`MCPTool.swift`: `ToolSchema.deviceId` becomes

```swift
    public static let deviceId = string(
        "Which connected app: its deviceId from beaver_status. Omit it for the default device (devices_set_default), or the only connected one.")
```

`MCPServer.swift` `instructions`: after the sentence ending `to commands_send, commands_list and storage changes.` insert:

```
 Or set a default with devices_set_default. Apps built with quick-brick-xray's \
native sink also offer toolboxes (storage, app, debugfeatures, React ones): list them with \
toolboxes_list and run one with tools_call; deviceId "beaver" reaches Beaver's own tools the same way.
```

(Keep the string's `\` line-continuation style; read the block with the Read tool first — `rtk` hides nothing here, but the literal is long.)

- [ ] **Step 5: MCP.md**

In the Tools table, after the `devices_disconnect` row:

```
| `devices_set_default` | Make one connected app the default for device tools (follows it across restarts); `null` clears |
| `toolboxes_list` | An app's toolboxes, or one toolbox's tools with their arguments; `deviceId: "beaver"` for Beaver's own |
| `tools_call` | Run one tool from `toolboxes_list` on the app (or on Beaver) and get its answer |
```

After the `### devices — two apps connected at once` recipe, add:

```
### toolboxes — use what the app offers beyond commands

1. `beaver_status()` — pick the app; with several, `devices_set_default(deviceId: "14")` so you can omit `deviceId`.
2. `toolboxes_list()` — its toolboxes, e.g. `storage (7)`, `app (3)`, `debugfeatures (2)`.
3. `toolboxes_list(toolbox: "storage")` — each tool's arguments.
4. `tools_call(name: "storage.get", arguments: {key: "volume"})` — the app's answer.
5. `tools_call(name: "app.restart")` may time out: the app drops the connection first. `beaver_status()` shows it back in a new session; the default follows it.
6. `toolboxes_list(deviceId: "beaver")` and `tools_call(deviceId: "beaver", name: "logs.query", arguments: {since: "5m"})` — Beaver's own tools the same way.
```

In `## Testing without Xcode`, add a numbered step at the end:

```
N. Toolboxes: connect an app built with quick-brick-xray's **native** WebSocket
   sink (the JS-only sink has none), click the device badge on the left of the
   toolbar — the popover lists its toolboxes. Nothing to turn on in Beaver.
```

(Use the next number in that list.)

- [ ] **Step 6: Run tests**

Run: `swift test --filter ToolboxToolsTests` → PASS. Then `swift test` → PASS, including `MCPDocTests` (drift: every tool in the table and in a recipe; descriptions start with "Use"). `make build` → succeeds.

- [ ] **Step 7: Commit**

```bash
git add Beaver/MCP/Tools/ToolboxTools.swift Beaver/MCP/BeaverTools.swift Beaver/MCP/Tools/StatusTools.swift Beaver/MCP/MCPTool.swift Beaver/MCP/MCPServer.swift Beaver/Resources/MCP.md BeaverTests/ToolboxToolsTests.swift
git commit -m "feat: agents reach apps' toolboxes — toolboxes_list, tools_call, devices_set_default"
```

---

### Task 8: Device popover and the default in the device menu

**Files:**
- Create: `Beaver/Features/Devices/DevicePopover.swift`
- Modify: `Beaver/Features/MainWindow.swift` (`ToolbarDeviceBadge` ~line 581, `DeviceSwitcher.body` ~line 675)

**Interfaces:**
- Consumes: `ToolboxLoad.fetch(from:sessionId:)`, `Toolbox`, `DeviceTool.parameters`, `ToolParameter.line` (Tasks 3, 6); `DefaultDevice(session:)`, `.matches(_:)`, `AppEnvironment.defaultDevice`, `AppEnvironment.setDefaultDeviceByUser(_:name:sessionId:)` (Task 5); `AppEnvironment.disconnect(_:)`, `ToastCenter.success(_:)` (existing)
- Produces: `struct DevicePopover: View` (app target only)

- [ ] **Step 1: Create the popover**

`Beaver/Features/Devices/DevicePopover.swift`:

```swift
//
//  DevicePopover.swift
//  Beaver
//
//  D74/D75: what the viewed device runs, Disconnect, the agents' default,
//  and the app's toolboxes (read-only). Opened from the leading device badge.

import AppKit
import SwiftUI

struct DevicePopover: View {
    let session: Session
    let isLive: Bool
    @Environment(AppEnvironment.self) private var env
    @Environment(ToastCenter.self) private var toasts
    @State private var load: ToolboxLoad = .loading
    @State private var openToolbox: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isLive {
                HStack {
                    Toggle("Default for agents", isOn: defaultBinding)
                        .toggleStyle(.checkbox)
                        .help("Agents' device tools use this app when a call names no device")
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        Task { await env.disconnect(session.id) }
                    }
                }
                Divider()
                toolboxes
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .task(id: session.id) { if isLive { await reload() } }
    }

    private var title: String {
        (session.appName ?? session.appPackage ?? "Device #\(session.id)")
            + (session.appVersion.map { " " + $0 } ?? "")
    }

    private var deviceLine: String {
        [session.deviceModel, session.osVersion.map { (session.platform ?? "OS") + " " + $0 }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var stateLine: String {
        if isLive { return "Connected since " + session.startedAt.formatted(date: .omitted, time: .shortened) }
        if let ended = session.endedAt { return "Ended " + ended.formatted(date: .abbreviated, time: .shortened) }
        return session.source == .imported ? "Imported" : "Not connected"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let package = session.appPackage {
                Text(package).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !deviceLine.isEmpty {
                Text(deviceLine).font(.caption).foregroundStyle(.secondary)
            }
            if let uid = session.deviceUID {
                HStack(spacing: 4) {
                    Text(uid).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(uid, forType: .string)
                        toasts.success("Copied device id")
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy device id")
                }
            }
            Text(stateLine).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var defaultBinding: Binding<Bool> {
        Binding(
            get: { env.defaultDevice?.matches(session) ?? false },
            set: { on in
                env.setDefaultDeviceByUser(on ? DefaultDevice(session: session) : nil,
                                           name: title, sessionId: session.id)
            }
        )
    }

    @ViewBuilder
    private var toolboxes: some View {
        HStack {
            Text("Toolboxes").font(.subheadline.weight(.semibold))
            Spacer()
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Ask the app for its toolboxes again")
                .disabled(load == .loading)
        }
        switch load {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .unsupported:
            Text("This app doesn't answer MCP — it needs quick-brick-xray's native WebSocket sink.")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { Task { await reload() } }
            }
        case .loaded(let boxes) where boxes.isEmpty:
            Text("This app has no toolboxes.").font(.caption).foregroundStyle(.secondary)
        case .loaded(let boxes):
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(boxes, id: \.name) { box in
                        DisclosureGroup(isExpanded: Binding(
                            get: { openToolbox == box.name },
                            set: { openToolbox = $0 ? box.name : nil }
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(box.tools, id: \.name) { ToolRow(tool: $0) }
                            }
                            .padding(.leading, 4)
                        } label: {
                            Text("\(box.name) · \(box.tools.count) tool\(box.tools.count == 1 ? "" : "s")")
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
        }
    }

    private func reload() async {
        load = .loading
        load = await ToolboxLoad.fetch(from: env, sessionId: session.id)
    }
}

private struct ToolRow: View {
    let tool: DeviceTool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tool.name)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            if !tool.description.isEmpty {
                Text(tool.description).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(tool.parameters, id: \.name) { p in
                Text(p.line).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Open it from the badge**

In `MainWindow.swift`, `ToolbarDeviceBadge`: add `@State private var showingDetails = false`, and wrap the existing `HStack { … }` together with its chrome modifiers (`.padding` ×2, `.background`, `.contentShape`) as the label of a plain button. The body becomes:

```swift
    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing: 8) {
                // … the existing icon + VStack, unchanged …
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(.controlBackgroundColor)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Self.fingerprint(session))
        .contextMenu {
            Button("Copy device fingerprint") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.fingerprint(session), forType: .string)
                toasts.success("Copied device fingerprint")
            }
        }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            DevicePopover(session: session, isLive: isLive)
        }
    }
```

Keep the existing comment about matching `ConnectionIndicator`'s chrome above `.padding`. Update the struct's doc comment: "Click → the device popover (app, Disconnect, default for agents, toolboxes); right-click → Copy device fingerprint."

- [ ] **Step 3: Mark the default in the device menu**

In `DeviceSwitcher.body`, the connected `ForEach`:

```swift
                    ForEach(sections.connected) { s in
                        choice(s, Self.item(s, suffix: Self.detail(s))
                            + (env.defaultDevice?.matches(s) == true ? " — default for agents" : ""))
                    }
```

- [ ] **Step 4: Build and check by hand**

Run: `make build` → succeeds. Then launch (the `run` skill, or open the built app) with an app using quick-brick-xray's native WebSocket sink connected (a simulator build of any QuickBrick app):
1. Click the leading device badge → popover shows app name, bundle id, model · OS, device id, "Connected since".
2. Toolboxes load; expanding `storage` shows its tools and parameters.
3. Tick "Default for agents" → the Connected pill's menu shows "— default for agents" on that device; the Agent panel has "You made … the default device for agents".
4. Disconnect → the popover's device ends; the SDK reconnects into a new session; the default still applies (`beaver_status` names it).
5. Open a past session from Sessions → badge popover shows only the header.

If no native-sink app is available, say so in the PR and check steps 1, 3 and 5 with a JS-sink app (toolboxes show "doesn't answer MCP" after ~5 s).

- [ ] **Step 5: Commit**

```bash
git add Beaver/Features/Devices/DevicePopover.swift Beaver/Features/MainWindow.swift
git commit -m "feat: device popover — app, Disconnect, default for agents, toolboxes"
```

---

### Task 9: Docs

**Files:**
- Modify: `PROTOCOL.md`, `DECISIONS.md`, `ARCHITECTURE.md`, `CHANGELOG.md`

- [ ] **Step 1: PROTOCOL.md**

- §2 envelope comment: `"<one of: handshake | event | storage | network | command | mcp>"`.
- Add **§3.3 `mcp` (server → client)** and **§4.4 `handshake` (client → server)**, **§4.5 `mcp` (client → server)** (renumber nothing else). Content:
  - §4.4: the JSON from the spec §2, the six fields (all optional), what Beaver stores (`device_uid`, `app_package`, `device_model`, `app_version`, `platform`/`os_version` split on the first space; applicaster.v2 wins where it has a value), sent once per connection, iOS and Android native sinks (#2848); the JS-only sink doesn't send it.
  - §3.3 / §4.5: envelope `{"type":"mcp","payload":<JSON-RPC 2.0>}`, correlation by JSON-RPC `id` (the envelope has none); Beaver sends `initialize` (then `notifications/initialized`) once, lazily, before its first request; methods used: `tools/list`, `tools/call`; timeouts 5 s / 5 s / 20 s; no reply to `initialize` → Beaver treats the app as having no toolboxes until it reconnects; a bare JSON-RPC frame (no `type`, has `jsonrpc`) is read as `mcp`; `mcp` frames are not log events; the device drops frames over 5 MB.
- §10: add "8. Toolbox descriptions are not in `tools/list` (toolboxes are named only by prefix). An `_meta.toolbox` description per tool would let Beaver describe them."

- [ ] **Step 2: DECISIONS.md** — append after D73, same format as D73 (`## D74. …`, `**Status:** Accepted (2026-09-28). Spec: plans/2026-09-28-device-toolboxes-design.md.`, then `- **Decision:**`, `- **Why:**`, `- **Alternatives:**`):
  - **D74. Apps' toolboxes through a gateway; Beaver is device "beaver".** Decision: `toolboxes_list` / `tools_call` reach any app's MCP tools over its WebSocket; Beaver's `tools/list` stays stable; Beaver's own tools are device `"beaver"` (`logs_query` ↔ `logs.query`). Why: the user wants one set of commands for Beaver and apps; MCP clients cache `tools/list` and ignore `list_changed`; device tools differ per app. Alternatives: merge device tools into `tools/list` (dynamic list, name clashes, renaming Beaver's tools breaks agents); only the gateway, Beaver's tools behind it (breaks agents, schemas unseen).
  - **D75. One default device for agents, kept by the SDK's device id.** Decision: `devices_set_default` or the popover toggle; omitted `deviceId` → explicit, default, only one, else error; a default that isn't connected is an error, never a fallback; in memory. Why: agreed with the user; the id survives `app.restart`. Alternatives: the viewed device (agent and user move each other); one per MCP connection (needs session ids through `ToolContext`, can't be shown in the UI).
  - **D76. Beaver reads the client handshake.** Decision: `device_uid`, `app_package` on the session; restart following matches on `device_uid`, D73's fingerprint heuristic is the fallback. Why: the SDK already sent a stable id that Beaver ignored. Alternatives: keep the heuristic (two identical builds look alike).
  - In D73, after "Two identical builds look alike until the SDK sends a device id." add " — it does; see D76."

- [ ] **Step 3: ARCHITECTURE.md** — in the transport section (search `WSServer`), add a paragraph: "`DeviceMCPClient` (D74): one per connection, created on connect and closed on disconnect by `BeaverApp.bootstrap`, held in `AppEnvironment.mcpClients`. Sends JSON-RPC in `mcp` frames through `WSServer.send(data:to:)`, matches replies by id, times out, initializes lazily. Tools reach it through `DeviceLink.mcp`."

- [ ] **Step 4: CHANGELOG.md** — under `[Unreleased]`:

```
### Added
- Click the device badge on the left of the toolbar: the app's name, bundle id,
  device and device id, a Disconnect button, "Default for agents", and the
  app's toolboxes with each tool's arguments (apps built with quick-brick-xray's
  native WebSocket sink).
- Agents: `toolboxes_list` and `tools_call` reach a connected app's toolboxes
  (and Beaver's own tools as `deviceId: "beaver"`); `devices_set_default` picks
  the app device tools use when `deviceId` is omitted — it follows the app
  across restarts. `beaver_status.devices` gains `default`, `uid`, `appPackage`.

### Changed
- An app that restarts is recognised by its device id, so two identical builds
  on two simulators are no longer confused.
```

(If `[Unreleased]` already has `### Added` / `### Changed`, add the bullets there.)

- [ ] **Step 5: Final verification**

Run: `swift test` → all PASS. `make build` → succeeds. `git status` → only the four docs changed.

- [ ] **Step 6: Commit**

```bash
git add PROTOCOL.md DECISIONS.md ARCHITECTURE.md CHANGELOG.md
git commit -m "docs: device toolboxes — protocol, D74–D76, architecture, changelog"
```
