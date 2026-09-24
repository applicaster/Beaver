# Beaver MCP — design

Status: design, awaiting review
Date: 2026-09-23
Scope: phase 1 (Beaver itself) in full; phase 2 (the app's toolbox through
Beaver) as a direction to be researched before it is planned.

Every choice below is a numbered decision in §12 (M1…M28), each with its
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
5. Everything the agent did is visible in Beaver's agent activity journal,
   and the journal signals new entries without taking focus.
6. Someone with only the downloaded `Beaver.zip` and no Xcode can turn Agent
   Access on and off, connect an agent, test it, and report what happened
   *(M27)*.

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
        │  every call recorded by the dispatcher
        ├──────────────────────────────► AgentJournal → agent_activity table
        │                                 → Agent panel, toolbar + Dock badge
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
| `Beaver/MCP/AgentJournal.swift` | BeaverCore | Records every tool call, agent notes and system entries; unseen count *(M17)* |
| `Beaver/Store/Schema.swift` | BeaverCore | One migration: the `agent_activity` table (§7.2) |
| `Beaver/Features/AgentActivity/AgentActivityView.swift` | app | The Agent panel (inspector), toolbar button with badge, Dock badge *(M17)* |
| `Beaver/Features/AgentActivity/AgentNotifier.swift` | app | `UNUserNotificationCenter`: permission state, the prompt, System Settings deep link, coalescing, click → reveal and show *(M28)* |
| `Beaver/MCP/AgentAccess.swift` | BeaverCore | The only entry point the app calls: `start(env:)`, `stop()`. The future access check goes here *(M24)* |
| `Beaver/AppEnvironment.swift` | app | Conforms to `AgentUI`; gains `selectedTab`, `selection`, `reveal()` *(M12)* |
| `Beaver/BeaverApp.swift` | app | Starts and stops the listener with the menu toggle *(M4, M22)* |
| `MCP.md` | repo root | Tool reference + usage rules, the source of truth for agents and humans *(M13)* |

### 3.2 A separate feature, open in phase 1 *(M4, M24)*

Agent Access is a feature of its own, not part of Beaver's core:
- The rest of the app uses nothing from `Beaver/MCP/` or
  `Beaver/Features/AgentActivity/` except three touch points: `AgentAccess.start(env:)` /
  `.stop()` called from `BeaverApp`, the menu items, and the Agent toolbar
  button in `MainWindow`. Removing the feature is deleting two folders and
  those three touch points.
- **Phase 1: access is open.** It is on for everyone who runs Beaver, including
  customers (same `Beaver.zip`). The only switch is the "Agent Access (MCP)"
  toggle in the app menu, on by default, for a person who wants it off.
- The UI state that moves into `AppEnvironment` (§7.1) is plain app state, and
  the `agent_activity` table is created in every build.

**To decide later — access control for customers** *(M24)*. Deliberately left
open (agreed 2026-09-23): phase 1 ships open, testing happens on PR builds
*(M27)*, and nobody outside the team knows the feature exists until we say so.
It must be settled before phase 2, when the agent can also control the app.
Options on the table:
- a build flag (`BEAVER_AGENT_ACCESS`) and a separate customer build;
- a `defaults` key (`AgentAccessPolicy`), settable by a person, an agent or a
  configuration profile. Not an environment variable: an app started from
  Finder or the Dock does not see the shell's environment;
- off by default for everyone, turned on by the team with that key;
- a token in the client config.

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
- The `User-Agent` header (e.g. `claude-code/2.1`) is recorded as the client
  name in the journal. Nothing else identifies a caller.
- Body limit 4 MB in; responses are capped by the tools themselves (§6).
- Bind failure (port taken) → the menu item shows "MCP: port 9081 in use", and
  `os_log` records it. The port can be overridden with
  `defaults write com.applicaster.LoggerNext mcpPort -int <port>`.

---

## 5. Tool catalog (phase 1)

