# Session File Format — v1

The file Beaver (macOS) and zapp-support (web) write on **Export** and read on
**Import**. Customers send logs from either tool and we open them in either, so
the two tools MUST stay mutually compatible: anything one writes, the other
opens, with the same result.

- **This file is the only copy.** It lives in `applicaster/Beaver`;
  zapp-support links here (its `AGENTS.md`, README). Do not copy it.
- **Keywords.** MUST / MUST NOT / SHOULD / MAY as in RFC 2119.
- **Implementations.**
  - Beaver: `Beaver/Support/EventJSON.swift` (read + write),
    `Beaver/Support/SessionExport.swift` (what goes in a file),
    `Beaver/Support/HARExport.swift` (HAR). Tests:
    `BeaverTests/EventJSONExportTests.swift`, `BeaverTests/ZappSupportImportTests.swift`.
  - zapp-support: `src/utils/sessionFile.ts` (read + write),
    `src/services/sessionExport.ts` (what goes in a file). Test:
    `src/utils/sessionFile.test.mts` (`pnpm test`).

---

## 1. Changing this format

1. **v1 changes are additive only**: a new *optional* key. Readers already
   ignore unknown keys (§3.4, §5, §6), so old versions of both tools keep
   opening new files.
2. **Readers before writers.** Teach both readers first; only then may a
   writer start producing the new thing.
3. **One change = a pair of PRs**, one per repo, cross-linked, each updating
   its implementation and tests; the Beaver one also updates this file.
   Neither merges without the other.
4. A **breaking** change (removing or re-typing a key, new required key) is a
   new version: add `"formatVersion": 2` at the top level and a new section
   here. v1 files MUST keep opening forever (§8).

---

## 2. Encoding

UTF-8 JSON, `.json` extension. Whitespace and key order carry no meaning.

## 3. Top-level shape

A file is exactly one of:

| Shape | When a writer uses it |
|---|---|
| **A. Bare array** `[Event, …]` | The session has no storage and no network entries. |
| **B. Session object** `{"events": [Event, …], "storage"?: Storage, "network"?: [NetworkEntry, …]}` | Otherwise. |

3.1 In shape B, `events` MUST be present (it MAY be empty). `storage` and
`network` MUST be omitted when empty, never written as `{}` / `[]`.

3.2 **One file = one session = one device.** A writer MUST NOT mix events,
storage or requests from different devices. A file loaded from disk counts as
its own session.

