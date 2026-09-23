//
//  LogStoreFacetTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

/// Subsystem and category menus narrow each other: each facet's counts
/// honour every filter except that facet's own chips.
@Suite("LogStore facets")
struct LogStoreFacetTests {

    /// A/x ×3 (one error), A/y ×2, B/z ×1, B/"" ×1.
    private func seeded() async throws -> (LogStore, Int64) {
        let store = try LogStore(source: .inMemory)
        let session = try await store.createSession(source: .live)
        let rows: [(String, String, LogLevel, String)] = [
            ("A", "x", .error, "boom"),
            ("A", "x", .info, "hello"),
            ("A", "x", .info, "hello"),
            ("A", "y", .info, "hello"),
            ("A", "y", .info, "needle"),
            ("B", "z", .info, "needle"),
            ("B", "", .info, "hello"),
        ]
        for (i, (subsystem, category, level, message)) in rows.enumerated() {
            await store.append(
                DecodedEvent(
                    timestampMillis: UInt64(1_000_000 + i),
                    level: level,
                    subsystem: subsystem,
                    category: category,
                    message: message,
                    dataJSON: nil,
                    contextJSON: nil
                ),
                to: session.id
            )
        }
        try await waitForEvents(rows.count, session: session.id, in: store)
        return (store, session.id)
    }

    private func counts(_ facets: [FacetCount]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: facets.map { ($0.value, $0.count) })
    }

    @Test("Including a subsystem narrows categories")
    func includeSubsystemNarrowsCategories() async throws {
        let (store, sid) = try await seeded()
        let result = try await store.facetCounts(
            sessionId: sid, facet: .category, filter: Filter(subsystems: ["A"])
        )
        #expect(result == [FacetCount(value: "x", count: 3), FacetCount(value: "y", count: 2)])
    }

    @Test("Including a category narrows subsystems")
    func includeCategoryNarrowsSubsystems() async throws {
        let (store, sid) = try await seeded()
        let result = try await store.facetCounts(
            sessionId: sid, facet: .subsystem, filter: Filter(categories: ["z"])
        )
        #expect(result == [FacetCount(value: "B", count: 1)])
    }

    @Test("Excluding a subsystem narrows categories")
    func excludeSubsystemNarrowsCategories() async throws {
        let (store, sid) = try await seeded()
        let result = try await store.facetCounts(
            sessionId: sid, facet: .category, filter: Filter(excludedSubsystems: ["A"])
        )
        #expect(result == [FacetCount(value: "z", count: 1)])
    }

    @Test("A facet ignores its own chips")
    func ownChipsDoNotNarrow() async throws {
        let (store, sid) = try await seeded()
        let included = try await store.facetCounts(
            sessionId: sid, facet: .subsystem, filter: Filter(subsystems: ["A"])
        )
        #expect(included == [FacetCount(value: "A", count: 5), FacetCount(value: "B", count: 2)])

        let excluded = try await store.facetCounts(
            sessionId: sid, facet: .subsystem, filter: Filter(excludedSubsystems: ["A"])
        )
        #expect(counts(excluded) == ["A": 5, "B": 2])
    }

    @Test("Level narrows both facets")
    func levelNarrowsBoth() async throws {
        let (store, sid) = try await seeded()
        let filter = Filter(minLevel: .error)
        let subsystems = try await store.facetCounts(sessionId: sid, facet: .subsystem, filter: filter)
        let categories = try await store.facetCounts(sessionId: sid, facet: .category, filter: filter)
        #expect(subsystems == [FacetCount(value: "A", count: 1)])
        #expect(categories == [FacetCount(value: "x", count: 1)])
    }

    @Test("Search narrows both facets")
    func searchNarrowsBoth() async throws {
        let (store, sid) = try await seeded()
        let filter = Filter(search: "needle")
        let subsystems = try await store.facetCounts(sessionId: sid, facet: .subsystem, filter: filter)
        let categories = try await store.facetCounts(sessionId: sid, facet: .category, filter: filter)
        #expect(counts(subsystems) == ["A": 1, "B": 1])
        #expect(counts(categories) == ["y": 1, "z": 1])
    }

    @Test("A stale selection shows with count 0, sorted last")
    func staleSelectionKeptAtZero() async throws {
        let (store, sid) = try await seeded()
        let filter = Filter(
            subsystems: ["A"],
            categories: ["z"],
            excludedCategories: ["gone"]
        )
        let result = try await store.facetCounts(sessionId: sid, facet: .category, filter: filter)
        #expect(result == [
            FacetCount(value: "x", count: 3),
            FacetCount(value: "y", count: 2),
            FacetCount(value: "gone", count: 0),
            FacetCount(value: "z", count: 0),
        ])
    }

    @Test("Empty categories are left out")
    func emptyCategoryDropped() async throws {
        let (store, sid) = try await seeded()
        let result = try await store.facetCounts(sessionId: sid, facet: .category, filter: .none)
        #expect(result == [
            FacetCount(value: "x", count: 3),
            FacetCount(value: "y", count: 2),
            FacetCount(value: "z", count: 1),
        ])
    }
}
