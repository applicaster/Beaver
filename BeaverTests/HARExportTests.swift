//
//  HARExportTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("HARExport")
struct HARExportTests {

    private func e(_ json: String) -> NetworkEntry { NetworkEntry.parse(json, fallbackMillis: 0)! }

    /// Encodes, re-parses with JSONSerialization and returns `log`.
    private func log(_ entries: [NetworkEntry]) throws -> [String: Any] {
        let data = try HARExport.encode(entries, creatorVersion: "1.2.3")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["log"] as? [String: Any])
    }

    private func firstEntry(_ entry: NetworkEntry) throws -> [String: Any] {
        let entries = try #require(try log([entry])["entries"] as? [[String: Any]])
        return try #require(entries.first)
    }

    private var get: NetworkEntry {
        e(#"{"url":"https://api.io/v1/feed?page=2&q=a%20b","method":"GET","status":200,"statusText":"no error","timing":{"startTime":1700000000123,"duration":42},"requestHeaders":{"b-header":"2","Accept":"*/*","X-Trace":"1"},"responseHeaders":{"content-type":"application/json","Location":"https://api.io/next"},"responseBody":"{\"ok\":true}"}"#)
    }

    @Test
    func topLevelShape() throws {
        let other = e(#"{"url":"https://b.io/","method":"POST","status":201}"#)
        let l = try log([get, other])
        #expect(l["version"] as? String == "1.2")
        let creator = try #require(l["creator"] as? [String: Any])
        #expect(creator["name"] as? String == "Beaver")
        #expect(creator["version"] as? String == "1.2.3")
        let entries = try #require(l["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        let urls = entries.compactMap { ($0["request"] as? [String: Any])?["url"] as? String }
        #expect(urls == ["https://api.io/v1/feed?page=2&q=a%20b", "https://b.io/"])

        let first = entries[0]
        #expect(first["time"] as? Int == 42)
        let timings = try #require(first["timings"] as? [String: Any])
        #expect(timings["wait"] as? Int == 42)
        #expect(timings["send"] as? Int == 0)
        #expect((first["cache"] as? [String: Any])?.isEmpty == true)

        let request = try #require(first["request"] as? [String: Any])
        #expect(request["method"] as? String == "GET")
        #expect(request["httpVersion"] as? String == "HTTP/1.1")
        #expect(request["headersSize"] as? Int == -1)
        #expect((request["cookies"] as? [Any])?.isEmpty == true)
        let query = try #require(request["queryString"] as? [[String: String]])
        #expect(query == [["name": "page", "value": "2"], ["name": "q", "value": "a b"]])

        let response = try #require(first["response"] as? [String: Any])
        #expect(response["status"] as? Int == 200)
        #expect(response["statusText"] as? String == "OK")
        #expect(response["redirectURL"] as? String == "https://api.io/next")
        #expect(response["bodySize"] as? Int == 11)
        let content = try #require(response["content"] as? [String: Any])
        #expect(content["mimeType"] as? String == "application/json")
        #expect(content["size"] as? Int == 11)
        #expect(content["text"] as? String == #"{"ok":true}"#)
    }

    @Test
    func getWithoutBodyHasNoPostData() throws {
        let request = try #require(try firstEntry(get)["request"] as? [String: Any])
        #expect(request["postData"] == nil)
        #expect(request["bodySize"] as? Int == 0)
    }

    @Test
    func postWithJSONBodyGetsItsMimeType() throws {
        let post = e(#"{"url":"https://api.io/login","method":"POST","status":200,"requestHeaders":{"CONTENT-TYPE":"application/json; charset=utf-8"},"requestBody":"{\"u\":\"a\"}"}"#)
        let request = try #require(try firstEntry(post)["request"] as? [String: Any])
        let postData = try #require(request["postData"] as? [String: Any])
        #expect(postData["mimeType"] as? String == "application/json; charset=utf-8")
        #expect(postData["text"] as? String == #"{"u":"a"}"#)
        #expect(request["bodySize"] as? Int == 9)

        let untyped = e(#"{"url":"https://api.io/raw","method":"PUT","requestBody":"xyz"}"#)
        let r2 = try #require(try firstEntry(untyped)["request"] as? [String: Any])
        #expect((r2["postData"] as? [String: Any])?["mimeType"] as? String == "application/octet-stream")
    }

    @Test
    func failedRequestGetsStatusZeroAndError() throws {
        let failed = e(#"{"url":"https://api.io/x","method":"GET","status":-1001,"error":"The request timed out."}"#)
        let entry = try firstEntry(failed)
        #expect(entry["_error"] as? String == "The request timed out.")
        #expect(entry["time"] as? Int == 0)
        let response = try #require(entry["response"] as? [String: Any])
        #expect(response["status"] as? Int == 0)
        #expect(response["statusText"] as? String == "")
        #expect(response["bodySize"] as? Int == -1)
        let content = try #require(response["content"] as? [String: Any])
        #expect(content["mimeType"] as? String == "x-unknown")
        #expect(content["text"] == nil)

        #expect(try firstEntry(get)["_error"] == nil)
    }

    @Test
    func startedDateTimeIsISO8601WithMilliseconds() throws {
        #expect(try firstEntry(get)["startedDateTime"] as? String == "2023-11-14T22:13:20.123Z")
        let whole = e(#"{"url":"https://a.io/","timing":{"startTime":1700000000000}}"#)
        #expect(try firstEntry(whole)["startedDateTime"] as? String == "2023-11-14T22:13:20.000Z")
    }

    @Test
    func headersAreSortedByName() throws {
        let request = try #require(try firstEntry(get)["request"] as? [String: Any])
        let headers = try #require(request["headers"] as? [[String: String]])
        #expect(headers.map { $0["name"] } == ["Accept", "X-Trace", "b-header"])
        #expect(headers.first?["value"] == "*/*")
    }
}
