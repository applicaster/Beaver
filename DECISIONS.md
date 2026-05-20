# Beaver — Design Decisions

Running log of architecture and feature decisions made during the
project's lifetime. Each entry: decision, reasoning, alternatives
considered, status.

> **Note on names.** Decisions D1–D37 were written when the
> codebase was still under the codename `LoggerNext`; references
> to it inside those historical entries are preserved as the
> record-of-the-time. From D38 onward, the source tree is named
> `Beaver` while the bundle ID + on-disk path stay
> `com.applicaster.LoggerNext` / `~/Library/Application Support/LoggerNext/`
> for backwards compatibility — see D38 itself for the full
> rationale.

---

## D1. Event storage: persist to disk with per-session history

**Status:** Accepted (2026-05-15)

**Decision.** Every event received over the WebSocket is written to an on-disk
SQLite database via GRDB. Each client connection starts a new session row;
the UI exposes a sidebar of past sessions that can be re-opened. The live
table view loads a virtualized window over the store (≈500 rows around the
scroll position), not the full event set.

**Why.**
- Fixes the root cause of the freeze at 3k+ events. The current
  implementation re-runs three linear `.filter()` passes on every keystroke
  and recomputes `highlightedText` occurrence indices per cell, which is
  O(events²) on the main thread. A `WHERE` query against an indexed SQLite
  table runs in milliseconds at 100k+ rows.
- Memory stays flat regardless of session size — the windowed table view
  bounds the working set.
- Session history is essentially free once persistence exists, and is
  directly useful ("what did the crash look like yesterday?").

**Alternatives considered.**
- *In-memory rolling buffer (cap at N).* Simpler, no disk I/O, but doesn't
  fix the per-keystroke filter scan and loses cross-session replay.
- *SwiftData.* Newer and more native, but less predictable performance for
  high-throughput append workloads and weaker query story than GRDB.

**Implications.**
- Adds GRDB as the only third-party dependency.
- Introduces a `LogStore` actor that owns the DB connection and exposes
  `AsyncStream` updates to view models.
- Schema migrations are a `LogStore` concern; wire format is fixed so the
  decode → row mapping is the only surface.

---

## D2. Connections: one client at a time

**Status:** Accepted (2026-05-15)

**Decision.** The WebSocket listener accepts a single active client. While a
client is connected, additional connection attempts are rejected with a
clean close code so the second client knows it's a duplicate (not a crash).
Each accepted connection starts a new session row.

**Why.** Matches the current mental model and the way developers actually
use it (one device under test at a time). Removes ambiguity in commands sent
back to the client (`storage.list`, `cmdlist`) — they always target a known
recipient. Simpler concurrency: no per-connection queues to merge.

**Alternatives considered.**
- *Multi-client with per-session tabs.* Useful for iPhone + Apple TV
  side-by-side debugging, but adds UI complexity and command-routing
  ambiguity. Can be revisited later if the workflow emerges.
- *Multi-client merged feed.* Cheapest to implement but makes commands
  ambiguous and confuses event provenance.

**Implications.**
- Listener tracks current `NWConnection?` and refuses new connections while
  it's non-nil.
- Connection-lost UI shows a clear state; rejected duplicate gets a distinct
  close-code message ("another client is already connected").

---

## D3. Scroll behavior: auto-pause on scroll-up

**Status:** Accepted (2026-05-15)

**Decision.** The live feed auto-scrolls to the tail while the user is at
(or within a few rows of) the bottom. Once the user scrolls up, auto-scroll
suspends and a floating button appears showing "N new events ↓" — clicking
it resumes follow-tail.

**Why.**
- Matches the established pattern in Console.app, Xcode console, Chrome
  DevTools, Sentry, Datadog — users already know it.
- Implicit intent detection: scrolling away means "I want to read this",
  shoving the viewport on new events would defeat that.
- The badge count is information the user wants anyway (how busy is the
  stream right now).

