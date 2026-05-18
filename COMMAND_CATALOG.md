# COMMAND_CATALOG.md — SDK Command Catalog Protocol

**Status:** Forward-looking spec. The current SDK responds to `cmdlist`
with names only (see `PROTOCOL.md §3.2.1`); Beaver maintains a
hard-coded mapping in `CommandRegistry.swift` as a temporary scaffold
(`DECISIONS.md` D17). This doc defines the new contract the SDK should
implement so Beaver can delete that mapping and read everything
straight from the wire.

This is the single source of truth for what Beaver expects. Any
deviation in the SDK implementation will require a corresponding change
on the desktop side; both should be PR-able together once the SDK
implements this.

---

## 1. Command name

The new command is **`cmdspec`** (replaces `cmdlist`).

- Short, mnemonic, follows the existing prefix-dot convention.
- Doesn't collide with any current registered name.

The legacy `cmdlist` should keep working — both names should be
registered side by side until Beaver drops the old code path. See
§7 (Backwards compatibility) for migration details.

**Suggested alternative names** if `cmdspec` doesn't fit the SDK's
naming conventions: `cmdcatalog`, `help.commands`, `cmd.help`,
`debug.commands.list`. The exact name doesn't matter — what matters is
that Beaver knows which command to send and which response to
parse.

---

## 2. Wire transport

The response travels over the existing WebSocket as a **regular log
event** (the `event` message type defined in `PROTOCOL.md §4.1`). No
new top-level message type is required.

The catalog lives in the event's `data` field, which is a free-form
JSON object. The `message` field carries a short human-readable
summary. This way the event remains useful when viewed in the log
feed (the user sees "Command catalog: 21 commands across 4 groups"
without having to expand the data pane).

**Why not a new top-level message type?** Cleaner long-term, but
adding a new `type` to the protocol requires every consumer to be
updated. Putting it in an event's `data` field rides the existing
infrastructure with zero protocol churn — Beaver only needs to
recognize a specific subsystem to demux.

---

## 3. Identifying the response

Beaver detects a catalog response by **exact match** on the event
metadata:

| Field        | Value                                                      |
|--------------|------------------------------------------------------------|
| `level`      | `"info"`                                                   |
| `subsystem`  | `"DebugFeatures/ConsoleCommands/Catalog"` *(or any stable, unique string the SDK picks)* |
| `category`   | `"cmdspec"` *(optional but recommended — disambiguates from other catalog-style events if the subsystem is ever reused)* |
| `data`       | A JSON object matching §4 below                            |

The chosen subsystem **must be stable across SDK versions** — that's
how Beaver keys the parser. If the SDK team wants to introduce a
different subsystem in v2, that becomes a coordinated change with
Beaver.

---

## 4. JSON shape

The `data` field carries this object:

