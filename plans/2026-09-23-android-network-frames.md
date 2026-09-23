# X-Ray Android: `network` frames Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Android X-Ray `WebSocketSink` sends every captured HTTP request as a `{"type":"network"}` frame, the same way iOS does since Zapp-Frameworks #2676. Beaver's and zapp-support's Network tabs then show Android traffic too.

**Architecture:** A pure Kotlin mapper (`NetworkEntryMapper`) turns an X-Ray `Event` from the SDK's `NetworkRequestListener` into the NetworkEntry map. `WebSocketSink.log` sends that map as a `network` message and still sends the normal `event`, as iOS does. There are no Android framework dependencies in the mapper, so a plain JUnit4 test covers it.

**Tech Stack:** Kotlin, OkHttp WebSocket, Gson (`GsonHolder.gson`), JUnit 4.13.2.

**Repo / worktree:** `/Users/antonkononenko/work/applicaster/Slot1/Zapp-Frameworks/.claude/worktrees/xray-android-network`, branch `feat/xray-android-network-frames` (from `origin/master` 64c83894d). Plugin dir: `plugins/quick-brick-xray/android`.

## Research (source of truth for the mapping)

- **Producer:** `com.applicaster.debugging.network.NetworkRequestListener` in the closed AAR `applicaster-android-sdk-core` (8.20.12, read with `javap`). It logs through `APLogger` with the listener's TAG as category. Callers detect it with `event.category.endsWith("NetworkRequestLogger")` (`EventActionCurl.kt:12`, `EventActionAddDomainRule.kt:18`).
  - Logged with `debug` when the request succeeded or redirected, otherwise with `error(tag, message, exception, data)`.
  - `message` looks like `"<METHOD> <url> <resultCode|Cancelled|<no_result>> ... <time>"`.
- **`event.data` keys, exactly as `getData()` builds them:**

  | key | type | notes |
  |---|---|---|
  | `time` | Long | **elapsed ms**: `currentTimeMillis() - start` (bytecode `lsub`) |
  | `method` | String | |
  | `url` | String | `HttpUrl.toString()` |
  | `requestHeaders` | `Map<String, List<String>>` | `Headers.toMultimap()`, only when non-null |
  | `requestBody` | String | may be `"<not logged>"` (body logging off) or `"<binary>"` |
  | `resultCode` | Int | absent when the request threw |
  | `resultHeaders` | `Map<String, List<String>>` | absent when the request threw |
  | `resultBody` | String | same placeholders as requestBody |

  There is no error key. The exception is `event.exception` (a Throwable; for a cancelled call its message is "Canceled").
- **Event** (`xray-core`): `data class Event(category, subsystem, timestamp: Long /* UTC ms */, level, message, data: Map<String, Any?>?, context, exception: Throwable?)`. It is logged **after** the response, so `timestamp` is the end time.
- **Sink:** `WebSocketSink.kt`.
  - `MessageType` has no `network` value.
  - `LogEvent(id, event: String, type = MessageType.event)` already takes a `type`.
  - `log()` sends `gson.toJson(event)` inside try/catch.
  - The sink is registered without a level filter (`XRayPlugin.kt:381`), so debug-level network events reach it.
- **Target contract** (as consumed by Beaver `NetworkEntry.parse` and zapp-support `NetworkEntry`):
  - envelope: `{"type":"network","id":"<uuid>","event":"<JSON string>"}`
  - inner fields: `requestId`, `url` (required), `method` (uppercase), `status` (number), `requestHeaders`/`responseHeaders` `{string:string}`, `requestBody`/`responseBody` strings, `timing{startTime,endTime,duration}` in ms, `timestamp` in ms, `error`.
- **iOS parity:**
  - bodies capped at 100 000 chars, then `"... [TRUNCATED]"` is appended;
  - request headers `authorization`, `cookie` and `x-api-key` (case-insensitive) are replaced with `"[REDACTED]"`;
  - each request is sent both as `network` and as a normal `event`.

## Global Constraints

- Change only `plugins/quick-brick-xray/android/**`. Add no dependencies (`build.gradle` untouched).
- The mapper is pure Kotlin with no `android.*`, Gson or OkHttp imports. Only `com.applicaster.xray.core.Event` and the stdlib.
- Multi-valued headers are joined with `", "`, in list order.
- Times are epoch **milliseconds**: `endTime = event.timestamp`, `duration = data["time"]`, `startTime = endTime - duration`, and `timestamp = startTime`. If `time` is missing, `duration = 0` and `startTime = endTime`.
- `status` is emitted only when `resultCode` is a Number. `error` is emitted only when `event.exception != null`, as `exception.message ?: exception.javaClass.simpleName`.
- Commit style: Conventional Commits, `feat(quick-brick-xray): …`. Do not bump `package.json`; CI publishes.
- Never log back to X-Ray from inside the sink. Use `android.util.Log` only, as the existing sink does.

