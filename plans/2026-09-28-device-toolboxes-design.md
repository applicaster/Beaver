# Device toolboxes over MCP — design

**Date:** 2026-09-28 · **Decisions:** D75, D76, D77 · **Release:** `feat:`

## 1. Goal

Agents connected to Beaver's MCP server can use the **toolboxes** of the apps
connected to Beaver (quick-brick-xray: `storage.set`, `app.restart`,
`debugfeatures.toggle`, React toolboxes, …) with the same small set of tools
for every device. Beaver itself is one more device, `"beaver"`, whose
toolboxes are its own tools. An agent can pick a **default device** so it
doesn't pass `deviceId` on every call.

In the app, clicking the device badge shows which app is running, a
Disconnect button, and the device's toolboxes; choosing a toolbox shows its
tools.

Agreed with the user:

- **Gateway, not a flat list.** Beaver's `tools/list` stays stable: three new
  tools reach any device's tools. Device tools are not merged into
  `tools/list` (most MCP clients cache it and ignore `list_changed`; names and
  schemas can differ between devices). Beaver's own tools stay as they are.
- **Default device** is one for all of Beaver, kept by the SDK's stable
  device id, so it survives `app.restart`. It never switches the user's
  window.
- **Disconnect** stays as D73 decided: it closes the connection; the SDK
  reconnects into a new session.
- The UI only **shows** toolboxes and tools; it doesn't run them.

Out of scope: SDK changes, the export/import file format (sessions don't
carry toolboxes; `SESSION_FILE_FORMAT.md` and zapp-support are untouched),
running tools from the UI, persisting the default device across Beaver
launches.

## 2. What the SDK already does (quick-brick-xray, native WebSocketSink)

