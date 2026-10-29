# Player controls in the detail pane — design

**Date:** 2026-10-29 · **Decision:** D99 · **Release:** `feat:` · **Repos:** Beaver, QuickBrick

## 1. Goal

A tester driving a TV (or a phone) from Beaver pauses, seeks and watches the
player's state from the Log feed instead of reaching for the remote and
looking at the TV. It makes test passes faster: pause, jump, read the logs,
go on.

Agreed with the user:

- **Where:** a small block at the bottom of the Log feed's right-hand detail
  pane.
- **When:** only while the viewed session's app has the X-Ray `player`
  toolbox (QuickBrick ≥ v16.0.0-rc.108, on iOS, tvOS, Android, Android TV and
  web TVs with X-Ray's socket sink, Zapp-Frameworks #2886). No toolbox, no
  block. A TV read over DevTools ("Connect a TV…", D94) has no toolboxes, so
  no block.
- **What:** play/pause, −10 s / +10 s, a progress bar the user drags to seek,
  "Go live" on a seekable live stream, and under the controls the player's
  state: what plays, position/duration, playing/paused/buffering/ad, stream
  type (VOD, live, seekable live), DRM, geo-block, ad break markers on the bar.
- **Ad markers, first step:** Beaver marks the breaks it has seen during this
  playback. **Second step:** a QuickBrick PR makes `player.state` report break
  positions (and DRM, stream type, the last error), and Beaver draws those too.
- **D91 exception:** D91 (Beaver #57, a UI that runs any toolbox tool) was
  rejected. This is not that: a fixed set of controls for one toolbox, built
  for one job. D99 records the difference. Running arbitrary tools from the
  UI stays out.

Non-goals: volume, captions/audio tracks, playback speed, choosing the entry
to play, controlling a player that isn't the app's active one, persisting
anything about playback (sessions, export/import and `SESSION_FILE_FORMAT.md`
are untouched).

Anti-goals: the block must never get in the way of reading logs (no focus
stealing, no toasts per poll, no log rows from polling), and it must not slow
agents' `tools_call` noticeably.

## 2. What exists

**QuickBrick `player` toolbox** (`zapp-react-native-utils/appUtils/playerManager/playerToolbox.ts`,
#8891): `player.state`, `player.play`, `player.pause`,
`player.seek {position}` (seconds from start, negative = from the end,
clamped to the seekable range; SSAI may snap back to the break before the
target), `player.offset {seconds}`. `state` today returns
`{active, playerId, entry{id,title}, position, duration, playing, buffering,
readyToPlay, ad, live, muted, role, casting}`, or `{active:false, casting}`.

**Beaver** already reaches it: `env.mcp("tools/call", …, to: sessionId)`
(`AppEnvironment.swift:231`, D75 queue: one request at a time per device,
`DeviceMCPClient`), `ToolboxLoad.fetch` (`tools/list`, used by
`DevicePopover`), `AppBuild.answer(fromCallResult:)` to unwrap a result.
`env.isLive(viewingSessionId)` says whether the viewed session is live.
X-Ray logs MCP calls only on failure, so polling adds no log rows.

## 3. Beaver

### 3.1 Placement and visibility

- Pinned at the bottom of `DetailPaneView`, under the scroll view, in every
  state of the pane (event selected, several selected, none). It doesn't
  scroll with the payload. Divider above it.
- Shown when the viewed session is live, its `tools/list` has
  `player.state`, and `player.state` says `active` (a player exists). Polling
  goes on while nothing plays, so the block appears within a second of
  playback starting and goes when the player closes. *(User's call,
  2026-10-29.)* The list is fetched when the viewed session or its live
  state changes, and again every 10 s while `player` is missing (React
  toolboxes appear after the JS bundle loads). Once found it's not
  re-fetched until the session changes; a `tools/call` answered with
  "unknown tool" hides the block and goes back to fetching.

### 3.2 Polling

- `player.state` every 1 s while the Log feed shows a live session with
  the toolbox (a minimised window keeps polling: one small call a second).
  Clicks while a command is on its way are dropped. Never two in flight: the
  next poll starts 1 s after the previous answer.
- After any action, poll at once.
- A failed poll keeps the last state greyed with a one-line reason ("The app
  didn't answer in time"); three failures in a row slow polling to 5 s until
  one succeeds.

### 3.3 Controls

| Control | Call | Notes |
|---|---|---|
| Play / Pause (one toggle) | `player.play` / `player.pause` | Toggle by `playing`. |
| −10 s / +10 s | `player.offset {seconds: ∓10}` | |
| Progress bar, draggable | `player.seek {position}` on release | While dragging, show the target time; send one seek on release, never during the drag. |
| Go live | `player.seek {position: <seekableDuration>}` | Only for seekable live. |

- Seek controls disabled when `seekableDuration` is reported and is 0. An
  older QuickBrick doesn't report it: the controls stay on and the device's
  own answer ("Seek is not supported") shows as the reason. *(Builder call:
  Beaver doesn't wait for the QuickBrick PR.)*
- On live, seek controls only when `player.state` has `liveClock` (the
  toolbox normalised the engine's clock, §4); else play/pause only.
- During an ad (`ad` true) seek controls are disabled; play/pause stays.
  *(Builder call: `seekTo` mid-ad may be ignored or break the ad.)*
- Polls use a short timeout (3 s), so a slow app never holds an agent's
  `tools_call` behind the line for long.
- A call's error ("Seek is not supported", "No active player") shows as the
  one-line reason in the block, never a toast.
- Keyboard: ⌃Space play/pause, ⌃← / ⌃→ −10 s / +10 s, while Beaver's window
  is key. Plain Space and arrows stay the Log feed's.
- Calls never activate Beaver or the device's window (same rule as MCP
  tools: work in the background).

### 3.4 State shown

Under the controls:

- Title (and entry id, selectable).
- `position / duration` (live: position within the DVR window, or "LIVE").
- Badges: PLAYING / PAUSED / BUFFERING, AD, stream type (VOD, LIVE,
  LIVE · DVR), DRM (with key system when known), GEO-BLOCKED, MUTED,
  CASTING, role when not Primary.
- Stream type and DRM/geo badges appear only when the app reports them
  (§4); an older QuickBrick shows "LIVE" from `live` and nothing for DRM/geo.

### 3.5 Ad markers

- **Seen breaks (step 1, VOD only):** while polling, when `ad` turns true
  Beaver records the content position under the ad if reported, else that
  of the last poll before it (forgotten after a seek); it draws a tick
  there. Kept in memory per session and entry id; a new entry
  clears them. With 1 s polling a marker can be up to ~1 s early.
- **Reported breaks (step 2):** when `player.state` has `adBreaks`, those are
  drawn (seen ones that match within 2 s are merged).
- The bar shades the current break while `ad` is true.

### 3.6 Docs and other places

- D99 in `DECISIONS.md` (the D91 difference, polling, seen breaks).
- `CHANGELOG.md` `[Unreleased]`.
- `Beaver/Resources/MCP.md`: no new MCP tool (agents already have
  `tools_call player.*`); add a short recipe "drive the player" using
  `tools_call` with `player.state/pause/seek`, and a line in "Testing without
  Xcode" on when the block shows.
- `ARCHITECTURE.md`: the new view and its poller.
- `PROTOCOL.md` and `MCP.md` still say the JS-only socket sink has no
  toolboxes; since Zapp-Frameworks #2886 a web app with X-Ray's socket sink
  has them. Fix those lines.
- The bar uses `contentPosition`/`contentDuration` when reported, else
  `position`/`duration` frozen at their last non-ad values while `ad` is true.
  The QuickBrick PR checks that live `position` is on the same 0…seekable
  range as `seek`; if an engine differs, `contentPosition` is normalised.
- kb-applicaster: `beaver-overview` (UI), `beaver-mcp-agent-access` (player
  recipe), naming the Beaver version that brings it.

## 4. QuickBrick PR — richer `player.state`

All additive; Beaver reads every new field as optional.

| Field | Value | Source |
|---|---|---|
| `seekableDuration` | seconds or null | `player.getSeekableDuration()` |
| `contentPosition`, `contentDuration` | seconds or null, on the content's clock even during an ad (`position`/`duration` switch to the ad's clock) | `getContentPosition()` / content duration in `player.ts` |
| `streamType` | `"vod"`, `"live"`, `"liveDvr"`, or null when unknown | `isLive()` + `seekableDuration > 0` |
| `drm` | key systems, e.g. `["widevine"]`, or null | `Object.keys(entry.extensions.drm)` |
| `adBreaks` | seconds, sorted, or null when unknown | see below |
| `lastError` | `{message, detail?}` or null | see below |
| `liveClock` | `"forward"`, `"behindLive"` or null | the engine's own live clock; `state`, `seek` and `offset` are normalised to forward (0 = oldest DVR point) |
| `geoBlocked` | true / false / null when unknown | see below |

- **Ad breaks:** a new `onAdCuePoints({cuePoints:[sec]})` player event,
  stored on `player.ts`, cleared on a new entry. Emitted by the web hls.js
  engine (where `ssaiAdBreaks.setBreaks` runs) and web IMA
  (`adsManager.getCuePoints()` once ads load). Until an engine emits, numeric
  offsets from `entry.extensions.video_ads` (`preroll` = 0) are used.
  Brightcove (SSAI timeline, `video.cuePoints`) is a later Zapp-Frameworks
  PR.
- **DRM:** from the entry, which every engine except Brightcove reads.
  Brightcove's DRM comes from its catalog, so for it `drm` may be wrong until
  a Zapp-Frameworks follow-up reports `usesFairPlay` in its load event.
- **Last error:** `player.ts` keeps the last `onError`/`onVideoError` payload
  (cleared on a new entry).
- **Geo-block (agreed):** no engine reports it today; it only shows as error
  text (a 403, or Brightcove's `CLIENT_GEO` subcode that only goes to the
  log). No guessing: this round ships `lastError`, and Beaver shows its text
  as one line under the state. `geoBlocked` and the GEO-BLOCKED badge come
  only when an engine says so explicitly (a Zapp-Frameworks follow-up for
  Brightcove's subcode); until then the field is left out.
- Tests next to `playerToolbox.test.ts`; the tool's description lists the
  new fields.

## 5. Left to the builder

View structure, poller type and where it lives, visuals of the bar and
badges within Beaver's look, test layout. Hotkeys may change if they clash
with an existing shortcut.

## 6. Open

- Whether the reviewer of Beaver #57 accepts D99 (§1).
