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
`Features/MainWindow.swift`, the Export menus in `MainWindow.swift` and
`Features/Storages/StoragesView.swift`):

1. Check it against `SESSION_FILE_FORMAT.md`. If the format itself changes,
   follow its §1: additive only in v1, readers before writers.
2. Update `SESSION_FILE_FORMAT.md` in the same PR.
3. Open the matching PR in zapp-support (`src/utils/sessionFile.ts`,
   `src/services/sessionExport.ts`, `src/utils/sessionFile.test.mts`) and
   cross-link the two. Neither merges without the other.
4. Every file that opens today must keep opening (§8): add a regression test
   for any shape you touch.

## MCP — every capability has a tool

Beaver ships an MCP server (`Beaver/MCP/`, reference and recipes in
`Beaver/Resources/MCP.md`) so agents can do everything a person can do in the
app. It is part of the product, not an add-on:

1. A change that adds, removes or changes a user-facing capability (a menu
   item, a toolbar action, a filter, an export, a new wire frame, a new column
   of data) updates the matching tool in `Beaver/MCP/Tools/` (registered in
   `BeaverTools.all`) in the same PR, or adds one.
2. Update `Beaver/Resources/MCP.md` (the Tools table, and a recipe that uses
   the tool) and, if agents need it to use the tool correctly,
   `MCPServer.instructions`.
3. `swift test` includes drift tests: every registered tool is in MCP.md's
   Tools table and in at least one recipe, and nothing else is.
4. Tools work in the background: never activate the app or take focus
   unless the call has `reveal: true`.
5. Every tool returns a one-line `summary` (it is also the journal line) and
   `Next:` suggestions; errors say what to do, with an example call. The
   dispatcher journals every call — don't bypass it.
6. Agent Access stays a separate feature: code outside `Beaver/MCP/` and
   `Beaver/Features/AgentActivity/` reaches it only through `AgentAccess`, the
   app-menu items and the Agent toolbar button.
7. Testers use a built bundle (the PR's "Tester bundle" CircleCI job, or a
   release), without Xcode. Anything they need to turn on, set up or check must
   work from the app menu, and be described in MCP.md → "Testing without Xcode".
8. Mention agent-visible changes in `CHANGELOG.md` `[Unreleased]`.