3.3 **Export scope.** Every Export offers *filtered* and *all* (when no filter
is active they are the same, and a writer MAY skip the choice). The scope
narrows **events only**; `storage` (the session's latest snapshot) and
`network` (all of the session's requests) are always written whole. Every
Export button in a tool — log screen, storage screen — writes this same file.

3.4 Readers MUST ignore unknown top-level keys.

## 4. Event

| Key | Type | Writer |
|---|---|---|
| `subsystem` | string | MUST |
| `timestamp` | integer, ms since epoch | MUST |
| `level` | string, see §4.1 | MUST, one of the five |
| `message` | string | MUST |
| `category` | string | MUST (`""` when none) |
| `data` | any JSON object/array | only when present |
| `context` | JSON object | only when present |

Readers MUST NOT drop an event for a missing field. Placeholders:

| Missing | Read as |
|---|---|
| `subsystem` | `"Unknown"` |
| `message` | the whole event, as JSON text |
| `timestamp` | the import time |
| `category` | `""` |

A `timestamp` that is present but not a non-negative number of milliseconds
that fits in Int64 MAY be rejected (Beaver drops the event; it is attacker
input on the live socket too). Readers MUST keep `data` and `context` as
given — the event reads the same as when it arrived live.

zapp-support displays an empty `subsystem` / `category` as "Unknown", the same
as for live events; that is presentation, not a different value.

4.1 **Levels.** Writers MUST write one of `verbose`, `debug`, `info`,
`warning`, `error` (older Beaver versions drop anything else). A level outside
that set MUST be written as `info` with the original value kept in
`context.originalLevel` (creating `context` if needed).

Readers MUST map, case-insensitively, and MUST NOT drop an event because of
its level:

| Read as | Strings | Numbers |
|---|---|---|
| `verbose` | `verbose`, `trace`, `""`, `"0"` | `0` |
| `debug` | `debug`, `"1"` | `1` |
| `info` | `info`, `"2"` | `2` |
| `warning` | `warning`, `warn`, `"3"` | `3` |
| `error` | `error`, `err`, `fatal`, `"4"` | `4` |

Anything else (including booleans) → `info`, raw value kept in
`context.originalLevel`. A missing level → `info`.

4.2 Writers MUST NOT write viewer-side fields (`id`, `emitterId`, …).
Readers MUST ignore unknown event keys.

4.3 In shape B, readers MUST also accept an event given as a JSON string
holding an Event object (older writers double-encoded); unparseable entries
are skipped.

## 5. Storage

```json
{ "session": { … }, "local": { … }, "secure": { … } }
```

Keys: only `session`, `local`, `secure` (Beaver shows `secure` as
"Keychain"). Each value is the device's snapshot of that layer **exactly as it
arrived** in the `storage` frame (PROTOCOL.md §4.2): top-level keys are the
SDK's namespaces, `{"<namespace>": {"<key>": value}}`; a key with no namespace
arrives either as a plain `"<key>": value` or as `"<key>": {"undefined": value}`.

- Writers MUST write the snapshot verbatim: no regrouping (e.g. no `"root"`
  group), no unwrapping of JSON-string values, no renaming.
- Writers MUST omit a layer the session has no snapshot for.
- Readers MUST ignore other keys.

## 6. NetworkEntry

Each entry is the device's `network` frame payload (PROTOCOL.md §4.3):
`requestId`, `url`, `method`, `status`, `statusText`, `requestHeaders`,
`responseHeaders`, `requestBody`, `responseBody`, `requestBodySize`,
`responseBodySize`, `timing{startTime,endTime,duration}`, `timestamp`, `error`.

- Writers MUST write it as received and MUST NOT add viewer-side fields
  (`id`, `emitterId`, …).
- Readers MUST skip an entry without a string `url`, MUST ignore unknown keys,
  and MUST also accept an entry given as a JSON string.

## 7. HAR

HAR 1.2 is a separate Export of the Network screen in both tools, not a
session file. Both tools read it: Beaver into Network, zapp-support as one log
row per request.

## 8. Inputs readers MUST keep opening

Detect in this order:

1. `{"log": {"entries": […]}}` → HAR (§7).
2. An array → shape A. This also covers zapp-support's pre-v1 log export
   (`RawLogEntry[]`: extra `id` / `emitterId`, any level spelling — §4.1 and
   §4.2 already handle it).
3. An object with an `events` array → shape B. (zapp-support: unless it also
   has a `message` key — that was always a single log entry.)
4. An object whose only keys are `session` / `local` / `secure` →
   zapp-support's pre-v1 storage export: `{type: {namespace: {key: value}}}`,
   keys with no namespace grouped under `"root"`. Read it as storage, putting
   each `"root"` key back as `"<key>": {"undefined": value}`.
5. Anything else: not a session file. (zapp-support has always imported a
   lone object as one log row.)

## 9. Examples

Shape A:

```json
[
  {"subsystem": "player", "timestamp": 1700000000000, "level": "warning",
   "message": "buffering", "category": "playback", "context": {"build": "1.0"}}
]
```

Shape B:

```json
{
  "events": [
    {"subsystem": "auth", "timestamp": 1700000000000, "level": "info",
     "message": "odd level", "category": "", "context": {"originalLevel": "off"}}
  ],
  "storage": {
    "session": {"applicaster.v2": {"app_name": "Demo"}},
    "local": {"player-storage": {"undefined": "{\"volume\":0.8}"}}
  },
  "network": [
    {"requestId": "R1", "url": "https://api.example.com/v1/feed", "method": "GET",
     "status": 200, "timing": {"startTime": 1700000000000, "duration": 250},
     "timestamp": 1700000000000}
  ]
}
```
