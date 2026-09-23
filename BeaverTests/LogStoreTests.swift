//
//  LogStoreTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("LogStore")
struct LogStoreTests {

    // MARK: - Schema / migration

    @Test
    func schemaMigratesOnFirstOpen() async throws {
        // Just opening an in-memory store should run the v1 migration
        // and leave the database in a usable state.
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        #expect(session.id > 0)
    }

    // MARK: - Append + query round-trip

    @Test
    func appendAndQueryRoundTrip() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        let events = (0..<100).map { i in
            DecodedEvent(
                timestampMillis: UInt64(1_000_000 + i),
                level: i % 5 == 0 ? .error : .info,
                subsystem: "com.example.\(i % 3)",
                category: "cat\(i % 7)",
                message: "event #\(i) login OK",
                dataJSON: nil,
                contextJSON: nil
            )
        }
        for e in events { await store.append(e, to: session.id) }

        try await waitForEvents(100, session: session.id, in: store)

        let total = try await store.eventCount(sessionId: session.id, filter: .none)
        #expect(total == 100)

        let page = try await store.events(
            sessionId: session.id,
            filter: .none,
            offset: 0,
            limit: 10
        )
        #expect(page.count == 10)
        // Ordered by timestamp ASC, so first row is the oldest.
        #expect(page.first?.timestampMillis == 1_000_000)
    }

    /// The Size column counts UTF-8 bytes on disk, with or without the
    /// payloads fetched — and multi-byte text must not be counted as
    /// characters.
    @Test
    func payloadBytesAreUTF8Bytes() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let data = #"{"city":"Zürich 🚀"}"#
        await store.append(
            DecodedEvent(timestampMillis: 1, level: .info, subsystem: "s", category: "",
                         message: "m", dataJSON: data, contextJSON: "{}"),
            to: session.id
        )
        try await waitForEvents(1, session: session.id, in: store)

        let expected = data.utf8.count + 2
        let lean = try await store.events(sessionId: session.id, filter: .none,
                                          offset: 0, limit: 10, includePayloads: false)
        #expect(lean.first?.payloadBytes == expected)
        let full = try await store.events(ids: [lean.first!.id])
        #expect(full.first?.payloadBytes == expected)
    }

    @Test
    func regexMatchNavigationUsesEachPatternAndSurvivesABrokenOne() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        try await store.appendBulk(["alpha 1", "beta 22", "gamma 333"].enumerated().map { i, m in
            DecodedEvent(timestampMillis: UInt64(i), level: .info, subsystem: "s", category: "",
                         message: m, dataJSON: nil, contextJSON: nil)
        }, to: session.id)

        func hits(_ pattern: String) async throws -> Int {
            try await store.matchingIds(sessionId: session.id, filter: .none,
                                        highlight: pattern, isRegex: true).count
        }
        #expect(try await hits(#"\d{2,}"#) == 2)
        #expect(try await hits("^alpha") == 1)       // a new pattern, not the cached one
        #expect(try await hits("(unclosed") == 0)    // invalid → no match, no throw
        #expect(try await hits("(unclosed") == 0)    // cached failure behaves the same
        #expect(try await hits(#"\d{2,}"#) == 2)
    }

    // MARK: - Payload-free feed query

    /// The log feed renders level / message / subsystem / category / time
    /// only, but `data_json` is ~97% of a row's bytes (10 KB average,
    /// 25 MB peak in the wild). Fetching a whole session *with* payloads
    /// is what let the app reach 56 GB, so the feed must ask for them to
    /// be dropped — and the detail pane must still be able to get them
    /// back by id.
    @Test
    func feedQuerySkipsPayloadsButIdLookupKeepsThem() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        await store.append(
            DecodedEvent(
                timestampMillis: 1_000_000,
                level: .info,
                subsystem: "com.example",
                category: "cat",
                message: "with payload",
                dataJSON: #"{"big":"blob"}"#,
                contextJSON: #"{"ctx":1}"#
            ),
            to: session.id
        )
        try await waitForEvents(1, session: session.id, in: store)

        let lean = try await store.events(
            sessionId: session.id,
            filter: .none,
            offset: 0,
            limit: 10,
            includePayloads: false
        )
        #expect(lean.count == 1)
        #expect(lean.first?.message == "with payload")
        #expect(lean.first?.dataJSON == nil)
        #expect(lean.first?.contextJSON == nil)

        let id = try #require(lean.first?.id)
        let full = try await store.events(ids: [id])
        #expect(full.first?.dataJSON == #"{"big":"blob"}"#)
        #expect(full.first?.contextJSON == #"{"ctx":1}"#)

        // Default stays payload-bearing so Export keeps working.
        let exported = try await store.events(
            sessionId: session.id,
            filter: .none,
            offset: 0,
            limit: 10
        )
        #expect(exported.first?.dataJSON == #"{"big":"blob"}"#)
    }

    // MARK: - Level filter

    @Test
    func levelFilterDropsLowerSeverity() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        for level in LogLevel.allCases {
            await store.append(
                DecodedEvent(
                    timestampMillis: 1,
                    level: level,
                    subsystem: "x",
                    category: "y",
                    message: "m",
                    dataJSON: nil,
                    contextJSON: nil
                ),
                to: session.id
            )
        }
        try await waitForEvents(LogLevel.allCases.count, session: session.id, in: store)

        // minLevel = .warning should yield only warning + error.
        let filter = Filter(minLevel: .warning)
        let count = try await store.eventCount(sessionId: session.id, filter: filter)
        #expect(count == 2)
    }

    // MARK: - FTS search

    @Test
    func ftsSearchMatchesMessageTokens() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        let phrases = [
            "user login OK",
            "network timeout",
            "user logout",
            "image upload failed",
        ]
        for (i, phrase) in phrases.enumerated() {
            await store.append(
                DecodedEvent(
                    timestampMillis: UInt64(i),
                    level: .info,
                    subsystem: "x",
                    category: "y",
                    message: phrase,
                    dataJSON: nil,
                    contextJSON: nil
                ),
                to: session.id
            )
        }
        try await waitForEvents(phrases.count, session: session.id, in: store)

        let filter = Filter(search: "user")
        let count = try await store.eventCount(sessionId: session.id, filter: filter)
        #expect(count == 2)  // "user login OK" and "user logout"

        let events = try await store.events(
            sessionId: session.id,
            filter: filter,
            offset: 0,
            limit: 10
        )
        let messages = events.map(\.message)
        #expect(messages.contains("user login OK"))
        #expect(messages.contains("user logout"))
    }

    // MARK: - Exclude

    @Test
    func excludeFilterDropsMatching() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        let phrases = ["alpha event", "beta event", "gamma event"]
        for (i, phrase) in phrases.enumerated() {
            await store.append(
                DecodedEvent(
                    timestampMillis: UInt64(i),
                    level: .info,
                    subsystem: "x",
                    category: "y",
                    message: phrase,
                    dataJSON: nil,
                    contextJSON: nil
                ),
                to: session.id
            )
        }
        try await waitForEvents(phrases.count, session: session.id, in: store)

        let filter = Filter(exclude: "beta")
        let count = try await store.eventCount(sessionId: session.id, filter: filter)
        #expect(count == 2)  // alpha + gamma; beta excluded
    }

    // MARK: - Storage snapshots

    @Test
    func storageSnapshotRoundTrip() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        try await store.recordStorageSnapshot(
            sessionId: session.id,
            namespace: .local,
            dataJSON: "{\"k\":\"v\"}"
        )

        let snapshot = try await store.latestStorageSnapshot(
            sessionId: session.id,
            namespace: .local
        )
        #expect(snapshot?.dataJSON == "{\"k\":\"v\"}")
        #expect(snapshot?.namespace == .local)
    }

    // MARK: - Session lifecycle

    @Test
    func endingSessionSetsEndedAt() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        try await store.endSession(session.id)
        let all = try await store.sessions()
        let target = all.first { $0.id == session.id }
        #expect(target?.endedAt != nil)
    }

    // MARK: - Change subscription

    @Test
    func appendedChangeIsBroadcast() async throws {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        let stream = await store.changes()

        await store.append(
            DecodedEvent(
                timestampMillis: 1,
                level: .info,
                subsystem: "x",
                category: "y",
                message: "z",
                dataJSON: nil,
                contextJSON: nil
            ),
            to: session.id
        )

        // Pull one change off the stream with a timeout.
        let received = await race(timeout: .seconds(1)) {
            for await change in stream {
                if case .appended(let sid, let count) = change,
                   sid == session.id, count > 0 {
                    return true
                }
            }
            return false
        }
        #expect(received == true)
    }
}