Conventions for every tool:
- `sessionId` is optional *(M9, M26)*:
  - **Omitted: follow the device.** The live session is used when a device is
    connected, otherwise the session being viewed, otherwise the most recent
    one. A waiting call (`logs_wait`, `commands_send` with `collectLogsMs`)
    that sees the device disconnect and reconnect carries on in the new
    session and reports `sessionChanged: {from, to}`.
  - **Given: pinned.** If that session ends during a wait, the call returns
    `sessionEnded: true` and the new live session id if one appeared.
  - A device that has not come back when the wait ends →
    `deviceDisconnected: true`.
  - The result always says which session was used.
- `deviceId` is optional on every tool that talks to a live device. Today
  there is at most one device (D2). If there are ever several, a call that
  needs a live device and has neither `sessionId` nor `deviceId` fails with the
  list of devices instead of guessing *(M25)*.
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
| `beaver_status` | — | Beaver version; WS state (`listening` / `clientConnected` / `failed(reason)`); `ws://` URLs for the device to connect to; `devices: [...]` — each with id, fingerprint (app, version, model, platform, OS) and live session id; an array even though D2 allows one *(M25)*; viewed session id; MCP port; `notifications` state *(M28)* | R |

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
| `logs_wait` | `sessionId`, `filter`, `afterId` (default: latest id now), `timeoutMs` (default 15 000, max 60 000), `limit` | the matching events that arrived, or `timedOut: true`; plus `sessionChanged` / `sessionEnded` / `deviceDisconnected` when they happen *(M26)* | R. Long-poll on `LogStore.changes()` *(M11)* |
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
| `commands_send` | `command`, `collectLogsMs` (default 0, max 30 000) | sent; if `collectLogsMs > 0`, the events that arrived in that window, following the device across a reconnect *(M26)* | W. Recorded in command history like a typed command. Never refused: Beaver cannot know which commands restart the app |

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
| `ui_state` | — | tab, viewed session, log filter, network filter, storage layer and search, selected event or request, whether the window is key | R |
| `ui_show` | any of: `tab` (`logs`/`network`/`storages`); `sessionId`; `filter` (logs, §5 conventions); `networkFilter` (`method[]`, `status`, `host[]`, `search` — same as `network_query`); `storage` (`layer`, `search`); `select` (`{eventId}`, `{networkId}`, or `"first"` / `"last"` match of the filter being set); `reveal` (default false) | the resulting `ui_state`, including the id that `"first"` / `"last"` resolved to | W. Without `reveal` the window updates in place and nothing takes focus |

### 5.9 Journal *(M17)*

| Tool | Args | Returns | Hints |
|---|---|---|---|
| `journal_note` | `text`, `level` (`info` default / `attention`), `links[]` (each `{sessionId}`, `{eventId}`, `{networkId}` or `{savedFilter}`) | the note id; `notified: true|false` and why not *(M28)* | W. How the agent tells the person something ("this subsystem floods 2 000 lines/s", "here is the cause"). Notes stand out in the panel; each link is clickable |

Twenty-six tools. Adding a user-facing capability to Beaver means adding or
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

## 7. What the person sees

### 7.1 Background UI model

*(M12)*

Today `MainWindow` owns `selectedTab` and the selection as `@State`, so nothing
outside the view can change them. The change:

1. `AppEnvironment` gets `selectedTab`, `selection` (`.event(id)` /
   `.network(id)` / `nil`), `networkFilter`, `storageLayer`, `storageSearch`
   and a `revealRequest` counter. `activeFilter` and `viewingSessionId`
   already live there. `NetworkViewModel.filter` and
   `StoragesViewModel.selectedNamespace` become reads of the env values
   instead of owning them.
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

**Examples.**

| The person says | The agent calls |
|---|---|
| "Show me the auth errors" | `logs_facets` (to learn the exact subsystem names) → `ui_show(tab: logs, filter: {minLevel: error, subsystems: ["com.app.auth"]}, select: "first", reveal: true)` |
| "Show the failed requests" | `ui_show(tab: network, networkFilter: {status: "errors"}, select: "first", reveal: true)` |
| "What's in keychain?" | `ui_show(tab: storages, storage: {layer: secure}, reveal: true)` |
| "Review the errors with me" | `logs_query(filter: {minLevel: error})` → groups them by cause → one `journal_note` with a link per group ("3 causes: token expired ×41, feed 500 ×12, player timeout ×3") → `ui_show(filter…, select: {eventId: first cause}, reveal: true)`. "Next" in chat → `ui_show(select: {eventId: …})` on the next cause; the person can also click the links in the note |
| (while working, unasked) | `ui_show(...)` without `reveal`: the window is ready on the right view when the person looks, nothing jumps |