```jsonc
{
  // Catalog format version. Increment on backwards-incompatible
  // changes. Beaver checks this before parsing; on a version it
  // doesn't recognize, it falls back to displaying just command
  // names from the `commands[].name` field (forward-compat path).
  "version": 1,

  // Metadata about the source — optional, but useful for the
  // device-info pill if we ever add one. Helps cross-platform
  // debugging: "this catalog came from iOS 26.4.2 SDK 1.5.2".
  "platform":          "iOS",         // "iOS" | "tvOS" | "Android" | "Web" | …
  "platform_version":  "26.4.2",      // os version
  "sdk_version":       "1.5.2",       // SDK semver
  "app_version":       "187",         // host app build, if known

  // The actual command catalog. Order is preserved if the SDK wants
  // a specific display order; Beaver otherwise groups by
  // `group` field.
  "commands": [
    {
      // REQUIRED. The command string the user types to invoke it.
      // Same value the SDK currently emits via `cmdlist`. Used as the
      // primary key — must be unique within `commands`.
      "name": "storage.local.set",

      // REQUIRED. Display string shown in the help popover row.
      // Should use angle-brackets for required args and square
      // brackets for optional, matching common CLI conventions:
      //   "<arg>"   required
      //   "[arg]"   optional
      //   "<arg…>"  required, variadic
      "syntax": "storage.local.set <key> <value> [namespace]",

      // REQUIRED. One-line description; shown beneath the syntax
      // in the popover row. Plain text, no markdown.
      "description": "Write a value to local storage",

      // RECOMMENDED. Logical grouping. Beaver renders one
      // section per distinct group, in catalog order. Examples
      // already in use:
      //   "Storage", "Debug", "Layout", "General"
      // SDKs are free to add new groups — Beaver just renders
      // whatever it gets. Commands without a `group` land in a
      // default "Other" section at the bottom.
      "group": "Storage",

      // OPTIONAL. Structured argument list. Beaver doesn't use
      // this yet, but having it landed means we can later add:
      //   - In-line argument validation as the user types
      //   - Auto-fill placeholders ("press Tab to fill <key>")
      //   - Type-aware widgets (color pickers for "color", file
      //     pickers for "path", etc.)
      // Until Beaver consumes this field, `syntax` is the
      // source of truth for display.
      "arguments": [
        { "name": "key",       "type": "string",  "required": true,
          "description": "Storage key to write" },
        { "name": "value",     "type": "string",  "required": true,
          "description": "Value to store (any UTF-8 string)" },
        { "name": "namespace", "type": "string",  "required": false,
          "description": "Optional namespace prefix; defaults to global" }
      ],

      // OPTIONAL. One or more example invocations. Currently
      // unused by Beaver but landed for the future "click to
      // run an example" feature.
      "examples": [
        "storage.local.set userId abc-123",
        "storage.local.set selectedTheme dark feature.theme"
      ],

      // OPTIONAL. Alternative names that resolve to the same
      // command. Useful if the SDK renames a command but wants to
      // keep the old name working. Beaver displays the primary
      // `name` and treats aliases as searchable synonyms.
      "aliases": ["storage.local.put"],

      // OPTIONAL. If the SDK has deprecated this command, set
      // this to a short reason. Beaver shows it with a
      // strikethrough + warning icon and surfaces `replaced_by`
      // if present.
      "deprecated":   false,
      "deprecation_reason": null,   // string or null
      "replaced_by":  null,         // command name or null

      // OPTIONAL. True if invoking this command produces a log
      // event in response (e.g., `cmdlist` itself, or
      // `debug.flag.list`). Beaver can use this to indicate
      // "this command will respond" in the UI.
      "produces_response": true,

      // OPTIONAL. True for destructive commands. Beaver can
      // show a confirmation dialog before sending.
      "destructive": false
    },

    // … more commands …
  ]
}
```

### 4.1 Argument types

`arguments[].type` should be one of:

| Type         | Notes                                                          |
|--------------|----------------------------------------------------------------|
| `"string"`   | Default; any UTF-8 text.                                       |
| `"int"`      | Integer. UI can validate.                                      |
| `"bool"`     | `true`/`false`. UI can offer a toggle.                         |
| `"url"`      | A URL string. UI can validate format.                          |
| `"path"`     | File path. UI may offer a picker.                              |
| `"enum"`     | Closed set; pair with `arguments[].choices: [string]`.         |
| `"json"`     | A JSON literal. UI can offer a syntax-highlighted editor.      |

Unknown types should be treated as `"string"` by Beaver.

### 4.2 Minimum viable response

The SDK is encouraged to populate all fields, but the **minimum
acceptable response** for Beaver to render usefully is:

```json
{
  "version": 1,
  "commands": [
    { "name": "storage.local.set",
      "syntax": "storage.local.set <key> <value> [namespace]",
      "description": "Write a value to local storage" }
  ]
}
```

Everything else (`platform`, `arguments`, `examples`, etc.) is
optional and can land in a follow-up.

---

## 5. Example response (full event payload)

What Beaver receives over the WebSocket:

```jsonc
{
  "type": "event",
  "id": "550E8400-E29B-41D4-A716-446655440000",
  "event": "{                                  // ← double-encoded, per PROTOCOL.md §4.1
    \"subsystem\":  \"DebugFeatures/ConsoleCommands/Catalog\",
    \"category\":   \"cmdspec\",
    \"timestamp\":  1715784000000,
    \"level\":      \"info\",
    \"message\":    \"Command catalog: 21 commands across 4 groups\",
    \"data\": {
      \"version\":          1,
      \"platform\":         \"iOS\",
      \"platform_version\": \"26.4.2\",
      \"sdk_version\":      \"1.5.2\",
      \"app_version\":      \"187\",
      \"commands\": [
        {
          \"name\":        \"cmdlist\",
          \"syntax\":      \"cmdlist\",
          \"description\": \"Print the list of all registered commands (legacy)\",
          \"group\":       \"General\",
          \"deprecated\":  true,
          \"replaced_by\": \"cmdspec\"
        },
        {
          \"name\":        \"cmdspec\",
          \"syntax\":      \"cmdspec\",
          \"description\": \"Return the full command catalog as structured JSON\",
          \"group\":       \"General\"
        },
        {
          \"name\":        \"storage.local.set\",
          \"syntax\":      \"storage.local.set <key> <value> [namespace]\",
          \"description\": \"Write a value to local storage\",
          \"group\":       \"Storage\",
          \"arguments\": [
            { \"name\": \"key\",       \"type\": \"string\", \"required\": true },
            { \"name\": \"value\",     \"type\": \"string\", \"required\": true },
            { \"name\": \"namespace\", \"type\": \"string\", \"required\": false }
          ],
          \"examples\": [ \"storage.local.set userId abc-123\" ]
        }
        // … rest of catalog …
      ]
    }
  }"
}
```

