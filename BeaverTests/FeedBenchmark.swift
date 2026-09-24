//
//  FeedBenchmark.swift
//  BeaverTests
//
//  What one live append costs the Log feed, before and after the
//  incremental tail. Opt-in, since seeding takes a few seconds:
//
//      BEAVER_BENCH=1 swift test --filter FeedBenchmark
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("FeedBenchmark", .enabled(if: ProcessInfo.processInfo.environment["BEAVER_BENCH"] != nil))
struct FeedBenchmark {

    private static let seeded = 100_000
    private static let batch = 20      // ~one 50 ms flush on a busy device
    private static let rounds = 10

    @Test("Per-append cost on a 100k-event session")
    func perAppend() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("beaver-bench-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LogStore(source: .onDisk(url))
        let sid = try await store.createSession(source: .live).id

        var next = 0
        func events(_ n: Int) -> [DecodedEvent] {
            (0..<n).map { _ in
                defer { next += 1 }
                return DecodedEvent(
                    timestampMillis: UInt64(1_000_000 + next * 10),
                    level: next % 50 == 0 ? .error : .info,
                    subsystem: "com.example/quick_brick/\(next % 12)",
                    category: "cat\(next % 7)",
                    message: next % 9 == 0 ? "player state \(next)" : "request \(next) finished",
                    dataJSON: #"{"n":\#(next),"url":"https://cdn.example.com/a/b/c.json","ok":true}"#,
                    contextJSON: nil
                )
            }
        }
        for _ in 0..<(Self.seeded / 10_000) {
            try await store.appendBulk(events(10_000), to: sid)
        }

        for filter in [Filter.none, Filter(search: "player")] {
            var before: [Duration] = []
            var after: [Duration] = []
            var feed = FeedRows(collapse: true)
            let snapshot = try await store.feedSnapshot(sessionId: sid, filter: filter, limit: 1_000_000)
            feed.replace(with: snapshot.events)
            var watermark = snapshot.watermark

            for _ in 0..<Self.rounds {
                try await store.appendBulk(events(Self.batch), to: sid)
                let clock = ContinuousClock()

                // Before: what `reload()` did on every append.
                before.append(try await clock.measure {
                    let count = try await store.eventCount(sessionId: sid, filter: filter)
                    let unfiltered = filter.isEmpty
                        ? count
                        : try await store.eventCount(sessionId: sid, filter: .none)
                    let page = try await store.events(sessionId: sid, filter: filter, offset: 0,
                                                      limit: 1_000_000, includePayloads: false)
                    // `collapsedRows` was recomputed on every body pass;
                    // count one.
                    var rows = FeedRows(collapse: true)
                    rows.replace(with: page)
                    _ = (unfiltered, rows.rows.count)
                })

                // After: fetch past the watermark and merge.
                after.append(try await clock.measure {
                    let tail = try await store.feedTail(sessionId: sid, filter: filter, after: watermark)
                    watermark = tail.watermark
                    feed.merge(tail.events)
                })
            }
            let label = filter.isEmpty ? "unfiltered" : "search \"player\""
            print("""
                FeedBenchmark [\(label)] \(Self.seeded)+ events, \(Self.batch) per append, median of \(Self.rounds):
                  before (2×COUNT + full SELECT + regroup): \(median(before))
                  after  (tail by rowid + merge):           \(median(after))
                """)
            #expect(median(after) < median(before))
        }
    }

    private func median(_ values: [Duration]) -> Duration {
        values.sorted()[values.count / 2]
    }
}
