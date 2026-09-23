import Testing
@testable import BeaverCore

@Suite("JSONFieldPatch")
struct JSONFieldPatchTests {

    @Test("Edits a field and keeps its type")
    func setKeepsType() {
        #expect(JSONFieldPatch.setting(".volume", to: "0.5", in: #"{"volume":0.8,"muted":false}"#)
                == #"{"muted":false,"volume":0.5}"#)
        // A string field stays a string even when the text looks like a number.
        #expect(JSONFieldPatch.setting(".lang", to: "42", in: #"{"lang":"en"}"#) == #"{"lang":"42"}"#)
        // Untouched numbers keep their short form (0.8, not 0.80000000000000004).
        #expect(JSONFieldPatch.setting(".muted", to: "true", in: #"{"volume":0.8,"muted":false,"url":"a/b \"q\""}"#)
                == #"{"muted":true,"url":"a/b \"q\"","volume":0.8}"#)
        // A non-string field that isn't valid JSON becomes a string.
        #expect(JSONFieldPatch.setting(".n", to: "abc", in: #"{"n":1}"#) == #"{"n":"abc"}"#)
    }

    @Test("Reaches nested objects and array items by tree id")
    func nested() {
        let json = #"{"a":{"b":[1,{"c":"x"}]}}"#
        #expect(JSONFieldPatch.setting(".a.b[1].c", to: "y", in: json) == #"{"a":{"b":[1,{"c":"y"}]}}"#)
        #expect(JSONFieldPatch.removing(".a.b[0]", in: json) == #"{"a":{"b":[{"c":"x"}]}}"#)
        #expect(JSONFieldPatch.removing(".a", in: json) == "{}")
    }

    @Test("Fails instead of guessing")
    func failures() {
        #expect(JSONFieldPatch.setting(".missing", to: "1", in: #"{"a":1}"#) == nil)
        #expect(JSONFieldPatch.removing(".a", in: "not json") == nil)
        #expect(JSONFieldPatch.removing(".a", in: #""just a string""#) == nil)
    }

    @Test("Ids match the tree LeafDecoder builds")
    func idsMatchDecodedTree() throws {
        let raw = #"{"list":[{"on":true}]}"#
        let tree = try #require(LeafDecoder.decode(raw)?.tree)
        let leaf = try #require(tree.allDescendants().first { $0.key == "on" })
        #expect(JSONFieldPatch.setting(leaf.id, to: "false", in: raw) == #"{"list":[{"on":false}]}"#)
    }
}
