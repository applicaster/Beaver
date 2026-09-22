import Testing
import Foundation
@testable import BeaverCore

/// Discover has to behave while the user is still typing — a
/// half-written regular expression must not wipe the screen — and the
/// match order is what the ▲ ▼ buttons walk.
@Suite("StorageSearch")
struct StorageSearchTests {

    private let records = StorageRecord.parseTopLevel("""
    {
      "applicaster.v2": {
        "deviceMake": "Apple",
        "deviceName": "iPhone 15",
        "app_name": "Demo"
      },
      "ZappPushPluginFirebase": {
        "token": "abc123",
        "enabled": "true"
      }
    }
    """)

    private func matcher(_ term: String, regex: Bool = false) -> StorageSearch.Matcher {
        StorageSearch.matcher(term: term, isRegex: regex)
    }

    // MARK: Plain text

    @Test("An empty search narrows nothing")
    func emptySearchPassesEverything() {
        let m = matcher("")

        #expect(m.isFiltering == false)
        #expect(StorageSearch.filter(records, with: m).count == 2)
        #expect(StorageSearch.collectMatches(in: records, with: m).isEmpty)
    }

    @Test("Plain search ignores case and looks at keys and values")
    func plainSearchMatchesKeysAndValues() {
        let byKey = StorageSearch.filter(records, with: matcher("devicemake"))
        #expect(byKey.map(\.key) == ["applicaster.v2"])

        let byValue = StorageSearch.filter(records, with: matcher("abc123"))
        #expect(byValue.map(\.key) == ["ZappPushPluginFirebase"])
    }

    @Test("A group name is searchable like anything else")
    func groupNameIsSearchable() {
        let hits = StorageSearch.filter(records, with: matcher("firebase"))

        #expect(hits.map(\.key) == ["ZappPushPluginFirebase"])
    }

    @Test("A search with no hits returns nothing")
    func noHitsReturnsEmpty() {
        #expect(StorageSearch.filter(records, with: matcher("nope")).isEmpty)
    }

    // MARK: Regex

    @Test("Regex mode matches two different keys at once")
    func regexMatchesAlternation() {
        // The reason regex mode exists, per the web guide.
        let m = matcher("device(Make|Name)", regex: true)
        let found = StorageSearch.collectMatches(in: records, with: m)

        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.ownerId == "applicaster.v2" })
    }

    @Test("The same text is literal in plain mode and a pattern in regex mode")
    func plainModeDoesNotInterpretPatterns() {
        let asPattern = matcher("device(Make|Name)", regex: true)
        let asText = matcher("device(Make|Name)", regex: false)

        #expect(StorageSearch.collectMatches(in: records, with: asPattern).count == 2)
        #expect(StorageSearch.collectMatches(in: records, with: asText).isEmpty)
    }

    @Test("A pattern that doesn't compile keeps the list on screen")
    func brokenPatternDoesNotEmptyTheList() {
        let m = matcher("device(", regex: true)

        #expect(m.isInvalid)
        #expect(m.isFiltering == false)
        // The box turns red, but the user doesn't lose their place.
        #expect(StorageSearch.filter(records, with: m).count == 2)
        #expect(StorageSearch.collectMatches(in: records, with: m).isEmpty)
    }

    // MARK: Match list

    @Test("Matches walk the groups in the order the list shows them")
    func matchesFollowTheDisplayedOrder() {
        // ▲ ▼ step through this array, so it has to track the list the
        // user is looking at — one contiguous run per group, groups in
        // display order. (That order is `parseTopLevel`'s Unicode sort,
        // which puts "Z" before "a" — not alphabetical as a reader
        // might assume, which is exactly why this is asserted against
        // `filter` rather than hard-coded.)
        let m = matcher("e")
        let found = StorageSearch.collectMatches(in: records, with: m)
        let displayed = StorageSearch.filter(records, with: m).map(\.id)

        #expect(found.count > displayed.count)

        let runs = found.map(\.ownerId).reduce(into: [String]()) { acc, owner in
            if acc.last != owner { acc.append(owner) }
        }
        #expect(runs == displayed)
    }
}