// MARK: - Chip filters

extension LogStoreTests {

    /// Three subsystems × two categories, so include and exclude can be
    /// told apart from "matched everything".
    private func seededStore() async throws -> (LogStore, Int64) {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)

        for (index, subsystem) in ["player", "auth", "network"].enumerated() {
            for category in ["ui", "net"] {
                await store.append(
                    DecodedEvent(
                        timestampMillis: UInt64(1_000_000 + index * 10),
                        level: .info,
                        subsystem: subsystem,
                        category: category,
                        message: "\(subsystem)/\(category)",
                        dataJSON: nil,
                        contextJSON: nil
                    ),
                    to: session.id
                )
            }
        }
        try await waitForEvents(6, session: session.id, in: store)
        return (store, session.id)
    }

    @Test("Including subsystems keeps only those")
    func includedSubsystemsNarrowTheQuery() async throws {
        let (store, sessionId) = try await seededStore()

        let filter = Filter(subsystems: ["player", "auth"])
        let rows = try await store.events(
            sessionId: sessionId, filter: filter, offset: 0, limit: 100
        )

        #expect(rows.count == 4)
        #expect(Set(rows.map(\.subsystem)) == ["player", "auth"])
    }

    @Test("Excluding a subsystem drops only it")
    func excludedSubsystemsAreDropped() async throws {
        let (store, sessionId) = try await seededStore()

        let filter = Filter(excludedSubsystems: ["network"])
        let rows = try await store.events(
            sessionId: sessionId, filter: filter, offset: 0, limit: 100
        )

        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.subsystem != "network" })
    }

    @Test("Subsystem and category chips compose")
    func chipsAcrossFacetsCombine() async throws {
        let (store, sessionId) = try await seededStore()

        // "show only player, and hide the ui category"
        let filter = Filter(subsystems: ["player"], excludedCategories: ["ui"])
        let rows = try await store.events(
            sessionId: sessionId, filter: filter, offset: 0, limit: 100
        )

        #expect(rows.count == 1)
        #expect(rows.first?.subsystem == "player")
        #expect(rows.first?.category == "net")

        // eventCount has to agree with the page it describes.
        let count = try await store.eventCount(sessionId: sessionId, filter: filter)
        #expect(count == rows.count)
    }

    @Test("Clearing the view hides events without deleting them")
    func clearViewIsNonDestructive() async throws {
        let (store, sessionId) = try await seededStore()

        let all = try await store.events(
            sessionId: sessionId, filter: .none, offset: 0, limit: 100
        )
        #expect(all.count == 6)

        // "Clear" watermarks the newest event at the time it ran.
        let watermark = try await store.latestEventId(sessionId: sessionId)
        #expect(watermark == all.last?.id)

        let cleared = Filter(hiddenThroughEventId: watermark)
        let visible = try await store.events(
            sessionId: sessionId, filter: cleared, offset: 0, limit: 100
        )

        // Screen is empty...
        #expect(visible.isEmpty)
        #expect(try await store.eventCount(sessionId: sessionId, filter: cleared) == 0)
        // ...but the session still holds everything, which is what the
        // "0 / 6" counter and Export-with-no-filter rely on.
        #expect(try await store.eventCount(sessionId: sessionId, filter: .none) == 6)
    }

    @Test("Events after the clear show up again")
    func eventsAfterClearAreVisible() async throws {
        let (store, sessionId) = try await seededStore()
        let watermark = try await store.latestEventId(sessionId: sessionId)

        await store.append(
            DecodedEvent(
                timestampMillis: 2_000_000,
                level: .info,
                subsystem: "player",
                category: "ui",
                message: "after the clear",
                dataJSON: nil,
                contextJSON: nil
            ),
            to: sessionId
        )
        try await waitForEvents(7, session: sessionId, in: store)

        let visible = try await store.events(
            sessionId: sessionId,
            filter: Filter(hiddenThroughEventId: watermark),
            offset: 0,
            limit: 100
        )

        #expect(visible.map(\.message) == ["after the clear"])
    }

    @Test("A saved filter doesn't carry the clear watermark")
    func savedFilterDropsTheWatermark() async throws {
        // An event id means nothing in another session, so persisting it
        // would hide an arbitrary slice the next time the preset is used.
        let store = try LogStore(source: .inMemory)
        let filter = Filter(minLevel: .warning, hiddenThroughEventId: 12_345)

        try await store.upsertSavedFilter(name: "Warnings", filter: filter)
        let loaded = try await store.savedFilters().first

        #expect(loaded?.filter.hiddenThroughEventId == nil)
        #expect(loaded?.filter.minLevel == .warning)
    }

    @Test("Size is right even when payloads aren't loaded")
    func sizeSurvivesPayloadFreeFetch() async throws {
        // The feed fetches rows without payloads — they are ~97% of the
        // bytes — so the Size column has to get the payload cost from
        // SQL rather than from a blob it never received.
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let payload = #"{"blob":"\#(String(repeating: "x", count: 4096))"}"#

        await store.append(
            DecodedEvent(
                timestampMillis: 1_000_000,
                level: .info,
                subsystem: "player",
                category: "net",
                message: "heavy",
                dataJSON: payload,
                contextJSON: nil
            ),
            to: session.id
        )
        try await waitForEvents(1, session: session.id, in: store)

        let lean = try await store.events(
            sessionId: session.id, filter: .none, offset: 0, limit: 10,
            includePayloads: false
        ).first
        let full = try await store.events(
            sessionId: session.id, filter: .none, offset: 0, limit: 10
        ).first

        // The lean row genuinely has no payload in hand...
        #expect(lean?.dataJSON == nil)
        // ...yet reports the same cost as the full one.
        #expect(lean?.sizeBytes == full?.sizeBytes)
        #expect(lean?.sizeBytes == "heavy".utf8.count
                + "player".utf8.count
                + "net".utf8.count
                + payload.utf8.count)
        #expect(lean?.sizeClass == .average)
    }

    @Test("A saved filter keeps its chips")
    func savedFilterRoundTripsChips() async throws {
        let store = try LogStore(source: .inMemory)
        let filter = Filter(
            minLevel: .warning,
            search: "login",
            subsystems: ["player"],
            excludedSubsystems: ["network"],
            categories: ["ui"],
            excludedCategories: ["net"]
        )

        try await store.upsertSavedFilter(name: "Player errors", filter: filter)
        let loaded = try await store.savedFilters()

        #expect(loaded.count == 1)
        #expect(loaded.first?.filter == filter)
    }

    @Test("An empty chip set round-trips as empty, not as a stray value")
    func savedFilterWithoutChipsStaysEmpty() async throws {
        let store = try LogStore(source: .inMemory)
        let filter = Filter(minLevel: .error)

        try await store.upsertSavedFilter(name: "Errors only", filter: filter)
        let loaded = try await store.savedFilters().first

        #expect(loaded?.filter.subsystems.isEmpty == true)
        #expect(loaded?.filter.excludedCategories.isEmpty == true)
        #expect(loaded?.filter == filter)
    }
}