## Review Focus

1. **Failed or cancelled request** (no `resultCode`, exception set): the frame must still be sent, with `error` and without `status`. Test: `mapsFailedRequestWithoutStatus`.
2. **`Authorization` header in any case** (`authorization`, `AUTHORIZATION`) must be redacted. Test: `redactsSensitiveRequestHeadersCaseInsensitive`.
3. **Huge body** (for example a 5 MB JSON with body logging on) must be truncated, so the WebSocket frame stays small. Test: `truncatesLongBodies`.
4. **A non-network event** must map to `null` and produce no `network` frame. Test: `ignoresNonNetworkEvents`.
5. **A mapping exception** must never stop the normal `event` being sent. In the sink, the network send gets its own try/catch that runs before the existing one (Task A2).

---

### Task A1: `NetworkEntryMapper` and JUnit test

**Files:**
- Create: `plugins/quick-brick-xray/android/src/main/java/com/applicaster/plugin/xray/sinks/NetworkEntryMapper.kt`
- Create: `plugins/quick-brick-xray/android/src/test/java/com/applicaster/plugin/xray/sinks/NetworkEntryMapperTest.kt`

**Interfaces:**
- Produces: `internal object NetworkEntryMapper { fun isNetworkRequest(event: Event): Boolean; fun map(event: Event, requestId: String): Map<String, Any>? }`. Returns null when the event is not a network request or has no String `url`.

- [ ] **Step 1: Write the failing test**

```kotlin
package com.applicaster.plugin.xray.sinks

import com.applicaster.xray.core.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkEntryMapperTest {

    private fun event(
        data: Map<String, Any?>?,
        category: String = "com.applicaster.NetworkRequestLogger",
        timestamp: Long = 10_000L,
        exception: Throwable? = null,
    ) = Event(category, "native/network", timestamp, 1, "GET https://api.io/x 200", data, null, exception)

    private val ok = mapOf(
        "time" to 250L,
        "method" to "get",
        "url" to "https://api.io/v1/feed?page=2",
        "requestHeaders" to mapOf("Accept" to listOf("application/json", "text/plain"), "Authorization" to listOf("Bearer x")),
        "requestBody" to "<not logged>",
        "resultCode" to 200,
        "resultHeaders" to mapOf("Content-Type" to listOf("application/json")),
        "resultBody" to "{\"items\":[1,2]}",
    )

    @Suppress("UNCHECKED_CAST")
    @Test
    fun mapsSuccessfulRequest() {
        val e = NetworkEntryMapper.map(event(ok), "R1")!!
        assertEquals("R1", e["requestId"])
        assertEquals("https://api.io/v1/feed?page=2", e["url"])
        assertEquals("GET", e["method"])
        assertEquals(200, e["status"])
        assertEquals(9_750L, e["timestamp"])
        assertEquals(mapOf("startTime" to 9_750L, "endTime" to 10_000L, "duration" to 250L), e["timing"])
        val req = e["requestHeaders"] as Map<String, String>
        assertEquals("application/json, text/plain", req["Accept"])
        assertEquals("[REDACTED]", req["Authorization"])
        assertEquals(mapOf("Content-Type" to "application/json"), e["responseHeaders"])
        assertEquals("<not logged>", e["requestBody"])
        assertEquals("{\"items\":[1,2]}", e["responseBody"])
        assertFalse(e.containsKey("error"))
    }

    @Test
    fun mapsFailedRequestWithoutStatus() {
        val data = mapOf("time" to 60_000L, "method" to "POST", "url" to "https://api.io/login")
        val e = NetworkEntryMapper.map(event(data, exception = java.io.IOException("timeout")), "R2")!!
        assertFalse(e.containsKey("status"))
        assertEquals("timeout", e["error"])
        val messageless = NetworkEntryMapper.map(event(data, exception = java.io.IOException()), "R3")!!
        assertEquals("IOException", messageless["error"])
    }

    @Suppress("UNCHECKED_CAST")
    @Test
    fun redactsSensitiveRequestHeadersCaseInsensitive() {
        val data = ok + ("requestHeaders" to mapOf(
            "authorization" to listOf("a"), "COOKIE" to listOf("c"), "X-Api-Key" to listOf("k"), "X-Other" to listOf("o")))
        val req = NetworkEntryMapper.map(event(data), "R")!!["requestHeaders"] as Map<String, String>
        assertEquals(mapOf("authorization" to "[REDACTED]", "COOKIE" to "[REDACTED]",
            "X-Api-Key" to "[REDACTED]", "X-Other" to "o"), req)
    }

    @Test
    fun truncatesLongBodies() {
        val long = "x".repeat(100_001)
        val e = NetworkEntryMapper.map(event(ok + ("resultBody" to long)), "R")!!
        assertEquals("x".repeat(100_000) + "... [TRUNCATED]", e["responseBody"])
        val exact = "y".repeat(100_000)
        assertEquals(exact, NetworkEntryMapper.map(event(ok + ("resultBody" to exact)), "R")!!["responseBody"])
    }

    @Test
    fun missingTimeMeansZeroDuration() {
        val e = NetworkEntryMapper.map(event(ok - "time"), "R")!!
        assertEquals(mapOf("startTime" to 10_000L, "endTime" to 10_000L, "duration" to 0L), e["timing"])
    }

    @Test
    fun ignoresNonNetworkEvents() {
        assertFalse(NetworkEntryMapper.isNetworkRequest(event(ok, category = "Player")))
        assertNull(NetworkEntryMapper.map(event(ok, category = "Player"), "R"))
        assertNull(NetworkEntryMapper.map(event(ok - "url"), "R"))
        assertNull(NetworkEntryMapper.map(event(null), "R"))
        assertTrue(NetworkEntryMapper.isNetworkRequest(event(ok)))
    }

    @Test
    fun omitsAbsentOptionalFields() {
        val e = NetworkEntryMapper.map(event(mapOf("url" to "https://a.io")), "R")!!
        assertEquals(setOf("requestId", "url", "method", "timing", "timestamp"), e.keys)
        assertEquals("GET", e["method"])
    }
}
```

