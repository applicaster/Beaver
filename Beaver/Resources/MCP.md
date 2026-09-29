# Beaver MCP

Beaver's MCP server lets an AI agent on this Mac read everything Beaver has
collected from the connected app — logs, network requests, storage, commands —
and act on it: send commands, change storage, import and export session
files, bookmark, save filters, watch for things over time, and leave notes for
you. It works in the background. Everything the agent calls is listed in
Beaver's **Agent** panel; deletions and notes that need you also show a toast,
and a macOS notification when Beaver is in the background. Design:
`plans/2026-09-23-mcp-design.md`.

## Setup

1. Open Beaver. Beaver → **Settings…** (⌘, or the gear at the bottom of the
   sidebar) → **Agents**: **Agent Access (MCP)** is on by default and the
   status shows `On · 127.0.0.1:9081`.
2. App menu (or Settings → Agents) → **Copy MCP Setup Command**, and run it:
   ```bash
   claude mcp add --scope user --transport http beaver http://127.0.0.1:9081/mcp
   ```
   `--scope user` installs it for every project, not just the one you're in.
   Cursor, Codex and other clients: add an HTTP MCP server with the URL
   `http://127.0.0.1:9081/mcp`.
3. Connect the device to Beaver as usual. The agent can also read past and
   imported sessions without one.

Port taken? Settings → Agents → **Port**: type another one (1024–65535) and
**Apply**; Beaver restarts the listener, and agents need the new setup
command. (An older Beaver has no Settings window: there,
`defaults write ~/Library/Preferences/com.applicaster.LoggerNext mcpPort -int 9082`
and toggle Agent Access off and on in the app menu.)

## Testing without Xcode

