# Player controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A player block at the bottom of the Log feed's detail pane that drives the viewed app's X-Ray `player` toolbox (play/pause, ±10 s, drag-to-seek, Go live) and shows its state, plus a QuickBrick PR that makes `player.state` richer.

**Architecture:** Testable logic in BeaverCore (`Beaver/Domain/PlayerControl.swift`: state parsing, commands, seen ad breaks, an `@Observable` poller over `DeviceLink`). A thin SwiftUI view in the app target mounts the poller for the viewed live session. QuickBrick adds fields to `player.state`; Beaver reads every field as optional.

**Tech Stack:** Swift 6, SwiftUI (macOS 15+), Swift Testing; TypeScript/Jest in QuickBrick.

**Spec:** `plans/2026-10-29-player-controls-design.md`

## Global Constraints

- Block shown only when the viewed session is live and its `tools/list` has `player.state`.
- Poll `player.state` every 1 s, never two in flight, 3 s timeout; after 3 failures in a row, every 5 s until one succeeds. Re-fetch `tools/list` every 10 s while `player` is missing.
- Seek sends one `player.seek` on release, never during a drag.
- Seek controls disabled while `ad` is true, and when `seekableDuration` is reported as 0. Missing `seekableDuration` (older QuickBrick) → enabled, the device's error shows.
- Errors are one line in the block, never a toast. Nothing activates Beaver or takes focus.
- Hotkeys only with ⌘⌥: ⌘⌥P play/pause, ⌘⌥← / ⌘⌥→ −10 s / +10 s (⌃Space is macOS's input-source switch).
- Seen ad breaks: in memory, per entry id, merged with reported ones within 2 s.
- No GEO-BLOCKED badge in this round; `lastError` text is shown.
- Commit prefix `feat:`; no `Co-Authored-By` trailer.

## Review Focus

1. The app restarts or reconnects into a new session while the block polls → it follows the viewed session, never polls a dead session forever. (Task 2: `pollerStopsOnNotSent`)
2. Pre-roll: `ad` true before any content position → no marker at a bogus position, bar shows no content position. (Task 1: `seenBreaksIgnorePreroll`)
3. An agent's long `tools_call` holds the line → the poll fails as not-sent within 3 s, the block greys, no pile-up. (Task 2: `pollFailureKeepsLastState`)
4. The player toolbox disappears (JS reload) → "unknown tool" hides the block and discovery restarts. (Task 2: `unknownToolHidesBlock`)
5. Live without DVR on an old QuickBrick → seek attempt shows "Seek is not supported" as the reason. (Task 2: `commandErrorBecomesReason`)

---

### Task 1: Player state, commands and seen breaks (BeaverCore)

**Files:**
- Create: `Beaver/Domain/PlayerControl.swift`
- Test: `BeaverTests/PlayerControlTests.swift`

**Interfaces:**
- Produces:
  - `public enum StreamType: String, Sendable { case vod, live, liveDvr }`
  - `public struct PlayerState: Sendable, Equatable` with `active: Bool`, `entryId: String?`, `title: String?`, `position: Double?`, `duration: Double?`, `contentPosition: Double?`, `contentDuration: Double?`, `seekableDuration: Double?`, `playing`, `buffering`, `ad`, `muted`, `casting: Bool`, `role: String?`, `streamType: StreamType?`, `drm: [String]?`, `adBreaks: [Double]?`, `lastError: String?`; `public init(json: JSON)`.
  - `PlayerState.timeline: (position: Double, length: Double)?` — position `contentPosition ?? position`; length `seekableDuration` for `.liveDvr`, else `contentDuration ?? duration`; nil when either is missing or length ≤ 0.
  - `PlayerState.canSeek: Bool` — `active && !ad && seekableDuration != 0`.
  - `public enum PlayerCommand: Sendable, Equatable { case play, pause, offset(Double), seek(Double), goLive }` with `var tool: String` and `func arguments(_ state: PlayerState?) -> JSON` (`goLive` → `player.seek {position: seekableDuration}`).
  - `public struct SeenAdBreaks: Sendable, Equatable { mutating func observe(_ s: PlayerState); var positions: [Double]; func merged(with reported: [Double]?) -> [Double] }`

- [ ] **Step 1: Write failing tests** in `BeaverTests/PlayerControlTests.swift`:
  - `stateParsesToday`: today's shape `{active:true, playerId:"p", entry:{id:"e1",title:"T"}, position:12, duration:100, playing:true, buffering:false, readyToPlay:true, ad:false, live:false, muted:false, role:"Primary", casting:false}` → `entryId == "e1"`, `title == "T"`, `streamType == .vod` (derived from `live:false`), `drm == nil`, `timeline == (12, 100)`, `canSeek`.
  - `stateParsesRich`: adds `streamType:"liveDvr", seekableDuration:3600, contentPosition:3500, drm:["widevine"], adBreaks:[0,600], lastError:{message:"403"}` → `timeline == (3500, 3600)`, `drm == ["widevine"]`, `lastError == "403"`.
  - `liveWithoutType`: `live:true`, no `streamType` → `.live`.
  - `inactive`: `{active:false, casting:false}` → `!active`, `!canSeek`, `timeline == nil`.
  - `noSeekDuringAdOrZeroRange`: `ad:true` → `!canSeek`; `seekableDuration:0` → `!canSeek`.
  - `commands`: `.offset(-10)` → tool `player.offset`, args `{seconds:-10}`; `.goLive` with `seekableDuration:3600` → `player.seek {position:3600}`.
  - `seenBreaksRecordAdStart`: observe e1 pos 100 ad false, pos 101 ad true, pos 101 ad true, pos 102 ad false → `positions == [100]`.
  - `seenBreaksIgnorePreroll`: first observation of an entry with `ad:true` → `positions == []`.
  - `seenBreaksResetOnNewEntry`: break on e1, then e2 observed → `positions == []`.
  - `mergeWithin2s`: seen `[100]` merged with `[99, 600]` → `[99, 600]`.
- [ ] **Step 2:** `swift test --filter PlayerControlTests` → fails (types missing).
- [ ] **Step 3:** Implement in `Beaver/Domain/PlayerControl.swift`. `lastError` reads `lastError.message`, or a string.
- [ ] **Step 4:** `swift test --filter PlayerControlTests` → passes.
- [ ] **Step 5:** Commit `feat: player state, commands and seen ad breaks for the player block`.

### Task 2: Player poller (BeaverCore)

**Files:**
- Modify: `Beaver/Domain/PlayerControl.swift`
- Test: `BeaverTests/PlayerControlTests.swift` (uses `FakeDevice` from `MCPTestSupport.swift`)

**Interfaces:**
- Consumes: Task 1 types; `DeviceLink.mcp`; `AppBuild.answer(fromCallResult:)`; `Toolboxes.tools(fromListResult:)`.
- Produces: `@MainActor @Observable public final class PlayerPoller` with
  - `init(device: any DeviceLink, sessionId: Int64)`
  - `private(set) var available: Bool`, `state: PlayerState?`, `reason: String?`, `failures: Int`, `seen: SeenAdBreaks`
  - `func discover() async` — `tools/list`; `available` = has `player.state`.
  - `func poll() async` — one `player.state` call, 3 s timeout; success updates `state`, `seen`, clears `reason`, `failures = 0`; failure keeps `state`, sets `reason`, `failures += 1`; `.noTool` sets `available = false`, `state = nil`.
  - `func send(_ command: PlayerCommand) async` — `DeviceMCPClient.callTimeout`; error → `reason`; then `poll()`.
  - `func run() async` — loop until cancelled: discover every 10 s while unavailable; poll every 1 s (5 s once `failures >= 3`). Stops (returns) on `.notSent` caused by the device being gone (`"no longer connected"`).
  - Error → one line: timeout "The app didn't answer in time.", disconnected "The app disconnected.", notSent(reason) capitalised + ".", rpc/failed(text) the text.

- [ ] **Step 1: Write failing tests:** `discoverFindsPlayer` (list with `player.state` → `available`), `discoverWithoutPlayer`, `pollUpdatesState`, `pollFailureKeepsLastState` (second poll throws `.notSent("the app is busy with tools/call")` → `state` unchanged, `reason == "The app is busy with tools/call."`, `failures == 1`), `unknownToolHidesBlock` (isError "Unknown tool: player.state" → `!available`, `state == nil`), `sendCallsToolThenPolls` (`.pause` → `mcpCalls` are `tools/call player.pause` then `tools/call player.state`), `commandErrorBecomesReason` (seek answered isError "Seek is not supported" → `reason == "Seek is not supported"`), `pollerStopsOnNotSent` (`run()` returns when the device says "the app is no longer connected").
- [ ] **Step 2:** run → fail. **Step 3:** implement. **Step 4:** `swift test --filter PlayerControlTests` → pass.
- [ ] **Step 5:** Commit `feat: player poller over the device's MCP`.

### Task 3: Player block in the detail pane (app target)

**Files:**
- Create: `Beaver/Features/DetailPane/PlayerControlsView.swift`
- Modify: `Beaver/Features/DetailPane/DetailPaneView.swift` (wrap `body` so the block is pinned under every state)

**Interfaces:**
- Consumes: `PlayerPoller`, `PlayerState`, `PlayerCommand`; `@Environment(AppEnvironment.self)`: `viewingSessionId`, `isLive(_:)`, `env` as `DeviceLink`.

- [ ] **Step 1:** `PlayerControlsView` owns a `PlayerPoller?` in `@State`, rebuilt in `.task(id: "\(sessionId)|\(isLive)")` which calls `run()`; renders nothing unless `available`. Layout per spec §3.3–3.5: toggle, −10/+10, `Slider`-like bar with local drag value and `onEditingChanged(false)` → `.seek`, ticks for `seen.merged(with: state.adBreaks)`, shaded current break while `ad`; Go live for `.liveDvr`; state lines and badges; `lastError` and `reason` one line each, secondary/red. Disabled with "Nothing playing" when `!active`.
- [ ] **Step 2:** In `DetailPaneView.body` put the existing content and `PlayerControlsView()` in a `VStack(spacing: 0)` with a `Divider` between; the block keeps its natural height.
- [ ] **Step 3:** Hotkeys ⌘⌥P, ⌘⌥←, ⌘⌥→ via `.keyboardShortcut` on the buttons.
- [ ] **Step 4:** `make build` → BUILD SUCCEEDED, no new warnings.
- [ ] **Step 5:** Commit `feat: player controls at the bottom of the Log feed detail pane (D99)`.

### Task 4: Docs

**Files:** `DECISIONS.md` (D99), `CHANGELOG.md` `[Unreleased]` Added, `ARCHITECTURE.md` (view + poller), `Beaver/Resources/MCP.md` (recipe "Drive the player" with `toolboxes_list` / `tools_call` `player.state|pause|seek`; "Testing without Xcode" line on when the block shows; fix "JS-only sink has no toolboxes" for web since Zapp-Frameworks #2886), `PROTOCOL.md` (same fix).

- [ ] **Step 1:** Write D99: what (spec §1), why not D91 (fixed set, one toolbox, non-destructive, no forms/history), polling and seen breaks, no geo guess.
- [ ] **Step 2:** `swift test` → all pass (MCP drift tests included).
- [ ] **Step 3:** Commit `feat: document player controls (D99)`.

### Task 5: QuickBrick PR (separate repo, own worktree off `origin/main`)

**Files:** `packages/zapp-react-native-utils/appUtils/playerManager/playerToolbox.ts` (+ test), `player.ts` (`lastError`, ad cue points), web engines in QuickBrick that hold break lists (hls.js `setBreaks`, web IMA `getCuePoints`).

- [ ] **Step 1:** Tests in `__tests__/playerToolbox.test.ts`: `state` returns `seekableDuration`, `contentPosition`, `contentDuration`, `streamType` (`vod` / `live` / `liveDvr` / null), `drm` (keys of `entry.extensions.drm`, null when absent), `adBreaks` (stored cue points, else numeric `video_ads` offsets with `preroll` = 0, else null), `lastError` (`{message, detail?}`, null after a new entry).
- [ ] **Step 2:** `player.ts`: keep `lastError` from `onError`/`onVideoError`; `onAdCuePoints({cuePoints})` stores sorted seconds; both cleared on a new entry. Emit `onAdCuePoints` from hls.js and web IMA.
- [ ] **Step 3:** `yarn jest playerToolbox` (and touched engines' tests) → pass; lint.
- [ ] **Step 4:** Commit `feat(player): richer player.state for Beaver's player controls`, push, open PR linking the Beaver PR.

### Task 6: KB and PR

- [ ] **Step 1:** kb-applicaster: `beaver-overview` (player block, "Beaver 4.24.0 or later"), `beaver-mcp-agent-access` (player recipe). If the KB tools are missing, list the needed edits in the PR.
- [ ] **Step 2:** `swift test`, `make build` green; open the Beaver PR (`feat:` title), cross-link the QuickBrick PR.