- [ ] **Step 2: Build a local JVM harness and check the test fails.** The plugin can't be built on its own (it has no gradlew and needs a host app for `project(':xray-core')`). Build a throwaway harness in the scratchpad `<SCRATCH>/android-harness` (the controller passes the path):
  - `settings.gradle.kts`: `rootProject.name = "harness"`
  - `build.gradle.kts`:

    ```kotlin
    plugins { kotlin("jvm") version "2.0.21" }
    repositories { mavenCentral() }
    dependencies { testImplementation("junit:junit:4.13.2") }
    kotlin { jvmToolchain(21) }
    sourceSets {
        main { kotlin.srcDirs("src/main/kotlin", "<WORKTREE>/plugins/quick-brick-xray/android/src/main/java/com/applicaster/plugin/xray/sinks/mapper-only") }
    }
    ```

    Simpler: symlink or copy only the mapper file and the xray-core `Event.kt` into `src/main/kotlin/`, and the test into `src/test/kotlin/`, before each run. Copy `Event.kt` from `<ZAPP_ROOT>/node_modules/@applicaster/x-ray/android/xray-core/src/main/java/com/applicaster/xray/core/Event.kt`.
  - Run with the cached Gradle and Android Studio's JDK:
    `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ~/.gradle/wrapper/dists/gradle-8.14.3-bin/*/gradle-8.14.3/bin/gradle -p <SCRATCH>/android-harness test`
  - If the JBR is not Java 21, set `jvmToolchain` to its major version (`"$JAVA_HOME/bin/java" -version`).
  - Expected at this step: compile failure, `Unresolved reference: NetworkEntryMapper`.

- [ ] **Step 3: Write the implementation**