### 7.2 Agent activity journal

*(M17)*

A toolbar button **Agent** opens an inspector panel on the right:

```
┌ Agent activity ─────────────── [Hide reads] [Copy] [Clear] ┐
│ 14:03:12  claude-code                                       │
│ ★ "401 on /oauth/token after refresh — the token expired"   │  agent note
│    → #48211 (event)   → #391 (request)                      │  links clickable
│ 14:03:05  storage_set  local/authToken = …     ✓ applied    │  change
│ 14:02:58  commands_send "debug.flag.on x"                   │
│ 14:02:40  logs_query  level≥warning, subsystem auth*        │  read, dimmed
│ 14:02:31  ⚠ sessions_delete #12                             │  destructive
│ 14:01:10  ⓘ device disconnected after "restart" → #13       │  system entry
└─────────────────────────────────────────────────────────────┘
```

**Entries.**
- **Every tool call**, recorded by the dispatcher, so a new tool is journaled
  with no extra work: time, client (`User-Agent`), tool, a one-line summary the
  tool provides, ✓ or ✗ with the error. Reads are dimmed and can be hidden
  with *Hide reads*; changes are normal; destructive calls are highlighted.
- **Agent notes** from `journal_note` (§5.9), highlighted, with clickable links.
- **System entries**: the device disconnecting after an agent's command and the
  session it came back in.
- An entry that points at something (session, event, request, saved filter)
  is clickable and shows it, through the same path as `ui_show`.

**Signalling: three volumes, none takes focus by itself** *(M17, M28)*

| What happens | Journal + toolbar badge | Toast in the window | macOS notification |
|---|---|---|---|
| Ordinary call (read, change) | ✓ | — | — |
| Destructive call (`sessions_delete`, `storage_delete`, `filters_delete`) | ✓ | ✓ "Agent deleted session #12" · button **Journal** | — |
| `journal_note(level: info)` | ✓ | — | — |
| `journal_note(level: attention)` — "look at this" | ✓ + Dock badge | ✓ the note · button **Show** | ✓ when Beaver is not frontmost |
| `ui_show(reveal: true)` | ✓ | — | — (brings the window forward itself) |

- The toolbar badge counts unseen entries and pulses once on a new one.
  Opening the panel marks everything seen and clears the toolbar and Dock
  badges.
- **Show** on the toast and a click on the notification do the same thing:
  bring Beaver forward and open what the note links to (the first link;
  the note is highlighted in the journal). It is `ui_show(reveal: true)`, but
  the person decides.
- Toasts use the existing `ToastCenter` with a `ToastAction`, shown longer
  (6 s) than ordinary confirmations.
- Notifications are coalesced: at most one per 30 s. Notes arriving meanwhile
  become one "3 new findings from the agent", and a click opens the journal.
- The Dock badge and toasts need no permission, so they work even when
  notifications are off.
- Agents are told in `instructions` to use `attention` only for what the
  person must see (a cause found, a decision needed, something broken).

**Notification permission** *(M28)*. macOS asks only once. After a refusal the
app cannot ask again and only System Settings can turn it back on. So Beaver
tracks the state (`notDetermined` / `denied` / `allowed`, re-read whenever
Beaver becomes active) and always offers the one action that works:

| State | Where it shows | Button does |
|---|---|---|
| `notDetermined` | Asked in context: on the first `attention` note, not at launch. The macOS prompt is a corner banner and does not take focus | — |
| still `notDetermined` (prompt ignored) or `denied` | A strip at the top of the Agent panel: "Notifications are off — the agent can't call you while Beaver is in the background." The menu item "Agent Notifications: Off — Turn On…" says the same | `notDetermined`: shows the system prompt. `denied`: opens System Settings on Beaver's notification page (`x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.applicaster.LoggerNext`) |
| `allowed` | The strip disappears; the panel has a "Notifications from the agent" switch to mute them within Beaver | — |