For testers with a built bundle (a PR's "Tester bundle" artifact on CircleCI,
or a release). Every setting is in Beaver → **Settings…** (⌘,, or the gear at
the bottom of the sidebar): General (session retention), Agents (Agent Access,
port, notifications), Zapp (token), About (version, What's New, updates).

1. Unzip `Beaver.zip`, move `Beaver.app` to Applications, open it.
2. Check Settings → Agents shows **Status: On · 127.0.0.1:9081**.
3. Smoke test in Terminal:
   ```bash
   curl -s -X POST http://127.0.0.1:9081/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```
   Expect JSON listing the tools below.
4. Connect Claude Code (Setup, step 2) and ask in plain words: "use beaver:
   what is connected, and show me the last errors". The Agent panel lists
   the calls it made.
5. Open the **Agent** toolbar button: every call is listed; the badge counted
   them while the panel was closed.
6. Actions (with a device connected; ask the agent in plain words):
   - "send `cmdlist` to the app and show me what it logged" → `commands_send`
     with `collectLogsMs`; the command also appears in the command bar's
     history (↑).
   - "set local storage key `beaverTest` to `1`, then delete it" → the panel
     shows both calls; the delete is highlighted and a toast says
     "Agent: Delete …" with **Journal**.
   - "what changed in storage since I connected?" → `storage_diff`; the
     Storages tab's **Changes** button shows the same for the layer on screen.
   - "watch for errors and tell me at the first one" → `watch_start` with
     `notify`; trigger an error on the device: an attention note appears,
     with a toast (Beaver in front) or a macOS notification (Beaver in the
     background). **Show** / clicking it brings Beaver forward on the event.
   - Notifications off? The Agent panel's strip says where to turn them on;
     so does Settings → Agents → **Agent notifications**, with the same button.
   - "export this session to ~/Desktop/beaver-test.json, import it back, then
     delete the imported copy" → three calls; the imported session is not
     shown until you pick it; the delete toasts.
7. With another app in front, ask the agent: "in Beaver, show the failed
   requests — don't bring it forward". Beaver's Network tab changes while
   the other app stays in front. Then "show me": Beaver comes forward.
8. In the **Agent** panel, click a row's link (**session #…**,
   **request #…**): the popover closes and Beaver shows it.
9. Turn **Agent Access (MCP)** off in Settings → Agents: the `curl` above now
   fails to connect. Turn it back on, set **Port** to 9082 and **Apply**: the
   status shows `127.0.0.1:9082` and the `curl` answers on 9082. Set 9081 back.
10. Connect two apps (two simulators, or a simulator and a phone): both
   appear in the menu behind the toolbar's Connected pill, and `beaver_status` lists both.
11. Report problems with the Beaver version (Settings → About, or Beaver →
   About) and the Agent panel's **Copy** output.
12. Compare: Sessions tab → right-click a session → **Compare with** → pick
   another. A sheet lists what differs; click a line to open it. Ask the agent
   "compare session <a> with <b>" → `sessions_compare`.
13. Toolboxes: connect an app built with quick-brick-xray's **native** WebSocket
   sink (the JS-only sink has none), then Sessions → select its live session —
   the details list its toolboxes (the device badge's popover links there with
   **Toolboxes in Sessions**). Nothing to turn on in Beaver.
13. Session retention: Settings → General → **Delete sessions older than**
   shows 30 Days, and "Database on disk" fills in a few seconds after
   launch. `beaver_status` reports `retentionDays: 30` and `storeBytes`.
   With sessions older than 30 days, the first launch only shows a toast
   (**Keep All** sets Never); a launch a day later deletes them and toasts
   "Deleted N old sessions, freed …". Picking a period in Settings deletes
   right away, no waiting day (try 7 Days). Bookmarked and imported
   sessions stay, and so does a connected device's session.
14. Smart TVs (Beaver 4.17.0 or later; nothing to install): turn on the TV's
   developer mode, then **Connect a TV…** — in the menu behind the toolbar's
   Connected pill, on the empty "Waiting for a client" screen (**TV? Connect
   a TV…**), or Beaver → Connect a TV…. Type the TV's IP, its DevTools port
   (Vizio 9555, Vidaa 9226, else often 9222) and a name such as "Living room
   Vizio", then **Connect**. The TV appears like a phone, model
   "TV (DevTools)"; its console lines and exceptions stream in under subsystem
   `tv-cdp`. `beaver_status` lists it with `platform: "tv-cdp"`;
   `commands_send` to it fails with "only sends logs". Try the errors: a wrong
   IP ("Can't reach"), a wrong port ("no DevTools on that port"), Chrome's
   chrome://inspect attached to the TV ("page is busy"). Reload the app on
   the TV: a `bridge` line says the page closed, then the logs carry on in
   the same session. The sheet lists the TV under Recent next time.
   Disconnect (pill menu) stops it. Agents: ask "connect the TV at
   192.168.1.40 port 9555" → `devices_connect_tv`. zapp-support's
   `node scripts/tv-bridge.mjs <tv-ip>:<port> --server ws://127.0.0.1:9080`
   (Beaver 4.15.0 or later) still works and makes the same device.
15. Config files: connect an app, open **Info** → Config files. The header
   says "saved <time>, as Zapp had them"; each row names the storage key it
   came from (`local/applicaster.v2/cell_styles_url`…) and **Open** opens the
   file. An imported or older session says "in Zapp now" with **Save with
   Session**. Agents: "what's the layout id in the remote configuration?" →
   `app_config`. No Zapp token is needed (Beaver 4.19 removed it).
16. What's New: the first launch of a new version shows "What's New in
   Beaver X.Y.Z" with every version since the last one you ran (nothing on
   a fresh install). Beaver → **What's New…** and Settings → About show it
   again.

## Tools

