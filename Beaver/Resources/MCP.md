# Beaver MCP

Beaver's MCP server lets an AI agent on this Mac read everything Beaver has
collected from the connected app — logs, network requests, storage, commands —
in the background. Everything the agent calls is listed in Beaver's **Agent**
panel. Design: `plans/2026-09-23-mcp-design.md`.

## Setup

1. Open Beaver. App menu → **Agent Access (MCP)** is on by default and shows
   `127.0.0.1:9081`.
2. App menu → **Copy MCP Setup Command**, and run it:
   ```bash
   claude mcp add --scope user --transport http beaver http://127.0.0.1:9081/mcp
   ```
   `--scope user` installs it for every project, not just the one you're in.
   Cursor, Codex and other clients: add an HTTP MCP server with the URL
   `http://127.0.0.1:9081/mcp`.
3. Connect the device to Beaver as usual. The agent can also read past and
   imported sessions without one.

Port taken? `defaults write ~/Library/Preferences/com.applicaster.LoggerNext mcpPort -int 9082`,
then toggle Agent Access off and on. (The bare domain form resolves to a
sandbox container on a machine that once ran a sandboxed build, which this
non-sandboxed Beaver never reads — the explicit path always hits the right
place.)

## Testing without Xcode

For testers with a built bundle (a PR's "Tester bundle" artifact on CircleCI,
or a release):

1. Unzip `Beaver.zip`, move `Beaver.app` to Applications, open it.
2. Check the app menu shows **MCP: On · 127.0.0.1:9081**.
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
6. Turn **Agent Access (MCP)** off in the app menu: the `curl` above now fails
   to connect.
7. Report problems with the Beaver version (Beaver → About) and the Agent
   panel's **Copy** output.

## Tools

| Tool | What it does |
|---|---|
| `beaver_status` | Device, live and viewed session, latest event id, where the device connects |
| `sessions_list` | Stored sessions, newest first, with app, device and counts |
| `sessions_import` | Open a Beaver / zapp-support JSON or a HAR file as a new session |
| `sessions_export` | Write a session (or a filtered part) as JSON, or its requests as HAR |
| `sessions_delete` | Delete one session, or all |
| `logs_facets` | Counts per level, subsystem, category under a filter and range |
| `logs_query` | Log lines by filter, id range or time; cursor paging |
| `logs_get` | Full events with data and context payloads (256 KB cap) |
| `logs_wait` | Wait up to 60 s for a matching event |
| `network_query` | Requests by status, method, host, text |
| `network_get` | One request with headers and bodies |
| `network_copy` | A request as cURL, fetch() or JSON, with replay warnings |
| `storage_snapshot` | Session / local / keychain storage, fresh from the app when connected |
| `storage_set` | Set a storage key; Beaver re-reads storage and says whether the app applied it |
| `storage_delete` | Delete a storage key, with the same check |
| `commands_list` | Commands the connected app accepts |
| `commands_send` | Send a command to the app; optionally collect the logs it causes, following a restart |
| `bookmarks_list` | Events and requests the user bookmarked |
| `filters_list` | The user's saved filters |
| `beaver_guide` | These recipes, by topic |

Conventions: omitting `sessionId` means the live session, else the viewed one,
else the most recent. Subsystem and category values accept `*` globs, name
fragments and any case; results say what they matched. `since: "5m"` works
wherever ids do. Every result ends with `Next:` suggestions.

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

### organise — what the user marked

1. `bookmarks_list()` — events and requests the user bookmarked.
2. `filters_list()` — their saved filters; reuse one's conditions in
   `logs_query`.

### files — a customer sent a log file

1. `sessions_import(path: "~/Downloads/customer.json")` — a Beaver or
   zapp-support export, or a HAR. The result has the new `sessionId`; the
   user's window doesn't move.
2. `logs_facets(sessionId: <id>)`, then investigate as in `investigate`.
3. `sessions_export(sessionId: <id>, path: "~/Desktop/errors-only.json", filter: {minLevel: "error"})`
   — the same file format, both ways. `format: "har"` writes the requests.
   An existing file is never replaced unless you pass `overwrite: true`.
4. `sessions_delete(sessionId: <id>)` when the user asks to remove it;
   `sessions_delete(all: true)` removes every session.