- **The strip always spells out where to go**, so it works even if the button
  doesn't (or the person prefers to do it by hand):

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │ 🔕 Notifications are off — the agent can't call you while       │
  │    Beaver is in the background.                                 │
  │    Turn on: System Settings → Notifications → Beaver →          │
  │    Allow Notifications (style: Banners)                          │
  │                                        [Open System Settings]   │
  └─────────────────────────────────────────────────────────────────┘
  ```

  For `notDetermined` the text is "Beaver hasn't asked yet" and the button is
  [Allow Notifications]. The menu item opens the same strip in the Agent
  panel. The path text lives in one constant, next to the deep link, because
  Apple renames System Settings panes between releases.
- An `attention` note that could not be delivered as a notification is marked
  in the journal ("not notified: notifications are off"), with the same
  button inline.
- The agent is told too: `journal_note` returns `notified: true|false`, a
  reason, and the same path text (`howToEnable`), so it can tell the person in
  chat exactly where to click; and `beaver_status` includes `notifications: allowed|denied|
  notDetermined|muted`. The agent can then ask the person in chat to turn
  them on.

**Storage.** Table `agent_activity` (id, at, client, tool, kind
`read`/`change`/`destructive`/`note`/`system`, summary, level, is_error,
error, links JSON, session_id nullable, seen). It:
- survives restarts;
- is **not part of any session export**, so nothing reaches customers or
  zapp-support by accident;
- is emptied by *Clear*;
- keeps the newest 2 000 rows, trimming the oldest on insert;
- keeps entries when their session is deleted (`ON DELETE SET NULL`); the link
  then shows as gone.

*Copy* puts the visible entries on the clipboard as text, for bug reports from
testers *(M27)*.

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
   > cannot contain spaces through `storage_set`. Omitting `sessionId`
   > follows the device: if it restarts during a wait, you carry on in its new
   > session and are told so; pass `sessionId` to stay on one session. Work in
   > the background: use `ui_show` only to point the user at something, and
   > `reveal: true` only when they ask to see it. Everything you call is
   > shown to the user in Beaver's agent journal; use `journal_note`, with
   > links, to tell them what you found. Use `level: attention` only when
   > they must look now; it may raise a macOS notification. If the result
   > says `notified: false`, tell them notifications are off and pass on the
   > `howToEnable` text.

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
5. Every tool gives the journal a one-line summary of what it did; the
   dispatcher records the call. Don't bypass the dispatcher.
6. Agent Access stays a separate feature: code outside `Beaver/MCP/` and
   `Beaver/Features/AgentActivity/` never imports from it; the app reaches it
   only through `AgentAccess`.
7. Testers use a built bundle (PR build or release), without Xcode. Anything
   they need to turn on, set up or check must work from the app menu, and be
   described in `MCP.md` → "Testing without Xcode".
8. Mention agent-visible changes in `CHANGELOG.md` `[Unreleased]`.
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
| `AgentJournalTests` | every call is recorded with the right kind; failed calls carry the error; notes keep their links; the 2 000-row trim; entries survive session delete with the link nulled; `SessionExport` output contains no journal data |
| `AgentSignalTests` | which calls produce a toast / Dock badge / notification (the table in §7.2); coalescing to one per 30 s with a fake clock; each permission state maps to the right strip text, path and button action; an undelivered note is marked and returns `notified: false` |
| `FollowDeviceTests` | omitted `sessionId` carries a wait across a disconnect/reconnect and reports `sessionChanged`; a pinned session reports `sessionEnded`; no reconnect → `deviceDisconnected` |
| `AgentAccessTests` | the menu toggle starts and stops the listener; toggled off, the port is closed |
| `MCPDocDriftTests` | the tool names in `MCP.md`'s tables equal the registered names |
| `AgentUITests` (app target, existing UI-test target) | `ui_show` without `reveal` leaves another app frontmost; with `reveal` Beaver becomes active |
| Tester checklist (manual, on the PR bundle) | `MCP.md` → "Testing without Xcode": enable, connect Claude Code, run the smoke test, check the journal, switch off *(M27)* |

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

### M4. On for everyone in phase 1; one toggle in the app menu
- **Why:** agreed with the user (2026-09-23). The value is in agents finding it
  with no setup; the risk is bounded by M3 and by nobody outside the team
  knowing the feature exists. Customers get it too (same `Beaver.zip`).
- **Alternatives:** opt-in toggle; see M24 for access control.
- **To change:** flip the `@AppStorage` default, or settle M24.

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

### M8. One tool per capability, grouped (26 tools)
- **Why:** agents choose better between named, narrow tools than between
  modes of one giant tool. 26 is well within what clients handle.
- **Alternatives:** a few "god tools" (`query(kind, …)`); one tool per UI
  control (hundreds).
- **To change:** merge within a group; the drift test and `MCP.md` follow.

### M9. Default session: live → viewed → most recent
- **Why:** matches what a person means by "the logs" when a device is
  connected, and still works offline or on imported sessions. Echoing the
  chosen id prevents silent confusion. What happens across a reconnect is
  M26.
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

### M17. Agent activity journal: every call, agent notes, badges; not in exports
- **Why:** agreed with the user (2026-09-23). The person needs to see what the
  agent did, notice when something new happens, and jump to what the agent
  found, all without the window taking focus (§7.2). Recording in the
  dispatcher means no tool can forget to log. A separate table keeps agent
  activity out of session exports, which go to customers and zapp-support.
  `journal_note` lets the agent say something to the person with clickable
  links, which a tool-call list cannot.
- **Volumes:** journal for everything, toasts for destructive calls and
  `attention` notes, a macOS notification for `attention` notes while Beaver
  is in the background (M28).
- **Alternatives:** toasts only (gone when missed, no history); synthetic
  `beaver.agent` events in the session (would end up in exports); `os_log`
  only (invisible).
- **To change:** kinds, cap and badge rules are constants in `AgentJournal`;
  the panel is one view. A `journal_list` tool for agents is additive if a
  use appears.

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

### M24. Access control is open in phase 1 — to decide before phase 2
- **Status:** open, deliberately (agreed 2026-09-23).
- **Decided now:** no build flag, no policy key, no token. The feature is
  isolated behind `AgentAccess` (§3.2), so any of those is one check in one
  place later.
- **Must be decided before phase 2**, when an agent can also restart the app
  and change its storage: how to keep Agent Access, or some of its data, from
  customers. Options are listed in §3.2: build flag + customer build,
  `defaults` key (also usable by a configuration profile), off by default with
  the team turning it on, client token. An environment variable is not an
  option: apps started from Finder don't see it.

### M25. The API is ready for several connected apps
- **Why:** the user expects to connect several apps at once later (today D2
  allows one). Tool shapes are hard to change once agents rely on them, so
  phase 1 already uses the multi-device shape: `beaver_status.devices` is an
  array, live-device tools take an optional `deviceId`, and with more than
  one live device a call that doesn't say which one fails with the list.
- **Alternatives:** a single `device` object now, reshaped later (a breaking
  change for agents).
- **To change:** lifting D2 changes `WSServer` and session creation; the tool
  API stays as is.

### M26. Omitted `sessionId` follows the device across reconnects
- **Why:** agreed with the user. A command can restart the app, and Beaver
  starts a new session on reconnect (D2). Beaver can't know which commands do
  that, so it doesn't refuse any. Instead, waits carry on in the new session
  and say so (`sessionChanged`), and a pinned `sessionId` reports
  `sessionEnded`. `restart` → `logs_wait(search: "App started")` just works.
  The journal records the disconnect as a system entry.
- **Alternatives:** refuse such commands without `expectDisconnect: true`
  (needs a list of disconnecting commands nobody has); leave it to the agent.
- **To change:** the follow logic lives in `ToolContext.resolveSession` and
  the wait helper shared by `logs_wait` and `commands_send`.

### M27. Testers use signed PR bundles, no Xcode
- **Why:** a few testers will check each step with a built app only, and
  testing happens in PRs (agreed 2026-09-23). Today the PR workflow only
  builds and tests; a signed app exists only after merge, which is also a
  release to customers. So:
  - the `on-pull-request` workflow gets a **manual approval job**, "Tester
    bundle", that builds, signs and notarizes `Beaver.zip` with the release
    job's steps, stores it as a CircleCI artifact and does **not** publish or
    touch the appcast. It costs nothing unless someone clicks it;
  - everything a tester needs works from the app menu: the toggle, "Copy MCP
    Setup Command", the Agent panel, and *Copy* in the panel for reports;
  - `MCP.md` has a "Testing without Xcode" section: install the bundle,
    connect Claude Code (and Cursor), a `curl` smoke test
    (`tools/list` against `http://127.0.0.1:9081/mcp`), a checklist per
    delivery step, and how to report (journal *Copy* + Beaver version).
