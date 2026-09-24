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

Port taken? `defaults write com.applicaster.LoggerNext mcpPort -int 9082`, then
toggle Agent Access off and on.

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
4. Connect Claude Code (Setup, step 2) and ask: "What is Beaver connected to?
   Show me the last errors." It should call `beaver_status`, then
   `logs_facets` / `logs_query`.
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
| `logs_facets` | Counts per level, subsystem, category under a filter and range |
| `logs_query` | Log lines by filter, id range or time; cursor paging |
| `logs_get` | Full events with data and context payloads (256 KB cap) |
| `logs_wait` | Wait up to 60 s for a matching event |
| `network_query` | Requests by status, method, host, text |
| `network_get` | One request with headers and bodies |
| `network_copy` | A request as cURL, fetch() or JSON, with replay warnings |
| `storage_snapshot` | Latest session / local / keychain storage snapshot |
| `commands_list` | Commands the connected app accepts |
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
2. Ask the user to do the action on the device (or do it yourself once
   command tools exist).
3. `logs_wait(afterId: <latestEventId>, filter: {search: "…"}, timeoutMs: 30000)`.
4. Timed out? `logs_query(afterId: <latestEventId>)` shows what did arrive.

### network — a failing request

1. `network_query(status: "errors")`.
2. `network_get(id: <id>)` — headers and bodies.
3. `network_copy(id: <id>, format: "curl")` — to replay it; the result says
   which headers were redacted and whether the body was cut.

### storage — what the app has stored

1. `storage_snapshot(layer: "local")` — or `"session"`, `"secure"`, `"all"`.
2. No snapshot? Ask the user to open Beaver's Storages tab while the device is
   connected.

### commands — what the app accepts

1. `commands_list()` — names, syntax, descriptions from the app's `cmdlist`.

### organise — what the user marked

1. `bookmarks_list()` — events and requests the user bookmarked.
2. `filters_list()` — their saved filters; reuse one's conditions in
   `logs_query`.
