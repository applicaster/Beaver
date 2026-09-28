# Several devices at once — design

**Date:** 2026-09-28 · **Decision:** D73 (supersedes D2) · **Release:** `feat:`

## 1. Goal

Several apps connect to Beaver at the same time, each into its own live
session. A dropdown in the toolbar lists them and switches the whole window
(Logs, Network, Storages, command bar) between them — the way the emitter
switcher works in zapp-support.

Agreed with the user:

- A device that connects while the user is looking at another live device
  does **not** take the window. It appears in the dropdown. The window switches
  to a new device only when the viewed session is not live (a past or imported
  session, or nothing).
- The dropdown lists connected devices **and** the 5 most recent ended live
  sessions, plus a link to the Sessions tab.

Out of scope: the SDK wire protocol, the export/import file format (one
session is still one device, so `SESSION_FILE_FORMAT.md` and zapp-support are
untouched), a merged feed of all devices (rejected in D2: commands become
ambiguous).

## 2. Today

- `WSServer` keeps one `current: NWConnection?`; a new connection cancels the
  old one (`handleNewConnection`). `send(command:)` goes to `current`.
- `Inbound` is `.connected` / `.frame(Data)` / `.disconnected` with no
  connection identity.
- `AppEnvironment.currentSessionId` is a singleton used for three different
  things: where inbound frames are written (`BeaverApp.handleInbound`), where
  commands go, and whether device-write affordances show (D35:
  `env.currentSessionId == vm.sessionId`).
- `availableCommands` (the `cmdlist` answer) is one global list.
- MCP already has the multi-device shape (D65): `beaver_status.devices` is an
  array, live-device tools take `deviceId` (only `"current"` exists).

## 3. Approach

**The live session id is the device's identity inside Beaver.** Choosing a
device in the dropdown sets `viewingSessionId`, which already drives every tab
and resets filters and selection in its `didSet`. Commands go to the
connection of the viewed session. No schema change.

Rejected: a separate `selectedDeviceId` next to `viewingSessionId` (two pieces
of state to keep in sync; in Beaver the session is already the unit of
viewing).

## 4. Transport and sessions

### 4.1 `WSServer`

- `current: NWConnection?` → `connections: [UUID: NWConnection]`. A new
  connection is added; nothing is cancelled.
- `Inbound`: `.connected(UUID)`, `.frame(UUID, Data)`, `.disconnected(UUID)`.
  `UUID` is minted in `handleNewConnection` and captured by that connection's
  handlers.
