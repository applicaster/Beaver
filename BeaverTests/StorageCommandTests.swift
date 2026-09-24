import Testing
import Foundation
@testable import BeaverCore

@Suite("StorageCommand")
struct StorageCommandTests {

    // MARK: - Command text

    @Test
    func buildsSetAndDelete() {
        #expect(StorageCommand.set(.keychain, key: " token ", value: "abc", parent: nil)
                == "storage.secure.set token abc")
        #expect(StorageCommand.set(.local, key: "k", value: "v", parent: " applicaster.v2 ")
                == "storage.local.set k v applicaster.v2")
        #expect(StorageCommand.set(.local, key: "k", value: "v", parent: "  ")
                == "storage.local.set k v")
        #expect(StorageCommand.delete(.session, key: "k", parent: "ns")
                == "storage.session.delete k ns")
        #expect(StorageCommand.delete(.session, key: "k", parent: nil)
                == "storage.session.delete k")
    }

    @Test
    func supportFollowsCmdlistNames() {
        let names = ["storage.local.set", "storage.local.delete", "storage.secure.set"]
        #expect(StorageCommand.isSupported(.set, in: .local, by: names))
        #expect(StorageCommand.isSupported(.set, in: .keychain, by: names))
        #expect(!StorageCommand.isSupported(.delete, in: .keychain, by: names))
        #expect(!StorageCommand.isSupported(.set, in: .session, by: names))
        // No cmdlist reply yet: don't hide anything on a guess.
        #expect(StorageCommand.isSupported(.delete, in: .session, by: []))
    }

    // MARK: - Wire value

    @Test
    func jsonIsSentCompact() {
        let pretty = """
        {
          "title" : "Hello World",
          "n": [1, 2.50, { }]
        }
        """
        #expect(StorageCommand.wireValue(pretty) == #"{"title":"Hello World","n":[1,2.50,{}]}"#)
        // Not JSON: left exactly as typed.
        #expect(StorageCommand.wireValue(" plain text ") == " plain text ")
        #expect(StorageCommand.wireValue("{ broken") == "{ broken")
    }

    @Test
    func plainValueWithSpacesIsBlockedWithTheActualOutcome() {
        let problem = StorageCommand.valueProblem("a b c", parent: "ns")
        #expect(problem == #"The device splits commands on spaces: it would store "a" in a namespace named "b" and ignore "c ns"."#)
        #expect(StorageCommand.valueProblem("a b", parent: nil)
                == #"The device splits commands on spaces: it would store "a" in a namespace named "b"."#)
    }

    @Test
    func jsonWithSpacesInsideStringsIsBlockedWithAnExplanation() {
        let wire = StorageCommand.wireValue(#"{ "title": "Hello World" }"#)
        let problem = StorageCommand.valueProblem(wire, parent: nil)
        #expect(problem == #"A JSON string here contains a space, which can't be sent: the device splits commands on spaces, so it would store "{"title":"Hello" in a namespace named "World"}"."#)
    }

    @Test
    func tabsAndLineBreaksAreBlocked() {
        #expect(StorageCommand.valueProblem("a\nb", parent: nil)
                == "Tabs and line breaks can't be sent in a storage command. Remove them.")
    }

    @Test
    func sendableValuesPass() {
        #expect(StorageCommand.valueProblem(#"{"a":"b"}"#, parent: "ns") == nil)
        #expect(StorageCommand.valueProblem("true", parent: nil) == nil)
    }

    @Test
    func emptyOrEdgeWhitespaceValueIsBlocked() {
        #expect(StorageCommand.valueProblem("", parent: nil) != nil)
        #expect(StorageCommand.valueProblem("   ", parent: nil) != nil)
        #expect(StorageCommand.valueProblem(" a", parent: nil)
                == #"The device drops surrounding spaces: it would store "a"."#)
    }

    // MARK: - Reading back

    @Test
    func findsStoredValueTopLevelAndInsideNamespace() {
        let records = StorageRecord.parseTopLevel(#"""
        {"ns": {"k": "v", "n": 5, "o": {"x": 1}}, "applicaster.v2": {"k": "default"}, "flat": {"undefined": "top"}}
        """#)
        #expect(StorageCommand.storedValue(in: records, parent: "ns", key: "k") == "v")
        #expect(StorageCommand.storedValue(in: records, parent: "ns", key: "n") == "5")
        #expect(StorageCommand.storedValue(in: records, parent: "ns", key: "missing") == nil)
        // No namespace: both SDKs write into `applicaster.v2`.
        #expect(StorageCommand.storedValue(in: records, parent: nil, key: "k") == "default")
        #expect(StorageCommand.storedValue(in: records, parent: nil, key: "flat") == nil)
        #expect(StorageCommand.storedValue(in: records, parent: "ns", key: "o") != nil)
    }

    @Test
    func sentAndStoredMatchIgnoringJSONFormatting() {
        #expect(StorageCommand.matches(stored: "v", sent: "v"))
        #expect(!StorageCommand.matches(stored: "v", sent: "w"))
        #expect(StorageCommand.matches(stored: nil, sent: nil))
        #expect(!StorageCommand.matches(stored: "v", sent: nil))
        #expect(StorageCommand.matches(stored: "{\n  \"b\": 1,\n  \"a\": 2\n}", sent: #"{"a":2,"b":1}"#))
    }
}

@Suite("JSONText")
struct JSONTextTests {

    @Test
    func compactKeepsOrderNumbersAndStrings() {
        #expect(JSONText.compact(#"{ "b" : 0.80, "a" : "x  y\" z" }"#) == #"{"b":0.80,"a":"x  y\" z"}"#)
        #expect(JSONText.compact("[ ]") == "[]")
        #expect(JSONText.compact("5") == nil)
        #expect(JSONText.compact("{ nope") == nil)
    }

    @Test
    func prettyIndentsTwoSpaces() {
        #expect(JSONText.pretty(#"{"a":[1,{}],"b":"c, d"}"#) == """
        {
          "a": [
            1,
            {}
          ],
          "b": "c, d"
        }
        """)
        #expect(JSONText.pretty("[]") == "[]")
        #expect(JSONText.pretty("hello") == nil)
    }

    @Test
    func validation() {
        #expect(JSONText.looksLikeJSON("  {\"a\":1}"))
        #expect(JSONText.looksLikeJSON("[1"))
        #expect(!JSONText.looksLikeJSON("abc"))
        #expect(JSONText.isValid("{\"a\":1}"))
        #expect(!JSONText.isValid("[1"))
    }
}