| Tool | What it does |
|---|---|
| `beaver_status` | Every connected device (its `id` is the `deviceId` other tools take), live and viewed session, latest event id, where the device connects, how long old sessions are kept (`retentionDays`) and the store's size (`storeBytes`) |
| `sessions_list` | Stored sessions, newest first, with app, device and counts |
| `sessions_import` | Open a Beaver / zapp-support JSON or a HAR file as a new session |
| `sessions_export` | Write a session (or a filtered part) as JSON, or its requests as HAR |
| `sessions_delete` | Delete one session, or all |
| `sessions_compare` | Two sessions side by side: log patterns only in one, warnings/errors per subsystem, requests only in one or whose status or median duration changed |
| `logs_facets` | Counts per level, subsystem, category under a filter and range |
| `logs_query` | Log lines by filter, id range or time; cursor paging |
| `logs_get` | Full events with data and context payloads (256 KB cap) |
| `logs_wait` | Wait up to 60 s for a matching event |
| `logs_clear` | Hide the viewed Log feed's events up to now, like Clear (⌘K); deletes nothing |
| `issues_list` | The Issues tab: warnings and errors grouped by signature (subsystem + normalised message, as `sessions_compare`), with level, count, first/last id and time, ignored flag, and the `logs_query` filter for each |
| `issues_ignore` | Mark a signature as known noise for the app (all its sessions), or unignore it — only when the user asks |
| `network_query` | Requests by status, method, host, text |
| `network_get` | One request with the SDK's `requestId`, headers and bodies |
| `network_copy` | A request as cURL, fetch() or JSON, with replay warnings |
| `storage_snapshot` | Session / local / keychain storage, fresh from the app when connected |
| `storage_diff` | What changed in storage between two snapshots of the session: keys added, removed, changed (old → new), fields inside JSON values; default earliest → latest |
| `storage_set` | Set a storage key; Beaver re-reads storage and says whether the app applied it |
| `storage_delete` | Delete a storage key, with the same check |
| `commands_list` | Commands a connected app accepts (`deviceId` when several are connected) |
| `devices_disconnect` | Close a connected app's connection (the Disconnect button); its session ends. With several apps, `deviceId` is required: the default doesn't count |
| `devices_connect_tv` | Read a smart TV app (Vizio, Vidaa, …) over DevTools from its IP and port, like Connect a TV…; it becomes a device that only sends logs. `devices_disconnect` stops it |
| `devices_set_default` | Make one connected app the default for device tools (follows it across restarts); `null` clears |
| `toolboxes_list` | An app's toolboxes, or one toolbox's tools with their arguments; `deviceId: "beaver"` for Beaver's own |
| `tools_call` | Run one tool from `toolboxes_list` on the app (or on Beaver) and get its answer; it is marked destructive, so clients that honor destructiveHint ask the user to confirm (app tools can delete data or restart the app) |
| `commands_send` | Send a command to the app; optionally collect the logs it causes, following a restart |
| `bookmarks_list` | Events and requests the user bookmarked |
| `bookmarks_set` | Bookmark an event or request, or remove the bookmark |
| `filters_list` | The user's saved filters, each one's ⌘1…⌘9 shortcut, and which is the default |
| `filters_save` | Save a named filter (replaces one with the same name); `default: true` makes new sessions start from it |
| `filters_delete` | Delete a saved filter |
| `watch_start` | Count matching events for minutes to hours; optionally notify the user at a count |
| `watch_status` | What a watch caught: counts, first/last, breakdown, whether it fired |
| `watch_stop` | Stop a watch and get its final status |
| `journal_note` | Tell the user something in the Agent panel, with clickable links; `attention` also notifies |
| `ui_state` | What Beaver's window shows: tab, session, filters, selection, whether it is in front |
| `ui_show` | Point the window at a tab, session, filter or row — in the background unless `reveal: true` |
| `scheme_build` | Build a deep link into a Zapp app (Scheme Generator): open, present, web page, layout, X-Ray, native and plugin hosts, with the app's scheme from its storage; fill the form on screen, copy it, save its QR code |
| `app_info` | What app and device a session is: app/SDK/QuickBrick versions, Zapp ids, screens, feed mapping (entry type → screen), cell styles, plugins, device model/OS/language/country/advertising id — each value with its source (the app's storage — the build it runs —, config files, logs); `configs` has the URL of every file the app loads at launch (layout, plugin/remote configurations, cell styles, presets mapping, pipes endpoints) and whether it is saved with the session. |
| `app_config` | One of those config files as saved with the session when the device connected (Zapp as of then): the JSON at a dot path (`general_settings.layout_id`, `screens.0.name`), keys of objects, counts of arrays; without `kind` the saved files; `download: true` saves Zapp's current ones for a session that has none |
| `beaver_guide` | These recipes, by topic |

Conventions: omitting `sessionId` means the live session (with several
devices, the viewed one if it is live, else the newest), else the viewed one,
else the most recent — and during a wait it follows the device into its new
session if the app restarts (`sessionChanged`); a given `sessionId` stays put
(`sessionEnded`). Subsystem and category values accept `*` globs, name
fragments and any case; results say what they matched. A filter's `search`
is a query in the Log feed's syntax, the same as zapp-support's web logger
(recipe `query`); `searchIsRegex: true` takes it as one regular expression
instead. `since: "5m"` works wherever ids do. File paths are absolute or start with `~`. Every result ends
with `Next:` suggestions.

A device with `platform: "tv-cdp"` is a smart TV, connected by Beaver
(`devices_connect_tv`, Connect a TV…, Beaver 4.17.0 or later) or by
zapp-support's TV bridge: it only sends logs (subsystem `tv-cdp`, categories
`console`, `exception`, `log:*`; Beaver's own bridge adds `bridge` lines when
the TV's page closes or it can't reach the TV). Commands, storage changes and
toolboxes are refused for it; read its logs instead.

