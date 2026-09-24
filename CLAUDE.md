# Beaver

macOS 26 SwiftUI log viewer (Swift 6, GRDB 7). Receives events, storage
snapshots and network requests from the mobile SDK over WebSocket.

- Test: `swift test` (Swift Testing, `BeaverTests/`). Build: `make build`.
- **Merging to `main` releases automatically** (CircleCI builds, signs,
  notarizes and publishes). Add user-facing changes to `CHANGELOG.md`
  `[Unreleased]`.
- Docs: `DECISIONS.md` (numbered decisions, source of truth),
  `ARCHITECTURE.md`, `PROTOCOL.md` (wire protocol with the SDK).

## Export / import files — shared with zapp-support

Beaver and zapp-support (the web logger, `applicaster/zapp-support`) write
and read the same file. Customers send logs from either tool; we open them in
either. The format is specified in **[`SESSION_FILE_FORMAT.md`](SESSION_FILE_FORMAT.md)**
— the only copy; zapp-support links to it.

When a change touches export or import (`Beaver/Support/EventJSON.swift`,
`SessionExport.swift`, `HARExport.swift`, the importer in
`Features/MainWindow.swift`):

1. Check it against `SESSION_FILE_FORMAT.md`. If the format itself changes,
   follow its §1: additive only in v1, readers before writers.
2. Update `SESSION_FILE_FORMAT.md` in the same PR.
3. Open the matching PR in zapp-support (`src/utils/sessionFile.ts`,
   `src/services/sessionExport.ts`, `src/utils/sessionFile.test.mts`) and
   cross-link the two. Neither merges without the other.
4. Every file that opens today must keep opening (§8): add a regression test
   for any shape you touch.