```kotlin
package com.applicaster.plugin.xray.sinks

import com.applicaster.xray.core.Event

/**
 * Maps a request logged by the SDK's NetworkRequestListener (category ending in
 * "NetworkRequestLogger") into the NetworkEntry shape that the Beaver and zapp-support
 * Network tabs read from a `network` frame. Mirrors iOS WebSocketSink+NetworkEvent.swift.
 *
 * Listener data keys: time (elapsed ms), method, url, requestHeaders/resultHeaders
 * (Map<String, List<String>>), requestBody/resultBody, resultCode. The event is logged
 * after the response, so event.timestamp is the end time.
 */
internal object NetworkEntryMapper {
    private const val MAX_BODY = 100_000
    private const val TRUNCATED = "... [TRUNCATED]"
    private const val REDACTED = "[REDACTED]"
    private val redactedHeaders = setOf("authorization", "cookie", "x-api-key")

    fun isNetworkRequest(event: Event) = event.category.endsWith("NetworkRequestLogger")

    fun map(event: Event, requestId: String): Map<String, Any>? {
        if (!isNetworkRequest(event)) return null
        val data = event.data ?: return null
        val url = data["url"] as? String ?: return null

        val duration = (data["time"] as? Number)?.toLong() ?: 0L
        val end = event.timestamp
        val start = end - duration

        val entry = linkedMapOf<String, Any>(
            "requestId" to requestId,
            "url" to url,
            "method" to ((data["method"] as? String) ?: "GET").uppercase(),
            "timing" to mapOf("startTime" to start, "endTime" to end, "duration" to duration),
            "timestamp" to start,
        )
        (data["resultCode"] as? Number)?.let { entry["status"] = it.toInt() }
        headers(data["requestHeaders"])?.let { entry["requestHeaders"] = redact(it) }
        headers(data["resultHeaders"])?.let { entry["responseHeaders"] = it }
        (data["requestBody"] as? String)?.let { entry["requestBody"] = cap(it) }
        (data["resultBody"] as? String)?.let { entry["responseBody"] = cap(it) }
        event.exception?.let { entry["error"] = it.message ?: it.javaClass.simpleName }
        return entry
    }

    private fun headers(value: Any?): Map<String, String>? {
        val map = value as? Map<*, *> ?: return null
        if (map.isEmpty()) return null
        return map.entries.associate { (k, v) ->
            k.toString() to ((v as? List<*>)?.joinToString(", ") ?: v.toString())
        }
    }

    private fun redact(headers: Map<String, String>) =
        headers.mapValues { (k, v) -> if (k.lowercase() in redactedHeaders) REDACTED else v }

    private fun cap(body: String) =
        if (body.length > MAX_BODY) body.take(MAX_BODY) + TRUNCATED else body
}
```

- [ ] **Step 4: Run the harness and check the tests pass.** Same command. Expected: `BUILD SUCCESSFUL`, 7 tests passing.
- [ ] **Step 5: Commit** (in the worktree)

```bash
git add plugins/quick-brick-xray/android/src/main/java/com/applicaster/plugin/xray/sinks/NetworkEntryMapper.kt plugins/quick-brick-xray/android/src/test/java/com/applicaster/plugin/xray/sinks/NetworkEntryMapperTest.kt
git commit -m "feat(quick-brick-xray): map Android network request events to NetworkEntry"
```

---

### Task A2: Send `network` frames from `WebSocketSink`

**Files:**
- Modify: `plugins/quick-brick-xray/android/src/main/java/com/applicaster/plugin/xray/sinks/WebSocketSink.kt`: the `MessageType` enum (27-49) and `log()` (76-87).

**Interfaces:**
- Consumes: `NetworkEntryMapper.map(event, requestId)` (Task A1).

- [ ] **Step 1: Add the enum value** after `storage`, in the same double-protected style:

```kotlin
        // Captured HTTP request, routed to the logger's Network tab
        @SerializedName("network")
        network("network"),
```

- [ ] **Step 2: Send the frame in `log()`.** Replace the body after the `webSocket` null check:

```kotlin
    override fun log(event: Event) {
        if(null == webSocket)
            return
        // A captured request is sent twice, like on iOS: as a `network` message for the
        // Network tab and, below, as a normal event for the log feed. Own try/catch so a
        // mapping failure never costs the log line.
        try {
            val id = UUID.randomUUID().toString()
            NetworkEntryMapper.map(event, id)?.let {
                sendMessage(LogEvent(id, gson.toJson(it), MessageType.network))
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send network entry", e)
        }
        try {
            // todo: a bit expensive, move to single worker thread
            val json = gson.toJson(event)
            // maybe build JSONObject directly?
            sendMessage(LogEvent(UUID.randomUUID().toString(), json))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send event", e)
        }
    }
```

- [ ] **Step 3: Check.** The module can't be compiled here (it needs a host app). Check by reading instead:
  - `MessageType.network` exists;
  - `LogEvent`'s third parameter is `type: MessageType`;
  - `Log` and `UUID` are already imported (`grep -n "^import" WebSocketSink.kt`);
  - the A1 harness still passes.

  Say in the PR that the module was not compiled against a host app (the iOS PR #2676 said the same).
- [ ] **Step 4: Commit**

```bash
git add plugins/quick-brick-xray/android/src/main/java/com/applicaster/plugin/xray/sinks/WebSocketSink.kt
git commit -m "feat(quick-brick-xray): send network frames from the Android WebSocket sink"
```

---

### Task A3: Push and open the PR (controller)

- Push `feat/xray-android-network-frames` and open a PR against `master` with the repo template (`.github/PULL_REQUEST_TEMPLATE.md`):
  - Description, linking iOS #2676;
  - Platforms: Android (and Android TV / Fire TV, which share the plugin);
  - Known issues: not compiled against a host app, and only the pure mapper is unit-tested (via a JVM harness);
  - Version Info: CI publishes.
- The PR body ends with the Claude Code attribution line.
