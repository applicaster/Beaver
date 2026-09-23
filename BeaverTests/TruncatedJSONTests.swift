//
//  TruncatedJSONTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("TruncatedJSON")
struct TruncatedJSONTests {

    private let marker = "... [TRUNCATED]"

    private func parsed(_ json: String?) -> Any? {
        json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    private func object(_ json: String?) -> [String: Any] { parsed(json) as? [String: Any] ?? [:] }

    @Test
    func cutAfterKeyColonDropsThatKey() {
        let o = object(TruncatedJSON.repair(#"{"a":1,"text_label_4_margin_top":"# + marker))
        #expect(o.count == 1)
        #expect(o["a"] as? Int == 1)
    }

    @Test
    func cutInsideStringValueDropsThePair() {
        let o = object(TruncatedJSON.repair(#"{"a":"done","b":"half-writ"# + marker))
        #expect(o.keys.sorted() == ["a"])
        #expect(o["a"] as? String == "done")
    }

    @Test
    func cutInsideUnicodeEscape() {
        let o = object(TruncatedJSON.repair(#"{"a":true,"b":"x\u12"# + marker))
        #expect(o.keys.sorted() == ["a"])
        #expect(o["a"] as? Bool == true)
    }

    @Test
    func cutInsideEscapedPathLikeTheSDKTail() {
        let text = #"{"n":1,"extra_dependencies":[{"OfflineContent":":path => '.\/node_modules\/@applicaster\"#
        let o = object(TruncatedJSON.repair(text + marker))
        #expect(o["n"] as? Int == 1)
        #expect((o["extra_dependencies"] as? [Any]) != nil)
    }

    @Test
    func cutAfterCommaInArrayKeepsCompleteElements() {
        #expect(parsed(TruncatedJSON.repair("[1,2,\"three\"," + marker)) as? [AnyHashable] == [1, 2, "three"])
    }

    @Test
    func trailingNumberAtTheCutIsDropped() {
        // "12" may be the start of "123": not provably complete.
        #expect(parsed(TruncatedJSON.repair("[1,12")) as? [Int] == [1])
    }

    @Test
    func nestedCutKeepsEarlierValues() {
        let text = #"""
        {"meta":{"v":2,"tags":["a","b"]},
         "items":[{"id":1,"sub":{"x":[10,20]}},{"id":2,"sub":{"x":[30,
        """#
        let o = object(TruncatedJSON.repair(text + marker))
        let meta = o["meta"] as? [String: Any]
        #expect(meta?["v"] as? Int == 2)
        #expect(meta?["tags"] as? [String] == ["a", "b"])
        let items = o["items"] as? [[String: Any]]
        #expect(items?.count == 2)
        #expect((items?[0]["sub"] as? [String: Any])?["x"] as? [Int] == [10, 20])
        #expect(items?[1]["id"] as? Int == 2)
        #expect((items?[1]["sub"] as? [String: Any])?["x"] as? [Int] == [30])
    }

    @Test
    func validJSONWithMarkerParsesUnchanged() {
        let text = #"{"a":[1,{"b":null}],"c":"}]\""}"#
        let repaired = TruncatedJSON.repair(text + marker)
        #expect(repaired == text)
    }

    @Test
    func notJSONIsNil() {
        #expect(TruncatedJSON.repair("<html><body>" + marker) == nil)
        #expect(TruncatedJSON.repair(#""just a string"#) == nil)
        #expect(TruncatedJSON.repair("") == nil)
    }

    @Test
    func realisticBodyCutAt100kChars() {
        let items = (0..<2_000).map { i -> [String: Any] in
            ["id": i, "title": "Item \(i) \u{e9}\u{1F600}", "path": "./node_modules/@applicaster/x\(i)",
             "flags": [true, false, NSNull()], "nested": ["depth": ["n": Double(i) / 3]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["items": items, "count": items.count])
        let full = String(decoding: data, as: UTF8.self)
        #expect(full.count > 150_000)
        let body = String(full.prefix(100_000)) + marker
        let o = object(TruncatedJSON.repair(body))
        let kept = o["items"] as? [[String: Any]]
        #expect((kept?.count ?? 0) > 100)
        #expect(kept?.first?["title"] as? String == "Item 0 \u{e9}\u{1F600}")
    }
}
