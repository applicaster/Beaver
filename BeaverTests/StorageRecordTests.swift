import Testing
import Foundation
@testable import BeaverCore

/// The tree model is shared by the log detail pane and the storage
/// inspector, and its serializer backs every "copy as JSON" action — so
/// a round trip has to come back unchanged.
@Suite("StorageRecord")
struct StorageRecordTests {

    /// Serialize a parsed record and read it back as a plain Foundation
    /// object, so the comparison is about structure rather than spacing.
    private func asDictionary(_ json: String) throws -> NSDictionary {
        let data = try #require(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? NSDictionary)
    }

    private func roundTrip(_ json: String) throws -> NSDictionary {
        let record = try #require(StorageRecord.parse(json))
        return try asDictionary(StorageRecord.serializeJSON(record))
    }

    @Test("A document survives parse → serialize unchanged")
    func roundTripPreservesStructure() throws {
        let json = """
        {"name":"beaver","count":3,"ok":true,"missing":null,\
        "nested":{"a":[1,2,{"b":"c"}]},"quotes":"he said \\"hi\\"\\\\"}
        """
        let original = try asDictionary(json)
        let result = try roundTrip(json)

        #expect(result == original)
    }

    @Test("Empty containers stay containers")
    func emptyContainersSerializeAsThemselves() throws {
        let result = try roundTrip(#"{"obj":{},"arr":[]}"#)

        #expect(result["obj"] as? NSDictionary == NSDictionary())
        #expect((result["arr"] as? NSArray)?.count == 0)
    }

    @Test("A stored JSON string is kept as a string")
    func jsonStringIsNotAutoExpanded() throws {
        // The raw string has to survive parsing: copy and edit act on it,
        // and the Raw tab shows it verbatim. Decoding happens at render
        // time instead, via LeafDecoder.
        let records = StorageRecord.parseTopLevel(
            #"{"featureFlags":"{\"premium\":true}"}"#
        )
        let flags = try #require(records.first)

        #expect(flags.children == nil)
        #expect(flags.valueText == #"{"premium":true}"#)
        guard case .string = flags.kind else {
            Issue.record("expected a string leaf, got \(flags.kind)")
            return
        }
    }

    @Test("An object key that looks like an array index stays an object key")
    func arrayLikeKeyDoesNotBecomeAnArray() throws {
        // Guards the old serializer, which decided array-vs-object by
        // checking whether every child key was shaped like `[0]`.
        let result = try roundTrip(#"{"weird":{"[0]":"x"}}"#)

        let weird = try #require(result["weird"] as? NSDictionary)
        #expect(weird["[0]"] as? String == "x")
    }
}

/// The include → exclude → off cycle behind the Subsystem / Category
/// chips. A value must never sit in both sets at once, which is the
/// invariant the SQL relies on.
@Suite("Filter chips")
struct FilterChipTests {

    @Test("A click advances include → exclude → off")
    func clickCyclesThroughThreeStates() {
        var filter = Filter.none
        #expect(filter.state(of: "Player", in: .subsystem) == .off)

        filter.cycle("Player", in: .subsystem)
        #expect(filter.state(of: "Player", in: .subsystem) == .include)

        filter.cycle("Player", in: .subsystem)
        #expect(filter.state(of: "Player", in: .subsystem) == .exclude)

        filter.cycle("Player", in: .subsystem)
        #expect(filter.state(of: "Player", in: .subsystem) == .off)
        #expect(filter.isEmpty)
    }

    @Test("A value is never included and excluded at once")
    func statesAreMutuallyExclusive() {
        var filter = Filter.none
        filter.set(.include, for: "Player", in: .subsystem)
        filter.set(.exclude, for: "Player", in: .subsystem)

        #expect(filter.subsystems.isEmpty)
        #expect(filter.excludedSubsystems == ["Player"])
    }

    @Test("The two facets don't interfere")
    func facetsAreIndependent() {
        var filter = Filter.none
        filter.set(.include, for: "Player", in: .subsystem)
        filter.set(.exclude, for: "Player", in: .category)

        #expect(filter.state(of: "Player", in: .subsystem) == .include)
        #expect(filter.state(of: "Player", in: .category) == .exclude)
        #expect(filter.chipCount(for: .subsystem) == 1)
        #expect(filter.chipCount(for: .category) == 1)
    }

    @Test("Clearing one facet leaves the other alone")
    func clearingIsScopedToOneFacet() {
        var filter = Filter.none
        filter.set(.include, for: "Player", in: .subsystem)
        filter.set(.include, for: "Heartbeat", in: .category)

        filter.clearChips(in: .subsystem)

        #expect(filter.chipCount(for: .subsystem) == 0)
        #expect(filter.chipCount(for: .category) == 1)
        #expect(filter.isEmpty == false)
    }
}

@Suite("StorageRecord — storage screen")
struct StorageScreenRecordTests {

    @Test("A key with no namespace arrives wrapped in `undefined` and is shown as a plain key")
    func undefinedWrapperIsUnwrapped() throws {
        let rows = StorageRecord.parseTopLevel(#"{"player-storage":{"undefined":"{\"a\":1}"},"ns":{"undefined":1,"b":2}}"#)
        let player = try #require(rows.first { $0.key == "player-storage" })
        #expect(player.children == nil)
        #expect(player.valueText == #"{"a":1}"#)
        // A real namespace that happens to hold an `undefined` key stays a namespace.
        let ns = try #require(rows.first { $0.key == "ns" })
        #expect(ns.children?.count == 2)
    }

    @Test("JSON 0 and 1 stay numbers; only true/false are booleans")
    func numbersAreNotBooleans() throws {
        let rows = StorageRecord.parseTopLevel(#"{"one":1,"zero":0,"yes":true}"#)
        #expect(rows.first { $0.key == "one" }?.kind == .number("1"))
        #expect(rows.first { $0.key == "zero" }?.kind == .number("0"))
        #expect(rows.first { $0.key == "yes" }?.kind == .bool(true))
    }

    @Test("Only new or changed rows are reported, and their namespace with them")
    func changedRowIds() {
        let old = StorageRecord.parseTopLevel(#"{"ns":{"a":"1","b":"2"},"top":"x","same":{"c":"3"}}"#)
        let new = StorageRecord.parseTopLevel(#"{"ns":{"a":"1","b":"9","d":"4"},"top":"x","same":{"c":"3"},"fresh":"y"}"#)
        #expect(StorageRecord.changedRowIds(from: old, to: new) == ["ns", "ns.b", "ns.d", "fresh"])
        #expect(StorageRecord.changedRowIds(from: new, to: new).isEmpty)
    }
}