UI tools work in the background: the window changes where it is and nothing
takes focus, unless you pass `reveal: true`.

## Recipes

### overview — first steps

1. `beaver_status()` — is a device connected, which app, which session is live.
2. No device? `sessions_list()` and pass a `sessionId`, or ask the user to
   connect the app to the address `beaver_status` shows.
3. `logs_facets(since: "10m")` — what the app has been logging.
4. Unsure how to do something: `beaver_guide(topic: "…")`.

### investigate — a reported problem ("login fails")

1. `logs_facets(filter: {search: "login"})` — which subsystems talk about it.
2. `logs_query(filter: {minLevel: "warning", subsystems: ["*auth*"]}, since: "15m")`.
3. `logs_get(ids: [<id>])` — the payload of the line that matters.
4. `network_query(status: "errors", search: "token")`, then `network_get(id: <id>)`.
5. Tell the user what you found, with event and request ids.

### query — the search syntax, one line for many conditions

`filter.search` takes the syntax people type in the Log feed's Filter field
and in zapp-support's web logger (Beaver 4.14.0 or later). Case never matters.

- `timeout player` — both words; a word is found in message, subsystem or
  category (and the data payload with `searchPayloads: true`).
- `timeout OR stall` — either; OR binds tighter than the space:
  `a OR b c` is (a or b) and c.
- `-heartbeat` excludes; `+word` is the same as `word`.
- `"token refresh"` — the exact phrase; `/^err\d+/` — a regular expression
  (ends at a space, so `/var/log` is a path).
- `level:error` — exactly that level (`warn` = `warning`); `minLevel` is
  "this and above".
- `sub:auth`, `cat:net`, `msg:401` — in that field only; `*` globs in `sub:`
  and `cat:`. Other `word:` prefixes are plain text.

1. `logs_query(filter: {search: "level:error sub:*auth* -heartbeat"}, since: "15m")`
   — auth errors without the heartbeat noise.
2. `logs_facets(filter: {search: "timeout OR stall"})` — who logs either.
3. `ui_show(filter: {search: "level:error sub:*auth* -heartbeat"})` — the
   user sees the same query in the Filter field.
4. An unclosed quote or a regex that doesn't compile is an error; fix the
   query, or pass `searchIsRegex: true` to take the text as one regular
   expression.

### wait — see what an action causes

1. `beaver_status()` — note `latestEventId` of the device.
2. Ask the user to do the action on the device, or do it yourself with
   `commands_send` / `storage_set`.
3. `logs_wait(afterId: <latestEventId>, filter: {search: "…"}, timeoutMs: 30000)`.
4. Timed out? `logs_query(afterId: <latestEventId>)` shows what did arrive.

### network — a failing request

1. `network_query(status: "errors")`.
2. `network_get(id: <id>)` — headers and bodies.
3. `network_copy(id: <id>, format: "curl")` — to replay it; the result says
   which headers were redacted and whether the body was cut.

### app-info — what app and device is this