Source: `Zapp-Frameworks/plugins/quick-brick-xray`,
`DOCS/specs/apple-mcp-toolbox.md`, `apple/Universal/Toolbox/`,
`apple/Universal/Sinks/WebSocketSink/`. Android is wire-compatible (#2848).

- **Client handshake**, sent right after the socket opens:
  ```json
  {"type":"handshake","deviceId":"<installation uuid, falls back to model>",
   "deviceName":"Apple iPhone15,2","model":"iPhone15,2","platform":"iOS 18.6",
   "appPackage":"com.example.app","version":"11.0.1"}
  ```
  Beaver decodes it today as `.unknown(typeRaw: "handshake")`.
- **MCP over the same socket.** Beaver sends
  `{"type":"mcp","payload":<JSON-RPC request>}`; the device answers
  `{"type":"mcp","payload":<JSON-RPC response>}`, correlated by the JSON-RPC
  `id` (the envelope has none). Methods: `initialize`,
  `notifications/initialized`, `ping`, `tools/list`, `tools/call`.
  `protocolVersion "2024-11-05"`, `capabilities.tools.listChanged = false`.
- `tools/call` result: `{content:[{type:"text",text}], isError,
  structuredContent?}`.
- **Tool names** are `<toolbox>.<tool>` (`logs.tail`, `storage.set`,
  `app.restart`, `console.execute`, `debugfeatures.toggle`, plus React
  toolboxes). `tools/list` carries no toolbox descriptions.
- React tools time out on the device after 15 s. Frames over 5 MB are
  dropped by the device.
- The **JS-only socket sink** (`src/sinks/socket.ts`) ignores `mcp` frames and
  sends no client handshake. Such apps have no toolboxes in Beaver.
- iOS reconnects forever (1 s → 30 s backoff). Android's sink does not
  reconnect at all — after a drop it stays gone until the app is
  relaunched by hand (F5, bug hunt).

## 3. Wire side (D77)

### 3.1 Client handshake

- `ProtocolDecoder` decodes `type: "handshake"` from the client into
  `.clientHandshake(ClientHandshake)` with the six optional string fields.
  A handshake with none of them is still accepted (no fields to store).
- `BeaverApp.handleInbound` writes it to the connection's live session:
  - Migration `v10_device_identity`: `session.device_uid TEXT`,
    `session.app_package TEXT`. `Session` gets `deviceUID`, `appPackage`.
  - `LogStore.setSessionDeviceInfo` grows `deviceUID` and `appPackage`
    parameters, same `COALESCE` rule.
  - `model` → `device_model`, `version` → `app_version`; `platform`
    `"iOS 18.6"` is split on the first space into `platform` / `os_version`.
    All through `COALESCE`, so the `applicaster.v2` harvest, which arrives
    later, still wins where it has a value.
- `LiveDevices` keeps each connection's handshake until it disconnects. When
  the user deletes a live session, the replacement session for the same
  connection (`replaceDeletedLiveSessions`) gets the handshake written again —
  the SDK sends it only once per connection.
- **Following a restart** (D66/D73, `DeviceWait`): when both the ended and
  the new session have a `device_uid`, match on it. Otherwise keep today's
  fingerprint heuristic (its `ponytail:` comment now says it is the fallback
  for SDKs without a client handshake).

### 3.2 `DeviceMCPClient`

One per connection, created in `AppEnvironment` on `.connected(c)`, dropped
on `.disconnected(c)`. An actor in `Beaver/Transport/DeviceMCPClient.swift`.

- `request(method: String, params: JSON, timeout: Duration) async throws -> JSON`
  - Mints an integer JSON-RPC `id`, sends
    `{"type":"mcp","payload":{"jsonrpc":"2.0","id":n,"method":…,"params":…}}`
    through `WSServer.send(data:to:)` (a new raw-send next to
    `send(command:to:)`), and suspends until the reply with that `id`, the
    timeout, or the disconnect.
  - A JSON-RPC `error` → `DeviceMCPError.rpc(code, message)`; timeout →
    `.timeout`; disconnect while waiting → `.disconnected`. A request whose
    frame was never sent — `initialize` failed first, or the app
    disconnected while it waited its turn — → `.notSent(reason)`.
- `receive(_ payload: JSON)`: resumes the matching waiter; an unknown `id` is
  ignored.
- **Initialize once, lazily** — before the first request on the connection:
  `initialize` (5 s timeout), then the `notifications/initialized`
  notification. Only for an app that sent no handshake: if it times out,
  the client is marked `unsupported` and every later request fails at once
  with `.unsupported` until the app reconnects or sends a handshake. This
  keeps a JS-sink app from costing 5 s on every popover open. An app that
  sent a handshake has an MCP server, so it is never latched: a failed
  `initialize` fails that request with `.notSent` and the next one retries.
- Timeouts: `tools/list` 5 s, `tools/call` 20 s (the device's own React
  timeout is 15 s).
- `handleInbound`: a `mcp` frame goes to that connection's client and is
  **not** stored as an event. A frame with no `type` but a `jsonrpc` key is
  treated the same way (the SDK accepts bare JSON-RPC; Beaver never sends it,
  but this avoids a synthetic "unknown type" event if one ever arrives).
- `DeviceLink` (in `ToolContext.swift`) grows
  `func mcp(_ method: String, params: JSON, to sessionId: Int64, timeout: Duration) async throws -> JSON`.
  `AppEnvironment` implements it by looking up the connection
  (`live.connection(for:)`); the test fake answers from a script.

### 3.3 Toolboxes

A toolbox is the tool name's prefix before the first `.`
(`storage.set` → `storage`). A name without a dot goes to a toolbox named
`other`. `tools/list` is fetched **on every** `toolboxes_list` call and
popover open; there is no cache (React toolboxes come and go, the device
sends no `list_changed`, and the call is local and small).

Shared model, `Beaver/Domain/Toolbox.swift`:

```swift
public struct DeviceTool: Sendable, Equatable { name, description, inputSchema: JSON }
public struct Toolbox: Sendable, Equatable { name: String; tools: [DeviceTool] }
public enum Toolboxes { static func group(_ tools: [DeviceTool]) -> [Toolbox] }  // sorted by name
```

## 4. Default device (D76)

- `AppEnvironment.defaultDevice: DefaultDevice?`, in memory,
  `enum DefaultDevice { case uid(String), session(Int64) }`. It is `.uid`
  when the chosen session has a `device_uid`, otherwise `.session` (an app
  without a client handshake; such a default is lost on reconnect, and the
  error says so).
- `ToolContext.requireDevice(args)`, used by every live-device tool
  (`commands_send`, `commands_list`, `storage_*`, `devices_disconnect`,
  `toolboxes_list`, `tools_call`):
  1. `deviceId` given → that live session (as today; `"beaver"` is handled
     by the gateway tools before this);
  2. otherwise the default, if set → its live session. If it is set but not
     connected: fail, naming it and listing the connected devices, with
     `devices_set_default(deviceId: null)` and a `deviceId` example. Never
     fall through to another device silently;
  3. otherwise the only live device;
  4. otherwise fail with the list (as today).
- Reads without `sessionId` (`resolveSession`) are unchanged: the viewed
  session, else the newest. The default is only for talking to devices.
- `HostSnapshot` gains `defaultSessionId: Int64?` (the default resolved to
  its current live session) and `defaultDeviceLabel: String?` (for the error
  when it isn't connected).
- The user sets and clears it too (§6). A change posts to the journal as a
  system entry when it comes from the UI; an agent's call is journaled by the
  dispatcher as usual.

## 5. MCP (D75)

### 5.1 New tools (`Beaver/MCP/Tools/ToolboxTools.swift`)

| Tool | Kind | Arguments | Does |
|---|---|---|---|
| `devices_set_default` | change | `deviceId` (string or null) | Sets the default device; `null` clears it. `"beaver"` is refused: the default is for apps. |
| `toolboxes_list` | read | `deviceId?`, `toolbox?` | Without `toolbox`: each toolbox with its tool count and tool names. With `toolbox`: each tool's name, description and `inputSchema`. |
| `tools_call` | change | `deviceId?`, `name`, `arguments?` (object) | Calls one tool on the device and returns its answer. |

- `tools_call` result: `summary` = `"<name> on <device>: "` + the first line
  of the device's text (truncated to 200 chars); `body` = the full text;
  `structured` = `{deviceId, name, isError, afterId}` plus the app's
  `structuredContent` when it sent one, else its `text` (one copy; the body
  carries the text). For `deviceId: "beaver"`: `{deviceId, name, isError,
  text, structuredContent}`, with the inner tool's summary as `text` and its
  structured result as `structuredContent`.
  The device's `isError: true` becomes a `ToolError`:
  `"<name> failed on <device>: <text>. Example: toolboxes_list(toolbox: "<box>") for its arguments."`
  An unknown tool name fails with the closest names from `tools/list`.
- Errors from `DeviceMCPClient`: `.unsupported` → "This app doesn't answer
  MCP (it needs quick-brick-xray's native WebSocket sink)…";
  `.timeout` → says the call may still have run on the device;
  `.disconnected` → points at `beaver_status()`; `.notSent` → says nothing
  ran on the app and gives the same call to try again.
- `Next:` for `toolboxes_list` suggests `tools_call` with the first tool's
  name and an arguments skeleton from its schema; for `tools_call`, the
  `logs_wait` cursor as `commands_send` does.
- `commands_send` stays: `console.execute` overlaps with it, but
  `commands_send` also collects logs and follows a restart.

### 5.2 `deviceId: "beaver"`

- `toolboxes_list(deviceId: "beaver")` lists Beaver's own tools
  (`BeaverTools.all`) minus the three gateway tools, grouped by the name's
  prefix before the first `_`: `logs_query` → toolbox `logs`, tool
  `logs.query`; `beaver_status` → `beaver.status`;
  `devices_disconnect` → `devices.disconnect`.
- `tools_call(deviceId: "beaver", name: "logs.query", …)` maps the name back
  (first `.` → `_`) and runs that `MCPTool` directly with the same
  `ToolContext`. The dispatcher journals the `tools_call`; its summary is the
  inner tool's summary. Gateway tools can't be called through `"beaver"`, so
  there is no recursion.
- **Destructive tools are left out.** `toolboxes_list(deviceId: "beaver")`
  doesn't list a tool whose `kind` is `.destructive` (`sessions_delete`,
  `storage_delete`, `filters_delete`, …), and `tools_call(deviceId: "beaver",
  name: …)` refuses one, pointing at the direct call instead — through the
  gateway they would hide behind `tools_call`'s generic confirmation rather
  than their own name and annotations, so those stay reachable only by
  calling the tool itself.
- `"beaver"` is never the default and never needs to be connected.

### 5.3 Changed

- `beaver_status.devices[]` gains `default: Bool`, `uid`, `appPackage`.
  Beaver itself is **not** added to `devices` (agents count that array as
  connected apps; D65 keeps shapes stable): the existing `structured.beaver`
  object gains `deviceId: "beaver"`. Summary names the default device when
  one is set.
- `ToolSchema.deviceId` description: "Omit it to use the default device
  (devices_set_default), or the only connected one."
- `MCPServer.instructions`: one paragraph — apps' toolboxes are reached
  through `toolboxes_list` / `tools_call`; set a default with
  `devices_set_default` when several apps are connected.
- `BeaverTools.all` registers `ToolboxTools.all`.
- `Beaver/Resources/MCP.md`: Tools table rows; recipe "Use the app's
  toolbox" (`beaver_status` → `devices_set_default` → `toolboxes_list` →
  `toolboxes_list(toolbox:)` → `tools_call`); "Testing without Xcode": the
  app must be built with quick-brick-xray's native WebSocket sink (the JS
  sink has no toolboxes) — no Beaver setting to turn on.

