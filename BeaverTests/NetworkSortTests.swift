//
//  NetworkSortTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("Network sort")
struct NetworkSortTests {

    private func e(_ id: Int64, _ fields: String) -> NetworkEntry {
        NetworkEntry.parse(#"{"url":"https://api.io/x",\#(fields)}"#, id: id, fallbackMillis: 0)!
    }

    private var entries: [NetworkEntry] {
        [
            e(1, #""method":"POST","status":500,"timing":{"startTime":30,"duration":300},"responseBody":"abcd""#),
            e(2, #""method":"GET","status":200,"timing":{"startTime":10}"#),
            e(3, #""method":"GET","status":404,"timing":{"startTime":20,"duration":100},"responseBodySize":9000"#),
            e(4, #""method":"DELETE","timing":{"startTime":20,"duration":100}"#),
        ]
    }

    private func ids(_ order: [KeyPathComparator<NetworkEntry>]) -> [Int64] {
        NetworkEntry.sorted(entries, using: order).map(\.id)
    }

    @Test
    func noSortKeepsArrivalOrder() {
        #expect(ids([]) == [1, 2, 3, 4])
    }

    @Test
    func sortsByTextAndNumbersBothWays() {
        #expect(ids([KeyPathComparator(\.method)]) == [4, 2, 3, 1])
        #expect(ids([KeyPathComparator(\.method, order: .reverse)]) == [1, 2, 3, 4])
        #expect(ids([KeyPathComparator(\.startMillis)]) == [2, 3, 4, 1])
        #expect(ids([KeyPathComparator(\.startMillis, order: .reverse)]) == [1, 3, 4, 2])
    }

    @Test
    func tiesFallBackToId() {
        // 3 and 4 share duration 100 and start 20.
        #expect(ids([KeyPathComparator(\.durationMillis)]) == [3, 4, 1, 2])
        #expect(ids([KeyPathComparator(\.durationMillis, order: .reverse)]) == [1, 3, 4, 2])
    }

    @Test
    func missingValuesSortLastEitherWay() {
        #expect(ids([KeyPathComparator(\.status)]) == [2, 3, 1, 4])
        #expect(ids([KeyPathComparator(\.status, order: .reverse)]) == [1, 3, 2, 4])
        // Reported size beats the captured body; 2 and 4 have neither.
        #expect(ids([KeyPathComparator(\.tableSizeBytes)]) == [1, 3, 2, 4])
        #expect(ids([KeyPathComparator(\.tableSizeBytes, order: .reverse)]) == [3, 1, 2, 4])
    }

    @Test
    func laterComparatorsBreakTies() {
        #expect(ids([KeyPathComparator(\.method), KeyPathComparator(\.startMillis, order: .reverse)]) == [4, 3, 2, 1])
    }
}
