# LoggerNext — Design Decisions

Running log of architecture and feature decisions made during planning.
Each entry: decision, reasoning, alternatives considered, status.

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

## D13. Distribution: scripted .pkg (modernized toolchain)

**Status:** Accepted (2026-05-15)

**Decision.** Keep the `.pkg` installer format. Replace the 12-step manual
README with a single `make release` (or `scripts/release.sh`) that runs
`productbuild`, `notarytool`, and `stapler` end-to-end. Credentials read
from environment variables. Runnable from CI.

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
- `scripts/release.sh` checked into the repo.
- Apple ID + app-specific password + team ID + distribution cert title
  loaded from env vars (`.envrc.example` documents the names).
- CI pipeline can produce a signed, notarized, stapled `.pkg` on each
  tagged release.

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