## 6. UI

### 6.1 Device popover

`ToolbarDeviceBadge` (leading, read-only since D73) becomes a plain button
opening a popover (`.popover(arrowEdge: .bottom)`, like Bookmarks). The
context menu's "Copy device fingerprint" stays. New view
`Beaver/Features/Devices/DevicePopover.swift`. Its loading logic is
`ToolboxLoad.fetch(from:sessionId:)` in core (`Beaver/Domain/Toolbox.swift`),
because `Features/` is not built by `swift test`.

- **Header:** app name (`appName ?? appPackage ?? "Device #<id>"`) and
  version; `appPackage`; `model · platform OS`; the device uid, selectable
  with a copy button. Live or ended state with time.
- **Live session only:**
  - **Disconnect** (`env.disconnect(sessionId)`, as in the pill menu).
  - **Default for agents** toggle, bound to `env.defaultDevice`.
  - **Toolboxes:** fetched when the popover opens; a list of
    `name · N tools`. Selecting a toolbox shows its tools below in the same
    popover: name, description, and parameters from `inputSchema`
    (`name: type`, required marker, description; `enum` values listed).
    A refresh button re-fetches.
  - States: loading (spinner), none ("This app has no toolboxes"),
    unsupported ("This app doesn't answer MCP — needs quick-brick-xray's
    native WebSocket sink"), error with **Retry**.
- **Ended or imported session:** header only.
- Width ~360 pt, list scrolls at ~420 pt height.

### 6.2 Device menu

In `DeviceSwitcher` (the Connected pill), the default device's row shows a
small "Default" label after its name. No new actions there.

## 7. Docs and release

- `PROTOCOL.md`: §4.4 client `handshake` (fields, what Beaver stores); §3.3 /
  §4.5 `mcp` frames both ways (envelope, correlation by JSON-RPC id,
  timeouts, what Beaver does when there is no answer); §2 envelope type list;
  §10 open question: toolbox descriptions in `tools/list` (would let the
  popover and `toolboxes_list` describe toolboxes).
- `DECISIONS.md`:
  - **D75** Device toolboxes through a gateway; Beaver is device `"beaver"`.
  - **D76** One default device for agents, kept by the SDK's device id.
  - **D77** Beaver reads the client handshake; `device_uid` identifies a
    device across reconnects (D73's fingerprint heuristic becomes the
    fallback).
- `ARCHITECTURE.md`: `DeviceMCPClient` in the transport section.
- `CHANGELOG.md` `[Unreleased]`: the device popover with toolboxes and the
  default toggle; for agents, `devices_set_default`, `toolboxes_list`,
  `tools_call`, and `beaver_status.devices` fields.
- Merge title: `feat: device toolboxes over MCP, default device, device popover`.

## 8. Tests (Swift Testing)

- `ProtocolDecoder`: client handshake with all fields, with none, with extra
  fields; `mcp` frame; bare JSON-RPC frame.
- Store: migration `v10`; handshake then `applicaster.v2` → harvest wins
  where set, handshake fills the rest; `platform` split.
- `DeviceMCPClient` (fake sender): reply by id, replies out of order,
  JSON-RPC error, timeout, disconnect while waiting, `initialize` failure →
  `unsupported` without a second wait.
- `Toolboxes.group`: prefixes, dotless name → `other`, sorting.
- `DeviceWait`: follows a restart by `device_uid` with two identical builds
  connected (the case the heuristic got wrong).
- MCP (`MultiDeviceToolsTests` style, fake `DeviceLink`):
  - `requireDevice` order: explicit, default, only one, error; default set
    but gone → error, no fallback; default by uid carried to the new session.
  - `devices_set_default`: set, clear, `"beaver"` refused, unknown id.
  - `toolboxes_list`: grouped list; one toolbox with schemas; unsupported
    device; `"beaver"`.
  - `tools_call`: passes `name`/`arguments`, returns text and
    `structuredContent`; device `isError` → `ToolError`; timeout;
    `"beaver"` runs the mapped tool; a gateway tool through `"beaver"` is
    refused.
  - `beaver_status`: `default`, `uid`, `structured.beaver.deviceId`.
- Drift tests stay green (new tools in MCP.md's table and a recipe).
- UI: no snapshot tests; `ToolboxLoad.fetch` (loaded, empty, unsupported,
  timeout, disconnected) is covered with a fake link.

## 9. Risks

- **A device without a client handshake** (JS sink, old native SDK): no uid,
  so the default is lost on reconnect and the restart heuristic stays. The
  errors say so; nothing breaks.
- **`tools_call` timeout** doesn't mean the tool didn't run (e.g.
  `app.restart` kills the socket before replying). The error says so and
  points at `beaver_status()` / `logs_wait`.
- **Two agents** share one default. Accepted by the user; `deviceId` always
  wins.
- **Keychain tools** (`storage.*` on `secure`) are reachable by any agent
  connected to Beaver — the same exposure the device's own MCP already has
  on this socket (xray spec Decision 8). Agent Access (the app-menu switch)
  still gates the MCP server as a whole.
