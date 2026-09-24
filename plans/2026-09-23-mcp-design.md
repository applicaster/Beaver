# Beaver MCP — design

Status: design, awaiting review
Date: 2026-09-23
Scope: phase 1 (Beaver itself) in full; phase 2 (the app's toolbox through
Beaver) as a direction to be researched before it is planned.

Every choice below is a numbered decision in §12 (M1…M24), each with its
reason, the alternatives, and what changing it would touch. Sections refer to
them as *(M4)*. To change the design, change the decision and follow its
"to change" note. When the first implementation PR lands, accepted decisions
move to `DECISIONS.md` as D-numbers, and this file becomes the history.

---

## 1. Goal

An agent (Claude Code, Cursor, Codex, anything that speaks MCP) can do
everything a person can do in Beaver, and read everything Beaver has
collected: logs, network requests, storage snapshots, sessions, commands.
It works **in the background**. The agent never takes over the window, the
mouse or the keyboard. It changes what the window shows only when asked, and
brings it forward only when asked.

Phase 2 extends this to the app itself. The mobile SDK's Toolbox (Android on
`master`, iOS in
[Zapp-Frameworks#2864](https://github.com/applicaster/Zapp-Frameworks/pull/2864))
already answers MCP over the WebSocket that connects the app to Beaver, so
Beaver can relay the agent's calls to the app: `app.info`, `app.restart`,
`storage.*`, `debugFeatures.*`, `console.*`, and JS toolboxes.

### Success criteria

1. `claude mcp add --transport http beaver http://127.0.0.1:9081/mcp` is the
   whole client-side setup.
2. For every user-facing capability in Beaver there is a tool, and a test
   fails if the tool list and `MCP.md` disagree.
3. A typical debugging loop works with no human in it: send a command to the
   device → wait for the log line it causes → read the network request →
   check storage.
4. No tool call moves focus, activates Beaver, or changes what the person is
   looking at, unless the call says `reveal: true` (or, for `ui_show`, it is
   the call's purpose).

### Non-goals (phase 1)

- Driving the device's UI (taps, screens). The device's own toolbox may offer
  this later, in phase 2.
- Remote access. The server is loopback only *(M3)*.
- MCP resources, prompts, sampling and subscriptions *(M7)*.
- A second process or CLI *(M1)*.

---

## 2. Context — what already exists

| Piece | Where | Relevance |
|---|---|---|
| `LogStore` actor (GRDB) | `Beaver/Store/LogStore.swift` | Sessions, events + filter queries, facets, bookmarks, saved filters, storage snapshots, network entries. Almost every read tool is a thin wrapper around it. |
| `WSServer` actor | `Beaver/Transport/WSServer.swift` | Single device connection on :9080 (D2). `send(command:)` is the outbound path for commands and storage edits. |
| `AppEnvironment` | `Beaver/AppEnvironment.swift` | `@MainActor` state: current/viewing session, `activeFilter`, available commands, server state. |
| `MainWindow` | `Beaver/Features/MainWindow.swift` | Holds `selectedTab` and the three view models as `@State`, plus the import/export flows. |
| `Filter`, `NetworkFilter`, `StorageCommand`, `NetworkCopy`, `SessionExport`, `HARExport`, `EventJSON` | `Beaver/Domain`, `Beaver/Support` | Pure logic the tools reuse, so agent and UI behave identically. |
| SDK Toolbox + `McpServer` | quick-brick-xray, Android `toolbox/`, iOS #2864 | JSON-RPC 2.0, `2024-11-05`, tools named `logs.tail`, `storage.set`, `app.restart`… |
| SDK `WebSocketSink` `mcp` envelope | Android `sinks/WebSocketSink.kt`, iOS #2864 | Inbound `{"type":"mcp","payload":<JSON-RPC>}` is answered with `{"type":"mcp","payload":<response object>}` over the same socket Beaver owns. On connect the device sends `{"type":"handshake","deviceId","deviceName","model","platform","appPackage","version"}`. Today Beaver logs both as `unknown packet type`. |

Beaver runs outside the App Sandbox (see `Beaver.entitlements`), so tools can
read and write file paths the agent gives them.

---

## 3. Architecture

```
MCP client (Claude Code / Cursor / Codex)
        │  HTTP POST, JSON-RPC 2.0, http://127.0.0.1:9081/mcp
        ▼
┌─────────────────────────────────────────────────────────────┐
│ MCPHTTPListener   NWListener, loopback, Origin check  (M2,M3)│
└─────────────────────────────────────────────────────────────┘
        │  Data → Data?
        ▼
┌─────────────────────────────────────────────────────────────┐
│ MCPServer         initialize · ping · tools/list · tools/call│
│                   pure, owns no socket                       │
└─────────────────────────────────────────────────────────────┘
        │  name + arguments → ToolResult
        ▼
┌─────────────────────────────────────────────────────────────┐
│ BeaverTools       [MCPTool] — name, description, inputSchema,│
│                   annotations, async handler           (M8)  │
└─────────────────────────────────────────────────────────────┘
   │ LogStore (actor)   │ DeviceLink (WSServer)   │ AgentUI (@MainActor)
   ▼                    ▼                         ▼
 sessions, logs,     commands, storage.list,   tab, session, filter,
 network, storage,   storage edits,            selection, reveal
 bookmarks, filters  (phase 2: mcp relay)      (implemented by AppEnvironment)
```

### 3.1 Files

| File | Target | Role |
|---|---|---|
| `Beaver/MCP/MCPServer.swift` | BeaverCore | JSON-RPC dispatch, protocol-version negotiation *(M21)*, `instructions` *(M13)* |
| `Beaver/MCP/MCPHTTPListener.swift` | BeaverCore | Minimal HTTP/1.1 over `NWListener`: `POST /mcp`, `GET` → 405, Origin check, `Content-Length` bodies |
| `Beaver/MCP/MCPTool.swift` | BeaverCore | `MCPTool`, `ToolResult`, a small JSON Schema builder, argument decoding helpers |
| `Beaver/MCP/BeaverTools.swift` | BeaverCore | The catalog in §5, one `static func` per group |
| `Beaver/MCP/ToolContext.swift` | BeaverCore | `ToolContext { store, device: DeviceLink, ui: AgentUI, clock }` plus the `DeviceLink` and `AgentUI` protocols *(M14, M15)* |
| `Beaver/MCP/AgentAccess.swift` | BeaverCore | The only entry point the app calls: `isAllowed` (build + policy + user), `start(env:)`, `stop()` *(M24)* |
| `Beaver/AppEnvironment.swift` | app | Conforms to `AgentUI`; gains `selectedTab`, `selection`, `reveal()` *(M12)* |
| `Beaver/BeaverApp.swift` | app | Starts and stops the listener with the menu toggle *(M4, M22)* |
| `MCP.md` | repo root | Tool reference + usage rules, the source of truth for agents and humans *(M13)* |

### 3.2 A separate, switchable feature *(M4, M24)*

Agent Access is a feature of its own, not part of Beaver's core. It can be
turned off for a customer build, for a machine, or by the person using it:

| Level | Who uses it | How | Effect |
|---|---|---|---|
| **Build** | us, for a customer build | the `BEAVER_AGENT_ACCESS` Swift compilation condition (set in the default build) | Without it, `Beaver/MCP/` is not compiled: no listener, no menu items, no code in the binary |
| **Policy** | IT / us, per machine or per customer | managed preference `AgentAccessPolicy` = `disabled` (configuration profile, or `defaults write com.applicaster.LoggerNext AgentAccessPolicy disabled`) | The server never starts and the menu items are hidden. A forced (profile-managed) value cannot be changed by the user |
| **User** | the person | "Agent Access (MCP)" toggle in the app menu (`@AppStorage("agentAccessEnabled")`) | Starts and stops the listener immediately |

The server runs only if all three allow it. The rest of the app never
imports anything from `Beaver/MCP/`. It talks to one entry point,
`AgentAccess.start(env:)` / `.stop()`, called from `BeaverApp`. So the build
flag wraps exactly one call site plus the menu items, and removing the
feature is deleting a folder. The UI state that moves into `AppEnvironment`
(§7) is plain app state and stays either way.

### 3.3 Concurrency

- `MCPHTTPListener` accepts on its own queue and handles each request in a
  `Task`. A long `logs_wait` never blocks other calls.
- `MCPServer` is `Sendable` and stateless. Handlers are `async` and reach
  `LogStore` and `WSServer` through their actors, and `AgentUI` on the main
  actor. This keeps ARCHITECTURE.md §3: no shared mutable state, no
  `DispatchQueue.main`.
- Stopping the listener cancels in-flight tasks. A cancelled `logs_wait`
  returns what it has.

---

## 4. Transport

*(M2, M3, M21)*

- `POST /mcp` with one JSON-RPC message (batches are not supported; they were
  removed from MCP in 2025-06-18).
  - Request → `200`, `Content-Type: application/json`, the response object.
  - Notification or response (no `id`) → `202`, empty body.
- `GET /mcp` → `405` (no server-initiated stream). `DELETE` → `405`.
- No `Mcp-Session-Id`: the server is stateless. Nothing a tool does depends on
  earlier calls in the same MCP session.
- **Origin.** If an `Origin` header is present and is not `http://localhost…`,
  `http://127.0.0.1…` or `null`, the request is rejected with `403`. This is
  the DNS-rebinding defense the MCP spec asks for. There are no
  `Access-Control-*` headers.
- Body limit 4 MB in; responses are capped by the tools themselves (§6).
- Bind failure (port taken) → the menu item shows "MCP: port 9081 in use", and
  `os_log` records it. The port can be overridden with
  `defaults write com.applicaster.LoggerNext mcpPort -int <port>`.

---

## 5. Tool catalog (phase 1)

Conventions for every tool:
- `sessionId` is optional. If omitted, the live session is used when a device
  is connected, otherwise the session being viewed, otherwise the most recent
  one. The result always says which session was used *(M9)*.
- `filter` is the same object everywhere logs are filtered: `minLevel`,
  `search`, `searchIsRegex`, `exclude`, `excludeIsRegex`, `searchPayloads`,
  `subsystems[]`, `excludeSubsystems[]`, `categories[]`,
  `excludeCategories[]`. It maps 1:1 onto `Filter`, so agent and UI results
  match *(M10)*.
- R = `readOnlyHint`, D = `destructiveHint`, I = `idempotentHint`, W = writes
  but not destructive.

### 5.1 Status

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `beaver_status` | — | Beaver version; WS state (`listening` / `clientConnected` / `failed(reason)`); `ws://` URLs for the device to connect to; connected device fingerprint (app, version, model, platform, OS); live and viewed session ids; MCP port | R |

### 5.2 Sessions

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `sessions_list` | `limit` (default 20), `source` (`live`/`imported`/any) | id, started/ended, source, device fingerprint, event and request counts | R |
| `sessions_delete` | `sessionId` or `all: true` | what was deleted | D |
| `sessions_import` | `path` (Beaver/zapp-support JSON or HAR) | new session id, event and request counts | W. Same decoder as the Import menu (`EventJSON.decodeExport`, `HARExport.decode`); follows `SESSION_FILE_FORMAT.md` |
| `sessions_export` | `sessionId`, `path`, `format` (`json` default, `har`), optional `filter` (JSON only: filtered export) | path written, counts | W. Same writers as the Export menu (`SessionExport`, `HARExport`) |

### 5.3 Logs

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `logs_facets` | `sessionId`, `filter` | counts per level, subsystem and category under the other facets (same as `LogStore.facetCounts`) | R |
| `logs_query` | `sessionId`, `filter`, `afterId`, `beforeId`, `limit` (default 100, max 500), `order` (`newest` default / `oldest`), `includeData` (default false) | one line per event, `#<id> HH:mm:ss.SSS LEVEL subsystem/category: message`; `total` matching; `nextCursor` | R |
| `logs_get` | `ids[]` (max 50) | full events with `data` and `context` JSON; payloads over 256 KB truncated with a `truncated` flag | R |
| `logs_wait` | `sessionId`, `filter`, `afterId` (default: latest id now), `timeoutMs` (default 15 000, max 60 000), `limit` | the matching events that arrived, or `timedOut: true` | R. Long-poll on `LogStore.changes()` *(M11)* |
| `logs_clear` | `sessionId` | the watermark event id | W. Same as the toolbar's Clear: hides events up to now via `hiddenThroughEventId`, deletes nothing |

### 5.4 Network

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `network_query` | `sessionId`, `method[]`, `status` (`errors`, `2xx`…`5xx`, `noStatus`, or codes), `host[]`, `search`, `afterId`, `limit` (default 100, max 500) | one line per request: `#<id> METHOD status duration size url` | R. Reuses `NetworkFilter` |
| `network_get` | `id`, `includeBodies` (default true) | method, url, status, timing, headers, bodies (with `truncated` flags as the SDK sent them) | R |
| `network_copy` | `id`, `format` (`curl` / `fetch` / `json`) | the text the Copy menu produces, plus the same warnings (redacted headers, truncated body) | R |

### 5.5 Storage

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `storage_snapshot` | `refresh` (default true), `layer` (`session`/`local`/`secure`/all), `timeoutMs` (default 5 000) | per layer: namespace → key → value, and `takenAt`. `refresh` sends `storage.list` and waits for a snapshot newer than the call | R. With `refresh: false` it reads the latest stored snapshot, and works offline and on imported sessions |
| `storage_set` | `layer`, `key`, `value`, `namespace` (default `applicaster.v2`) | `applied` / `notApplied` / `rejected(reason)` | W. Same validation (`StorageCommand.valueProblem`: no whitespace, no empty values) and the same read-back check as the Storages screen *(M16)* |
| `storage_delete` | `layer`, `key`, `namespace` | `applied` / `notApplied` | D |

### 5.6 Commands

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `commands_list` | `refresh` (default false: resend `cmdlist`) | name, syntax, description, group — the merged list the command bar shows | R |
| `commands_send` | `command`, `collectLogsMs` (default 0, max 30 000) | sent; if `collectLogsMs > 0`, the events that arrived in that window | W. Recorded in command history like a typed command |

### 5.7 Bookmarks and saved filters

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `bookmarks_list` | `sessionId` | bookmarked events and requests | R |
| `bookmarks_set` | `eventId` or `networkId`, `on` | new state | W, I |
| `filters_list` | — | saved filters | R |
| `filters_save` | `name`, `filter` | saved filter id (upsert by name) | W, I |
| `filters_delete` | `name` | deleted | D |

### 5.8 UI (background by default) *(M12)*

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `ui_state` | — | tab, viewed session, active filter, selected event or request, whether the window is key | R |
| `ui_show` | any of `tab` (`logs`/`network`/`storages`), `sessionId`, `filter`, `selectEventId`, `selectNetworkId`, `reveal` (default false) | the resulting `ui_state` | W. Without `reveal` the window updates in place and nothing takes focus |

Twenty-five tools. Adding a user-facing capability to Beaver means adding or
extending one of them (§9).

---

## 6. Output conventions

*(M10)*

- Every result has a `text` content block written for an agent to read
  (compact, one line per row, ids first), plus `structuredContent` with the
  same data as JSON. Clients that read either get the same thing.
- Hard caps keep a call from flooding the agent's context: `limit ≤ 500` rows,
  message text cut at 500 characters in list views, payloads only through
  `logs_get` / `network_get`, and each payload capped at 256 KB with
  `truncated: true`.
- Pagination is a cursor by row id (`afterId` / `beforeId` / `nextCursor`), not
  offset, so rows arriving while the agent pages do not shift pages.
- Errors follow MCP: a tool that fails returns `isError: true` with a sentence
  saying what to do ("No device connected — ask the user to open remote
  assistance on the device, or pass sessionId to read a past session"). Only
  malformed JSON-RPC gets a protocol error (`-32700`, `-32600`, `-32601`,
  `-32602`).

---

## 7. Background UI model

*(M12)*

Today `MainWindow` owns `selectedTab` and the selection as `@State`, so nothing
outside the view can change them. The change:

1. `AppEnvironment` gets `selectedTab`, `selection` (`.event(id)` /
   `.network(id)` / `nil`) and a `revealRequest` counter. `activeFilter` and
   `viewingSessionId` already live there.
2. `MainWindow` binds to those instead of its own `@State`. The view models
   already rebuild on `env.viewingSessionId` changes and read
   `env.activeFilter`, so no view model logic changes. A new selection scrolls
   to the row the way a bookmark jump does today.
3. `reveal()` brings the window to the front and activates the app
   (`NSApp.activate()`, `makeKeyAndOrderFront`). It is the only path that
   takes focus, and only `ui_show(reveal: true)` calls it.

No Accessibility API, no synthetic events, no AppleScript: the agent changes
state and SwiftUI renders it, whether the window is visible, behind other
windows, or minimized.

---

## 8. Teaching agents to use it

*(M13)*

Three layers, each covering what the others cannot:

1. **Server `instructions`** (returned by `initialize`, shown to the model by
   every mainstream client). Travels with the server, so an agent working in
   an app repo gets it with no setup. Draft:

   > Beaver is a macOS log viewer connected to one mobile app over WebSocket.
   > Start with `beaver_status`: if no device is connected, the user must
   > open remote assistance on the device, and you can still read past
   > sessions. Omitted `sessionId` means the live session, else the viewed one.
   > Discover before filtering: call `logs_facets` before `logs_query`,
   > because subsystem names are namespaced strings you will not guess. To
   > see what a device action causes, note the latest id, act
   > (`commands_send`, `storage_set`), then `logs_wait` with `afterId`.
   > Network bodies are capped at 100 KB by the SDK and headers such as
   > Authorization are redacted, so a replayed cURL may fail. Storage values
   > cannot contain spaces through `storage_set`. Work in the background:
   > use `ui_show` only to point the user at something, and `reveal: true`
   > only when they ask to see it.

2. **Tool and parameter descriptions**: what each does, defaults, limits.

3. **`MCP.md`**: the same catalog as §5 for humans, the usage rules above, and
   the connection instructions per client. The drift test (§10) keeps it
   honest.

A `SKILL.md` is not shipped. The `instructions` string already reaches every
client; add a skill only if agents are seen misusing the tools in ways
instructions cannot fix.

---

## 9. Keeping the MCP in step with Beaver

*(M20)*

Added to `CLAUDE.md` in the first implementation PR:

```markdown
## MCP — every capability has a tool

Beaver ships an MCP server (`Beaver/MCP/`, reference in `MCP.md`) so agents
can do everything a person can do in the app. It is part of the product, not
an add-on:

1. A change that adds, removes or changes a user-facing capability (a menu
   item, a toolbar action, a filter, an export, a new wire frame, a new column
   of data) updates the matching tool in `Beaver/MCP/BeaverTools.swift` in the
   same PR, or adds one.
2. Update `MCP.md` (tool table + usage rules) and, if agents need to know it
   to use the tool correctly, the server `instructions` in `MCPServer.swift`.
3. `swift test` includes a drift test: every registered tool must be in
   `MCP.md` and every tool in `MCP.md` must be registered.
4. Tools work in the background: never activate the app or take focus
   unless the call has `reveal: true`.
5. Agent Access stays a separate feature: code outside `Beaver/MCP/` never
   imports from it, and the app must build and pass tests without the
   `BEAVER_AGENT_ACCESS` flag.
6. Mention agent-visible changes in `CHANGELOG.md` `[Unreleased]`.
```

The drift test is what enforces rule 3. Rules 1–2 rest on review, with the
test catching the most common miss (a new tool nobody documented, or a
documented tool that was renamed).

---

## 10. Testing

Swift Testing, `swift test`, no device and no app host:

| Test | What it proves |
|---|---|
| `MCPServerTests` | `initialize` negotiates the version and returns `instructions`; `tools/list` schemas are valid JSON Schema; `tools/call` on an unknown tool → `isError`, never a crash; notifications return nothing; malformed JSON → `-32700` |
| `MCPHTTPListenerTests` | one real loopback round-trip with `URLSession`; notification → 202; foreign `Origin` → 403; `GET` → 405 |
| `BeaverToolsTests` | each group against `LogStore(databaseURL: .inMemory)` and a `FakeDeviceLink`: filter mapping equals the UI's `Filter`; pagination cursors; `logs_wait` returns on append and times out; `storage_set` rejects whitespace, reports `applied` / `notApplied` from the read-back; session resolution order *(M9)* |
| `AgentAccessPolicyTests` | the server starts only when build, policy and user all allow it; a forced policy value hides the toggle |
| CI build without `BEAVER_AGENT_ACCESS` | the app still compiles, i.e. nothing outside `Beaver/MCP/` depends on it |
| `MCPDocDriftTests` | the tool names in `MCP.md`'s tables equal the registered names |
| `AgentUITests` (app target, existing UI-test target) | `ui_show` without `reveal` leaves another app frontmost; with `reveal` Beaver becomes active |

---

## 11. Phase 2 — the app's toolbox through Beaver (direction, to research)

*(M18, M19)*. Not planned yet; this section records the direction so the
phase 1 code does not block it.

**Why it is cheap.** The device already runs an MCP server behind the same
WebSocket Beaver owns. Beaver only has to speak the `mcp` envelope and
correlate replies. The npm "host-side bridge" in #2864's spec becomes
unnecessary for anyone running Beaver.

**Shape.**

1. `ProtocolDecoder` learns two inbound types:
   - `handshake` (device → Beaver): `deviceId`, `deviceName`, `model`,
     `platform`, `appPackage`, `version` → `LogStore.setSessionDeviceInfo`.
     This also stops the `unknown packet type: handshake` line in the feed.
   - `mcp`: a JSON-RPC response for a pending call.
2. `DeviceToolbox` actor: `call(method, params, timeout) async throws -> JSON`.
   It rewrites JSON-RPC ids to its own counter, keeps a pending map, times out
   after 20 s (the iOS React bridge blocks up to 15 s), and fails every pending
   call when the device disconnects. `initialize` runs lazily on first use per
   connection.
3. Two Beaver tools, not a mirror of the device's list:
   - `app_tools_list` → the device's `tools/list`, verbatim (names keep
     their dots: `storage.set`, `app.restart`, …), or a clear error: no
     device, or a device whose SDK has no toolbox (no answer to
     `initialize` within the timeout).
   - `app_tools_call(name, arguments)` → the device's `tools/call` result,
     verbatim.
4. `PROTOCOL.md` gains §3.3 `mcp` (server → client), §4.4 `handshake` and
   §4.5 `mcp` (client → server).
5. Server `instructions` gain: prefer Beaver's `logs_*` over the device's
   `logs.*` (Beaver has the whole persisted session; the device only has its
   in-memory buffer); prefer the device's `storage.set` over `storage_set`
   when present, because it takes a real JSON value and so has no
   whitespace limit.

**To research before planning.**
- iOS parity: which providers exist on iOS after #2864 (only `logs.*` and
  JS toolboxes today) versus Android (`storage.*`, `app.*`, `console.*`,
  `debugFeatures.*`).
- What `app.restart` / `app.killProcess` do to the WebSocket, and whether the
  reconnect lands in the same Beaver session or a new one (today: new).
- Whether JS toolboxes (`RemoteToolProvider`, e.g. OAuth2, player) need
  longer timeouts than 20 s.
- Whether the device's tool list changes during a connection (JS toolboxes
  registering late). If yes, `app_tools_list` re-queries on every call rather
  than caching.