- **Alternatives:** test only released builds (customers get untested
  changes); run the job on every PR (a notarization per push).
- **To change:** the job's trigger in `.circleci/config.yml`.

### M28. macOS notifications for `attention` notes, with a way back from "off"
- **Why:** agreed with the user (2026-09-23). A toast is only seen if the
  window is in view; the agent needs a way to say "look" while Beaver is in
  the background, and a click should bring Beaver forward on what it found.
  A notification does that without taking focus until clicked. macOS asks
  for permission only once, so the design must lead back from a refusal: a
  strip in the Agent panel and a menu item whose button is the system prompt
  (`notDetermined`) or System Settings (`denied`), a mark on undelivered
  notes, and the state reported to the agent.
- **Details:** asked in context on the first `attention` note, not at
  launch; re-checked on `didBecomeActive`; coalesced to one per 30 s;
  mutable within Beaver.
- **Alternatives:** ask at launch (people refuse prompts without context);
  provisional authorization (quiet delivery to Notification Center only, no
  banner, so nobody notices); no notifications (agent can't reach a person
  whose window is hidden).
- **To change:** `AgentNotifier` (app target) owns permission, delivery and
  coalescing; the coalescing window is a constant.

---

## 13. Delivery

Each step is a PR that releases on merge (see `CLAUDE.md`), so each must stand
on its own. Testers check each PR on its tester bundle before merge *(M27)*.