1. `app_info(sessionId)` — versions, Zapp ids, the layout's screens and plugins, the device and its advertising id, each with where it came from.
   Config files: their URLs, and whether they're saved with the session.
2. Read one: `app_config(kind: "remoteConfigurations", path: "general_settings")`,
   then walk down (`app_config(kind: "layout", path: "screens.0")`). Saved when the
   device connected, so as Zapp had them then — a later publish doesn't change
   them. A debug build runs on the files bundled at build time instead. An older
   or imported session has none: `app_config(download: true)` saves Zapp's now.
3. `ui_show(tab: "info")` to show it to the user.

### storage — read and change what the app has stored

1. `storage_snapshot(layer: "local")` — or `"session"`, `"secure"`, `"all"`.
   With a device connected Beaver asks the app for fresh storage first;
   `refresh: false` reads the last stored snapshot (past and imported
   sessions always do).
2. `storage_set(layer: "local", key: "onboardingDone", value: "false")` —
   `applied` means Beaver re-read storage and saw it; `notApplied` means the
   app kept the old value; `noAnswer` means it didn't send storage back.
   Values can't contain spaces: pick another value.
3. `storage_delete(layer: "local", key: "onboardingDone")`.
4. `logs_wait(filter: {search: "onboardingDone"})` — what the app did with it.

### storage-changes — what changed in storage after login

1. `logs_query(filter: {search: "login"})` — note the id of the line where
   login starts.
2. `storage_diff(beforeEventId: <id>)` — every layer, from the last snapshot
   before that line to the latest (fresh from the app when connected):
   `+` added, `-` removed, `~` changed with old → new; a JSON value lists the
   fields that changed inside it. Or `since: "5m"`; with neither, the whole
   session (earliest → latest).
