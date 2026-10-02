# Beaver — Changelog

All notable user-facing changes to Beaver go here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely, and
versions track [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

Add your change under `[Unreleased]`. Releasing is automatic: every merge
to `main` releases (D23), and CI's `version X.Y.Z [skip ci]` commit moves
the `[Unreleased]` items into `## [X.Y.Z] - YYYY-MM-DD`, which becomes the
GitHub Release notes (`scripts/changelog-release.sh`, D90). `make bump`
does the same for a manual release.

## [Unreleased]

### Fixed
- **No empty sessions from a silent connection.** An app in the background
  keeps retrying its socket every ~30 s; each attempt that sent nothing
  before it closed left an empty "Ended" session in the list. Such a
  session is now dropped when its connection closes. A connection that sent
  at least one frame keeps its session, even with no events.

## [4.20.3] - 2026-10-01

### Fixed
- **No more piles of empty live sessions.** A device whose connection said
  nothing at all after the handshake (an iPhone sink losing its ping/pong
  opens a new socket every ~30 s and never closes the old one) stayed a live
  session for good. Beaver now closes a connection that sends no frame, not
  even a ping, within 15 s. Agent-visible: `beaver_status` and
  `sessions_list` stop listing those ghosts.

## [4.20.2] - 2026-10-01

### Fixed
- **Commands reach zapp-xray-companion.** The companion app on a TV
  registers like a DevTools bridge, so Beaver treated it as logs-only and
  refused every command. Only a DevTools bridge (`platform: "tv-cdp"`) is
  logs-only now; the companion gets commands, `cmdlist` and storage like any
  device. Agent-visible: `commands_send` works for it.

## [4.20.1] - 2026-09-30

No user-facing changes.

## [4.20.0] - 2026-09-30

### Added
- **What the app was built with.** When an app with X-Ray's native sink
  connects, Beaver asks it for its `app.info` and its build's plugins
  (`build.plugins`), and keeps the answer with the session.
  - Info shows **Built into the app**. For version, build, SDK, QuickBrick
    and layout id the app's own answer wins; a storage value that differs
    shows under it in orange, e.g. "Build number (storage)", with a ⚠ line
    naming what differs.
  - **Plugins** lists each plugin's build version next to Zapp's current
    one. Plugins that differ come first, under a ⚠ line saying
    how many; their versions and status are orange. A plugin whose version differs is marked "rebuild to pick it up":
    plugin versions change only with a rebuild, while their configuration
    comes from Zapp at launch.
  - When the build's list isn't known, Plugins shows Zapp's list marked
    **build not confirmed**, with the reason: an older X-Ray, an app built
    with an older QuickBrick CLI, or an app that wasn't connected with the
    native sink.
  - Agents get the same in `app_info`: `buildPlugins`, `pluginsConfirmed`
    and `build`.

## [4.19.0] - 2026-09-29

### Added
- **Info → Config files** lists every file the app loads at launch, not just
  three: remote configurations, plugin configurations, layout, cell styles,
  presets mapping and pipes endpoints (and the tablet variants when the Zapp
  CMS names them) — found without a Zapp token too, through the app's
  storage and `remote_configurations.json`. The URLs the app itself keeps
  in storage (`applicaster.v2` → `layout_url`, `cell_styles_url`,
  `endpoints_url`, `styles_url`…) come first, and each row says which key.
- **Config files are saved with the session**: when a device connects,
  Beaver downloads them and keeps them with its session, so the session
  shows Zapp as it was then, not after the next publish. **Open** shows a
  file in your JSON viewer; an older or imported session can **Save with
  Session** (Zapp's current files). A file shared by several sessions is
  stored once. Agents: `app_config` reads a saved file by path
  (`general_settings.layout_id`, `screens.0.name`).
- **Info → Type mapping**: which screen opens each entry type (layout.json's
  `content_types`: `audio` → Audio Player). Info is laid out anew: app
  identity, device, user agent and advertising on the left, so every id is
  together; screens, type mapping, plugins, cell styles and config files on
  the right. Ids in the tables have a copy button on hover. Agents get the
  type mapping in `app_info`.
- **Info shows more of the app**:
  - **Navigation**: each menu and tab item and the screen it opens.
  - **Data sources**: the feeds the app requests and the storage keys each
    one sends.
  - **Sign-in**: whether those keys, such as the login token, are stored.
    It shows only "stored" or "not in storage", never a value, and checks
    the keychain too.
  - **Languages**, and the app's strings file for the device's language,
    saved with the other config files.
  - The app's **icon** in the header.
  - More from the app's storage: its URL scheme, sessions of this version
    and in total, country code, region, currency and right-to-left.
  - Agents get all of this in `app_info`.

### Fixed
- **Info shows the versions the app runs, not Zapp's latest build.** With a
  Zapp token, Info showed the CMS's build parameters over the app's own:
  they describe the Zapp version's newest build (70), not the one on the
  device (66). Info now reads the app's storage only.

### Removed
- **The Zapp token** (Settings → Zapp): the app's storage already names its
  versions and config files. A token saved by an older Beaver is removed
  from the keychain at launch.

## [4.18.0] - 2026-09-29

### Added
- **Issues**: a new sidebar tab under Log feed lists the session's errors
  and warnings grouped by what they say — `Token refresh failed: <n>` ×41 —
  with the level, count, first and last time and a small timeline, like
  Sentry but local. Numbers, ids and times are ignored when grouping, the
  same way Compare does. Sort by newest, most frequent or errors first;
  switch to errors only. Click one to see exactly its events in the Log
  feed, the first one selected; right-click to copy it or **Ignore** it as
  known noise — it stays hidden in every session of that app (**Show
  ignored** brings it back). While a device is connected new issues appear
  at the top, briefly highlighted. The sidebar badge counts error issues,
  the Log feed's filter bar has a ⚠ chip that opens the tab, and Sessions
  shows each session's issue count and top three. Agents: `issues_list`
  and `issues_ignore`, and a `pattern` key in every log filter.

## [4.17.0] - 2026-09-29

### Added
- **Connect a TV…**: read a smart TV app's logs (Vizio, Vidaa, other TVs
  with remote debugging on) from Beaver itself — no Node, no zapp-support
  checkout. Open it from the Connected pill's menu, the "waiting for a
  device" screen, or the Beaver menu; type the TV's IP address and DevTools
  port (Vizio 9555, Vidaa 9226, others usually 9222) and an optional name.
  The TV shows up like a phone that only sends logs: console lines,
  exceptions and log entries, with the TV's own timestamps. Connection
  problems say what to check (wrong address, no DevTools on that port, a
  DevTools window already attached). The last five TVs are one click away.
  Disconnect stops reading it. Agents: `devices_connect_tv`.

### Fixed
- The command bar is off while a TV (through the TV bridge) is viewed and
  says why: the TV sends logs only, so a typed command used to be dropped
  without a word.

## [4.16.0] - 2026-09-29

### Changed
- The device badge's popover no longer lists the app's toolboxes: they're
  in Sessions → the session's details. **Toolboxes in Sessions** in the
  popover takes you there.

### Added
- **Settings window**: Beaver → **Settings…** (⌘,), or the **gear** at the
  bottom of the sidebar. **General**: how long sessions are kept and their
  size on disk. **Agents**: Agent Access (MCP) on or off, its **port** (type
  one and Apply — no more `defaults write`), Copy MCP Setup Command, and
  agent notifications. **Zapp**: whether a Zapp token is set, Save/Replace,
  Remove, and **Test**, which asks Zapp whether it accepts the token.
  **About**: version, What's New and Check for Updates. The Info tab's
  **Set Zapp Token…** opens the Zapp tab.
- Settings → General → **Delete All Sessions…** (asks first) removes every session, as Sessions → Delete all sessions… does. Text in Settings and What's New can be selected and copied.
- **What's New**: the first launch of a new version shows what changed
  since the version you ran before. Beaver → **What's New…** and Settings →
  About show every release back to 1.0, any time.

### Changed
- The settings left the Beaver menu for the Settings window: Delete
  Sessions Older Than, Agent Access (MCP), Zapp Access Token… and Agent
  Notifications. The menu keeps its actions: Check for Updates, What's
  New…, Copy WebSocket Address and Copy MCP Setup Command.

## [4.15.0] - 2026-09-29

### Added
- **Smart TVs (Vizio, Vidaa, …) show up in Beaver like a phone.** Run
  zapp-support's TV bridge against Beaver:
  `node scripts/tv-bridge.mjs <tv-ip>:<devtools-port> --server ws://127.0.0.1:9080 --name "Living room Vizio"`.
  The TV's console lines and exceptions arrive under subsystem `tv-cdp`; the
  device is named after `--name` (else the app's page title), shows as
  "TV (DevTools)", and is followed across bridge reconnects. It only sends
  logs: Beaver asks it for no commands or storage, the device popover says
  it has no toolboxes, and agents' commands, storage changes and toolboxes
  are refused for it (`beaver_status` shows `platform: "tv-cdp"`).
- Log lines with the browser console's levels `warn` and `log` are read as
  warning and info instead of being rejected.

## [4.14.2] - 2026-09-29

### Fixed
- Text in Beaver's panels can be selected and copied: Info, Storages,
  Network (and its expanded sheet), the event detail pane, Sessions
  details, the Scheme Generator, the compare sheet, the Agent panel, the
  device popover and the storage Changes and value popovers. Rows of the
  Log feed, Network and Sessions lists still select on click and copy with
  ⌘C; rows that expand on click (storage keys, JSON trees) keep doing so.
  Info values copy with a button that shows on hover.

## [4.14.1] - 2026-09-29

### Added
- Network: the request detail shows the SDK's **Request ID** (with a copy
  button), to find the request in the app's own logs. Agents:
  `network_get` returns it as `requestId`.

## [4.14.0] - 2026-09-29

### Added
- **The Log feed's Filter field understands the web logger's query
  syntax**, so one query works in Beaver and zapp-support:
  `level:error sub:*auth* -heartbeat`. Words must all match; `OR` joins
  alternatives, `-word` excludes, `"a phrase"`, `/regex/`, and `level:`
  (exactly that level), `sub:`, `cat:` (`*` globs), `msg:` search one
  field. The **?** in the field lists the syntax; an unclosed quote or a
  broken regex outlines the field in red. With `.*` on, the whole text is
  still one regular expression. Several words now match wherever they are
  in the row (before, only side by side): quote them for the old
  behaviour. Agents: `filter.search` in `logs_query`, `logs_facets`,
  `ui_show` and the other filter tools takes the same syntax
  (`beaver_guide(topic: "query")`).

## [4.13.0] - 2026-09-29

### Changed
- Compare also compares **storage** (each layer's latest snapshot, key by key, with the fields inside JSON values) and **App Info** (versions, Zapp ids, device, plugin versions), in the sheet and in `sessions_compare` (default: all four sections).
- Compare works only on sessions of the same app (same bundle id, else app name); the menus offer only those, and `sessions_compare` says why it refuses two different apps.

### Fixed
- The Agent button's count no longer hides under the window's rounded
  corner.
- The Info tab uses the window's width: app and device side by side when
  there's room.

## [4.12.0] - 2026-09-29

### Added
- **Sessions: click a session to see its details** on the right — times,
  status, the device and device id, **Disconnect** (red), **Default for
  agents** (ⓘ explains it) and the app's toolboxes, which open with a short
  animation. **Open**, a double-click or Return opens it in the Log feed;
  a click no longer does.

## [4.11.0] - 2026-09-28

### Added
- **Info tab**: App & Device Info for the viewed session, as in zapp-support — app, SDK and QuickBrick versions, Zapp ids, the layout's screens, cell styles and plugins (from the app's config files on Zapp's bucket), the device, language, country and advertising id. Every value says where it came from; click to copy. **Copy Fingerprint** now also gives the device id, bundle id, session and time. App menu → **Zapp Access Token…** adds the Zapp CMS's build parameters (your own token, kept in the keychain). Agents: `app_info`, `ui_show(tab: "info")`.

### Fixed
- Sessions left open by quitting Beaver (or a crash) while a device was
  connected no longer stay "Live" for ever: they end at their last event
  when Beaver starts.
- The row separator under a live session in Sessions runs the full width
  again.

## [4.10.1] - 2026-09-28

### Fixed
- **Events a device sends just before it disconnects are no longer lost.**
  When the connection closed, Beaver could stop reading while the last
  few frames were still waiting, or show them after the session ended.
  It now reads every frame that arrived, then ends the session.

## [4.10.0] - 2026-09-28

### Added
- **Compare two sessions** — "it works on 4.5, not on 4.6", "works on
  device A, not on B". Sessions → right-click a session → **Compare with**
  → pick the other. A sheet lists log lines only in one of them (numbers,
  ids, times and URL query values don't count, so `Loaded 42 items in
  118ms` matches `Loaded 7 items in 95ms`), warnings and errors per
  subsystem A vs B, requests only in one (ids in the path don't count),
  and requests whose status class or median duration changed. Click a
  line to open that event or request. Storage and App Info comparisons
  come later. Agents: new tool `sessions_compare(a, b, sections?)`.

## [4.9.0] - 2026-09-28

### Added
- **Storage changes.** Storages → **Changes** compares the layer on screen
  with an earlier snapshot of the session (pick its time): keys added,
  removed and changed with old → new, and for a JSON value the fields that
  changed inside it. Works on past and imported sessions; an imported one
  usually has a single snapshot, so there is nothing to compare. Agents:
  new tool `storage_diff` (earliest → latest by default; `since`,
  `beforeEventId`, or `fromId` / `toId`), and a `storage-changes` recipe —
  "what changed in storage after login".

## [4.8.0] - 2026-09-28

### Added
- **Old sessions are deleted automatically.** Beaver menu → **Delete
  Sessions Older Than** 7 / 30 / 90 Days / Never (default 30 days); the
  menu also shows how much disk the sessions use. Checked a few seconds
  after launch and then daily; a toast says how many went and the space
  freed. Never deleted: a connected device's session, imported sessions,
  and any session with a bookmarked event or request. The first launch
  with this only announces it (with **Keep All** to switch to Never);
  deleting starts a day later, or at once when you pick a period in the
  menu. `beaver_status` reports the setting
  (`retentionDays`) and the store's size (`storeBytes`).
- **Find in the event detail pane:** ⌥⌘F (or the magnifier next to the
  level) opens a find bar over the selected event. It matches the message
  and the keys and values of DATA and CONTEXT, highlights every hit, shows
  "n of N", and Return / ⇧Return step through them, opening collapsed rows
  and "Show more" pages to scroll each one into view. `.*` for regex, Esc
  closes. ⌘F still filters the feed.

## [4.7.0] - 2026-09-28

### Added
- **⌘1…⌘9 apply your saved filters** — the 1st…9th in the ★ popover,
  which shows each one's shortcut. From another tab, they switch to the
  Log feed.
- **A default saved filter.** Click the pin next to a saved filter in the
  ★ popover: Beaver starts from it at launch and whenever a device
  connects, instead of the last filter used. Agents: `filters_list` shows
  the default and the shortcuts; `filters_save(name:, default: true)`
  sets it.

## [4.6.0] - 2026-09-28

### Added
- Drop a session file (`.json`) or HAR anywhere on the window to import
  it, the same as Import. A file Beaver can't open now says so instead of
  doing nothing.
- The command bar remembers sent commands across launches (↑/↓, the
  newest 50).
- The Log feed shows a banner with Retry when it can't read the session,
  instead of silently showing stale rows.

### Changed
- The reply to the `cmdlist` Beaver sends on connect no longer shows up in
  the Log feed; a `cmdlist` you or an agent send still does.

## [4.5.2] - 2026-09-28

### Fixed
- A toolbox request stuck behind a slow one gives up after its own timeout
  and says the app is busy (nothing ran), instead of waiting indefinitely.
- Agents: `tools_call` on a restart, kill or launch tool watches for the app
  dropping only once the call is sent, and stops watching when the app
  answers with an error, so a later unrelated drop isn't pinned on it.

## [4.5.1] - 2026-09-28

### Changed
- Agents: `tools_call(deviceId: "beaver")` returns Beaver's result under
  `structuredContent`; on an app, `tools_call` returns `structuredContent`
  when the app sent one and `text` otherwise.

### Fixed
- Agents: `tools_call` is marked destructive, so clients that honor
  destructiveHint ask you to confirm, since an app tool can delete data or
  restart the app. Restart, kill, launch and
  execute tools are marked destructive in the Agent panel, also when the app
  drops before answering, and the panel notes the drop.
- Agents: device tools name the app a call went to (and "default" when the
  default device picked it), and their suggested `logs_wait` reads that
  app's session, not the newest one. `devices_disconnect` needs `deviceId`
  whenever several apps are connected, default or not.
- Agents: `tools_call` counts images and other non-text items instead of
  dropping them, and doesn't repeat the app's answer three times;
  `deviceId: "Beaver"` works in any case; `beaver_status` marks one default
  device; a toolbox without a read tool no longer suggests a mutating one.
- Toolbox loading retries after a native app that was merely slow to answer
  once — it no longer gets stuck saying the app doesn't support MCP until it
  reconnects.
- Requests to a connected app's toolboxes go one at a time, so a slow tool
  call no longer makes an unrelated request to the same app time out.
- Agents: a `tools_call` that never reached the app — it didn't answer
  `initialize`, or disconnected while the call waited its turn — says
  nothing ran and gives the same call to try again, instead of "it may
  still have run". The device popover says why too.
- The toolbar badge and device popover show the app's real device model,
  platform and OS once quick-brick-xray's own storage harvest arrives,
  instead of sticking with whatever the handshake alone reported.
- Device popover: a Retry button when an app doesn't answer MCP,
  accessibility labels on the icon-only buttons and the live/connected
  indicator, and long app- or device-supplied text now wraps within a limit
  instead of overflowing the popover.
- Only the one live session a shared device id resolves to is marked
  "default for agents" — not every session that happens to share it. On
  that device's other sessions the toggle is disabled and says why.
- PROTOCOL.md, the design plan and DECISIONS.md corrected against the real
  SDK behavior found in the bug hunt (frame encoding, Android's handshake
  order and lack of reconnect, and more).

## [4.5.0] - 2026-09-28

### Added
- **Updates install themselves.** Beaver checks for a new version on every
  launch and downloads it in the background. When it's ready, choose
  **Restart Now** or **Later**; Later installs it when you quit Beaver.
- Scheme Generator: under the template picker, a line says what a link of
  that template does in the app. Agents get the same text: `scheme_build`
  lists it for every template and returns it as `does`.

## [4.4.2] - 2026-09-28

### Fixed
- A device whose app closes its socket is disconnected at once. Before, if
  the socket closed cleanly (no reset), Beaver never noticed, and the
  device and its session stayed live until you disconnected it by hand.

## [4.4.1] - 2026-09-28

No user-facing changes.

## [4.4.0] - 2026-09-28

### Added
- Click the device badge on the left of the toolbar: the app's name, bundle id,
  device and device id, a Disconnect button, "Default for agents", and the
  app's toolboxes with each tool's arguments (apps built with quick-brick-xray's
  native WebSocket sink).
- Agents: `toolboxes_list` and `tools_call` reach a connected app's toolboxes
  (and Beaver's own tools as `deviceId: "beaver"`, its destructive tools left
  out — call those directly instead); `devices_set_default` picks the app
  device tools use when `deviceId` is omitted — it follows the app across
  restarts. `beaver_status.devices` gains `default`, `uid`, `appPackage`.
  An app tool that deletes, removes, clears, kills or resets shows the
  destructive toast in the Agent panel.
- The Agent panel's "What an agent can do" covers several connected apps,
  the default app and each app's toolboxes.

### Changed
- An app that restarts is recognised by its device id, so two identical builds
  on two simulators are no longer confused.

## [4.3.0] - 2026-09-28

### Added
- **Scheme Generator.** A new "Tools" section in the sidebar builds deep
  links into a Zapp app: open a screen or a feed entry, present a feed, a
  web page or another layout, X-Ray (open the logger, connect the device
  to this Beaver, a remote assistance PIN, share or export logs, logger
  settings), reset the device ID, external account, or any plugin host —
  with extra parameters, Copy and a QR code to scan with the device. The
  app's own scheme comes from the active session's storage.
- Agents: new tool `scheme_build` builds the same links — with the
  connected app's own scheme, read from its storage, unless given — fills the Scheme
  Generator form on screen (`show: true`, in the background), copies it to
  the clipboard (`copy: true`) and saves a QR code (`qrFile`).
  `ui_show(tab: "schemes")` opens the tab and `ui_state` returns the form
  and its URL.

## [4.2.0] - 2026-09-28

### Added
- Several devices can be connected at once. Click the Connected pill in
  the middle of the toolbar to switch between them or open a recent
  session. A device that connects doesn't take the window while you're
  looking at another live one.
- **Disconnect** a device: the red Disconnect button on a live session in
  Sessions, or Disconnect in the Connected pill's menu. An app that
  reconnects on its own comes back in a new session.
- Agents: `beaver_status` lists every connected device; with more than one,
  `commands_send`, `commands_list` and storage changes take `deviceId`.
  New tool `devices_disconnect`. A device's id is now its live session id
  (`"12"`); `deviceId: "current"` still works while one device is
  connected.

## [4.1.2] - 2026-09-25

### Fixed
- A device that connects is shown at once, even if a past or imported
  session was open — before, you had to pick it in Sessions by hand.

## [4.1.1] - 2026-09-25

### Fixed
- Double-clicking empty space in the toolbar zooms the window again —
  before, only the strip above the sidebar did.

## [4.1.0] - 2026-09-24

### Added

## [4.0.1] - 2026-09-24

### Changed
- **Release notes in order.** The changes of 2.0.2, 3.0.0 and 4.0.0 are
  now listed under their own versions. 3.0.0 and 4.0.0 continue Agent
  Access (2.0.0); nothing in them breaks what 2.0.0 does — the major
  versions came from how they were merged, not from the changes.

## [4.0.0] - 2026-09-24

### Added
- **Agent Access: the agent can point Beaver at something.** Asked to show
  the failed requests or the auth errors, it switches the tab, session,
  filters, storage layer and selected row while Beaver stays in the
  background. Beaver comes forward only when the agent passes
  `reveal: true`, which agents are told to do only when you ask to see it.
  In the **Agent** panel, a call that touched a session, event or request
  links to it — click to open it.

## [3.0.0] - 2026-09-24

### Added
- **Agent panel: what an agent can do.** The ⓘ button in the Agent
  panel's toolbar opens a tour of Beaver's MCP capabilities — logs,
  network, storage, commands, watches, sessions, bookmarks and filters —
  each with a prompt to copy. **Hide reads** moved to the end of the
  panel's toolbar and its tooltip explains what a read is.
- **Agent Access: agents can act, not just read.** Through Beaver's MCP
  server an agent can send commands to the app (and collect the logs they
  cause, following the app across a restart), set and delete storage keys
  with the same check the Storages tab does, import, export and delete
  session files, clear the Log feed, bookmark, save and delete filters,
  and watch for matching logs for minutes or hours. It tells you what it
  found with notes in the Agent panel whose links open the event, request
  or session. Deletions and notes that need you show a toast; those notes
  also raise a macOS notification when Beaver is in the background, and a
  Dock badge. The Agent panel and the app menu (**Agent Notifications**)
  say where to turn notifications on, and the panel can mute them.

## [2.0.2] - 2026-09-24

### Fixed
- **Events sent right after a device connects are no longer lost.** What
  the SDK sent the moment it connected (for example, events it buffered
  while disconnected) could arrive before Beaver had opened the live
  session and was silently dropped. The session now always exists
  before the first event is stored.

## [2.0.1] - 2026-09-24

### Fixed
- **No more "decode failed: notJSON" every 20 seconds.** The SDK's keepalive
  ping reached the decoder as if it were a log frame and showed up as a
  `loggernext.protocol` warning in the feed. Beaver now answers pings and
  ignores control frames.

## [2.0.0] - 2026-09-24

### Added
- **Agent Access (MCP).** An AI agent on this Mac (Claude Code, Cursor,
  Codex) can read what Beaver collected — sessions, logs, network requests,
  storage, the app's commands — through an MCP server on
  `127.0.0.1:9081`. App menu → **Copy MCP Setup Command** connects Claude
  Code in one line, installed for every project (`--scope user`); **Agent
  Access (MCP)** turns it off. The new **Agent** toolbar button lists
  everything an agent did, with a badge for what you haven't seen, and
  **Connect agent** shows how to hook up Claude Code, Cursor or any other
  MCP client — Claude Code, Cursor, Perplexity (also in the README).
- **Log feed: the filter survives reconnects and relaunches**, and
  changing it keeps the selected row when it still matches.
  Right-click → **Show in Context** clears the filter and lands on the
  row.
- **Log feed: multi-select and ⌘C.** Selected rows copy as
  `HH:mm:ss.SSS [LEVEL] subsystem/category: message` lines. The detail
  pane has **Copy data** / **Copy context**.
- **Log feed keyboard:** ⌘F focuses Search & highlight, ⌘G / ⇧⌘G step
  through matches, `e` / `⇧E` jump to the next / previous error.
- **Log feed: Time column shows its time zone**, plus an optional
  **Δ** column (right-click the header): the time since the previous
  row, or since the selected row when one is selected.
- **Log feed: "⏎ N lines" badge** on rows whose message is cut off.
- **Log feed: search event data.** The `{}` chip on Filter / Exclude
  also matches each event's JSON payload. It's off by default, since
  it's slower on big sessions, and saved filters keep it.
- **Import opens zapp-support files.** Its log export (any level
  spelling — `WARN`, `err`, `fatal`, `trace`, `"2"`…) and its storage
  export now open like Beaver's own. A line with an unknown level opens
  as info with the original kept in context as `originalLevel`, instead
  of being silently dropped. zapp-support HAR files already opened in
  Network. Every Beaver file opens exactly as before.
- **Import never drops a line for a missing field.** A line without a
  subsystem opens as "Unknown", without a message shows the whole line, and
  without a timestamp gets the import time — the same as zapp-support.
- **Storages: edit and copy-key on every key row.** Hover a key for
  **copy key / copy value / edit / delete**; edit reuses the Add-key
  sheet with the key locked. Namespace rows show **＋ / copy** right
  next to the name, and Add key is now a green **＋** tile beside the
  Session / Local / Keychain tabs.
- **Storages: changed values flash.** After a Reload or auto-refresh,
  keys that appeared or changed get a brief yellow highlight (a
  collapsed namespace flashes on their behalf).
- **Storages: spaces are caught before sending.** The device splits
  commands on spaces, so a space in the key, namespace or value blocks
  Save, and the warning says what the device would do instead ("it
  would store `a` in a namespace named `b`"). JSON values are sent
  compact; a JSON string containing a space still blocks, explained.
- **Storages: edits are checked.** After a save or delete Beaver reads
  the key back from the next snapshot and says **Applied** (with
  **Undo**) or **Device didn't apply this — see the log**. Keychain
  writes ask first. Edit / delete hide for a layer whose command the
  device doesn't list in `cmdlist`.
- **Storages: multi-line value editor.** Stored JSON opens
  pretty-printed and must parse before Save; smart quotes stay off.
- **Storages: search shows matches per layer.** Each tab shows its
  match count; clicking it jumps to that layer's first match.
- **Storages: ⌘F** focuses search, **⌘R** reloads, and a row's
  right-click menu has **Edit… / Delete…**.
- **Storages: "as of" time and a Disconnected — cached strip** show
  how old the storage on screen is.
- **Storages: Export storage only**, with **Redact Keychain values**
  on by default. The file uses zapp-support's
  `{storageType: {namespace: {key: value}}}` shape and opens in Beaver.
- **Storages: the full-value popover has the row's buttons** — copy key,
  copy value, edit, delete — plus **copy decoded value** (pretty-printed
  JSON / decoded text) for JSON-string, Base64 and JWT values.
- **Storages: edit and delete fields inside a JSON value.** Expand a
  value stored as JSON text (e.g. `player-storage` →
  `{"volume":0.8}`) and hover a field for **edit / delete**. The SDK
  can only replace a whole key, so Beaver rewrites the JSON with that
  one change and sends it back; the sheet previews the full command.
  Base64 and JWT values stay read-only (re-encoding / a broken
  signature). Row buttons on top-level keys now appear on hover, like
  inner rows.
- **Storages: layer tabs show an icon** (clock / database / lock), the
  name in sentence case and a namespace count with a tooltip; empty
  layers are dimmed.

### Fixed
- **Log feed: live streaming no longer refetches the session.** Each
  append fetches only the new rows and merges them in place, including
  events that arrive late with an earlier timestamp. On a 100k-event
  session an append drops from ~150 ms to under a millisecond. Past
  the 1M-row cap the feed now keeps the newest rows, not the oldest.
- **Log feed: `%` and `_` in Filter / Exclude are literal**, regex
  terms ignore case like plain ones, and an invalid regex outlines its
  pill in red instead of silently showing no rows.
- **A failed write shows an error toast** instead of dropping events
  silently.
- **Storages: unchanged snapshots no longer pile up.** Auto-refresh
  stored a full copy of every layer every 2 s; an unchanged report now
  only updates its time.
- **Storages: overlapping reloads could show stale values** and flash
  rows that hadn't changed. A reload that has been overtaken is dropped.
- **Storages: the delete dialog** no longer mentions other devices.
- **Storages: the list could stop updating.** After a new snapshot
  arrived the key list could keep showing old values until the tab was
  reopened. It now refreshes as soon as the device reports new storage.
- **JSON `0` and `1` showed as `false` / `true`** in every tree (storage,
  log detail). They are numbers again; only real booleans read as such.
- **Storages: keys stored without a namespace** (the SDK reports them
  as `{"player-storage": {"undefined": …}}`) now show as a plain key,
  and edit / delete target the key itself instead of `undefined`.

### Changed
- **Log feed follows the tail by being at the bottom (D3).** Scroll up
  and it stops; a floating **N new ↓** pill counts what arrived and
  takes you back. The Auto-scroll toggle is gone.
- **Log detail pane:** the message is a monospaced, scrollable block,
  and very large payloads show 200 entries per level with
  **Show more**.
- **Storages tab restructured (D30 + D31).** Session / Local /
  Keychain are back as **tabs at the top** (one layer visible at a
  time). Inside each tab, every **namespace** (`applicaster.v2`,
  `continue-watching`, etc.) is an **expandable row** — click the
  chevron (or anywhere on the row) to reveal its inner
  `key: value` pairs inline. Per-row icons:
  namespace rows have **copy-all-as-JSON / add-key-inside**
  (no delete — the SDK can't wipe a whole namespace in one call);
  scalar top-level and inner key rows have **copy-value / trash**.
  The right-side detail pane is gone — everything's visible inline,
  and deeply nested values can be inspected via copy-as-JSON.
- **Tab switches preserve per-screen state (D32).** Log feed and
  Storages no longer lose filter / sort / exclude / selected
  layer / expanded namespaces / search term when you jump
  between tabs. State only resets when the *session* changes,
  which is the expected reset point.
- **Storages tab redesigned with better information density
  (D37).** Inner rows use a larger monospaced font with more
  breathing room. Every other row picks up a zebra-stripe tint
  so long lists are easier to scan. A new hover-revealed
  expand button on long strings and container values opens a
  read-only popover with the full content monospaced and
  scrollable. Namespace tab chips are a little bigger so they
  read as proper navigation.
- **Add-key sheet now inherits the active layer.** The
  Session / Local / Keychain picker is gone — the sheet uses
  whichever tab you opened it from and shows the chosen layer
  as a small colour-coded chip in the title row. There's a new
  optional "Namespace" field if you want the new key to land
  inside a subscope (e.g., `applicaster.v2`); leave it empty to
  write at the layer's root.

### Removed
- The unused full-text index (`event_fts`) and its triggers — inserts
  and session deletes no longer pay for them (D40).
- **Inline edit on storage values.** Changing a value now means
  delete + add. The common case (flip a feature flag) is binary
  anyway; keeping edit would re-introduce a sheet for a flow that
  should be peek-and-poke.
- **Editing affordances on past sessions (D35).** Add / Reload /
  Auto-refresh / per-row add and delete now stay hidden when
  viewing any session other than the live one — those buttons
  would silently no-op because the device that recorded the past
  session is gone. Read-only (copy, expand, search, export) stay
  available so past sessions are still browsable.

### Added
- **Network tab.** A new tab lists every HTTP(S) request the SDK
  reports (`network` wire frames, PROTOCOL.md §4.3): method, host +
  path, status (colour-coded: green 2xx, orange 4xx, red 5xx/
  failed), and duration. Select a row to see request/response
  headers and the body rendered as a JSON tree. Filter by search
  text, method, status class, or host (include/exclude); the filter
  bar mirrors the Log feed's. Rows persist per session and reopen
  with it; clearing the log feed clears the Network tab too. Sent
  today by iOS (quick-brick-xray ≥ #2676); Android support is in
  review ([Zapp-Frameworks#2869](https://github.com/applicaster/Zapp-Frameworks/pull/2869)).
  Each request also still appears once in the Log feed under
  `native_application/network_requests` — that's the SDK's existing
  behaviour and is unchanged (D39).
- **Session export/import now include network requests.** An
  exported file carries a top-level `"network"` array alongside
  `"events"` and `"storage"` whenever the session has any; importing
  a file replays those entries back into the new session, same as
  events and storage.
- **Device context in the toolbar.** A small chip on the leading
  edge of the toolbar shows the app name, version, device model,
  platform, and OS that recorded the active session. Pulled from
  the SDK's well-known `applicaster.v2` storage namespace.
  Right-click the chip → "Copy device fingerprint" copies the
  joined string for pasting into bug reports.
- **Device fingerprint persisted per session (D34).** A schema
  migration adds `app_name`, `app_version`, `device_model`,
  `platform`, and `os_version` columns to the `session` table.
  Captured automatically the first time `applicaster.v2` arrives,
  then surfaced on Session list rows so past sessions show
  "Miami Heat 11.0.1 · iPhone 15 Pro Max · iOS 26.4.2" instead of
  just a timestamp. Sessions recorded before this build stay
  blank — only future ones backfill.
- **Toast notifications (D33).** A small chip slides down from
  the top of the window after every copy / save / delete /
  bookmark / filter action and self-dismisses after 2 seconds.
  Confirms actions that used to be silent (especially copies to
  the clipboard).
- **"Show level and above" right-click action.** New entry in the
  log row context menu sets the minimum level to the row you
  clicked — right-click a Warning to instantly hide verbose /
  debug / info noise. A sibling "Reset level to Verbose" appears
  when a level filter is active.
- **One-click install URL (D36).** New landing page at
  `https://applicaster.github.io/Beaver/` with a Download button
  that always serves the newest signed + notarized build.
  Backed by a stable-named `Beaver.zip` asset on every Release.
- **Auto-load storage on connect.** When a device connects while
  the user is on the Storages tab, the first `storage.list` now
  fires automatically — no need to click Reload to see anything.

### Internal
- **Source tree renamed `LoggerNext` → `Beaver` (D38).** Xcode
  project, source folder, app entry struct, entitlements, target,
  scheme, SPM library, and the `release.sh` build output all
  switch to `Beaver`. The bundle identifier
  (`com.applicaster.LoggerNext`) and the on-disk Application
  Support path (`~/Library/Application Support/LoggerNext/`) stay
  put so existing installs keep their data and Sparkle in-place
  upgrades remain valid. Pure refactor — no user-visible change.

### Fixed
- **Bookmark popover showed empty after the first bookmark.**
  Race between the fire-and-forget write Task and the popover's
  read against `LogStore`. `MainWindow` now subscribes to
  `.bookmarksChanged` and keeps the snapshot continuously
  fresh, so the popover reflects current state regardless of
  scheduling order.
- **"Nothing to show" empty state was left-pinned on Storages.**
  Parent `LazyVStack(alignment: .leading)` was inheriting; the
  empty state now restores its native centered layout via
  `.frame(maxWidth: .infinity)`. The accompanying message also
  branches on session state — past sessions no longer promise a
  Reload that can't work.
- **Toolbar buttons had inconsistent widths.** All six action
  buttons are now pinned to 76pt so labels like "Jump To Time"
  no longer stretch past their neighbours.
- **Top control-bar heights now match across tabs.** The Log
  feed filter row and the Storages tab row are both pinned to
  48pt so the strip below the toolbar reads as one consistent
  shape regardless of which tab is active.
- **Sessions footer hugged the sidebar seam.** The 'N sessions'
  footer now uses `.bar` material and a wider leading inset so
  the sidebar's rounded corner no longer bleeds through.
- **Add / delete keys inside a namespace.** The "+" button on a
  namespace row opens the Add-key sheet with the parent
  pre-filled; the trash button on an inner row deletes just that
  one key. Both use the SDK's existing 3rd-arg subscope on
  `storage.<wireKey>.set/delete`, no protocol changes.
- **Storage edit / delete / add (D6).** The Storages detail pane now
  has Edit and Delete buttons for top-level keys, plus an "Add key"
  button in the top bar. Hits the SDK's existing
  `storage.<namespace>.set` / `storage.<namespace>.delete` console
  commands (already shipped — no SDK change needed). Auto-refreshes
  after each change so the table reflects the new state.
- **Jump to Time** toolbar button. Click → pick a target time → table
  scrolls to the event with the closest timestamp. Respects the active
  filter, so "what happened at 14:13:42?" inside a `level≥warning` view
  snaps to the nearest warning around that time. Sets Pause so the
  jump doesn't get yanked away by streaming events.
- **Filter-aware Export.** The toolbar's Export action now respects
  the active Log-feed filter. Narrow the view with level/search/exclude
  pills, click Export, and the resulting JSON contains only the rows
  you're looking at. Button label changes to "Export (filtered)" when
  a filter is active so it's clear what's being shipped. Clear the
  filter to export the whole session as before.
- **Saved filter presets.** Click the ★ button at the leading edge of
  the filter bar to save the current level/include/exclude combination
  under a name. Apply with one click; delete on hover; the icon fills
  in when an active preset matches the current filter.

## [1.0.2] - 2026-05-19

First Sparkle-enabled release — installed copies of 1.0.2 and later
auto-update from the appcast. Users on 1.0.0 / 1.0.1 must download
1.0.2 manually once; subsequent versions arrive automatically.

### Added
- **Auto-update via Sparkle 2.** Beaver checks for updates on launch
  and once per day, plus an explicit "Check for Updates…" item in
  the Beaver menu. Updates are Ed25519-signed; only releases built
  by Applicaster's CI are accepted by installed copies.
  Appcast: https://applicaster.github.io/Beaver/appcast.xml
- Hover-revealed red trash button on each Sessions row.
- Footer "Delete all sessions…" (red) with confirmation dialog.
- Right-click context menu on Sessions rows: Open in Log feed / Delete session.
- Clicking a session row jumps to the Log feed showing that session.
- Syntax-highlighted JSON detail panes (Log feed + Storages) with
  per-depth indentation, expand/collapse chevrons, and Xcode-style
  colours (keys, strings, numbers, bools).
- App rebrand: "Beaver" display name on every user surface
  (internal codename remains `LoggerNext`).

### Fixed
- Storages tab no longer leaves the screen blank when opened — the
  change-stream subscription is now registered before the first
  `storage.list`, so the inbound snapshot is never dropped.
- Click-to-select on Log feed rows works reliably while events stream.
- Stale "Connected" status after the device closes its WebSocket —
  TCP keepalive now detects half-open connections within ~60s.
- Reconnect after disconnect now creates a new session and follows
  into it automatically.

### Internal
- New `JSONKind` enum + shared `JSONSyntax` SwiftUI Text builder.
- `LogStore.deleteSession(id:)` and `LogStore.deleteAllSessions()`
  with cascading FK deletes.
- `Change.sessionDeleted` and `Change.sessionsCleared` broadcast cases.
- CircleCI release pipeline that signs each .zip with Sparkle's
  Ed25519 key and appends a fresh `<item>` to `docs/appcast.xml`.

## [1.0.1] - 2026-05-19

Plumbing-only release used to verify the CI release pipeline
end-to-end. No code-visible changes versus 1.0.0.

## [1.0] - 2026-05-18

Initial Beaver release. See `DECISIONS.md` D1–D20 for the design history.

[Unreleased]: https://github.com/applicaster/Beaver/compare/4.20.3...HEAD
[2.0.1]: https://github.com/applicaster/Beaver/releases/tag/2.0.1
[2.0.0]: https://github.com/applicaster/Beaver/releases/tag/2.0.0
[1.0.2]: https://github.com/applicaster/Beaver/releases/tag/1.0.2
[1.0.1]: https://github.com/applicaster/Beaver/releases/tag/1.0.1
[1.0]: https://github.com/applicaster/Beaver/releases/tag/1.0.0