1. **Core, read tools, journal.** `AgentAccess`, `MCPServer`, listener, menu
   items, `beaver_status`, `sessions_list`, `logs_*`, `network_*`,
   `storage_snapshot(refresh:false)`, `commands_list`, `bookmarks_list`,
   `filters_list`; `AgentJournal`, the `agent_activity` migration and the
   Agent panel with badges; `MCP.md` with "Testing without Xcode"; the drift
   test; the `CLAUDE.md` rule; the CI "Tester bundle" job; migration of
   M1–M17 and M20–M28 to `DECISIONS.md` (M24 as an open decision).
2. **Actions.** `commands_send`, `storage_snapshot(refresh:true)`,
   `storage_set/delete`, `sessions_import/export/delete`, `logs_clear`,
   `bookmarks_set`, `filters_save/delete`, `journal_note`, follow-device
   waits (M26) and the disconnect system entry; toasts for destructive calls
   and `attention` notes; macOS notifications with the permission strip and
   menu item (M28).
3. **UI.** State move (§7.1), `ui_state`, `ui_show`, clickable journal links.
4. **Before phase 2:** settle M24 (access control). Then phase 2 research
   (§11), its own spec update and plan.

## 14. Open questions

1. **Access control for customers (M24)** — open on purpose; must be decided
   before phase 2.
2. ~~Should `commands_send` refuse commands that close the WebSocket?~~
   **Answered:** no; waits follow the device (M26).
3. ~~Is 9081 free?~~ **Answered:** yes.
4. ~~How do customers get Beaver?~~ **Answered (2026-09-23):** the same
   build, from
   `https://github.com/applicaster/Beaver/releases/latest/download/Beaver.zip`,
   so phase 1 ships Agent Access to them too (M4, M24).