3. The result lists each layer's `snapshots` (id, time): `storage_diff(layer:
   "local", fromId: <id>, toId: <id>)` compares any two.
4. "Nothing to compare" means one snapshot per layer: Beaver keeps a new one
   only when storage changes, and an imported session has one.

### commands — what the app accepts, and sending one

1. `commands_list()` — names, syntax, descriptions from the app's `cmdlist`.
2. `commands_send(command: "<name> <args>")` — exactly as typed in Beaver's
   command bar; it joins the bar's history.

### act-and-observe — change something and see the effect

1. `commands_list()` — what the app accepts.
2. `commands_send(command: "debug.flag.on newPlayer", collectLogsMs: 5000)` —
   sends it and returns what the app logged in the next 5 s.
3. Or in two steps: `beaver_status()` → note `latestEventId`, then
   `commands_send(command: …)`, then
   `logs_wait(afterId: <latestEventId>, filter: {subsystems: ["player*"]})`.

### restart — the app restarts and you carry on

1. `commands_send(command: "<restart command from commands_list>", collectLogsMs: 20000)`.
2. The result says `sessionChanged: {from, to}` when the app came back in a
   new session, and holds the logs from the new launch. Without `sessionId`,
   `logs_wait` and `commands_send` follow the device; pass `sessionId` to stay
   on one session (you get `sessionEnded: true` when it ends).
3. `deviceDisconnected: true`: the app hasn't come back — ask the user to
   open it.

### devices — two apps connected at once

1. `beaver_status()` — `devices` lists both, e.g. `"12"` (Alpha on iPhone) and `"14"` (Beta on Pixel).
2. `commands_list(deviceId: "14")` — Beta's commands.
3. `commands_send(deviceId: "14", command: "<command>", collectLogsMs: 5000)`.
4. `logs_query(sessionId: 12, since: "5m")` — reads take a sessionId; a device's live session id is its deviceId.
5. `devices_disconnect(deviceId: "12")` — only when the user asks to drop Alpha; an app that reconnects on its own comes back in a new session. With several apps it always needs `deviceId`, even with a default set.

### tv — logs from a smart TV

A TV app (Vizio, Vidaa, other web TVs) has no Beaver SDK: Beaver reads it
over the Chrome DevTools Protocol. The TV's developer mode must be on.

1. Ask the user for the TV's IP address, and the DevTools port if it isn't
   the usual one: Vizio 9555, Vidaa 9226, others 9222.
2. `devices_connect_tv(host: "192.168.1.40", port: 9555, name: "Living room Vizio")`
   — returns its `deviceId`. An error says what to check: the address, the
   port, an app open on the TV, or another DevTools window attached (close
   it). A TV already connected returns its device.
3. `logs_query(sessionId: <deviceId>, since: "5m")` — console lines,
   exceptions (`exception`, with the stack) and log entries; `logs_wait`
   for what comes next. Lines in category `bridge` are Beaver's own: the
   page closed (the app reloaded), the TV can't be reached. The device
   stays connected meanwhile and picks the page up again.
4. Commands, storage and toolboxes don't reach a TV.
   `devices_disconnect(deviceId: "<deviceId>")` stops reading it.

### toolboxes — use what the app offers beyond commands

1. `beaver_status()` — pick the app; with several, `devices_set_default(deviceId: "14")` so you can omit `deviceId`.
2. `toolboxes_list()` — its toolboxes, e.g. `storage (7)`, `app (3)`, `debugfeatures (2)`.
3. `toolboxes_list(toolbox: "storage")` — each tool's arguments.
4. `tools_call(name: "storage.get", arguments: {key: "volume"})` — the app's answer. The summary names the app (`(default)` when the default picked it); Next's `logs_wait(sessionId: …)` reads that app's logs. `tools_call` is marked destructive, so clients that honor destructiveHint ask the user to confirm: app tools can delete data or restart the app.
5. `tools_call(name: "app.restart")` may time out or report a disconnect: the app drops the connection first, so it may still have run. `beaver_status()` shows it back in a new session; the default follows it. The Agent panel notes the drop. An error that says the call didn't reach the app is different: nothing ran, so the same call can be sent again.
6. `toolboxes_list(deviceId: "beaver")` and `tools_call(deviceId: "beaver", name: "logs.query", arguments: {since: "5m"})` — Beaver's own tools the same way (`"beaver"` in any case). Beaver's destructive tools aren't listed there: call them directly. A Beaver tool reached through `tools_call` is marked destructive too (the hint is `tools_call`'s), so call Beaver's tools directly to avoid a confirmation.

### organise — bookmarks, saved filters, a clean screen

1. `bookmarks_list()` — events and requests the user bookmarked.
2. `bookmarks_set(eventId: <id>)` or `bookmarks_set(networkId: <id>)` — mark
   what you found; `on: false` removes the mark.
3. `filters_list()` — their saved filters; reuse one's conditions in
   `logs_query`. The user applies the first nine with ⌘1…⌘9 (alphabetical).
4. `filters_save(name: "Auth problems", filter: {minLevel: "warning", subsystems: ["*auth*"]})`
   — the user can pick it in the Log feed; `filters_delete(name: "Auth problems")`.
   `filters_save(name: "Auth problems", default: true)` makes Beaver start
   from it at launch and when a device connects; `default: false` undoes it.
5. `logs_clear()` — before the user reproduces something: the viewed Log feed
   hides what's there now. Nothing is deleted; note the `watermark` and use
   `logs_wait(afterId: <watermark>)`.

### files — a customer sent a log file

1. `sessions_import(path: "~/Downloads/customer.json")` — a Beaver or
   zapp-support export, or a HAR. The result has the new `sessionId`; the
   user's window doesn't move.
2. `logs_facets(sessionId: <id>)`, then investigate as in `investigate`.
3. `sessions_export(sessionId: <id>, path: "~/Desktop/errors-only.json", filter: {minLevel: "error"})`
   — the same file format, both ways. `format: "har"` writes the requests.
   An existing file is never replaced unless you pass `overwrite: true`.
4. `sessions_delete(sessionId: <id>)` when the user asks to remove it
   (not the live session while the device is connected);
   `sessions_delete(all: true)` removes every session.
5. Imported sessions stay until deleted. Other sessions older than
   `retentionDays` in `beaver_status()` go on their own unless they have a
   bookmark: to keep one, `bookmarks_set(eventId: <id>)` in it, or tell the user
   the setting is in Beaver → Settings… → General.

### issues — what's broken in this session

Beaver 4.18.0 or later.

1. `issues_list()` — the session's warnings and errors grouped by signature:
   `ERROR ×41 com.app/auth: Token refresh failed: <n> (first #812 …, last #9120 …)`.
   Numbers, UUIDs, hex ids, times and URL query values are normalised, as in
   `sessions_compare`. `minLevel: "error"` for errors only. Signatures the
   user ignored as known noise are left out and counted;
   `includeIgnored: true` lists them.
2. `logs_get(ids: [<firstId>])` — the first occurrence in full.
3. `logs_query(filter: <the issue's filter>)` — every event of that issue:
   each row carries `filter: {minLevel, subsystems: [<subsystem>], pattern}`,
   which shows exactly its events (`pattern` works in any filter).
4. `ui_show(tab: "issues")` points the user at the Issues tab;
   `ui_show(filter: <the issue's filter>, select: "first")` at one issue's events.
5. The user says one is expected noise: `issues_ignore(signature: "<signature>")`
   hides it in every session of that app (bundle id, else app name);
   `ignored: false` brings it back. It's their setting — don't ignore on your own.

### compare — "why does it fail on 4.6 but not on 4.5?"

1. `sessions_list()` — find a session that works (4.5, or device A) and one
   that fails (4.6, or device B), **of the same app**: two different apps
   (another bundle id) don't compare. No session that works? Ask the user to
   record one, or import one: `sessions_import(path: …)`.
2. `sessions_compare(a: <works>, b: <fails>)` — log lines only in one side,
   compared by pattern (`Loaded <n> items in <n>ms`: numbers, UUIDs, hex
   ids, times and URL query values don't count), warnings and errors per
   subsystem (▲ = more in b), requests only in one side (`GET host/users/:id`),
   requests whose status class or median duration changed (×2 and
   100 ms or more), storage keys that differ between the two sessions'
   latest snapshots (per layer, with the fields inside JSON values), and App
   Info that differs (versions, Zapp ids, device, plugin versions).
   `sections: ["storage"]` for one part; `limit` for longer lists.
3. Each line has an id: `logs_get(ids: [<firstId>])`, `network_get(id: <firstId>)`,
   or `logs_query(sessionId: <b>, filter: {subsystems: ["<subsystem>"]})`
   for the context around it.
4. Storage within one session (what login wrote): `storage_diff(sessionId: <b>)`;
   everything about one side: `app_info(sessionId: <b>)`.
5. Tell the user what changed first, with ids; the user sees the same in
   Sessions → right-click a session → **Compare with**.

### review-errors — go through the errors with the user

1. `issues_list(minLevel: "error")` — the errors already grouped by cause
   (recipe `issues`). For a time window instead:
   `logs_facets(filter: {minLevel: "error"}, since: "1h")`.
2. `logs_query(filter: {minLevel: "error"}, since: "1h", limit: 500)` — the
   lines themselves.
3. `journal_note(text: "3 causes: token expired ×41, feed 500 ×12, player timeout ×3", links: [{eventId: <first of each cause>}, …])`
   — the user clicks a link to open that event.
4. Found the cause and the user must look now?
   `journal_note(level: "attention", text: "Login fails: the refresh token expired", links: [{eventId: <id>}, {networkId: <id>}])`
   — a toast with **Show**, and a macOS notification when Beaver is in the
   background. Use `attention` only for that.

### notifications — the user doesn't get notified

1. `beaver_status()` — `notifications` is `allowed`, `denied`,
   `notDetermined` or `muted`.
2. `journal_note(level: "attention", …)` returns `notified: false`, a
   `reason` and `howToEnable`. Tell the user in chat, word for word:
   System Settings → Notifications → Beaver → Allow Notifications (style:
   Banners). The Agent panel shows the same path with a button.
3. `muted`: the user turned agent notifications off in Beaver's Agent panel
   on purpose; don't ask them to change it.

### watch — while someone tests, for minutes to hours

1. `watch_start(name: "player errors", filter: {minLevel: "error", subsystems: ["player*"]}, notify: {atCount: 10})`
   — counting starts now. `notify` tells the **user** (an attention note and
   a notification); you are not woken. Without `sessionId` the watch follows
   the device into new sessions.
2. Your turn may end; later, `watch_status(name: "player errors")` — matches,
   first and last ids, counts per level, subsystem, category, whether it fired.
3. `logs_query(afterId: <startId>, filter: {…same…}, order: "oldest")` for the
   lines themselves.
4. `watch_stop(name: "player errors")` — final status. Watches live until
   Beaver quits.

### ui — point the user at something

Everything here happens in the background: Beaver's window changes where it
is, and nothing takes focus. Pass `reveal: true` only when the user asks to
see it.

1. `ui_state()` — what the user is looking at now.
2. `ui_show(filter: {minLevel: "error", subsystems: ["*auth*"]}, select: "first")`
   — the Log feed, filtered, first match selected. `filter` takes the same
   keys as `logs_query`.
3. `ui_show(networkFilter: {status: "errors"}, select: "first")` — the first
   failing request. One method, one status and one host at a time.
4. `ui_show(storage: {layer: "secure", search: "token"})` — the keychain,
   searched.
5. The user says "show me": `ui_show(reveal: true)`. "Next one":
   `ui_show(select: {eventId: <next id>})` — it opens the event's session if
   needed.
6. An event or request hidden by the user's filter fails with the call that
   shows it. `filter: {}` shows every event, including ones the user cleared
   from view.

### schemes — a deep link into the app

The Scheme Generator tab builds every link the apps handle: QuickBrick's
`open` and `present`, the native `xray`, `generateNewUUID` and
`externalLinkAccount`, and any plugin host. Nothing here needs a device,
but a session tells you the app's scheme.

1. `scheme_build(screenType: "movie", id: "42")` — `aio://open?type=movie&id=42`
   for a connected app whose scheme is `aio`: without `scheme`, Beaver reads
   the app's own from the session's storage (`applicaster.v2.urlScheme`;
   `sessionId` picks another session). The summary says where it came from,
   or that `myapp` is a placeholder — then ask the user, or pass
   `scheme: "…"`.
2. Pick what the link does (the result's `does` says it in a sentence, as
   the form does under its template picker):
   - a screen: `screenType` (content type), `screenId`, or `template:
     "feed-content"` with `feedUrl` and `id` or `position` (from 1).
     Optional `state` (inline; fullscreen is the default), `title`, and
     `params` — `open` passes unknown ones to the screen.
   - `template: "present"` — `feedUrl` (sent base64), `screenId`, `id`,
     `resumeTime`; `pushScreen: true` pushes instead of replacing.
   - `linkUrl: "https://…"` — a web page in the app (`contentType`,
     `showNavBar`).
   - `layoutId: "…"` — reload the app with another layout (rivers
     configuration). The one web link that works on every web platform;
     other `mode: "web"` links open a screen on Vizio only.
   - `xrayAction: "connect"` — the device connects to this Beaver
     (remote assistance; debug and TestFlight builds), `pinCode: 1234` for
     release builds; also `logger`, `share-log`, `export-logs`,
     `export-storages`, `enable-websocket`, and settings `fileLogLevel`,
     `showXrayFloatingButton`, `shortcutEnabled`, `mcpServerEnabled`.
   - `template: "reset-uuid"` (new device id, the app asks first),
     `template: "external-account"`.
   - `host: "plugin", params: {pluginIdentifier: "…"}` — a plugin's host.
3. The user wants to see it or scan it: `scheme_build(show: true, …)` fills
   the form on screen and switches to the tab, in the background; the keys
   you pass change the form, the rest stays (`reset: true` starts empty).
   `reveal: true` also brings Beaver forward. `ui_show(tab: "schemes")` just
   opens the tab; `ui_state()` returns the form and its URL.
4. The user asks to copy it: `scheme_build(copy: true, …)` puts the URL on
   their clipboard, like the Copy button. Only when asked — it replaces
   what they copied.
5. `scheme_build(xrayAction: "connect", qrFile: "~/Downloads/connect.png")`
   — a QR code to scan with the device.