**Alternatives considered.**
- *Always follow tail* (today's behavior): unreadable at high event rates.
- *Explicit pause button only*: predictable but loses the row the user was
  reaching for, since events arrive while they reach for the toolbar.

**Implications.**
- Need a "scrolled-to-tail" predicate (within ≤3 rows of bottom).
- Floating button overlay over the table.
- Counter increments while paused, resets to zero when follow-tail resumes.

---

## D4. Search and filtering: substring + level + regex toggle + saved filters

**Status:** Accepted (2026-05-15)

**Decision.** Keep today's two-textbox UX (search / exclude) plus level
dropdown. Add: a regex toggle on each text box, and a saved-filters
dropdown for re-using common filter combinations by name.

**Why.**
- Substring search is the muscle-memory pattern for debug tools; don't
  break it.
- Regex is a high-leverage power-user feature that's cheap to add now that
  filtering runs as a query, not as in-Swift `.filter()`.
- Saved filters codify the repeated-workflow pattern ("auth errors", "my
  feature flag", "network only") with minimal UI cost.
- Filtering itself becomes a SQL `WHERE`/FTS5 query against the indexed
  store, making it instant at 100k+ rows.

**Alternatives considered.**
- *Today's UX unchanged.* Wastes the opportunity the rewrite creates.
- *Chip-based structured query builder.* High UI cost; in practice most
  users just want to type a substring and see results.

**Implications.**
- Search/exclude inputs gain a small "rx" toggle button.
- A new `saved_filters` table (name + filter spec JSON).
- Filter UI gets a "Save as…" action and a dropdown of saved filters.

---

## D5. Match highlighting: yes; Prev/Next occurrence navigation: dropped

**Status:** Accepted (2026-05-15)

**Decision.** Search matches are visually highlighted in the message,
subsystem, and category columns. The current app's Prev/Next occurrence
buttons and the underlying global-occurrence-index machinery are removed.

**Why.**
- Highlighting is cheap and high-value: makes filtered results scannable.
  Implementation is precomputed `AttributedString` per row, cached when
  the search term changes.
- Prev/Next navigation in the current app walks `filteredEvents` per cell
  render to compute global occurrence indices. It is one of the direct
  causes of the freeze at 3k+ events.
- With FTS-backed filtering narrowing the visible rows, intra-table
  occurrence navigation is redundant — scrolling does the same thing
  faster.

**Alternatives considered.**
- *Keep Prev/Next.* Preserves a feature, but at significant perf cost and
  ~80 LOC of fragile occurrence-counting code.
- *No highlighting at all.* Simpler still, but scannability suffers when
  the result set is non-trivial.

**Implications.**
- Removes `getGlobalOccurrenceIndex`, `eventIdForOccurrenceIndex`,
  `getTotalOccurrences`, `navigateToOccurrence`, and related state.
- Adds a `highlightedAttributedString(for:term:)` helper that runs once per
  row on filter change.
- Detail pane gets a Cmd-F / Cmd-G text search later if intra-message
  navigation is ever requested.

---

## D6. Storages: auto-refresh on focus + edit-and-push-back

**Status:** Accepted (2026-05-15), one dependency pending verification.

**Decision.** Keep the three-tab storages browser (session / local /
keychain). Two new behaviors:

1. **Auto-refresh on focus.** Switching to the Storages tab triggers a
   `storage.list` command automatically; the user shouldn't have to click
   reload. A manual reload button remains for explicit re-fetch.
2. **Edit and push back to client.** Each leaf value can be inline-edited.
   On commit, the app sends a command back to the client (presumed
   `storage.set` with the namespace + key + new value) to apply the change.
   Useful for testing edge cases without rebuilding the mobile app.

**Why.** Auto-refresh removes a friction point during active debugging.
Edit-push-back is the highest-leverage debug feature: it turns the inspector
into a writeable surface so you can poke the device into specific states.

**Dependency / open question.**
- The mobile SDK must support a `storage.set` (or equivalent) command. Need
  to confirm with the SDK team:
  - Command name and exact payload shape
  - Per-namespace support (can you write to keychain? session?)
  - Error responses (what does the client send back on failure?)
- If the command doesn't exist yet, this becomes a coordinated SDK +
  LoggerNext change rather than a LoggerNext-only feature.

**Alternatives considered.**
- *Keep as-is, polished only.* Doesn't justify the rewrite for this screen.
- *Diff between snapshots.* Useful but secondary; can layer on later once
  history is in place.

**Implications.**
- `StoragesViewModel` issues `storage.list` on tab activation, debounced
  if the user toggles back and forth.
- A small edit affordance per leaf row, with optimistic UI + revert on
  error response from client.
- Need an audit log so the user can see "you wrote 'foo' to local.user.id".

---

## D7. JSON I/O: import as new session, export filtered vs full

**Status:** Accepted (2026-05-15)

**Decision.** Dragging in a `.json` file creates a new session row rather
than destroying the current one. Export has two options: "Export filtered
view" (what's currently visible after filters/search) and "Export full
session" (every event in the session, regardless of filter).

**Why.**
- The current `parseLoadedData` calls `clearLoggerData()` first, which
  loses an in-progress live session. Sessions-as-first-class makes that
  obviously wrong.
- The split between filtered-export and full-export disambiguates what
  "export" means once sessions can be large and filtered views narrow.

**Alternatives considered.**
- *Keep as-is.* Inconsistent with the session model from D1.
- *Always export full.* Loses the common workflow of "show me only these
  errors and send the result to a colleague".

**Implications.**
- Imported sessions carry a `source: imported` flag (vs `live`) so the
  sidebar can render them differently.
- Original event timestamps are preserved on import; we don't re-stamp.
- Export menu has two entries; default keyboard shortcut goes to filtered.

---

## D8. Collapse repeated events (new feature)

**Status:** Accepted (2026-05-15)

**Decision.** Add a toolbar toggle for "Collapse repeats." When on,
consecutive events with the same `(subsystem, category, message, level)`
are visually grouped into a single row showing a count and the first/last
timestamps. Every event is still stored individually; this is a
display-time operation only.

**Why.** Noisy clients (loops, polling, retry-on-failure) make the live
feed unreadable. Collapse-while-streaming makes a busy session scannable
without losing the underlying data — expanding a collapsed row reveals
each individual event with its full timestamp and payload.

**Alternatives considered.**
- *Group at the query level (`GROUP BY`).* Cheaper, but loses per-event
  data and complicates the detail pane.
- *Auto-collapse always.* Surprises users who want a strict chronological
  trace; behind a toggle is clearer.

**Implications.**
- Grouping logic lives in the view model layer over a query result, not in
  SQL. Keeps the underlying row structure intact.
- Expanded/collapsed state persists per-session in memory but not on disk.
- A small UI affordance: a chevron + count badge on collapsed rows.

---

## D9. Command bar: history + autocomplete

**Status:** Accepted (2026-05-15)

**Decision.** Free-form command input remains (one of the things the
current app does well). Add: persistent command history (up/down arrows
scroll through past commands), and autocomplete from the command list
returned by the client's `cmdlist` response.

**Why.**
- History is the smallest possible workflow win — you debug the same
  thing repeatedly, and re-typing `storage.list` is annoying.
- Autocomplete from `cmdlist` keeps the UI in sync with whatever the
  current mobile SDK actually supports, without us hard-coding command
  names.

**Alternatives considered.**
- *Keep as-is.* Functional but a missed cheap upgrade.
- *Add response-display pane.* Useful but adds a second log area in the
  bottom strip; defer until command/response volume justifies it.

**Implications.**
- New `command_history` storage (small table, capped at ~200 entries).
- Command bar consumes `cmdlist` response from the connected client and
  refreshes the autocomplete source.
- Up/Down keys navigate history, with the typed prefix preserved as a
  filter.

---

## D10. Minimum macOS target: macOS 26 (Tahoe)

**Status:** Accepted (2026-05-15)

**Decision.** LoggerNext targets macOS 26.0 or later. This is the unified
version-numbering release (formerly the "macOS 16" slot) introduced at
WWDC 2025.

**Why.**
- Internal debug tool — we control which Macs run it.
- Unlocks Swift 6 strict concurrency as the language baseline, full
  Observation framework, the Liquid Glass design system, and any new
  SwiftUI table/navigation polish from this release.
- Avoids carrying `if #available` checks throughout the codebase for
  features that are core to the architecture (e.g., `@Observable`).

**Trade-offs.**
- Team members on Macs that can't run macOS 26 can't run dev/debug builds.
- Distribution audience is limited, but the audience is internal so this
  is acceptable.

**Implications.**
- `Package.swift` `platforms: [.macOS(.v26)]` (or Xcode target deployment
  set to 26.0).
- Swift language mode set to 6.
- Free to use `@Observable`, `Observable` macro, `@Bindable`, the new
  `Group`/`ViewBuilder` improvements without availability shims.

---

## D11. Dependency management: SPM only

**Status:** Accepted (2026-05-15)

**Decision.** LoggerNext uses Swift Package Manager exclusively. No
Podfile, no Pods/, no Gemfile. Project structure is either a plain Xcode
project consuming SPM packages, or (later) a Tuist-managed project if the
codebase grows multi-target.

**Why.**
- Today's Podfile is empty (zero pods), and the `Pods/SwiftUIIntrospect`
  folder is stale and unreferenced. CocoaPods carries cost (Ruby toolchain,
  `bundle exec pod install`, post-install hacks for Xcode 15 DT_TOOLCHAIN
  rewrites) for zero benefit.
- SPM is the standard for new Swift projects, integrates natively with
  Xcode, and resolves transparently in CI.
- GRDB (D1's only dep) ships SPM support as primary.

**Alternatives considered.**
- *Keep CocoaPods* for parity. Rejected — pure carrying cost.
- *Tuist + SPM* for declarative project generation. Worth it later if the
  project grows multi-target; overkill for the rewrite's first cut.

**Implications.**
- `Package.swift` at the project root, declaring the app target and GRDB.
- No `Podfile`, `Podfile.lock`, `Pods/`, or `Gemfile`.
- Migration script for `Logger/`'s `Pods/` is not needed — we start clean.

---

## D12. Testing: Swift Testing for unit, XCTest for UI

**Status:** Accepted (2026-05-15)

**Decision.** Unit tests use Swift Testing (`@Test`, `#expect`,
parameterized tests). UI tests use XCTest / XCUITest, since Swift Testing
doesn't cover UI testing. Both frameworks coexist in the same Xcode
project.

**Why.**
- Swift Testing is the standard for new Swift code in 2026 — cleaner
  syntax, less boilerplate, async-first, parameterized tests built in.
- XCUITest is still the only path for UI automation on Apple platforms.
- The current project's empty `XCTestCase` stubs and empty UI test class
  are zero loss to walk away from.

**Implications.**
- `LoggerNextTests/` target uses Swift Testing.
- `LoggerNextUITests/` target uses XCTest/XCUITest.
- No coverage target enforced initially; aim for the core store,
  filtering, and protocol-decode logic first.

---

## D13. Distribution: scripted .app.zip with Sparkle auto-updates

**Status:** Accepted (2026-05-15), **revised 2026-05-17 from .pkg to
.app.zip**. Phase 1 (signed + notarized .app.zip) shipped; Phase 2
(Sparkle auto-updates) deferred until manual updates become annoying.

**Decision.** Ship LoggerNext as a signed + notarized `LoggerNext.app`
packaged as a `.zip`. A single `make release` (calling
`scripts/release.sh`) runs `xcodebuild archive` → `codesign` →
`notarytool submit --wait` → `stapler` → `ditto -c -k` end-to-end.
Credentials read from `.envrc.local` (gitignored). Phase 2 will layer
Sparkle on top so users get auto-updates from an HTTPS appcast feed.

**Why the .pkg → .app.zip pivot.**
- Internal audience is the Applicaster dev team — technical users for
  whom drag-to-Applications is muscle memory; .pkg's installer wizard
  adds zero value.
- .app.zip needs only the **Developer ID Application** certificate.
  .pkg additionally needs **Developer ID Installer** + `productsign` +
  `pkgutil --check-signature`. Half the moving parts to break.
- The old Logger's 12-step README depended on the 3rd-party
  Packages.app GUI tool to build .pkg from a .pkgproj. We avoid that
  whole dependency.
- `notarytool submit --wait` (the modern replacement for `altool`)
  blocks until Apple finishes notarization, so we don't have the
  "check email, then come back to staple" two-phase manual flow.

**Why.**
- The current README is manual toil, not a format problem. Scripting it
  removes the toil while preserving the user-facing install experience.
- `notarytool` is the supported replacement for the deprecated `altool`
  used today; switching now avoids a forced migration later.
- Internal audience doesn't justify Sparkle's added dependency + update
  feed hosting yet. Auto-updates can be layered on later additively.

**Alternatives considered.**
- *DMG + Sparkle.* Best long-term UX (auto-updates), but adds a dep and
  infrastructure. Revisit when release cadence justifies it.
- *Bare .app on shared drive.* Simplest, but loses code signing/install
  affordances and Gatekeeper quarantine handling.

**Implications.**
- `scripts/release.sh` + `Makefile` checked into the repo.
- Credentials loaded from `.envrc.local` (gitignored);
  `scripts/.envrc.example` documents the four required vars
  (`APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`,
  `DEVELOPER_ID_APPLICATION`).
- Output: `build/LoggerNext-<version>.zip`. Uploaded manually to a
  shared location for Phase 1; Phase 2 adds Sparkle + an HTTPS
  appcast for auto-updates.
- CI-friendly — same script runs on a macOS GitHub Actions runner with
  cert imported from a base64-encoded secret. Tag-triggered release
  is Phase 3.

---

## D14. Regex search via SQLite `REGEXP` custom function

**Status:** Accepted (2026-05-16)

**Decision.** Register a custom `REGEXP(pattern, value)` SQL function on
every GRDB database connection, backed by `NSRegularExpression`. SQL
queries can then use `column REGEXP ?` to filter rows by pattern. The UI
exposes a per-field regex toggle (`.*` chip inside each of Filter,
Exclude, and Search & highlight pills); each field independently
controls whether its term is treated as regex or substring (D4).

**Why.**
- D4 committed to per-field regex toggles. SQLite supports the
  `REGEXP` operator natively but ships no implementation — registering
  our own is the canonical way to add it via GRDB.
- `NSRegularExpression` patterns follow ICU syntax, which matches what
  developers expect from `grep -E` and most other tools.
- Registered on every connection via
  `Configuration.prepareDatabase { db in db.add(function:) }`.

**Implications.**
- `LogStore.regexpFunction` is a `nonisolated static let` so it's
  Sendable for use from the `prepareDatabase` closure.
- Invalid patterns return `false` (no match) rather than throwing — a
  half-typed pattern doesn't kill the query, just produces zero rows.
- Regex queries are row-by-row (no index can satisfy them). At ~100k
  rows complex patterns are still <100ms; at multi-million-row scale
  this would need rethinking.

---

## D15. Filter substring uses `LIKE`, not FTS5

**Status:** Accepted (2026-05-16). **Reverses the original intent of
D1 and ARCHITECTURE.md §4.**

**Decision.** Substring filter / exclude / highlight queries use plain
`LIKE '%term%'` across message, subsystem, and category. The FTS5
`event_fts` virtual table and its sync triggers stay in the schema but
are not consulted by any query. Regex paths use `REGEXP` (see D14).

**Why.**
- FTS5 prefix-match semantics are wrong for the user's mental model of
  substring search: `'l*'` matches *words starting with `l`*, not
  strings containing `l`. Users typing `load` expect "any row whose
  message contains the substring `load`" — `LIKE` gives that exactly,
  FTS5 gives something subtly different.
- For short prefixes (`'l*'`, `'lo*'`), FTS5 returns enormous candidate
  sets — every distinct token starting with that prefix, joined to
  every row that contains any such token. `NOT IN (...)` against a
  huge set for exclude queries became pathological: typing or
  backspacing through `load` froze the app at intermediate
  single-character states.
- `LIKE` on `WHERE session_id = ?` narrowed rows is a bounded linear
  scan — predictable, fast (<10ms at our row counts), and correct.

**Alternatives considered.**
- *Min-length skip + FTS5* (only filter when term ≥ 3 chars). Fixes
  the freeze but inconsistent — users sometimes wonder why `l` matches
  nothing. Also doesn't help backspace-through-the-term flow.
- *FTS5 with `unicode61` tokenizer + post-filter*. More complex,
  marginal benefit at our scale.

**Implications.**
- FTS5 schema (`event_fts` + `event_ai` / `event_ad` triggers) kept —
  insertion cost is one extra index update per row, negligible.
  Re-introduce when we genuinely need full-text search at much larger
  scale.
- Performance is bounded by row count and average column length per
  session. At ~100k events expect single-digit-ms filter queries.
- `LogStore.where` is materially simpler — no `IN (SELECT rowid FROM
  event_fts WHERE event_fts MATCH ?)` plumbing for substring paths.

---

## D16. Coalesced reload debouncing

**Status:** Accepted (2026-05-16)

**Decision.** All `LogFeedViewModel` reload triggers route through a
single `requestReload()` helper that schedules a 150 ms debounced
reload. Cancellation of an outstanding debounce on every new call
ensures only the final trigger in a burst hits the store.

Triggers covered: initial mount, `filter` `didSet`, scroll overscan
(`didReachEnd`), `.appended` change broadcasts, `.cleared` change
broadcasts.

Not covered (direct `await reload(...)` retained): jump-to-match
navigation, which is a one-shot user action where latency matters.

**Why.**
- Each keystroke in a filter pill changes `filter`, which previously
  triggered an immediate `eventCount` + `events()` SQL pair. Typing
  `load` (four characters) ran four pairs serialized on the store
  actor — even with task cancellation, each in-flight SQL completed
  before any cancellation check ran.
- Live event broadcasts in a busy session can fire dozens of times per
  second; without coalescing, each one queued its own reload behind
  the previous, freezing the UI under load.
- 150 ms is below human perception for "did my keystroke do
  something?" but well above the inter-keystroke interval for a fast
  typist — most typing bursts coalesce to a single query.

**Implications.**
- `reloadDebounce` is a `nonisolated(unsafe)` `Task<Void, Never>?` on
  the view model (the same pattern as `matchTask` from D14).
- One-shot user actions (Next/Previous match) bypass the debouncer to
  feel snappy.
- Tunable in one place if 150 ms turns out to be the wrong knob value.

---

## D17. Command-help registry as temporary scaffold

**Status:** Accepted (2026-05-16). **Scheduled for removal** when the
SDK protocol upgrades — see PROTOCOL.md §3.2.1.

**Decision.** Ship a hard-coded `CommandRegistry` mapping each known
SDK command name to `{ syntax, description }`. On client connect,
LoggerNext sends `cmdlist` automatically; when the SDK's response
arrives (a log event with subsystem
`DebugFeatures/ConsoleCommands/GeneralHandler` and a known message
prefix), we parse out the command names and merge them with the
registry. The command-help popover displays:

- **Mapped commands** with full syntax + description, grouped by
  prefix (Storage, Debug, Layout, General).
- **Unmapped commands** in a separate "Unknown to LoggerNext"
  section so the user can still discover and run them.

**Why.**
- The current SDK's `cmdlist` returns names only, no syntax. Without
  a mapping the popover would just show a flat name list and the user
  would have to read SDK docs to know argument shapes.
- The mapping captures *today's* iOS SDK. Cross-platform (tvOS,
  Android, Web) clients will likely return the same names with the
  same syntax — but where they don't, the merge falls through and the
  unmapped commands still work.
- Self-deleting: when the SDK extends `cmdlist`'s response to return
  structured `{name, syntax, description}` (proposed shape in
  PROTOCOL.md §3.2.1), we delete `CommandRegistry.swift` and have
  `CommandHints.merge` read syntax directly from the response.

**Alternatives considered.**
- *Names-only popover.* Simpler but unhelpful — users still need to
  consult SDK docs for arg shapes.
- *Embed full command spec in LoggerNext per-platform.* More accurate
  but contradicts the "no LoggerNext-side ownership of SDK contracts"
  principle. The registry-as-scaffold is the minimum viable
  shortcut while the SDK catches up.

**Implications.**
- `CommandRegistry.swift` carries a prominent TODO header marking it
  as temporary and pointing at PROTOCOL.md §3.2.1.
- `cmdlist` is sent automatically 500 ms after `.clientConnected` so
  the popover is pre-populated by the time the user opens it.
- The cmdlist response event still appears in the log feed
  (discovery is a pure side-channel; we don't suppress it). When the
  SDK adopts a typed response message, we can stop polluting the feed.

---

## D18. JSON detail pane: typed kind + manual recursive tree

**Status:** Accepted (2026-05-18)

**Decision.** Replace `OutlineGroup`-based JSON rendering with a manual
recursive view (`JSONTree` for log events, `StorageTree` for storages)
that owns its own disclosure chevrons and applies an explicit
`depth × 14pt` indent per nesting level. Each node carries a
`JSONKind` enum (`.string`, `.number`, `.bool`, `.null`,
`.object(count:)`, `.array(count:)`) instead of a stringified
`valueText`. A shared `JSONSyntax` Text builder renders one row per
node with inline colour: quoted purple keys, orange strings, blue
numbers, magenta bools, muted `null` / container summaries.

**Why.**
- `OutlineGroup` only indents children visually when it's nested
  inside a `List`. Used directly inside a `VStack` the children render
  flat — the tree didn't read as a tree. The screenshot review caught
  this immediately.
- The stringified `valueText` approach couldn't distinguish a JSON
  string `"42"` from the number `42` once formatted, breaking the
  copy-as-JSON path (a leaf was always emitted unquoted). A typed
  `JSONKind` makes the copy serialiser straightforward and the
  syntax-colouring trivial.
- Sharing `JSONSyntax.row(key:isArrayIndex:kind:)` between the
  log-event detail pane and the Storages detail pane keeps the two
  visually identical with zero duplication.

**Alternatives considered.**
- *Stick with OutlineGroup, wrap in a List.* Would re-introduce a
  full `List` row chrome (selection highlight, hover background) that
  the detail pane doesn't want.
- *Compute depth via SwiftUI preference keys.* More cleverness, same
  outcome; the manual recursive view is half the code.

**Implications.**
- New file `Domain/JSONKind.swift` (model) + `Features/Shared/JSONSyntaxText.swift`
  (SwiftUI Text builder).
- `JSONTreeNode.build` no longer appends `{ N }` / `[ N ]` to labels —
  the container summary is rendered as its own coloured segment.
- `StorageRecord` gained a `kind: JSONKind` field; `jsonLiteral` now
  switches on `kind` instead of guessing from `valueText`.

---

## D19. Storages tab: explicit subscription bootstrap before refresh

**Status:** Accepted (2026-05-18)

**Decision.** Move the Storages view-model's "subscribe to store
changes" step out of the fire-and-forget Task pair in `init` into an
explicit `bootstrap()` async method. `StoragesView.task(id:)` must
`await fresh.bootstrap()` before publishing the VM and before sending
the first `storage.list`. Also add a 400 ms delayed `reloadFromStore()`
inside `requestRefresh` as a belt-and-braces fallback.

**Why.**
- Two `Task { await … }` blocks fired from `init` have no guaranteed
  scheduling order relative to each other or to the request Task that
  `StoragesView.task` kicked off immediately after. The SDK could
  respond and broadcast `.storageUpdated` before the subscription Task
  had even reached `await store.changes()`, leaving the UI showing the
  empty state even after a manual Reload. This was the user-reported
  bug ("storage not loaded also reload not help").
- Awaiting `bootstrap()` makes the ordering explicit: subscription
  registered, cached snapshots read, only then does the request go
  out. The belt-and-braces delayed reload catches any remaining race
  if a future broadcast slips through.

**Alternatives considered.**
- *Poll the store on a timer.* Heavier and still racy at the edges.
- *Make `store.changes()` a multicast subject with replay.* Larger
  change to the store actor; the explicit-bootstrap fix is local to
  the view model.

**Implications.**
- `StoragesViewModel.init` no longer self-starts any Tasks. Callers
  must `await vm.bootstrap()` before treating the VM as live.
- Same pattern should apply to any future VM that combines a store
  subscription with an outbound request — see D19 when refactoring.

---

## D20. Sessions: delete + click-to-open

**Status:** Accepted (2026-05-18)

**Decision.** The Sessions tab now supports three actions:

1. *Click a row* → switches the selected tab to Log feed (showing
   that session's events) and updates `viewingSessionId`.
2. *Hover a row* → red trash icon appears on the right; clicking it
   opens a confirmation dialog and, on confirm, deletes the session.
   Same dialog is reachable via right-click → "Delete session…".
3. *Footer "Delete all sessions…"* (red) → confirmation dialog;
   wipes every session, every event, every storage snapshot, every
   bookmark via `ON DELETE CASCADE` on the FK constraints.

The currently-live session (matching `currentSessionId`) is tagged
with a green "LIVE" capsule in the row and cannot be deleted while
the device is connected.

**Why.**
- Without a delete, sessions accumulate forever — even short-lived
  reconnect sessions clutter the sidebar.
- Tab-switch on click matches the user expectation that picking a
  past session means "show me its logs", not "highlight it in the
  sidebar".
- Cascading deletes via SQLite FKs keep the implementation tiny
  (one DELETE per call) and atomic (no dangling rows).

**Alternatives considered.**
- *Edit-mode list with bulk checkbox selection.* Heavier UI for a
  tool that's mostly used one session at a time.
- *Soft-delete with hide/restore.* Adds a column, an "Archived"
  filter, and a "Show archived" toggle — not worth it for a debug
  tool.

**Implications.**
- New `LogStore.deleteSession(id:)` and `LogStore.deleteAllSessions()`
  + two new `Change` cases: `.sessionDeleted(id:)` and
  `.sessionsCleared`. All existing consumers had `default:` arms, so
  the addition is backwards-compatible.
- `LoggerNextApp` bootstrap subscriber clears `viewingSessionId` /
  `currentSessionId` on deletion and, if a device is still connected,
  immediately spins up a fresh live session so its events have
  somewhere to go.
- **Known limitation.** macOS `.contextMenu` items don't respect
  SwiftUI's `role: .destructive` tint or per-element `.foregroundColor`
  in this version — the right-click "Delete session…" stays in the
  system menu colour even though the matching hover/footer affordances
  are explicitly red. The primary delete path is the hover trash
  button; the context menu is a secondary shortcut. A future change
  could replace `.contextMenu` with a custom `.popover` driven by an
  `NSViewRepresentable` right-click catcher, which would give us full
  styling control.

---

## D21. Rebrand to "Beaver" — display only, internals unchanged

**Status:** Accepted (2026-05-18)

**Decision.** Change every *user-facing* surface to read "Beaver"
while leaving the internal Xcode project, target name, bundle
identifier, executable name, entitlements file, on-disk store
directory, and Git history alone (all still "LoggerNext"). The
rebrand is implemented as:

- `INFOPLIST_KEY_CFBundleDisplayName = Beaver` and
  `INFOPLIST_KEY_CFBundleName = Beaver` in both Debug + Release build
  configs of the app target.
- `MainWindow.navigationTitle("Beaver")`.
- `scripts/release.sh` renames the exported `LoggerNext.app` →
  `Beaver.app` *after* notarization, and packages it into
  `build/Beaver-<version>.zip`.
- README header rebranded with a note explaining the split.

**Why.**
- The brand only needs to live where users see it — Finder, Apple
  menu, About dialog, window title, distribution zip. Everywhere
  else the codename `LoggerNext` is fine and changing it would carry
  real cost.
- Renaming the bundle identifier would invalidate every existing
  user's Application Support data directory (named after
  `com.applicaster.LoggerNext`) and require re-issuing the Developer
  ID-signed builds with a new identifier. Both are wasteful for a
  cosmetic rebrand.
- Renaming the Xcode target / scheme / group paths is a 100+ line
  pbxproj edit, with high risk of breaking the project file or the
  test target's `TEST_HOST` / `TEST_TARGET_NAME` references. Display
  keys give us 95% of the rebrand for 1% of the risk.

**Alternatives considered.**
- *Full rename.* Folders, target, scheme, bundle id all → Beaver.
  Cleaner long-term, but breaks installed user data (bundle id move),
  forces a new signed cert, and demands a careful pbxproj surgery
  pass that's hard to verify without a successful Xcode build.
- *Keep "LoggerNext" everywhere.* Avoids the work but means the user
  sees the internal codename — the whole point of picking a brand.

**Implications.**
- The .app on disk inside the distribution zip is `Beaver.app`.
- The .app's Mach-O executable inside the bundle is still
  `LoggerNext` (matches PRODUCT_NAME = $(TARGET_NAME)). Users never
  see this; Finder uses CFBundleDisplayName.
- Application Support directory remains
  `~/Library/Application Support/LoggerNext/store.sqlite`. Stable
  across the rebrand, so existing users keep their session history.
- If we ever do want a full rename (e.g., to fully decouple from the
  old Logger trademark), the path is documented here and is a
  one-time migration project rather than something to do reactively.

---

## D23. CI decides the version from commit messages

**Status:** Accepted (2026-05-19)

**Decision.** Stop bumping `MARKETING_VERSION` locally. Every push to
`main` triggers CI, which scans the commit messages since the last
release tag and computes the next version:

| Prefix on any commit in the range  | Bump | 1.0.3 →   |
|------------------------------------|------|-----------|
| `release:` (or `release(scope):`)  | major | 2.0.0    |
| `feat:`    (or `feat(scope):`)     | minor | 1.1.0    |
| anything else (`fix:`, `chore:`, …) | patch | 1.0.4   |

Highest-impact prefix wins. CI then bumps the pbxproj, runs
`make release`, commits the bump with `[skip ci]` so it doesn't
re-trigger the workflow, tags the commit, publishes the GitHub
Release, and appends a signed `<item>` to the Sparkle appcast.

The escape hatch — `make bump VERSION=X.Y.Z` followed by a push —
still works: `scripts/compute-next-version.sh` detects that the
pbxproj is already ahead of the last tag and respects the manual
value rather than auto-bumping past it.

**Why.**
- Removes "did you remember to bump?" friction. The only thing
  contributors do is commit + push. Everything else is automated.
- Conventional Commits is the broadest convention in the ecosystem —
  almost every engineer already recognises `feat:` / `fix:`. Adopting
  it doesn't force learning anything new.
- Couples version bumps to actual content. A typo fix that gets
  merged shouldn't accidentally cut a `1.1.0` if the contributor
  reflexively named the commit "feat" — but accepting that risk is
  cheaper than the cost of forgetting to release at all.
- Patch-by-default means low-churn PRs (`fix:`, `chore:`, `ci:`,
  `docs:`) still ship as a new patch release. Combined with Sparkle,
  every push gets to users automatically.

**Alternatives considered.**
- *Tag-triggered releases.* CI runs only on `git push --tags`. Cleaner
  semantically but reintroduces the "I forgot to bump" problem and
  makes hot-fix releases require local CLI steps.
- *Manual version field in PR template.* Cleaner intent capture, but
  requires every contributor to think about semver explicitly — the
  whole point is to avoid that.
- *No automation — keep `make ship` as the canonical path.* What we
  had until D23. Works fine for a small team where one person ships
  everything; doesn't scale.

**Implications.**
- New script `scripts/compute-next-version.sh` — pure function from
  the git history + pbxproj to a version string. Importable into the
  CI config or runnable from a developer's Mac for "what would the
  next release be?" forecasting.
- `.circleci/config.yml` adds a "Compute next version" step before
  the existing "Skip if release already exists" idempotency gate, and
  a "Apply version bump to pbxproj" step right before `make release`.
- The bump commit lives on `main`, not on a release branch. It has
  `[skip ci]` in the message; CircleCI honours that to avoid an
  infinite re-trigger loop.
- `make bump` and `make ship` remain — they're now emergency tooling
  for the day CI is down or someone needs to cut an out-of-band patch
  without going through main. Documented as the escape hatch in the
  README.
- Branch protection on `main`, if ever enabled, must allow the
  `GITHUB_TOKEN` to push. Otherwise CI's bump commit + appcast push
  will fail.

---

## D24. Saved filter presets

**Status:** Accepted (2026-05-19)

**Decision.** The `saved_filter` table (schema v1, unused until now)
backs a named list of `Filter` combinations the user can apply with
one click. The log-feed filter bar gains a `★` button as its leading
control: clicking opens a SwiftUI popover that lists every saved
preset (name + 1-line summary), highlights the one matching the
current active filter, and provides a "Save current filter…" action
that opens a sheet for naming. Each row has a hover-revealed red
trash icon for deletion.

Apply semantics: clicking a preset overwrites `vm.filter` wholesale.
`vm.highlight` is *not* affected — it's a session-local visual aid,
not part of the persisted preset.

**Why.**
- Every engineer has 3-5 filter combos they re-type daily ("errors
  only, no analytics", "this feature flag's subsystem", etc.). The
  schema was provisioned for this on day one; it just never got UI.
- Upsert-by-name (UNIQUE index on `name`) gives "save as / overwrite"
  for free without a separate "rename" flow.
- Putting the button at the *leading* edge of the filter bar keeps
  the existing visual grammar — level menu, then filter pills, then
  highlight — intact; the ★ slots in as "preset selector before the
  individual fields."

**Alternatives considered.**
- *Recent-filter history (no save action).* Simpler but doesn't match
  how users actually work — they recall a *name* like "the auth
  filter," not a position in time.
- *Per-session presets.* Saved filters scoped to one session. Wrong
  scope; the value is cross-session re-use.
- *App-wide hot-keys (⌘1, ⌘2, …) per preset.* Nice future addition
  but requires a stable order — punting until presets stabilize.

**Implications.**
- New `Domain/SavedFilter.swift` value type.
- `LogStore` gains `savedFilters()`, `upsertSavedFilter(name:filter:)`,
  `deleteSavedFilter(id:)`, plus `.savedFiltersChanged` broadcast.
- `LogFeedViewModel` gains `savedFilters`, `applySavedFilter(_:)`,
  `saveCurrentFilter(as:)`, `deleteSavedFilter(id:)`. Subscription
  reloads the list on `.savedFiltersChanged`.
- `LogFeedView` adds the `★` button + popover + save-sheet at the
  leading edge of the filter bar.
- `SessionsViewModel`'s exhaustive switch over `Change` gains the
  new case in its no-op arm (storage / bookmarks / saved filters
  don't affect the sessions sidebar).

**Future work.**
- ⌘1…⌘9 keyboard shortcuts per preset for power users.
- Sync presets across teammates via a shared JSON export (would
  need `Filter`-to-JSON Codable on top of the existing struct).

---

## D26. Export respects the active Log-feed filter

**Status:** Accepted (2026-05-19)

**Decision.** The toolbar's Export action emits only the events
matching the currently-active Log-feed filter. If no filter is set
the behavior is identical to before (whole session). The button
label flips between `Export` and `Export (filtered)` so the user
sees what they're about to ship.

**Why.**
- The realistic export use case is "narrowed to N relevant rows,
  want to share THOSE with a colleague" — never "give me 50,000
  events in one zip". Filter-aware export turns the common case
  from a copy/paste workflow into one click.
- The store's `events(sessionId:filter:offset:limit:)` query already
  takes a filter; piping `vm.filter` through is mechanical.
- D7 specifically noted this as a "follow-up" — the time was now.

**Alternatives considered.**
- *Two separate buttons* (Export all / Export filtered). More
  discoverable but doubles the toolbar surface; rejected.
- *Confirmation dialog asking "filtered or all?"*. Friction tax on
  every export; rejected.
- *Implicit always-filtered behavior with no UI hint*. Surprising
  if the user forgot they had a filter set. Adding the label flip
  is the cheapest way to make the behavior visible.

**Implications.**
- `AppEnvironment.activeFilter: Filter` — new state, mirror of
  `LogFeedViewModel.filter`. The Log-feed view syncs it via
  `.onAppear` / `.onChange` / `.onDisappear` so the env always
  reflects the visible feed (or `.none` when the feed isn't shown).
- `MainWindow.prepareExport` reads `env.activeFilter` instead of
  passing `.none` to the store query.
- `MainWindow.hasFilter` drives the button label + tooltip swap.
- Bookmarks, Storages, and the Clear action are unaffected —
  Clear still wipes the whole session (a destructive op shouldn't
  silently inherit a filter).

---

## D27. Jump-to-Time toolbar action

**Status:** Accepted (2026-05-19)

**Decision.** A new "Jump To Time" toolbar button opens a popover
with a `DatePicker` and a Jump action. On Jump, the active
`LogFeedViewModel` finds the event whose `timestamp_ms` is closest
to the target (respecting the current filter) and scrolls to it.
Pause is set during the jump so the destination isn't immediately
yanked away by streaming events.

**Why.**
- Crash investigations have a recurring shape — "the app died at
  14:13:42; what was Beaver showing right then?" Today the answer
  is scroll-by-feel through hundreds of rows. A scoped jump is the
  shortest path from question to context.
- Respecting the active filter is the right default: if the user
  has already narrowed to a subsystem, they're saying "show me what
  THIS subsystem was doing around then." Clearing the filter
  before jumping is a one-click escape if they want the broader
  view.

**Alternatives considered.**
- *Time-range filter (hide events outside a window).* More
  powerful but heavier UI; the common case is a point query, not a
  range. Range-filtering can be added later as a separate D entry.
- *Scrubber along the table edge.* Visual but vague — "scroll to
  14:13:42" is precise, "scroll to ~3/4 of the way through" isn't.
- *Cmd-G with time syntax.* Tempting (typed `14:13:42` in the
  highlight field jumps), but conflates two distinct user
  intents (highlight matching text vs scroll to a time).

**Implications.**
- New `LogStore.nearestEventId(sessionId:targetMillis:filter:)` —
  single SELECT ordered by `ABS(timestamp_ms - target)`. O(N) per
  query but with N capped by the session's event count and
  short-circuited by `LIMIT 1`.
- New `LogFeedViewModel.jumpToTime(_:)` — wraps the store query,
  pauses the feed, and routes through the existing `jumpTo(eventId:)`
  scroll path.
- New `loggerNextJumpToTime` `NotificationCenter` name + listener
  in `LogFeedContent` — same pattern as `loggerNextJumpToBookmark`.
- New `JumpToTimePopover` view + toolbar item in `MainWindow`.
  The picker seeds to "now" each time the popover opens so the
  user typically just adjusts hours/minutes.

---

## D28. Storage edit-and-push-back via existing SDK console commands

**Status:** Accepted (2026-05-19)

**Decision.** Wire the Storages detail pane's Edit / Delete / Add
buttons to the `storage.<namespace>.set` and
`storage.<namespace>.delete` console commands the SDK already exposes
(cataloged in `CommandRegistry.swift` since D17). No SDK change
needed — Beaver constructs and sends the command string over the
existing `command` channel, then issues `storage.list` ~400 ms later
to refresh the table.

UI scope for v1:
- Detail-pane header gains Edit + Delete buttons, only enabled for
  top-level **leaf** records (id == key, no children). Container
  records (objects / arrays) and nested leaves are skipped — the
  current SDK command doesn't accept dotted paths or whole-tree
  payloads, and replacing them by sending the whole JSON value is a
  Phase 2 concern (Edit-as-JSON sheet).
- Top bar gains "Add key" — opens a sheet with a segmented namespace
  picker + key/value fields + a live preview of the command being
  sent.
- Delete uses a confirmation dialog (matches the rest of the
  destructive actions in the app).
- All three buttons are disabled when no client is connected — the
  SDK can't apply anything if the device isn't on the wire.

**Why.**
- The SDK's `storage.<ns>.set` / `.delete` were verified live by
  typing them in Beaver's command bar; both return success log
  events from `DebugFeatures/ConsoleCommands/StorageCommandsHandler`.
  Nothing to ask for from the SDK team.
- This is the #2 must-have feature ("flip a feature flag from the
  desktop") and we already had every piece of plumbing except the
  buttons. Half-day delivery.
- Keeping the protocol opaque-string (rather than the typed JSON
  payload we'd ideally want — see prior D6 discussion) limits us:
  values containing spaces, quoting rules, complex objects are all
  TBD. Surfaced in the UI as a yellow inline warning when the user
  types a value with a space.

**Alternatives considered.**
- *Wait for the SDK team to ship a typed payload variant of
  `storage.set`.* Indefinite timeline; we'd be sitting on a feature
  the SDK already supports.
- *Inline-edit inside the detail-pane tree rows.* Tighter UX but
  conflicts with the recursive tree's hover-copy / disclosure
  triangle affordances. A separate sheet keeps the tree read-only
  for browsing and isolates the editing semantics.

**Implications.**
- `StoragesViewModel` gains `setValue(in:key:value:via:)` and
  `deleteValue(in:key:via:)`. Both fire-and-forget — they don't
  wait for the SDK's reply, they just refresh after a short delay.
- `StoragesDetail` takes `onEdit` / `onDelete` callbacks; the parent
  view owns the sheet state.
- Two new sheets: `EditStorageValueSheet` and `AddStorageKeySheet`,
  both with command-preview text so the power user always sees
  exactly what's about to fly over the wire.
- Phase 2 candidates (later, if anyone asks):
  - JSON-editor for containers
  - Quote-handling for values with spaces
  - Per-namespace permission introspection (cmdlist could tell us
    which namespaces are read-only on a given platform)

---

## D29. Storages — outline layout instead of namespace tabs

**Status:** Accepted (2026-05-19)

**Decision.** Replace the tab-style namespace chip row + per-namespace
table with a single outline view that shows all three namespaces as
collapsible sections. Each row gets its own hover-revealed Edit +
Delete buttons. Detail pane on the right is unchanged — it still
renders the selected key's value tree.

**Why.**
- User mental model is "the left column IS the namespace, rows are
  keys inside it." Splitting across three tabs hid that
  relationship and forced an extra click to find a key in an
  unfamiliar namespace.
- Per-row actions (Edit/Delete) want to live close to the row, not
  in the detail pane header. The outline view makes per-row
  affordances the obvious place for them — matches the Sessions
  list pattern.
- Collapsible sections let power users hide noisy namespaces (e.g.,
  Local with 100 SDK-internal keys) when they're debugging
  Session/Keychain.

**Alternatives considered.**
- *Keep tabs, add per-row affordances inside each table.* Works
  but reinforces the wrong mental model and triples the affordance
  surface (one Edit per tab × 3).
- *Master/detail with a NavigationSplitView third pane.* Too
  heavy — adds a fourth visual area when three (outline + detail)
  already do the job.

**Implications.**
- `StoragesViewModel`:
  - `selectedRecordId: String?` becomes
    `selection: SelectionKey?` (composite `{namespace, recordId}`)
    so two namespaces with the same key name don't collide.
  - `records` / `filteredRecords` become parameterised by
    namespace (`records(in:)`, `filteredRecords(in:)`).
  - New `expandedNamespaces: Set<Namespace>` drives the collapse
    state (default: all open).
- `StoragesView`:
  - `StoragesTopBar` loses the namespace chips; "Add key" sits on
    the leading edge of the top bar.
  - `StoragesTable` deleted, replaced by `StoragesOutline` ⇒
    `NamespaceSection` ⇒ `StorageOutlineRow`.
  - `StoragesDetail` loses its in-header Edit/Delete buttons —
    those affordances now live on the row that owns the value.
- `NamespaceChip` view deleted (no callers).

The wire protocol is unchanged. Edit/Delete still pipe through
`storage.<wireKey>.set / .delete` (D28).

---

## D30. Storages — tabs back + expandable namespaces

**Status:** Accepted (2026-05-19), revises D29

**Decision.** Restructure the Storages screen one more time:

1. **Layer tabs at the top** (Session / Local / Keychain), back the
   way they were in the old Logger app. One layer is visible at a
   time. This restores the original mental model where the chip
   colour tells you instantly what storage you're looking at.
2. **One namespace per row** in the layer's outline. Each row is
   expandable: click the chevron to reveal its inner `key: value`
   children inline. The detail pane on the right still drives full
   recursive browsing for arbitrarily nested values.
3. **Per-row actions, two flavours:**
   - **Namespace (container) row**: `[copy-all-as-JSON]`
     `[add-key-inside]` `[trash]` — copy serializes the whole
     subtree, add-inside opens the sheet with parent pre-filled,
     trash removes the entire namespace.
   - **Namespace (scalar) row**: `[copy-value]` `[pencil-edit]`
     `[trash]` — same as before (D28).
   - **Inner key row**: `[copy-value]` `[trash]` — copies the
     child's literal value (or its JSON subtree), trash deletes
     just that one key from inside the parent namespace.

**Why.** Pure response to user feedback after living with D29 for an
afternoon: *"Session/Local/Keychain should go to tabs like was
before. Namespaces (`applicaster.v2`, `continue-watching`, etc.)
must be expandable with items inside."* The D29 all-three-at-once
outline was useful for power users debugging cross-layer state but
got in the way of the common case — *"show me my flags in the local
namespace and let me flip one."*

**Why expandable inner rows (and not just the detail pane)?** Two
clicks vs. one. With one click on the chevron the user can see
*every* key/value inside the namespace at a glance — no need to
click into each one to inspect. The detail pane is still there for
nested-JSON browsing, but the common "I just want to see my five
feature flags" case is one click.

**Wire protocol.** Unchanged from D28. The SDK's
`storage.<wireKey>.set/delete` already accepts an optional 3rd-arg
subscope, which is exactly what "the parent namespace" means in
this UI. So `[add-key-inside]` on `applicaster.v2` builds
`storage.local.set premium true applicaster.v2`. We just hand the
parent key to `vm.setValue(in:parent:key:value:via:)`.

**Implications.**
- `StoragesViewModel`:
  - Restored `selectedNamespace` as the active layer tab.
  - Added `expandedRecordKeys: Set<String>` keyed by
    `"<wireKey>:<recordId>"` so expand state survives tab
    switches without leaking across layers.
  - `setValue` and `deleteValue` gained an optional
    `parent: String?` parameter — appended as the SDK's 3rd-arg
    subscope when non-nil.
- `StoragesView`:
  - `StoragesTopBar` restored `NamespaceTab` chip row.
  - `StoragesOutline` rewritten to show only the current layer's
    top-level records, with four callbacks (edit, delete,
    add-inside, delete-inside).
  - New `NamespaceRow` view (top-level key + actions + expanded
    inline children) + `InnerKeyRow` view (one-level child with
    hover-revealed copy/delete).
  - `AddStorageKeySheet` now takes `initialParent: String?` and
    runs in two modes: "Add key" (parent = nil, user picks layer)
    or "Add key inside &lt;parent&gt;" (parent + layer locked,
    user types key + value only).
  - New `pendingInnerDelete: InnerDeleteTarget?` state +
    confirmation dialog for inner-row deletes.
- D29's `NamespaceSection` + `StorageOutlineRow` views deleted
  (no longer used).

**Trade-offs.**
- We lose D29's "see all three layers at once" affordance. The
  three-tab pattern means a power user looking for a key across
  layers has to switch tabs. Considered acceptable because the
  search filter still spans the current tab, and the new design
  optimises for the common case (working inside one layer) over
  the rare one.
- Expand state lives in the VM, not on disk. So which namespaces
  are expanded resets on app relaunch. Acceptable until anyone
  complains.

---

## D31. Storages — drop namespace-delete and right-side detail pane

**Status:** Accepted (2026-05-19), follows D30

**Decision.** Two simplifications, both driven by user feedback the
same afternoon D30 landed:

1. **Container (namespace) rows can no longer be deleted from the
   UI.** Only `[copy-all-as-JSON]` and `[add-key-inside]` show on
   namespace rows. Top-level scalar rows still get `[copy] [delete]`.
   Inner key:value rows still get `[copy] [delete]`.
2. **The right-side detail pane is gone.** Every value is visible
   by expanding the namespace row inline; deeper structures are
   surfaced via the row's copy-as-JSON button.

**Why drop namespace-delete?** The Applicaster iOS SDK doesn't
expose a "wipe a whole namespace" command. `storage.local.delete
<key>` removes one key at a time; there's no
`storage.local.delete-all <namespace>`. Surfacing a trash icon that
silently fails (or that requires N round-trips to clear N keys)
is a worse UX than not surfacing it at all. Users who really want
to clear a namespace can do it via the inner-row trash on each
child, one at a time — which is the SDK's actual model.

**Why drop the detail pane?** Once every namespace row expands
inline to show its `key: value` children, the detail pane is
redundant for the 99% case. For the rare deep-nesting case
(stringified JSON several levels deep), the namespace row's
copy-as-JSON button still gets the full subtree into the user's
clipboard. Removing the pane reclaims ~30% of horizontal screen
space for the actual content.

**Implications.**
- `StoragesViewModel` loses `SelectionKey`, `selection`,
  `selectedRecord`, and `selectedRecordNamespace`. `clearLocalCache`
  also clears `expandedRecordKeys` so a re-imported snapshot
  starts collapsed.
- `StoragesView` loses `StoragesDetail`, `StorageTree`,
  `StorageTreeRow`, and `EditStorageValueSheet` (no more edit
  affordance; user deletes + re-adds to change a value).
- `StoragesOutline` and `NamespaceRow` lose their `onEdit`
  callback; only `onDelete`, `onAddInside`, and `onDeleteInside`
  remain.
- `EditTarget` renamed `DeleteTarget` (since edit is gone, the
  struct only carries the row for delete confirmation).
- The `HSplitView` is gone; the outline gets the full viewport.

**Trade-offs.**
- **No inline edit.** Changing a value now means delete + add (two
  confirmations, two SDK calls). Acceptable because the common
  case is "flip a feature flag" — a binary change where
  delete+add is fine — and because keeping edit would re-introduce
  a sheet for what the user wants to be a peek-and-poke flow.
  If complaints come in, we can re-add edit on inner rows behind
  a `pencil` icon without un-doing the rest of D31.
- **No deep-tree browser.** Anything nested ≥2 levels deep (a
  JSON object inside `applicaster.v2.someKey`) can only be
  inspected via copy-as-JSON. Acceptable for the same reason as
  above — the typical Logger workload is one level deep.

---

## D32. Hoist per-session view models to `MainWindow`

**Status:** Accepted (2026-05-19)

**Decision.** `LogFeedViewModel` and `StoragesViewModel` now live as
`@State` on `MainWindow`, keyed by `env.viewingSessionId`. The tab
views (`LogFeedView`, `StoragesView`) become thin pass-throughs that
receive their VM as a parameter rather than constructing it in their
own `@State`.

**Why.** With the previous layout — each tab view owned its VM as
`@State` — switching tabs tore down the view subtree and destroyed
the VM. Coming back to the Log feed wiped the user's filter, exclude,
level, search, highlight, sort, and selection. Same story for Storages
(selected layer, expanded namespaces, search term, auto-refresh
toggle). Users hit this constantly because the natural debugging flow
is "look at logs → check storage → back to logs."

**Alternatives considered.**
- *Keep all tab views alive with a ZStack and opacity*: works but
  every tab pays render cost continuously.
- *Cache VMs in `AppEnvironment`*: env is for services + global
  state, not per-window UI state. Mixing concerns.
- *Add a `@Environment` "store of view models"*: same problem as
  above, plus invented infrastructure.

Hoisting to `MainWindow` is just SwiftUI working as designed —
parent owns the state, child renders it.

**Implications.**
- `MainWindow` has `@State var logFeedVM: LogFeedViewModel?` and
  `@State var storagesVM: StoragesViewModel?`.
- A single `.task(id: env.viewingSessionId)` block creates/destroys
  both when the session changes. Tab switches don't invalidate
  the task id, so the VMs survive.
- `LogFeedViewModel.sessionId` had to flip from `private` to
  internal so `MainWindow` can compare it against
  `env.viewingSessionId` and decide whether to replace.
- `StoragesView` no longer self-bootstraps; its `bootstrap()`
  call moved up into the same `MainWindow` task and runs
  *before* `storagesVM` is published — preserves the
  subscribe-before-first-request ordering that D52 fixed.
- Side benefit: the same `storagesVM` is what the toolbar's
  device badge reads from, so `applicaster.v2` metadata is
  visible across every tab not just Storages.

**Trade-offs.**
- Eager VM construction on session change, even if the user
  never visits that tab. Cheap (a subscription + one query) so
  not worth lazy-loading.

---

## D33. App-level `ToastCenter` for action feedback

**Status:** Accepted (2026-05-19)

**Decision.** Add `ToastCenter` — an `@Observable @MainActor`
service injected via `.environment(_:)` from `LoggerNextApp` — and
a `ToastPresenter` view that floats one toast at a time at the top
of the window. Every primary user action (copy, delete, save,
bookmark toggle, filter change, …) calls `toasts.success(…)`,
`toasts.info(…)`, or `toasts.error(…)`.

**Why.** Actions used to be silent. Right-click → "Copy Message"
performed the copy but gave no feedback; users couldn't tell if it
landed. Worse, the bookmark popover race (the "first bookmark not
shown" bug) was effectively invisible without confirmation. A
2-second floating chip is the macOS-native pattern (Notification
Center–style) and costs nothing.

**Alternatives considered.**
- *NSAlert on each action*: modal, disruptive, wrong tool.
- *Status-bar label that's always visible*: takes permanent
  vertical space, ages out poorly.
- *Pulse the changed UI element*: hard to do consistently across
  the 20+ places we want feedback, and the eye misses pulses
  outside the focal area.

**Implications.**
- `LoggerNext/Features/Shared/Toast.swift` is the new home:
  `Toast` value type, `ToastCenter` controller, `ToastPresenter`
  view.
- `ToastPresenter` is `.overlay(alignment: .top)` on
  `MainWindow.body`, with `.allowsHitTesting(false)` so the chip
  never blocks underlying clicks.
- `MainWindow`, `LogFeedView`, `StoragesView`, `SessionsView`,
  and every helper that touches the clipboard reads
  `@Environment(ToastCenter.self)` and calls into it.
- Toast presets: green check for success, blue info-circle for
  passive actions like filter changes, red triangle for errors
  (longer dismiss — 3s). UUID-keyed auto-dismiss so back-to-back
  toasts don't cut each other off.

**Trade-offs.**
- One toast at a time — back-to-back actions replace the
  previous chip rather than queueing. Intentional: users want
  feedback on the *latest* thing they did.
- Toast lives at the window level; popovers and sheets render
  over the toast (correct z-order). If we ever want a sheet to
  itself fire toasts, the sheet would need its own
  `ToastPresenter` overlay or to pass results back. Not a
  current pain point.

---

## D34. Persist device fingerprint per session

**Status:** Accepted (2026-05-19)

**Decision.** Capture `app_name`, `app_version` (`version_name`),
`device_model`, `platform`, and `os_version` from the SDK's
well-known `applicaster.v2` session-storage namespace and write them
onto the session row itself. Migration `v3_session_device_info` adds
five nullable TEXT columns. `LogStore.recordStorageSnapshot` runs a
small `harvestDeviceInfo` step whenever a session-namespace snapshot
arrives, and `setSessionDeviceInfo` patches the row via `COALESCE`
so later snapshots don't clobber earlier fields they don't carry.
A new `Change.sessionUpdated(Session)` broadcast lets the Sessions
list refresh its rows.

**Why.** When a user opens a past session they need to know which
build of which app they're looking at. Without persistent
fingerprint data, the only context for a session was its start
timestamp — useless for "which of these is the iPhone 15 Pro Max
crash?" Surfacing the fingerprint on the Sessions list and in the
toolbar makes session identification instant.

**Alternatives considered.**
- *Compute on-demand by reading the latest snapshot each session
  needs to render*: N queries to paint the Sessions list. Bad
  scaling, plus snapshots may not exist for older sessions.
- *Single JSON blob column*: defeats the "group by device model"
  queries we might want later (analytics, debugging cohorts).
- *Capture from a synthetic SDK event*: would require an SDK
  protocol change. `applicaster.v2` already contains this data.

**Implications.**
- Schema v3 adds: `app_name`, `app_version`, `device_model`,
  `platform`, `os_version` (all nullable TEXT) on `session`.
- `Session` domain struct grows matching optional properties.
- `LogStore.setSessionDeviceInfo(id:…)` uses `COALESCE` so a
  later partial snapshot doesn't blow away an earlier complete
  one.
- `Change.sessionUpdated(Session)` joins the existing change
  cases. `SessionsViewModel` reloads on it.
- `SessionListItem.appLabel` / `deviceLabel` derived properties
  drive the new SessionRow subtitle line.
- `StoragesViewModel.appContext` still computes from
  `snapshots[.session]` for the toolbar badge — they were both
  added in the same pass but they read from different sources:
  the badge wants what's currently in memory (so it updates as
  storage refreshes); the session list wants what was persisted
  (so past sessions remember).

**Trade-offs.**
- Sessions recorded BEFORE this migration ran don't auto-backfill;
  their device columns stay `NULL` and Session list rows fall
  back to the timestamp-only layout. A one-shot backfill on app
  launch (walk sessions, fetch latest `.session` snapshot, harvest
  if non-empty) would close this gap; deferred until someone
  complains.
- Five columns is more than strictly necessary — `device_model`
  alone covers most needs — but the others (platform, os_version,
  app_version) are cheap to store and useful for future queries.

---

## D35. Hide device-write affordances when viewing a past session

**Status:** Accepted (2026-05-19)

**Decision.** When the session being viewed is not the live session
(`env.currentSessionId != vm.sessionId`), the Storages tab hides
its device-writing controls entirely:
- Top bar: "Add key", "Auto-refresh", and "Reload" are not
  rendered.
- Namespace rows: "+ add-inside" and the scalar-row trash are not
  rendered.
- Inner key/value rows: trash is not rendered.

Read-only affordances stay visible across both modes: copy
buttons, expand-value popover, layer tabs, search, right-click
copy menus, and Export/Clear (which act on local cache, not the
device).

**Why.** Those buttons would silently no-op on past sessions
because the device that recorded the session is gone — any write
would either go nowhere or land on a *different* device that
happens to be connected now. The previous behavior was
"disabled with tooltip", but disabled-tease is a worse UX than
"not shown" when the action can never apply. The user shouldn't
have to inspect tooltips to learn the action is meaningless.

**Alternatives considered.**
- *Disable with explanation tooltip*: previous behavior. Too
  subtle — users see the buttons and don't read the tooltip.
- *Hide everything including copy/export*: too aggressive;
  copying past data is exactly what past sessions are useful
  for.
- *Cross-route writes to the currently-connected device*:
  semantically wrong; the user thinks they're editing this
  session's state.

**Implications.**
- `StoragesTopBar` and `NamespaceRow` gain a private
  `isViewingLiveSession` check reading
  `env.currentSessionId == vm.sessionId`.
- `InnerKeyRow` takes an explicit `isLiveSession: Bool` param
  threaded from its parent (doesn't have direct env access).
- Empty-state message branches on the same flag:
  - live, no snapshot → "Click Reload to fetch"
  - past, no snapshot → "No data was captured during this session"
- Same rule applies to disconnect mid-session: while connected
  you can write, once disconnected the buttons hide until
  reconnect.

**Trade-offs.**
- A live session that briefly disconnects (e.g., device sleeps)
  loses its editing buttons until reconnect. Acceptable — they
  wouldn't work anyway, and reappearing is automatic.

---

## D36. Distribution: GitHub Pages landing page + stable Beaver.zip

**Status:** Accepted (2026-05-19)

**Decision.** Add `docs/index.html` as a one-page install landing
page at `https://applicaster.github.io/Beaver/` and have CI upload
two artifacts per release: the existing versioned
`Beaver-X.Y.Z.zip` AND a stable-named `Beaver.zip` (a copy of the
same content). The stable name unlocks GitHub's
`/releases/latest/download/Beaver.zip` redirect, which always
points at the newest non-prerelease build. The landing page's
Download button targets that redirect.

**Why.** First-time installs needed a single URL to share — "go to
the GitHub Releases page and pick the right asset" is too many
steps for non-developer users. Sparkle handles updates after
install; this fills the gap before install.

**Alternatives considered.**
- *DMG distribution*: prettier first-install UX (drag-to-Apps
  background), but adds `create-dmg` + an additional notarize
  step. Punted; the zip flow is fine for an internal tool.
- *Direct-link to versioned zip on the landing page, update the
  page on every release*: bad — the link rots between releases.
- *Host the zip ourselves (S3, CDN)*: adds infrastructure we
  don't need. GitHub Releases is already serving the data.

**Implications.**
- `docs/index.html` joins `docs/appcast.xml` in the
  GitHub-Pages-served folder. Single-file HTML, dark-mode aware
  via `prefers-color-scheme`, no JS.
- CI's release job now copies `build/Beaver-${VERSION}.zip` to
  `build/Beaver.zip` and uploads both via `gh release create`.
- README's "Install (end users)" section points at the landing
  page and the redirect URL instead of the per-release Assets
  section.
- One URL to share with the team:
  `https://applicaster.github.io/Beaver/`.

**Trade-offs.**
- Two copies of the same bytes per release — ~30 MB each, so
  60 MB. GitHub Releases storage is free for public repos at the
  scale we care about.
- The landing page version isn't auto-updated; it's a static
  page. If we ever want to show the current version on the page,
  that's a small JS fetch against the GitHub API. Skipped for
  now.

---

## D37. Storages UI density polish + expand-value popover

**Status:** Accepted (2026-05-19)

**Decision.** Inner-row font goes from `.caption` monospaced (12pt
/ 3pt vertical padding) to `.callout` monospaced (13pt / 6pt
vertical padding). Add zebra striping (every other inner row gets
`Color.secondary.opacity(0.04)`). Add a hover-revealed
`rectangle.expand.vertical` button on long strings (>60 chars) and
all containers; clicking opens a 540×380 popover with the full
value monospaced + scrollable, header showing key name and a copy
button. Namespace tab chips bump from `.caption.semibold` /
padding 10/5 to `.subheadline.semibold` / padding 14/7.

**Why.** D31 removed the right-side detail pane, so long values
(base64 PNGs, JWT payloads) had no escape hatch from the truncated
single-line view. And the dense inner-row list (100+ keys in a
typical `applicaster.v2`) was a wall of text at the previous font
size. Three small polish moves restored readability without
re-introducing the detail pane.

**Alternatives considered.**
- *Bring the detail pane back*: regression on D31. Vertical real
  estate matters more.
- *Wrap long values inline*: row heights become unpredictable,
  Tables panic on irregular heights in macOS Tahoe (see fixes
  around D60).
- *Auto-truncate at a smarter point (e.g., middle ellipsis)*:
  helps marginally but doesn't help "I need to read the whole
  base64 blob".

**Implications.**
- `InnerKeyRow` gains `canExpand` computed property + a new
  `StorageValuePopover` view.
- Zebra needs an index, so `ForEach(Array(children.enumerated()),
  id: \.element.id)` threads `rowIndex` into each row.
- `NamespaceTab` styling values changed; toolbar height in
  `StoragesTopBar` later got an explicit `.frame(height: 48)` so
  the row matches `LogFeedFilterBar`'s height regardless of
  which inner control is tallest.

**Trade-offs.**
- "Long string" threshold (60 chars) is heuristic; some 50-char
  values might benefit from expand too. Tunable later if the
  cutoff bothers anyone.
- Popover width is fixed at 540pt. A truly huge JWT or asset URL
  could overflow horizontally; scrolling works but the user
  might miss it. Acceptable for now.

---

## D38. Source-tree rename `LoggerNext` → `Beaver` (revises D21)

**Status:** Accepted (2026-05-20), revises D21

**Decision.** Rename the visible parts of the codebase from the
codename `LoggerNext` to the user-facing brand `Beaver`:

- `LoggerNext.xcodeproj` → `Beaver.xcodeproj`
- `LoggerNext/` → `Beaver/`
- `LoggerNextTests/` → `BeaverTests/`
- `LoggerNextUITests/` → `BeaverUITests/`
- `LoggerNextApp.swift` → `BeaverApp.swift`, `struct LoggerNextApp`
  → `struct BeaverApp`
- `LoggerNext.entitlements` → `Beaver.entitlements`
- Xcode target / scheme name `LoggerNext` → `Beaver`
- `PRODUCT_NAME = LoggerNext` → `PRODUCT_NAME = Beaver` (build
  output is now `Beaver.app` directly, no post-build rename
  needed in `release.sh`)
- SPM library/target name `LoggerNextCore` → `BeaverCore`
- Notification.Name strings `LoggerNextJumpToBookmark` /
  `LoggerNextJumpToTime` → `BeaverJumpToBookmark` /
  `BeaverJumpToTime` (and their static accessors)
- User-facing UI strings (e.g., "Unknown to LoggerNext" in the
  command-help popover) → "Unknown to Beaver"

**Kept stable, intentionally:**

- `PRODUCT_BUNDLE_IDENTIFIER = com.applicaster.LoggerNext` (and
  the test bundle IDs). Changing it would break Sparkle in-place
  upgrades for every existing install — Sparkle uses bundle ID
  + version to decide whether a download is an upgrade.
- `~/Library/Application Support/LoggerNext/store.sqlite` — the
  on-disk persistence anchor. Changing it would orphan every
  existing user's sessions, bookmarks, storage snapshots, and
  saved filters. A migration could move the data, but the cost /
  risk ratio is wrong for an internal tool.
- `DispatchQueue` label `com.applicaster.LoggerNext.WSServer` —
  mirrors the bundle ID for consistency in Console.app and
  Activity Monitor.

Each of these has an in-code comment explaining the
"intentionally LoggerNext, see D38" reasoning so future
maintainers don't reflexively rename them.

**Why now (revising D21).**

D21's original "don't rename" was correct at the time — early
in development, the bundle ID and on-disk path concerns
dominated, and the codebase didn't have enough surface area
yet to make the codename leakage really painful. Six months
later, the codebase is many tens of files. Every new
contributor / future-me reading the source has to mentally
substitute "this thing called LoggerNext is the same product as
Beaver". The cost of that ongoing cognitive overhead exceeds
the one-time cost of the rename.

D21's actual blockers (bundle ID + on-disk path) are still
respected — they stay as `LoggerNext`. Only the visible source
tree is rebranded. So D38 doesn't contradict D21; it scopes
D21 down to the two identifiers that really must not change.

**Alternatives considered.**

- *Full rename including bundle ID + Application Support path*:
  requires a one-shot data migration on first launch of the
  renamed app + new Developer ID provisioning + verification
  that Sparkle in-place updates work when the upgrading bundle
  has a different ID than the installed one. Doable, ~1–2 days
  of work plus careful testing, but adds risk that an existing
  user might lose their session history if migration has a bug.
  Punted unless there's a concrete reason (App Store submission,
  team transfer, …).
- *Do nothing*: keeps the cost-of-confusion that drove this
  decision.

**Implications.**

- Anyone with a local checkout needs to close Xcode, pull, and
  reopen `Beaver.xcodeproj`. Xcode's user-state files
  (`xcuserdata`) under the old `.xcodeproj` are abandoned, which
  loses breakpoint and bookmark positions — acceptable.
- CI's `Beaver.xcodeproj` reference is already updated; first
  CI run after the rename rebuilds the SPM cache once.
- `release.sh`'s post-build `LoggerNext.app` → `Beaver.app`
  rename step is gone — the build directly produces
  `Beaver.app` now.
- README's "internal name" disclaimer was updated to point at
  D21 + D38 together and to clarify which identifiers are
  intentionally still `LoggerNext`.

**Trade-offs.**

- Discoverable inconsistency: a new contributor opens the app's
  Application Support folder and finds `LoggerNext/`, not
  `Beaver/`. The in-code comment + this DECISIONS entry are
  the doc trail; nothing prevents momentary confusion.
- Bundle ID looks like a brand name in `defaults`, Keychain,
  and `codesign -d`. Invisible to end users; only matters to
  devs who actively look.
