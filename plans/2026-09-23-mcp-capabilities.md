# What Beaver's MCP can do — capabilities and flows

Status: draft for review, companion to
[`2026-09-23-mcp-design.md`](2026-09-23-mcp-design.md) (the design and its
decisions M1–M31). This file describes the result from the outside: what an
agent can do, and how a whole task flows from the first call to what the
person sees. It seeds `MCP.md`, which `beaver_guide` serves to agents (M31),
so its recipes are written to be followed literally by a weak agent.

Phase 1 only. Phase 2 (controlling the app itself) is previewed at the end.

---

## 1. In one paragraph

Beaver runs on your Mac and receives everything a connected mobile app
reports: logs, network requests, storage, and the commands it accepts. With
Agent Access, an AI agent on the same Mac can read all of it, filter and
compare it, send commands to the app, change its storage, import and export
log files, watch for things over time, and point you at what it found in
Beaver's window. It works in the background. It tells you what it did in
Beaver's **Agent** panel, and asks for your attention with a toast or a
macOS notification only when something is worth looking at.

## 2. Setup

For developers and testers alike. No Xcode needed: a tester bundle from a PR
works the same way (design M27).

1. Open Beaver. The app menu shows **Agent Access (MCP): On · 127.0.0.1:9081**.
2. App menu → **Copy MCP Setup Command**, paste it into a terminal:
   ```bash
   claude mcp add --scope user --transport http beaver http://127.0.0.1:9081/mcp
   ```
   `--scope user` installs it for every project. Cursor / Codex: add an HTTP
   MCP server with the same URL.
3. Check it answers:
   ```bash
   curl -s -X POST http://127.0.0.1:9081/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```