---

## 12. Decisions

Each decision: what, why, alternatives, and what changing it touches.

### M1. The MCP server lives inside Beaver.app
- **Why:** only the running app has the live WebSocket to the device (commands,
  storage, phase 2), the live UI state (`ui_*`), and the actors that already
  serialize access to the store.
- **Alternatives:** (a) a stdio CLI reading `store.sqlite` read-only: works
  without Beaver running, but cannot send anything to the device or touch the
  UI, and adds a second writer-adjacent process on the database; (b) both.
- **To change:** a stdio shim can be added later as a thin proxy to the HTTP
  endpoint, without changing tools.

### M2. Transport: stateless Streamable HTTP, POST only
- **Why:** every mainstream client supports HTTP servers directly
  (`claude mcp add --transport http …`). Stateless POST is a small amount of
  code on `NWListener`, which the project already uses, and matches what the
  SDK ships on the device.
- **Alternatives:** full Streamable HTTP with an SSE stream and sessions (needed
  only for server-initiated messages: `list_changed`, progress, log push);
  stdio (impossible for an app that is already running).
- **To change:** adding `GET` + SSE is additive; tools are unaffected.

### M3. Loopback only, port 9081, Origin check, no auth token
- **Why:** agents run on the same Mac. Loopback plus an Origin check blocks
  other machines and browser pages (DNS rebinding). A token would add setup
  steps for every client while protecting only against local processes,
  which already run as the user.
