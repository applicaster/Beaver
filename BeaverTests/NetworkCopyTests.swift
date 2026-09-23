//
//  NetworkCopyTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("NetworkCopy")
struct NetworkCopyTests {

    private func e(_ json: String) -> NetworkEntry { NetworkEntry.parse(json, fallbackMillis: 0)! }

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: cURL

    @Test
    func curlForGetWithoutBody() {
        let entry = e(#"{"url":"https://api.io/v1/feed?a=1","method":"GET"}"#)
        #expect(entry.curlCommand == "curl -X 'GET' 'https://api.io/v1/feed?a=1'")
    }

    @Test
    func curlForPostWithSortedHeadersAndBody() {
        let entry = e(#"""
        {"url":"https://api.io/login","method":"post",
         "requestHeaders":{"X-Token":"[REDACTED]","Accept":"application/json"},
         "requestBody":"{\"user\":\"a\"}"}
        """#)
        #expect(entry.curlCommand ==
            "curl -X 'POST' 'https://api.io/login' -H 'Accept: application/json' -H 'X-Token: [REDACTED]' --data-raw '{\"user\":\"a\"}'")
    }

    @Test
    func curlEscapesSingleQuotes() {
        let entry = e(#"{"url":"https://api.io/q?name=o'neil","method":"POST","requestBody":"it's"}"#)
        #expect(entry.curlCommand ==
            #"curl -X 'POST' 'https://api.io/q?name=o'\''neil' --data-raw 'it'\''s'"#)
    }

    @Test
    func curlQuotesAMethodContainingShellMetacharacters() {
        let entry = e(#"{"url":"https://api.io/x","method":"GET;rm x"}"#)
        #expect(entry.curlCommand == "curl -X 'GET;RM X' 'https://api.io/x'")
        #expect(entry.curlCommand.contains(";"))
    }

    // MARK: Request / response JSON

    @Test
    func requestJSONNestsAJSONBody() {
        let entry = e(#"""
        {"url":"https://api.io/login","method":"POST","requestHeaders":{"A":"1"},"requestBody":"{\"user\":\"a\"}"}
        """#)
        let o = object(entry.requestJSON)
        #expect(o["method"] as? String == "POST")
        #expect(o["url"] as? String == "https://api.io/login")
        #expect((o["headers"] as? [String: String]) == ["A": "1"])
        #expect((o["body"] as? [String: Any])?["user"] as? String == "a")
        #expect(entry.requestJSON.contains("\n"))   // pretty
    }

    @Test
    func requestJSONKeepsATextBodyAsString() {
        let entry = e(#"{"url":"https://api.io/x","method":"POST","requestBody":"a=1&b=2"}"#)
        #expect(object(entry.requestJSON)["body"] as? String == "a=1&b=2")
    }

    @Test
    func requestJSONOmitsAbsentFields() {
        let o = object(e(#"{"url":"https://api.io/x"}"#).requestJSON)
        #expect(Set(o.keys) == ["method", "url"])
    }

    @Test
    func responseJSONOmitsAbsentFields() {
        let ok = object(e(#"{"url":"https://api.io/x","status":200,"responseBody":"[1,2]"}"#).responseJSON)
        #expect(Set(ok.keys) == ["status", "body"])
        #expect(ok["status"] as? Int == 200)
        #expect(ok["body"] as? [Int] == [1, 2])

        let failed = object(e(#"{"url":"https://api.io/x","error":"offline"}"#).responseJSON)
        #expect(Set(failed.keys) == ["error"])
    }

    @Test
    func responseJSONIncludesEverythingPresent() {
        let o = object(e(#"""
        {"url":"https://api.io/x","status":403,"statusText":"no error","responseHeaders":{"B":"2"},"responseBody":"nope","error":"x"}
        """#).responseJSON)
        #expect(Set(o.keys) == ["status", "statusText", "headers", "body", "error"])
    }

    @Test
    func prettyPayloadJSONSortsAndIndents() {
        let entry = e(#"{"url":"https://api.io/x","method":"GET"}"#)
        #expect(entry.prettyPayloadJSON.contains("\n"))
        let methodAt = entry.prettyPayloadJSON.range(of: "\"method\"")!.lowerBound
        let urlAt = entry.prettyPayloadJSON.range(of: "\"url\"")!.lowerBound
        #expect(methodAt < urlAt)
        #expect(!entry.prettyPayloadJSON.contains(#"\/"#))
    }

    // MARK: Size and status line

    @Test
    func responseBytesCountsUTF8() {
        #expect(e(#"{"url":"https://api.io/x","responseBody":"é"}"#).responseBytes == 2)
        #expect(e(#"{"url":"https://api.io/x"}"#).responseBytes == nil)
        #expect(e(#"{"url":"https://api.io/x","responseBody":""}"#).responseBytes == nil)
    }

    @Test
    func statusLineReplacesNoErrorWithTheReason() {
        #expect(e(#"{"url":"https://api.io/x","status":403,"statusText":"no error"}"#).statusLine == "403 Forbidden")
        // Foundation's own reason for 200 is "no error" too.
        #expect(e(#"{"url":"https://api.io/x","status":200,"statusText":"no error"}"#).statusLine == "200 OK")
        #expect(e(#"{"url":"https://api.io/x","status":201,"statusText":"Made it"}"#).statusLine == "201 Made it")
    }

    @Test
    func statusLineForAnUnknownCodeShowsOnlyTheCode() {
        #expect(e(#"{"url":"https://api.io/x","status":299}"#).statusLine == "299")
    }

    @Test
    func statusLineForNSURLErrorCodes() {
        #expect(e(#"{"url":"https://api.io/x","status":-999,"error":"cancelled"}"#).statusLine == "-999 — cancelled")
        #expect(e(#"{"url":"https://api.io/x","status":-999}"#).statusLine == "-999")
    }

    @Test
    func statusLineWithoutStatus() {
        #expect(e(#"{"url":"https://api.io/x"}"#).statusLine == "—")
        #expect(e(#"{"url":"https://api.io/x","error":"offline"}"#).statusLine == "offline")
    }
}