// MARK: - Test helpers

struct WaitTimedOut: Error, CustomStringConvertible {
    let expected: Int
    let actual: Int
    var description: String {
        "timed out waiting for \(expected) events to flush — store had \(actual)"
    }
}

/// Block until `expected` events have actually landed in the store.
///
/// `LogStore.append` batches writes behind a 50 ms timer, so asserting
/// after a fixed sleep is a race: swift-testing runs these suites in
/// parallel, and on a loaded CI runner the flush lands after the
/// assertion has already read an empty table. Poll for the condition
/// instead of guessing a duration.
func waitForEvents(
    _ expected: Int,
    session: Int64,
    in store: LogStore,
    timeout: Duration = .seconds(10)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var seen = 0
    while ContinuousClock.now < deadline {
        seen = try await store.eventCount(sessionId: session, filter: .none)
        if seen >= expected { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw WaitTimedOut(expected: expected, actual: seen)
}

/// Runs `work` with a timeout. Returns `nil` on timeout, otherwise
/// the result of `work`.
///
/// A free function rather than a `Task` extension: inside
/// `extension Task where Failure == Never`, `Task.sleep` resolves to
/// `Task<Success, Never>.sleep` and fails to compile (it needs
/// `Success == Never`), and the call site can't infer `Success` either.
func race<T: Sendable>(
    timeout: Duration,
    _ work: @Sendable @escaping () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