- **Alternatives:** bind all interfaces (remote agents; exposes device data
  to the LAN); bearer token in the client config.
- **To change:** a token is an extra header check plus a "Copy setup command"
  that includes it.

### M4. On by default in our build; user toggle in the app menu
- **Why:** agreed with the user (2026-09-23). The value is in agents finding it
  with no setup; the risk is bounded by M3. The toggle is the "User" level of
  M24.
- **Alternatives:** opt-in toggle.
- **To change:** flip the `@AppStorage` default.

### M24. Agent Access is a separate feature with three off switches
- **Why:** the user asked (2026-09-23) that it can be switched off for
  customers or at will. Beaver ships one Sparkle build to everyone, so a
  customer build needs a compile-time switch, and machines we don't build for
  need a policy that users can't override. The one `AgentAccess` entry point
  keeps the rest of the app unaware of MCP (§3.2).
- **Alternatives:** runtime toggle only (can't guarantee "off" for a
  customer); a separate app or plugin bundle (a second product to sign,
  notarize and update); remote config (needs a backend Beaver doesn't have).
- **To change:** each level is independent; dropping one removes one check in
  `AgentAccess.isAllowed`.

### M5. Destructive tools are allowed; the client confirms
- **Why:** agreed with the user. MCP clients already ask before calling a tool
  (Claude Code's permission prompt), and `destructiveHint` tells them which
  ones deserve care. A second confirmation inside Beaver would steal focus,
  which contradicts M12.
- **Alternatives:** a "Allow destructive agent actions" setting; per-call
  confirmation in Beaver.
- **To change:** the handler checks one setting before running any tool with
  `destructiveHint`.

### M6. Tool names are `group_verb` with underscores
- **Why:** the Claude API restricts tool names to `[a-zA-Z0-9_-]`, and clients
  prefix server names (`mcp__beaver__logs_query`). Dots work in some clients
  and not others.
- **Alternatives:** dots, like the SDK (`logs.tail`).
- **To change:** a rename is a breaking change for agents' saved permissions,
  so do it before release or not at all.

### M7. Tools only: no resources, prompts or subscriptions
- **Why:** tools are the one primitive every client supports well. Resources
  and subscriptions would duplicate `*_get` and `logs_wait`, and
  subscriptions need the SSE stream M2 leaves out.
- **To change:** additive.

### M8. One tool per capability, grouped (25 tools)
- **Why:** agents choose better between named, narrow tools than between
  modes of one giant tool. 25 is well within what clients handle.
- **Alternatives:** a few "god tools" (`query(kind, …)`); one tool per UI
  control (hundreds).
- **To change:** merge within a group; the drift test and `MCP.md` follow.

### M9. Default session: live → viewed → most recent
- **Why:** matches what a person means by "the logs" when a device is
  connected, and still works offline or on imported sessions. Echoing the
  chosen id prevents silent confusion.
- **To change:** one function, `ToolContext.resolveSession`.

### M10. Results: text + `structuredContent`, hard caps, id cursors, filter = `Filter`
- **Why:** text is what models read best; structured data is there for clients
  and scripts. Caps protect the agent's context from a 100k-event session.
  Id cursors are stable while events stream in. Reusing `Filter` means the
  agent and the UI can never disagree on what a filter matches.
- **To change:** caps are constants in `BeaverTools.swift`.

### M11. `logs_wait` is a long-poll with a timeout ≤ 60 s
- **Why:** the "act, then observe" loop is the most common agent pattern here.
  Long-poll needs no push channel (M2) and uses `LogStore.changes()`, which
  already exists.
- **Alternatives:** the agent polls `logs_query` in a loop (slower, noisier);
  resource subscriptions (need SSE).
- **To change:** the max is a constant; client-side tool timeouts
  (e.g. Claude Code's `MCP_TOOL_TIMEOUT`) must stay above it.

### M12. Background UI: agents change state, never input
- **Why:** agreed with the user. The agent configures Beaver without
  interrupting the person; the window reflects the change whenever it is
  looked at. `reveal` is explicit.
- **How:** tab, selection and a reveal counter move from `MainWindow`'s
  `@State` to `AppEnvironment` (§7).
- **Alternatives:** Accessibility / synthetic clicks (takes over the mouse,
  needs a TCC grant, breaks on any layout change); no UI tools.
- **To change:** the `AgentUI` protocol is the boundary; new UI tools add
  members to it.

### M13. Agent guidance: `instructions` + descriptions + `MCP.md`; no skill file
- **Why:** `instructions` reach every client with no setup, including agents
  working in the app repos rather than this one. `MCP.md` is for humans and
  review. A skill would be a third copy to keep in sync.
- **To change:** add `.claude/skills/beaver/SKILL.md` if agents show misuse
  that instructions do not fix.

### M14. MCP code lives in `BeaverCore`; UI is reached through a protocol
- **Why:** `swift test` covers the server, listener and every tool headlessly.
  `AgentUI` has one live implementation (`AppEnvironment`) and one fake, and
  exists because `AppEnvironment` is excluded from the SPM target.
- **To change:** nothing else depends on the split.

### M15. Tools reach the device through `DeviceLink`, implemented by `WSServer`
- **Why:** storage and command tools need a fake device in tests. The protocol
  is two methods: `send(command:)`, and in phase 2 `send(mcp:)`.
- **To change:** adding a method adds it to `WSServer` and the fake.

### M16. `storage_set` / `storage_delete` behave exactly like the Storages screen
- **Why:** same wire limitation (no quoting, PROTOCOL.md §3.2), same
  read-back verification. The agent gets the same honest "device didn't
  apply this" as a person.
- **To change:** shared code in `StorageCommand`; both paths move together.

### M17. Audit: toasts and `os_log`, not the event log
- **Why:** the person should see what an agent changed ("Agent deleted session
  #12") without focus moving. That rules out alerts but allows the existing
  `ToastCenter`, which shows in the window without activating it. Writing
  agent actions into the session's events would end up in exports sent to
  customers and zapp-support.
- **Alternatives:** synthetic `beaver.agent` events; an "Agent activity" panel.
- **To change:** one call site in the tool dispatcher.

### M18. Phase 2 exposes the device through two generic tools
- **Status:** deferred to phase 2; not reviewed yet.
- **Why:** the device's tool set differs per platform, SDK version and
  connection. Mirroring it as individual Beaver tools needs
  `notifications/tools/list_changed`, which needs the SSE stream M2 leaves
  out, and clients handle a changing list unevenly. `app_tools_list` +
  `app_tools_call` work in every client today.
- **Alternatives:** dynamic mirroring as `app_<name>` tools.
- **To change:** needs M2's SSE extension first.

### M19. Phase 2 speaks the existing WS `mcp` envelope and rewrites JSON-RPC ids
- **Status:** deferred to phase 2; not reviewed yet.
- **Why:** it is what both SDKs already implement (Android #2848, iOS #2864),
  so there is no SDK change. Rewriting ids keeps two agents' calls from
  colliding on one device connection.
- **Alternatives:** Beaver dials the device's HTTP listener on :11434 (needs
  `adb forward` / `iproxy`, and does not reach a real iPhone over Wi-Fi).
- **To change:** `DeviceToolbox` is the only place that knows the envelope.

### M20. `CLAUDE.md` rule + drift test keep the MCP in step with the app
- **Why:** agreed with the user. A rule alone decays; the drift test catches
  the most common miss mechanically. The text is in §9.
- **To change:** edit `CLAUDE.md` and the test together.

### M21. Protocol versions: `2025-06-18`, `2025-03-26`, `2024-11-05`
- **Why:** echo the client's requested version if supported, else answer the
  newest. The subset used here (tools, text + structured content,
  annotations) exists in all three. `structuredContent` is omitted for
  clients older than `2025-06-18`.
- **To change:** a list constant in `MCPServer`.

### M22. Settings live in the app menu, not a Settings window
- **Why:** Beaver has no Settings scene. Two items cover it: "Agent Access
  (MCP)" (toggle, with the port and state in the title) and "Copy MCP Setup
  Command" (copies the `claude mcp add …` line).
- **To change:** move to a `Settings` scene if more settings appear.

### M23. This spec lives in `plans/`; decisions migrate to `DECISIONS.md`
- **Why:** `docs/` is the GitHub Pages site (appcast), so anything there is
  published. `plans/` already holds specs and plans. `M` numbers avoid
  colliding with D-numbers other branches may take.
- **To change:** renumber on migration.

---

## 13. Delivery

Each step is a PR that releases on merge (see `CLAUDE.md`), so each must stand
on its own.

1. **Core + read tools.** `MCPServer`, listener, menu items, `beaver_status`,
   `sessions_list`, `logs_*`, `network_*`, `storage_snapshot(refresh:false)`,
   `commands_list`, `bookmarks_list`, `filters_list`, `MCP.md`, the drift test,
   the `CLAUDE.md` rule, D-number migration of M1–M17 and M20–M24. `AgentAccess` entry point with all three off switches (M24) and the no-flag CI build.
2. **Actions.** `commands_send`, `storage_snapshot(refresh:true)`,
   `storage_set/delete`, `sessions_import/export/delete`, `logs_clear`,
   `bookmarks_set`, `filters_save/delete`, toasts (M17).
3. **UI.** State move (§7), `ui_state`, `ui_show`.
4. **Phase 2 research** (§11), then its own spec update and plan.

## 14. Open questions

1. Should `commands_send` refuse commands that would close the WebSocket
   (e.g. a device restart) unless the agent passes `expectDisconnect: true`?
   Default in this spec: no, just send it.
2. Is 9081 free of conflicts with other Applicaster tooling? (The SDK uses
   11434 on the device and 9080 for Beaver.)
3. ~~How do customers get Beaver?~~ **Answered (2026-09-23):** the same
   build, downloaded from
   `https://github.com/applicaster/Beaver/releases/latest/download/Beaver.zip`.
   So phase 1 ships Agent Access to customers too, on by default. That is
   accepted for phase 1: the server is loopback only and reads only data
   already on the customer's own Mac. How to keep information from customers
   is discussed in phase 2 or 3, when the device toolbox makes the stakes
   higher. M24's build level is not used until then.
