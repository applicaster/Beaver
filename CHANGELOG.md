# Beaver — Changelog

All notable user-facing changes to Beaver go here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely, and
versions track [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

When releasing:

1. Move items from `[Unreleased]` into a new dated section.
2. `make bump VERSION=X.Y.Z` (commits + tags).
3. `make release` → `build/Beaver-X.Y.Z.zip`.
4. `git push && git push --tags`.

## [Unreleased]

### Added
- **Auto-update via Sparkle 2.** Beaver now checks for updates on
  launch and once per day, plus an explicit "Check for Updates…"
  item in the Beaver menu. Updates are Ed25519-signed; only releases
  built by Applicaster's CI are accepted by installed copies.
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

## [1.0] - TBD

Initial Beaver release. See `DECISIONS.md` D1–D20 for the design history.

[Unreleased]: https://github.com/applicaster/Logger/compare/1.0...HEAD
[1.0]: https://github.com/applicaster/Logger/releases/tag/1.0