(The `event` field is a JSON-encoded string per the existing protocol
convention. The example is unescaped for readability — wire format is
the double-encoded form.)

---

## 6. Beaver parser contract

When Beaver receives an event matching the §3 identifier, it:

1. Parses `data` into a `CommandCatalog` value type.
2. Validates `version`. On `version != 1` (or absent), falls back to
   reading just `commands[].name` and continues.
3. Builds `[CommandHint]` directly from `commands[]`, skipping
   `CommandRegistry` entirely.
4. Stores the result on `AppEnvironment.availableCommands`.
5. Caches platform/SDK metadata on `AppEnvironment` for potential UI
   (e.g., "Connected · iPhone 15 Pro Max · TCS Go! · SDK 1.5.2").

When `cmdspec` arrives, **`CommandRegistry.swift` is no longer
consulted for matched commands.** It can be deleted entirely once
all platforms support `cmdspec`. Until then it remains as a
fallback for SDKs that only implement legacy `cmdlist`.

---

## 7. Backwards compatibility

| SDK state                                | Beaver behavior                                            |
|------------------------------------------|----------------------------------------------------------------|
| Implements `cmdspec` only                | Uses catalog directly; ignores registry.                       |
| Implements both `cmdspec` and `cmdlist`  | Prefers `cmdspec` response when it arrives; ignores `cmdlist`. |
| Implements `cmdlist` only (today)        | Falls back to registry-merged names (current behavior).        |
| Implements neither                       | Help popover shows "No commands available" state.              |

**On the desktop side**, Beaver sends both commands on connect:

```
500 ms after .clientConnected:
  WSServer.send("cmdspec")     # new path
  WSServer.send("cmdlist")     # legacy fallback
```

Whichever response arrives first populates the catalog. If
`cmdspec` arrives later, it replaces the registry-merged version
(because catalog data is strictly richer).

When all known SDKs ship `cmdspec`, the `cmdlist` line is removed
on the desktop side.

---

## 8. Error handling

If the SDK can't build the catalog (e.g., during early startup), it
should still respond — with an empty `commands: []` and an
informative `message`:

```json
{
  "version": 1,
  "message": "Command catalog not ready; retry in 1 second",
  "commands": []
}
```

Beaver should re-send `cmdspec` after a short delay if the
catalog is empty but a session is active. (Future work; today the
manual ⟳ button in the popover is the user's escape hatch.)

---

## 9. Versioning rules

- Any breaking change to the JSON shape bumps `version`.
- Beaver checks `version <= MAX_SUPPORTED_VERSION` before
  parsing. On a higher version, falls back to legacy `name`-only
  rendering and logs a warning.
- New optional fields don't require a version bump — Beaver
  ignores unknown keys.

---

## 10. Open questions for the SDK team

1. **Final command name.** `cmdspec` is the proposal; SDK team's
   call.
2. **Subsystem string.** `DebugFeatures/ConsoleCommands/Catalog`
   is the proposal. Anything stable that uniquely identifies the
   catalog event works.
3. **`platform` enum values.** Match the values used in event
   `context.platform` so cross-platform tooling stays consistent
   (`"iOS"`, `"tvOS"`, `"Android"`, `"Web"`, …).
4. **Coordination with Android/tvOS/Web teams.** Should all three
   ship the same `cmdspec` contract, or is each platform free to
   diverge? Same protocol = simpler Beaver, less SDK
   flexibility.
5. **Per-environment catalog filtering.** Should `cmdspec` filter
   out commands that aren't available in production builds? Or
   always return the full catalog and rely on the runtime check
   when the command is invoked?

Track these here as they're resolved.