4. Connect a device to Beaver as usual (remote assistance → Beaver's address).
   The agent can work without a device too, on past or imported sessions.

To turn it off: app menu → **Agent Access (MCP)**.

## 3. Capability map

| Area | The agent can | Tools |
|---|---|---|
| Orientation | See whether a device is connected and which, which session is live, where the device should connect, whether notifications are on | `beaver_status`, `beaver_guide` |
| Sessions | List past and live sessions; delete; import a JSON/HAR file from a customer or zapp-support; export a session or a filtered part of it | `sessions_list`, `sessions_delete`, `sessions_import`, `sessions_export` |
| Logs | Discover subsystems and categories; filter by level, text, regex, exclusions, payload contents, time; read full payloads; wait for a log line; clear the view | `logs_facets`, `logs_query`, `logs_get`, `logs_wait`, `logs_clear` |
| Network | Filter requests by method, status, host, text; read headers and bodies; copy as cURL / fetch / JSON | `network_query`, `network_get`, `network_copy` |
| Storage | Read session / local / keychain storage (fresh from the device or the last snapshot); set and delete keys, with a check that the device applied it | `storage_snapshot`, `storage_set`, `storage_delete` |
| Commands | List the commands the app accepts, with syntax; send one and collect the logs it causes | `commands_list`, `commands_send` |
| Organise | Bookmark events and requests; save, list and delete named filters | `bookmarks_list`, `bookmarks_set`, `filters_list`, `filters_save`, `filters_delete` |
| Over time | Watch for matching logs for minutes or hours; get counts and a breakdown later; notify you when a threshold is hit | `watch_start`, `watch_status`, `watch_stop` |
| Talk to you | Leave a note in the Agent panel with clickable links; ask for your attention (toast, macOS notification) | `journal_note` |
| Window | Read what the window shows; set tab, session, filters, selection in the background; bring Beaver forward when you ask | `ui_state`, `ui_show` |

What it **cannot** do in phase 1:
- control the app beyond the commands the app itself accepts (that is
  phase 2);
- wake itself up: when a watch fires, *you* are notified, and the agent sees
  it the next time it looks;
- reach Beaver on another machine: loopback only.

## 4. How every call feels to the person

| The agent… | You see |
|---|---|
| reads (queries, facets, status) | a dimmed line in the Agent panel; the toolbar badge counts it |
| changes something (bookmark, filter, command, storage write) | a line in the Agent panel |
| deletes something | a line plus a toast: "Agent deleted session #12 · Journal" |
| leaves an `info` note | a highlighted note with links in the Agent panel |
| leaves an `attention` note | the note, a toast with **Show**, a Dock badge, and a macOS notification if Beaver is in the background. **Show** or a click brings Beaver forward on what it found |
| prepares the window (`ui_show` without `reveal`) | nothing moves; the window is on the right view when you look |
| is asked to show you something (`reveal: true`) | Beaver comes forward on it |

Nothing the agent does takes focus on its own.

## 5. Flows

Each flow lists the calls in order. Arguments are examples. What the person
sees is in *italics*.

### 5.1 Orientation — always first

```
beaver_status()
  → device: "MyApp 7.2 (iPhone15,2, iOS 18.6)", live session #13, notifications: allowed
  → Next: logs_facets() to see what the app logs
logs_facets(since: "10m")
  → levels: error 41, warning 120 …; subsystems: com.app.auth 300, player.core 2100 …
```
If no device is connected, the status says so and how to connect. The agent
can still work on past sessions (`sessions_list`).

### 5.2 Investigate a report — "login fails"

```
beaver_status()
logs_facets(filter: {search: "login"})                 ← which subsystems talk about login
logs_query(filter: {minLevel: warning, subsystems: ["*auth*"]}, since: "15m")
  → "#48211 14:03:12.482 ERROR com.app.auth/token: refresh failed 401" …
  → resolved subsystems: ["com.app.auth"]
logs_get(ids: [48211])                                  ← payload: the response, the token age
network_query(status: "errors", search: "token")
  → "#391 POST 401 120ms 0.4KB https://api…/oauth/token"
network_get(id: 391)
journal_note(level: attention,
  text: "Login fails: token refresh gets 401 — refresh token expired",
  links: [{eventId: 48211}, {networkId: 391}])
```
*A toast "Login fails: …" with **Show**; if Beaver is in the background, a
notification. Clicking opens event #48211.*

### 5.3 Act, then observe — change something and see the effect

```
commands_list()                                          ← what the app accepts, with syntax
beaver_status()                                          ← note the latest event id, e.g. 48300
commands_send(command: "debug.flag.on newPlayer")
logs_wait(afterId: 48300, filter: {subsystems: ["player*"]}, timeoutMs: 15000)
  → the log lines the command caused, or timedOut: true
```
Or in one call: `commands_send(command: …, collectLogsMs: 5000)`.

Storage works the same way:
```
storage_snapshot(layer: local)
storage_set(layer: local, key: "onboardingDone", value: "false")
  → applied  (Beaver re-read storage and saw the new value)
```
A value with spaces is refused with the reason (the SDK splits on spaces).

### 5.4 Restart the app and carry on

The restart comes from whatever `commands_list` offers (the name depends on
the app and SDK), or from the person restarting the app by hand.
```
commands_send(command: "<restart command from commands_list>", collectLogsMs: 20000)
  → deviceDisconnected, then sessionChanged: {from: 13, to: 14}
  → the logs from the new launch
logs_wait(filter: {search: "App started"}, timeoutMs: 30000)
```
Without `sessionId`, calls follow the device into its new session and say so.
*The Agent panel shows "device disconnected after <command> → session #14".*

### 5.5 Watch while someone tests — minutes to hours

```
watch_start(name: "player errors",
  filter: {minLevel: error, subsystems: ["player*"]},
  notify: {atCount: 10})
… the tester plays for 20 minutes; the agent's turn may even end …
```
*At the 10th error: an attention note "Watch 'player errors': 10 matches",
toast + notification; clicking shows the first one.*
```
watch_status(name: "player errors")
  → 23 matches since 14:10; by subsystem: player.core 20, player.ads 3; ids 49001–51877
logs_query(afterId: 49000, filter: {minLevel: error, subsystems: ["player*"]})
watch_stop(name: "player errors")
```

### 5.6 Review the errors with the person

```
logs_facets(filter: {minLevel: error}, since: "1h")
logs_query(filter: {minLevel: error}, since: "1h", limit: 500)
  → the agent groups them by cause
journal_note(level: info,
  text: "3 causes: token expired ×41, feed 500 ×12, player timeout ×3",
  links: [{eventId: 48211}, {eventId: 48950}, {eventId: 50112}])
ui_show(tab: logs, filter: {minLevel: error}, select: {eventId: 48211}, reveal: true)
```
*Beaver comes forward, errors filtered, the first cause selected.* On "next"
in chat → `ui_show(select: {eventId: 48950})`. The person can also click the
links in the note.

### 5.7 A failing request — reproduce it outside the app

```
network_query(status: "errors")
network_get(id: 391)
network_copy(id: 391, format: curl)
  → the cURL, plus "Authorization redacted by the SDK, body truncated"
```
The agent knows the replay may fail for those reasons and says so.

### 5.8 A customer sent a log file

```
sessions_import(path: "~/Downloads/customer-2026-09-20.json")
  → session #15, 12 400 events, 310 requests
logs_facets(sessionId: 15)
logs_query(sessionId: 15, filter: {minLevel: error})
… investigate as in 5.2 …
sessions_export(sessionId: 15, path: "~/Desktop/errors-only.json", filter: {minLevel: error})
```
The same file format as zapp-support, both ways.

### 5.9 Prepare the window in the background, show on request

```
filters_save(name: "Auth problems", filter: {minLevel: warning, subsystems: ["com.app.auth"]})
ui_show(tab: logs, filter: {minLevel: warning, subsystems: ["com.app.auth"]}, select: "first")
```
*Nothing moves. When the person switches to Beaver, it is already on the
right view, and the saved filter is in the filter menu.* When they ask "show
me": `ui_show(reveal: true)`.

### 5.10 Notifications are off

```
journal_note(level: attention, text: "…")
  → notified: false, reason: "notifications are off",
    howToEnable: "System Settings → Notifications → Beaver → Allow Notifications"
```
The agent tells the person in chat where to turn them on. *The Agent panel
shows the same path with an **Open System Settings** button.*

## 6. Limits and gotchas

| Limit | Why | What the agent does |
|---|---|---|
| Network bodies are cut at 100 KB, some headers are `[REDACTED]` | the SDK does it before sending | treat replays as best effort; `network_copy` says what's missing |
| Storage values can't contain spaces via `storage_set` | the SDK command splits on spaces | pick another value; phase 2's device `storage.set` removes this |
| Lists return at most 500 rows | protects the agent's context | page with `nextCursor` / `afterId`, or narrow the filter |
| Payloads come only from `logs_get` / `network_get`, max 256 KB each | same | ask for a few ids at a time |
| `logs_wait` waits at most 60 s | HTTP request lifetime | use a watch for longer |
| One device at a time | Beaver's D2 | the API already accepts `deviceId` for when that changes |
| Beaver must be running | the server is inside the app | `beaver_status` failing to connect means Beaver is closed or Agent Access is off |

## 7. Phase 2 preview — controlling the app

Not in phase 1. The app's own toolbox (Android on `master`, iOS in
Zapp-Frameworks#2864) answers MCP over the same connection Beaver already
has. Beaver will pass calls through with `app_tools_list` and
`app_tools_call`: app info, restart, storage with real JSON values, debug
features, console commands, and tools registered by JS plugins. Access
control for customers (design M24) must be settled first.
