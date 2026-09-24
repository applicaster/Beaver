// BeaverTests/ToolInputTests.swift
import Testing
import Foundation
@testable import BeaverCore

@Suite("Forgiving tool inputs")
struct ToolInputTests {

    @Test("Level aliases", arguments: [
        ("warn", LogLevel.warning), ("W", .warning), ("err", .error), ("E", .error),
        ("fatal", .error), ("trace", .verbose), ("3", .warning), ("info", .info),
    ])
    func levels(input: String, expected: LogLevel) {
        #expect(ToolInput.level(.string(input)) == expected)
    }

    @Test("Numeric level and nonsense")
    func levelEdges() {
        #expect(ToolInput.level(4) == .error)
        #expect(ToolInput.level("loud") == nil)
    }

    @Test("Durations and ISO times")
    func times() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(ToolInput.time("5m", now: now) == Date(timeIntervalSince1970: 9_700))
        #expect(ToolInput.time("2h", now: now) == Date(timeIntervalSince1970: 2_800))
        #expect(ToolInput.time("30s", now: now) == Date(timeIntervalSince1970: 9_970))
        #expect(ToolInput.time("1970-01-01T00:00:05Z", now: now) == Date(timeIntervalSince1970: 5))
        #expect(ToolInput.time("yesterday-ish", now: now) == nil)
    }

    @Test("Names: exact, case, glob, fragment, miss with suggestions")
    func names() {
        let available = ["com.app.auth", "com.app.player", "player.ads", "Network"]
        #expect(ToolInput.resolveNames(["com.app.auth"], among: available).resolved == ["com.app.auth"])
        #expect(ToolInput.resolveNames(["network"], among: available).resolved == ["Network"])
        #expect(ToolInput.resolveNames(["*player*"], among: available).resolved == ["com.app.player", "player.ads"])
        #expect(ToolInput.resolveNames(["auth"], among: available).resolved == ["com.app.auth"])
        let miss = ToolInput.resolveNames(["autth"], among: available)
        #expect(miss.resolved.isEmpty)
        #expect(miss.misses.first?.closest.first == "com.app.auth")
    }

    @Test("Session: given, live, viewed, latest, none")
    func sessions() async throws {
        let store = try LogStore(source: .inMemory)
        let ctxEmpty = makeContext(store)
        await #expect(throws: ToolError.self) { try await ctxEmpty.resolveSession(ToolArguments()) }

        let old = try await store.createSession(source: .imported)
        let live = try await store.createSession(source: .live)
        #expect(try await makeContext(store).resolveSession(ToolArguments()).id == live.id)
        #expect(try await makeContext(store).resolveSession(ToolArguments()).how == .latest)
        #expect(try await makeContext(store, ui: HostSnapshot(liveSessionId: live.id))
            .resolveSession(ToolArguments()).how == .live)
        #expect(try await makeContext(store, ui: HostSnapshot(viewingSessionId: old.id))
            .resolveSession(ToolArguments()).id == old.id)
        #expect(try await makeContext(store).resolveSession(ToolArguments(["sessionId": .number(Double(old.id))])).how == .given)
        await #expect(throws: ToolError.self) {
            try await makeContext(store).resolveSession(ToolArguments(["sessionId": 999]))
        }
    }

    @Test("Session label: most recent says so, given/live/viewed don't")
    func sessionLabels() async throws {
        let store = try LogStore(source: .inMemory)
        let imported = try await store.createSession(source: .imported)
        let live = try await store.createSession(source: .live)

        // .latest: an old live session sitting around must not read as "live".
        #expect(try await makeContext(store).resolveSession(ToolArguments()).label == "#\(live.id) (most recent, live)")
        // .given keeps the source, with no "most recent".
        #expect(try await makeContext(store)
            .resolveSession(ToolArguments(["sessionId": .number(Double(imported.id))])).label == "#\(imported.id) (imported)")
        // .live / .viewed report how the session was picked, not its source.
        #expect(try await makeContext(store, ui: HostSnapshot(liveSessionId: live.id))
            .resolveSession(ToolArguments()).label == "#\(live.id) (live)")
        #expect(try await makeContext(store, ui: HostSnapshot(viewingSessionId: imported.id))
            .resolveSession(ToolArguments()).label == "#\(imported.id) (viewed)")
    }

    @Test("Filter: resolves names, echoes them, rejects a miss and a bad regex")
    func filters() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.info, "com.app.auth", "token", "a"), (.error, "player.core", "", "b")])
        let ctx = makeContext(store)

        let r = try await ctx.resolveFilter(["minLevel": "warn", "subsystems": ["*auth*"]], sessionId: s.id)
        #expect(r.filter.minLevel == .warning)
        #expect(r.filter.subsystems == ["com.app.auth"])
        #expect(r.notes == ["subsystems *auth* → com.app.auth"])

        await #expect(throws: ToolError.self) {
            try await ctx.resolveFilter(["subsystems": ["nothing-like-it"]], sessionId: s.id)
        }
        await #expect(throws: ToolError.self) {
            try await ctx.resolveFilter(["search": "(", "searchIsRegex": true], sessionId: s.id)
        }
        let none = try await ctx.resolveFilter(nil, sessionId: s.id)
        #expect(none.filter == .none)
    }

    @Test("Range: since resolves to the id before the first event at that time")
    func ranges() async throws {
        let store = try LogStore(source: .inMemory)
        let s = try await store.createSession(source: .live)
        try await seed(store, session: s.id, [(.info, "a", "", "old")], startMillis: 1_000)
        try await seed(store, session: s.id, [(.info, "a", "", "new")], startMillis: 9_000_000)
        let ids = try await store.eventPage(sessionId: s.id, filter: .none, limit: 10, newestFirst: false).events.map(\.id)
        let ctx = makeContext(store, now: Date(timeIntervalSince1970: 9_100))   // 9 100 000 ms
        let r = try await ctx.resolveRange(ToolArguments(["since": "5m"]), sessionId: s.id)  // → 8 800 000 ms
        #expect(r.afterId == ids[0])
        #expect(r.notes.first?.hasPrefix("since 5m") == true)
    }

    @Test("Text helpers")
    func text() {
        let long = String(repeating: "x", count: 600) + "\nnext"
        let e = EventRecord(id: 7, sessionId: 1, timestampMillis: 0, level: .error, subsystem: "a",
                            category: "b", message: long, dataJSON: nil, contextJSON: nil)
        let line = ToolText.eventLine(e)
        #expect(line.hasPrefix("#7 "))
        #expect(line.contains("ERROR a/b: "))
        #expect(line.contains("logs_get"))
        #expect(ToolText.describe(Filter(minLevel: .warning, subsystems: ["x"])) == "level ≥ warning; subsystems x")
        #expect(ToolText.describe(.none) == "no filter")
        let capped = ToolText.capped(String(repeating: "é", count: 10), maxBytes: 5)
        #expect(capped.truncated)
        #expect(capped.text.utf8.count <= 5)
        // "🔥" is 4 UTF-8 bytes (F0 9F 94 A5); cutting inside it needs two
        // continuation-byte step-backs to reach the lead byte.
        let emoji = ToolText.capped("ab🔥", maxBytes: 4)
        #expect(emoji.truncated)
        #expect(emoji.text == "ab")
    }

    @Test("Cutting inside a multi-scalar Character keeps the prefix, doesn't empty it")
    func cappedMidGrapheme() {
        // "e" + combining acute (U+0301, 2 UTF-8 bytes) form one Character;
        // byte 11 lands exactly between them — scalar-aligned, but not a
        // Character boundary, which used to make String.Index(_:within:)
        // return nil and fall back to an empty result.
        let combining = ToolText.capped("xxxxxxxxxxe\u{301}tail", maxBytes: 11)
        #expect(combining.truncated)
        #expect(combining.text == "xxxxxxxxxxe")
        #expect(combining.text.utf8.count <= 11)

        // A flag emoji is two regional-indicator scalars (4 UTF-8 bytes
        // each) forming one Character; byte 7 lands between them.
        let flag = ToolText.capped("abc🇺🇦zzz", maxBytes: 7)
        #expect(flag.truncated)
        #expect(flag.text.hasPrefix("abc"))
        #expect(!flag.text.isEmpty)
        #expect(flag.text.utf8.count <= 7)

        // "\r\n" is one Character; byte 1 lands between "\r" and "\n". A
        // whole scalar ("\r") does fit in 1 byte, so the result must not be
        // empty.
        let crlf = ToolText.capped("\r\n\r\n", maxBytes: 1)
        #expect(crlf.truncated)
        #expect(crlf.text == "\r")
        #expect(crlf.text.utf8.count <= 1)
    }

    @Test("resolveSession picks the same session as sessions_list lists first")
    func resolveSessionConsistency() async throws {
        let store = try LogStore(source: .inMemory)
        _ = try await store.createSession(source: .imported)
        _ = try await store.createSession(source: .live)
        let ctx = makeContext(store)
        let resolved = try await ctx.resolveSession(ToolArguments())
        let sessions = try await store.sessions()
        #expect(resolved.id == sessions.first?.id)
    }
}
