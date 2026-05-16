//
//  LogStoreTests.swift
//  LoggerNextTests
//

import Testing
import Foundation
@testable import LoggerNextCore

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

        // Force the batch flush.
        try await Task.sleep(for: .milliseconds(120))

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
        try await Task.sleep(for: .milliseconds(120))

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
        try await Task.sleep(for: .milliseconds(120))

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
        try await Task.sleep(for: .milliseconds(120))

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
        let received = await Task.race(timeout: .seconds(1)) {
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

// MARK: - Test helpers

extension Task where Failure == Never {
    /// Runs `work` with a timeout. Returns `nil` on timeout, otherwise
    /// the result of `work`.
    static func race<T: Sendable>(
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
}