- State updates from a connection that is no longer in `connections` are
  ignored (replaces today's `connection === current` guard).
- `State.clientConnected` → `.connected(count: Int)`. `clientDisconnected`
  is yielded only when the count drops to 0.
- `send(command:)` → `send(command: String, to: UUID)`.
- `stop()` cancels every connection.

### 4.2 `AppEnvironment`

- `currentSessionId: Int64?` → `liveSessions: [UUID: Int64]`.
- Helpers: `liveSessionIds: [Int64]`, `isLive(_ sessionId: Int64?) -> Bool`,
  `connection(for sessionId: Int64) -> UUID?`.
- `didConnectSession(_ id:, connection:)` records the pair and sets
  `viewingSessionId = id` **only if** `!isLive(viewingSessionId)` (checked
  before recording).
- `didDisconnectSession(connection:)` removes the pair.
- `availableCommands: [CommandHint]` → `commandsBySession: [Int64: [CommandHint]]`
  plus `availableCommands` computed for `viewingSessionId`.
- `send(command:to sessionId:)` looks up the connection and calls the server;
  no-op if the session is not live.

### 4.3 `BeaverApp.bootstrap`

- `.connected(c)`: create a live session, `didConnectSession`, then send
  `cmdlist` to `c` after 500 ms (moved here from the `state` loop, which no
  longer knows which connection connected).
- `.frame(c, data)`: `handleInbound` writes to `liveSessions[c]`; a `cmdlist`
  answer is stored under that session.
- `.disconnected(c)`: end that session, `didDisconnectSession`.
- `.sessionDeleted(id)` / `.sessionsCleared`: a deleted live session is
  replaced by a fresh one for the same connection
  (`ensureLiveSessionIfConnected` becomes per connection).

### 4.4 Call sites of `currentSessionId`

| Where | Becomes |
|---|---|
| `StoragesView` (D35 checks, 4 places) | `env.isLive(vm.sessionId)` |
| `SessionsView` "can't delete the live session" | `env.isLive(item.id)` |
| `StoragesViewModel` `server.send(command: "storage.list")` | `env.send(command:to: sessionId)` |
| `CommandBarViewModel`, `CommandBarView` | send to `viewingSessionId`; Send enabled iff `env.isLive(viewingSessionId)` |
| `StorageCommand` via `DeviceLink` | see §6 |
| `AppEnvironment+AgentUI.snapshot` | `liveSessionIds` |

## 5. UI

### 5.1 Device menu (toolbar, leading)

Replaces `ToolbarDeviceBadge` in the same capsule chrome, with a chevron.

- **Label:** the viewed session's device, from the session row (D34 columns):
  `AppName` on the first line, `version · model · OS` below. A live session
  without a fingerprint yet shows `Device #<id>`. Nothing at all → hidden, as
  today.
- **Menu:**
  - *Connected* — each live session, green dot, `App · model · OS`, a
    checkmark on the viewed one;
  - *Recent* — the 5 most recent ended **live** sessions (imports excluded),
    secondary style, with their end time;
  - divider, *All Sessions…* → `selectedTab = .sessions`.
- Choosing an item sets `env.viewingSessionId`.
- "Copy device fingerprint" stays on the label's context menu.
- Source is `LogStore.sessions()`, refreshed on `sessionStarted`,
  `sessionEnded`, `sessionDeleted`, `sessionsCleared` and `sessionUpdated`
  (posted when a fingerprint is harvested).

### 5.2 Other UI

- Centre pill: `Connected` for one device, `Connected · N` for N > 1.
- `ConnectionPlaceholder` is unchanged (it shows only when nothing is viewed).

## 6. MCP

- `DeviceLink.send(command:)` → `send(command: String, to sessionId: Int64)`.
  `AppEnvironment` conforms (instead of `WSServer`); `ToolContext.device` is
  the environment. The test fake records `(command, sessionId)`.
- `HostSnapshot.deviceConnected` + `liveSessionId` → `liveSessionIds: [Int64]`.
- `deviceId` is the live session id as a string (`"42"`); `"current"` is gone.
  `beaver_status.devices` lists every live session.
- `requireDevice(args:)`: returns the live session for `deviceId`; without it,
  the only live session; with several and no `deviceId`, fails with the list
  and an example: `commands_send(deviceId: "42", command: "cmdlist")`.
  Unknown id fails with the list.
- `commands_send`, `storage_set`, `storage_delete`, `storage_snapshot`
  (reload) send to that session.
- **Following a reconnect (D66)** with several devices: the wait moves to a new
  live session if its fingerprint (`app_name`, `device_model`, `platform`)
  matches the ended one; if either fingerprint is unknown, only if exactly one
  new live session appeared meanwhile. Marked `// ponytail:` — a heuristic
  until the SDK sends a stable device id.
- `watchForDisconnect` compares `liveSessionIds.contains(sessionId)`.
- `MCPServer.instructions`: "One mobile app connects" → "Several apps can
  connect; with more than one, live-device tools need deviceId from
  beaver_status".
- `MCP.md`: Tools table text for `deviceId`, a recipe with two devices,
  "Testing without Xcode" note (connect two simulators).

## 7. Docs

- `DECISIONS.md`: D73 "Several devices at once" (this design); D2 → Status:
  Superseded by D73; D65's "To change" note is fulfilled.
- `ARCHITECTURE.md`, `PROTOCOL.md`: wherever they say one client.
- `CHANGELOG.md` `[Unreleased]`: the dropdown, and the agent-visible
  `deviceId` change.

## 8. Tests (Swift Testing)

- `WSServer`: two clients connect; both stay open; frames arrive tagged with
  their own id; one disconnecting leaves the other (extends
  `WSServerInboundTests`).
- `AppEnvironment`: a frame from connection B goes to B's session; a second
  device doesn't change `viewingSessionId` while a live one is viewed, does
  when a past session is viewed; `send(command:to:)` picks the right
  connection; `isLive`.
- MCP: `beaver_status` with two devices; `commands_send` without `deviceId`
  and two devices fails with the list; with `deviceId` reaches the right
  session; unknown `deviceId` fails; reconnect follow by fingerprint and by
  "only one new session"; drift tests stay green.

## 9. Risks

- Two identical builds on two simulators have the same fingerprint → the
  reconnect heuristic may follow the wrong one. Acceptable until the SDK sends
  a device id; the result says `sessionChanged`, so the agent sees it.
- A device that reconnects quickly while viewed: its old session ends → not
  live → the new connection takes the window. That is today's behaviour and
  what the user wants for restarts.
