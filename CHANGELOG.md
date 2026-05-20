# Beaver — Changelog

All notable user-facing changes to Beaver go here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely, and
versions track [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

When releasing:

1. Move items from `[Unreleased]` into a new dated section.
2. `make bump VERSION=X.Y.Z` (commits + tags).
3. `git push && git push --tags`.
4. CI builds, signs, notarizes, and publishes the GitHub Release
   plus a new `<item>` in the Sparkle appcast.

## [Unreleased]

### Changed
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

[Unreleased]: https://github.com/applicaster/Beaver/compare/1.0.2...HEAD
[1.0.2]: https://github.com/applicaster/Beaver/releases/tag/1.0.2
[1.0.1]: https://github.com/applicaster/Beaver/releases/tag/1.0.1
[1.0]: https://github.com/applicaster/Beaver/releases/tag/1.0.0
