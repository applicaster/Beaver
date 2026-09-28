import Testing
import Foundation
@testable import BeaverCore

/// The detail pane's find (D84) steps through these in order and opens
/// `reveal` to show each one — a wrong path lands on a collapsed row.
@Suite("DetailFind")
struct DetailFindTests {

    private let data = StorageRecord.parse("""
    {"user": {"name": "Ann", "tags": ["x", "needle", "y"]}, "needleKey": 1}
    """)!
    private let context = StorageRecord.parse(#"{"screen": "Needle screen"}"#)!

    private func find(_ term: String, message: String = "no hit", regex: Bool = false) -> [DetailFind.Match] {
        DetailFind.matches(message: message, data: data, context: context, term: term, isRegex: regex)
    }

    @Test("Blank or invalid terms find nothing")
    func blank() {
        #expect(find("  ").isEmpty)
        #expect(find("(", regex: true).isEmpty)
    }

    @Test("Message, then data, then context, rows in drawing order")
    func order() {
        let found = find("NEEDLE", message: "a needle and a needle")
        #expect(found.map(\.section) == [.message, .data, .data, .context])
        #expect(found.map(\.id) == [nil, "$.needleKey", "$.user.tags[1]", "$.screen"])
    }

    @Test("Reveal names every parent and the child index on the way down")
    func reveal() {
        let hit = find("needle").first { $0.id == "$.user.tags[1]" }
        #expect(hit?.reveal == ["$": 1, "$.user": 1, "$.user.tags": 1])
        // Keys sort, so "needleKey" is the root's first child.
        #expect(find("needleKey").first?.reveal == ["$": 0])
    }

    @Test("Keys and containers match, values match as stored")
    func keysAndValues() {
        #expect(find("tags").map(\.id) == ["$.user.tags"])
        #expect(find("^ann$", regex: true).map(\.id) == ["$.user.name"])
    }
}
