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
    func contentSizeUsesTheReportedSizeOverTheCapturedOne() throws {
        let truncated = e(#"""
        {"url":"https://api.io/x","status":200,"responseBodySize":312450,"responseBody":"short... [TRUNCATED]"}
        """#)
        let truncatedResponse = try #require(try firstEntry(truncated)["response"] as? [String: Any])
        let content = try #require(truncatedResponse["content"] as? [String: Any])
        #expect(content["size"] as? Int == 312450)
        // bodySize (unrelated field) still reflects what was actually captured.
        #expect(truncatedResponse["bodySize"] as? Int == truncated.responseBody?.utf8.count)

        // No reported size: falls back to the captured body's length.
        let getResponse = try #require(try firstEntry(get)["response"] as? [String: Any])
        let getContent = try #require(getResponse["content"] as? [String: Any])
        #expect(getContent["size"] as? Int == get.responseBody?.utf8.count)
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

    // MARK: Decode

    @Test
    func encodeThenDecodeRoundTrips() throws {
        let post = e(#"{"url":"https://api.io/login?x=1","method":"POST","status":201,"statusText":"Created","timing":{"startTime":1700000000456,"duration":87},"requestHeaders":{"Content-Type":"application/json"},"requestBody":"{\"u\":\"a\"}","responseHeaders":{"Content-Type":"text/plain"},"responseBody":"hello"}"#)
        let failed = e(#"{"url":"https://api.io/x","method":"GET","timing":{"startTime":1700000001000,"duration":5},"error":"offline"}"#)
        let data = try HARExport.encode([get, post, failed], creatorVersion: "1")

        let back = HARExport.decode(data)

        #expect(back.map(\.url) == [get.url, post.url, failed.url])
        #expect(back.map(\.method) == ["GET", "POST", "GET"])
        #expect(back.map(\.status) == [200, 201, nil])
        #expect(back.map(\.startMillis) == [1700000000123, 1700000000456, 1700000001000])
        #expect(back.map(\.durationMillis) == [42, 87, 5])
        #expect(back[1].requestBody == #"{"u":"a"}"#)
        #expect(back[1].responseBody == "hello")
        #expect(back[1].statusText == "Created")
        #expect(back[1].requestHeaders == ["Content-Type": "application/json"])
        #expect(back[0].responseBody == #"{"ok":true}"#)
        #expect(back[0].requestBody == nil)
        #expect(back[2].error == "offline")
    }

    @Test
    func encodeThenDecodeRoundTripsTheReportedBodySizes() throws {
        let entry = e(#"""
        {"url":"https://api.io/x","method":"POST","status":200,
         "requestBodySize":9,"requestBody":"{\"u\":\"a\"}",
         "responseBodySize":312450,"responseBody":"short... [TRUNCATED]"}
        """#)
        let data = try HARExport.encode([entry], creatorVersion: "1")
        let back = try #require(HARExport.decode(data).first)
        #expect(back.requestBodySize == 9)
        #expect(back.responseBodySize == 312450)
    }

    @Test
    func decodesMinimalChromeHAR() {
        let har = #"""
        {"log":{"version":"1.2","creator":{"name":"WebInspector","version":"537.36"},"pages":[],
         "entries":[{"startedDateTime":"2024-03-01T10:20:30.5Z","time":123.456,
          "request":{"method":"GET","url":"https://cdn.io/a.js","httpVersion":"http/2.0",
                     "headers":[{"name":":authority","value":"cdn.io"},{"name":"accept","value":"*/*"}],
                     "queryString":[],"cookies":[],"headersSize":-1,"bodySize":0},
          "response":{"status":304,"statusText":"","httpVersion":"http/2.0",
                      "headers":[{"name":"etag","value":"abc"}],"cookies":[],
                      "content":{"size":0,"mimeType":"x-unknown"},"redirectURL":"","headersSize":-1,"bodySize":0},
          "cache":{},"timings":{"send":0.1,"wait":120,"receive":3.3}},
          {"startedDateTime":"not a date","request":{"method":"GET"},"response":{}}]}}
        """#
        let entries = HARExport.decode(Data(har.utf8))
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.url == "https://cdn.io/a.js")
        #expect(entry.status == 304)
        #expect(entry.statusText == nil)
        #expect(entry.durationMillis == 123)
        #expect(entry.startMillis == 1709288430500)
        #expect(entry.requestHeaders["accept"] == "*/*")
        #expect(entry.responseHeaders == ["etag": "abc"])
        #expect(entry.responseBody == nil)
    }

    @Test
    func decodeDecodesBase64ContentTextWhenItIsValidUTF8() {
        // "hello world" base64-encoded, as a browser HAR would write a
        // text response under content.encoding == "base64".
        let har = #"""
        {"log":{"entries":[{"request":{"method":"GET","url":"https://a.io/"},
         "response":{"content":{"text":"aGVsbG8gd29ybGQ=","encoding":"base64"}}}]}}
        """#
        let entries = HARExport.decode(Data(har.utf8))
        #expect(entries.first?.responseBody == "hello world")
    }

    @Test
    func decodeKeepsRawTextWhenBase64DoesNotDecodeToUTF8() {
        // Not valid base64 at all — kept as-is rather than dropped.
        let notBase64 = #"""
        {"log":{"entries":[{"request":{"method":"GET","url":"https://a.io/"},
         "response":{"content":{"text":"not base64 !!","encoding":"base64"}}}]}}
        """#
        #expect(HARExport.decode(Data(notBase64.utf8)).first?.responseBody == "not base64 !!")

        // Valid base64 but binary (invalid UTF-8) — kept as the raw base64
        // text rather than turned into mojibake.
        let binary = #"""
        {"log":{"entries":[{"request":{"method":"GET","url":"https://a.io/"},
         "response":{"content":{"text":"/////w==","encoding":"base64"}}}]}}
        """#
        #expect(HARExport.decode(Data(binary.utf8)).first?.responseBody == "/////w==")
    }

    @Test
    func decodeRejectsNonHAR() {
        #expect(HARExport.decode(Data(#"{"events":[]}"#.utf8)).isEmpty)
        #expect(HARExport.decode(Data("nope".utf8)).isEmpty)
        // Out-of-range values don't trap; the entry keeps its URL.
        let odd = #"{"log":{"entries":[{"startedDateTime":"1900-01-01T00:00:00Z","time":1e300,"request":{"url":"https://a.io/"}}]}}"#
        let entries = HARExport.decode(Data(odd.utf8))
        #expect(entries.map(\.url) == ["https://a.io/"])
        #expect(entries.first?.durationMillis == nil)
    }
}
