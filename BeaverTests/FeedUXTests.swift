//
//  FeedUXTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("Log feed UX logic")
struct FeedUXTests {

    // MARK: - Filter carry-over

    @Test("A filter survives a round trip through its stored form, minus Clear")
    func filterCarriesOver() throws {
        let filter = Filter(minLevel: .warning, search: "auth", searchIsRegex: true,
                            exclude: "noise", searchPayloads: true,
                            subsystems: ["a"], excludedCategories: ["b"],
                            hiddenThroughEventId: 42)
        let restored = try #require(Filter.restore(from: filter.carriedOver.stored))
        var expected = filter
        expected.hiddenThroughEventId = nil
        #expect(restored == expected)
        #expect(Filter.restore(from: Data("junk".utf8)) == nil)
    }

    // MARK: - Tail following (D3)

    @Test("Following until scrolled away, counting what arrives meanwhile")
    func tailFollow() {
        var follow = TailFollow()
        #expect(follow.isFollowing)
        follow.appended(5)
        #expect(follow.unseen == 0)

        follow.scrolled(atBottom: false)
        #expect(!follow.isFollowing)
        follow.appended(3)
        follow.appended(2)
        #expect(follow.unseen == 5)

        follow.scrolled(atBottom: false)
        #expect(follow.unseen == 5)
        follow.scrolled(atBottom: true)
        #expect(follow.isFollowing)
        #expect(follow.unseen == 0)
    }

    @Test("A jump stops following; resuming clears the count")
    func tailFollowStopResume() {
        var follow = TailFollow()
        follow.stop()
        follow.appended(4)
        #expect(!follow.isFollowing && follow.unseen == 4)
        follow.resume()
        #expect(follow.isFollowing && follow.unseen == 0)
    }

    // MARK: - Row text

    private func event(_ message: String, category: String = "net", ms: UInt64 = 0) -> EventRecord {
        EventRecord(id: 1, sessionId: 1, timestampMillis: ms, level: .warning,
                    subsystem: "com.app/player", category: category, message: message,
                    dataJSON: nil, contextJSON: nil)
    }

    @Test("A copied line reads time, level, subsystem/category and message")
    func logLine() {
        let ms: UInt64 = 1_700_000_000_123
        let time = event("", ms: ms).timeOfDayWithMillis
        #expect(event("stalled", ms: ms).logLine == "\(time) [WARNING] com.app/player/net: stalled")
        #expect(event("stalled", category: "", ms: ms).logLine == "\(time) [WARNING] com.app/player: stalled")
    }

    @Test("Line count sees \\n, \\r\\n and a trailing newline")
    func lineCount() {
        #expect(event("one").lineCount == 1)
        #expect(event("a\nb\nc").lineCount == 3)
        #expect(event("a\r\nb").lineCount == 2)
        #expect(event("a\n").lineCount == 2)
    }

    // MARK: - Time deltas

    @Test("Deltas read in ms, then seconds, then minutes, with a sign")
    func delta() {
        #expect(TimeDelta.text(milliseconds: 0) == "+0 ms")
        #expect(TimeDelta.text(milliseconds: 12) == "+12 ms")
        #expect(TimeDelta.text(milliseconds: 1_234) == "+1.234 s")
        #expect(TimeDelta.text(milliseconds: -1_500) == "−1.500 s")
        #expect(TimeDelta.text(milliseconds: 125_000) == "+2m 05s")
        #expect(TimeDelta.text(milliseconds: 3_725_000) == "+1h 02m")
    }
}
