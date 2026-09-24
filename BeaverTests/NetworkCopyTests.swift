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
        let pretty = NetworkEntry.prettyPayloadJSON(#"{"url":"https:\/\/api.io\/x","method":"GET"}"#)
        #expect(pretty.contains("\n"))
        let methodAt = pretty.range(of: "\"method\"")!.lowerBound
        let urlAt = pretty.range(of: "\"url\"")!.lowerBound
        #expect(methodAt < urlAt)
        #expect(!pretty.contains(#"\/"#))
        #expect(NetworkEntry.prettyPayloadJSON("not json") == "not json")
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

    // MARK: fetch snippet

    @Test
    func fetchForGetWithoutHeadersMatchesTheUsersExample() {
        let entry = e(#"{"url":"https://assets-production.applicaster.com/zapp/x/app_loader.json","method":"GET"}"#)
        #expect(entry.fetchSnippet == """
        fetch("https://assets-production.applicaster.com/zapp/x/app_loader.json", {
          method: "GET",
        });
        """)
    }

    @Test
    func fetchForPostWithSortedHeadersAndAnEscapedBody() {
        let entry = e(#"""
        {"url":"https://api.io/login","method":"POST",
         "requestHeaders":{"X-Token":"a\"b","Accept":"*/*"},
         "requestBody":"{\"user\":\"a\"}\nline2\\end"}
        """#)
        #expect(entry.fetchSnippet == #"""
        fetch("https://api.io/login", {
          method: "POST",
          headers: {
            "Accept": "*/*",
            "X-Token": "a\"b",
          },
          body: "{\"user\":\"a\"}\nline2\\end",
        });
        """#)
    }

    // MARK: Query parameters

    @Test
    func queryItemsArePercentDecoded() {
        let entry = e(#"{"url":"https://api.io/x?q=a%20b&n=1"}"#)
        #expect(entry.queryItems.map(\.name) == ["q", "n"])
        #expect(entry.queryItems.first?.value == "a b")
        #expect(entry.rawQuery == "q=a%20b&n=1")
        #expect(object(entry.queryJSON ?? "") as NSDictionary == ["q": "a b", "n": "1"] as NSDictionary)
    }

    @Test
    func aRepeatedKeyBecomesAnArrayAndKeysAreSorted() throws {
        let entry = e(#"{"url":"https://api.io/x?t=2&a&t=1"}"#)
        let json = try #require(entry.queryJSON)
        #expect(object(json)["t"] as? [String] == ["2", "1"])
        #expect(object(json)["a"] as? String == "")
        #expect(json.range(of: "\"a\"")!.lowerBound < json.range(of: "\"t\"")!.lowerBound)
    }

    @Test
    func aURLWithoutQueryHasNoQueryParameters() {
        let entry = e(#"{"url":"https://api.io/x"}"#)
        #expect(entry.queryItems.isEmpty)
        #expect(entry.rawQuery == nil)
        #expect(entry.queryJSON == nil)
    }

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Synthetic stand-in for the real `ctx` parameter: URL-safe Base64 of a
    /// JSON object holding an (expired, fake-signed) access token.
    @Test
    func ctxDecodesThroughBase64AndJSONToAnExpiredJWT() throws {
        let jwt = [#"{"alg":"HS256"}"#, #"{"exp": 1000000000}"#].map(Self.base64URL).joined(separator: ".") + ".c2ln"
        let ctx = Self.base64URL(#"{"quick-brick-login-flow.access_token": "\#(jwt)"}"#)
        #expect(!ctx.hasSuffix("="))
        let entry = e(#"{"url":"https://api.io/feed?ctx=\#(ctx)&asset_type=episodes"}"#)

        let query = object(try #require(entry.queryJSON))
        let ctxValue = try #require(query["ctx"] as? String)
        #expect(query["asset_type"] as? String == "episodes")

        let decoded = try #require(LeafDecoder.decode(ctxValue))
        #expect(decoded.kinds.first == .base64)
        #expect(decoded.kinds == [.base64, .json])
        let tree = try #require(decoded.tree)
        #expect(LeafDecoder.nestedJWTStatus(in: tree) == .expired)
        let token = try #require(tree.children?.first)
        #expect(token.key == "quick-brick-login-flow.access_token")
        guard case .string(let raw) = token.kind else { Issue.record("token is not a string"); return }
        #expect(LeafDecoder.decode(raw)?.chip == .expired)
    }

    @Test
    func urlSafeUnpaddedBase64WithDashesDecodes() throws {
        let value = Self.base64URL(#"{"note":"a?b>c~, a longer tail"}"#)
        #expect(value.contains("-") && value.count % 4 != 0)
        #expect(try #require(LeafDecoder.decode(value)).kinds == [.base64, .json])
    }

    // MARK: Truncation

    @Test
    func truncatedResponseBodyIsDetected() {
        #expect(e(#"{"url":"https://api.io/x","responseBody":"{\"a\":1... [TRUNCATED]"}"#).isResponseBodyTruncated)
        #expect(!e(#"{"url":"https://api.io/x","responseBody":"{\"a\":1}"}"#).isResponseBodyTruncated)
        #expect(!e(#"{"url":"https://api.io/x"}"#).isResponseBodyTruncated)
    }

    @Test
    func truncatedRequestBodyIsDetected() {
        #expect(e(#"{"url":"https://api.io/x","requestBody":"{\"a\":1... [TRUNCATED]"}"#).isRequestBodyTruncated)
        #expect(!e(#"{"url":"https://api.io/x","requestBody":"{\"a\":1}"}"#).isRequestBodyTruncated)
        #expect(!e(#"{"url":"https://api.io/x","responseBody":"x... [TRUNCATED]"}"#).isRequestBodyTruncated)
    }

    // MARK: Compact size

    @Test
    func compactSize() {
        #expect(NetworkEntry.compactSize(0) == "0 B")
        #expect(NetworkEntry.compactSize(237) == "237 B")
        #expect(NetworkEntry.compactSize(999) == "999 B")
        #expect(NetworkEntry.compactSize(4_200) == "4.2 KB")
        #expect(NetworkEntry.compactSize(9_960) == "10 KB")
        #expect(NetworkEntry.compactSize(42_400) == "42 KB")
        #expect(NetworkEntry.compactSize(100_015) == "100 KB")
        #expect(NetworkEntry.compactSize(999_700) == "1.0 MB")
        #expect(NetworkEntry.compactSize(1_500_000) == "1.5 MB")
        #expect(NetworkEntry.compactSize(25_000_000) == "25 MB")
    }

    // MARK: Real body size

    @Test
    func responseSizeReportedTakesPriorityOverEverything() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBodySize":312450,"responseBody":"short... [TRUNCATED]",
         "responseHeaders":{"Content-Length":"8197"}}
        """#)
        #expect(entry.responseSize == NetworkEntry.BodySize(bytes: 312450, source: .reported, isLowerBound: false))
    }

    @Test
    func responseSizeUsesContentLengthWhenTruncatedAndNoReportedSize() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"short... [TRUNCATED]","responseHeaders":{"Content-Length":"8197"}}
        """#)
        #expect(entry.responseSize == NetworkEntry.BodySize(bytes: 8197, source: .contentLength(encoding: nil), isLowerBound: false))
    }

    @Test
    func responseSizeContentLengthIsCaseInsensitive() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"short... [TRUNCATED]","responseHeaders":{"content-length":"8197"}}
        """#)
        #expect(entry.responseSize?.bytes == 8197)
    }

    @Test
    func responseSizeContentEncodingGzipIsReported() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"short... [TRUNCATED]",
         "responseHeaders":{"Content-Length":"8197","Content-Encoding":"gzip"}}
        """#)
        #expect(entry.responseSize?.source == .contentLength(encoding: "gzip"))
    }

    @Test
    func responseSizeContentEncodingBrIsReported() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"short... [TRUNCATED]",
         "responseHeaders":{"Content-Length":"8197","Content-Encoding":"br"}}
        """#)
        #expect(entry.responseSize?.source == .contentLength(encoding: "br"))
    }

    @Test
    func responseSizeContentEncodingIdentityMeansNoEncoding() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"short... [TRUNCATED]",
         "responseHeaders":{"Content-Length":"8197","Content-Encoding":"identity"}}
        """#)
        #expect(entry.responseSize?.source == .contentLength(encoding: nil))
    }

    @Test
    func responseSizeWithoutContentEncodingHeaderMeansNoEncoding() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"short... [TRUNCATED]","responseHeaders":{"Content-Length":"8197"}}
        """#)
        #expect(entry.responseSize?.source == .contentLength(encoding: nil))
    }

    @Test
    func responseSizeIgnoresContentLengthWhenNotTruncated() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"{\"a\":1}","responseHeaders":{"Content-Length":"999999"}}
        """#)
        #expect(entry.responseSize == NetworkEntry.BodySize(bytes: 7, source: .captured, isLowerBound: false))
    }

    @Test
    func responseSizeIgnoresNonNumericContentLength() {
        let entry = e(#"""
        {"url":"https://api.io/x","responseBody":"short... [TRUNCATED]","responseHeaders":{"Content-Length":"nope"}}
        """#)
        #expect(entry.responseSize?.source == .captured)
        #expect(entry.responseSize?.isLowerBound == true)
    }

    @Test
    func responseSizeCapturedWhenNoSizeInfoAtAll() {
        let entry = e(#"{"url":"https://api.io/x","responseBody":"{\"a\":1}"}"#)
        #expect(entry.responseSize == NetworkEntry.BodySize(bytes: 7, source: .captured, isLowerBound: false))
    }

    @Test
    func responseSizeIsNilWithNoBodyAndNoReportedSize() {
        #expect(e(#"{"url":"https://api.io/x"}"#).responseSize == nil)
        #expect(e(#"{"url":"https://api.io/x","responseBody":""}"#).responseSize == nil)
    }

    @Test
    func requestSizeReportedTakesPriority() {
        let entry = e(#"{"url":"https://api.io/x","requestBodySize":100,"requestBody":"ab"}"#)
        #expect(entry.requestSize == NetworkEntry.BodySize(bytes: 100, source: .reported, isLowerBound: false))
    }

    @Test
    func requestSizeNeverUsesContentLength() {
        // Request headers rarely carry Content-Length; even truncated, skip straight to captured.
        let entry = e(#"""
        {"url":"https://api.io/x","requestBody":"short... [TRUNCATED]","requestHeaders":{"Content-Length":"999999"}}
        """#)
        #expect(entry.requestSize?.source == .captured)
        #expect(entry.requestSize?.bytes == entry.requestBody?.utf8.count)
    }

    @Test
    func requestSizeIsNilWithNoBodyAndNoReportedSize() {
        #expect(e(#"{"url":"https://api.io/x"}"#).requestSize == nil)
    }

    // MARK: Short URL

    /// Synthetic stand-in for a long token.
    private static let ctx = String(repeating: "QUJDREVGR0g", count: 200)

    private func url(_ u: String) -> NetworkEntry { e(#"{"url":"\#(u)"}"#) }

    @Test
    func shortURLDropsTheQuery() {
        let entry = url("https://zapp-1.web.app/beacon/user-data/favorites?ctx=\(Self.ctx)&x=1")
        #expect(entry.shortURL == "https://zapp-1.web.app/beacon/user-data/favorites...")
    }

    @Test
    func shortURLWithoutQueryIsUnchanged() {
        let entry = url("https://api.io/v1/a%20b/feed")
        #expect(entry.shortURL == "https://api.io/v1/a%20b/feed")
    }

    @Test
    func shortURLKeepsThePort() {
        #expect(url("http://localhost:8080/api/items?page=2").shortURL == "http://localhost:8080/api/items...")
    }

    @Test
    func shortURLDropsAFragment() {
        #expect(url("https://docs.io/guide#section-2").shortURL == "https://docs.io/guide...")
    }

    @Test
    func shortURLOfUnparsableStringIsTheString() {
        #expect(url("http://[::1?q=1").shortURL == "http://[::1?q=1")
    }

    // MARK: Table colour helpers

    @Test
    func durationTiers() {
        #expect(NetworkEntry.DurationTier(millis: nil) == .normal)
        #expect(NetworkEntry.DurationTier(millis: 999) == .normal)
        #expect(NetworkEntry.DurationTier(millis: 1000) == .slow)
        #expect(NetworkEntry.DurationTier(millis: 2999) == .slow)
        #expect(NetworkEntry.DurationTier(millis: 3000) == .verySlow)
    }

    @Test
    func compactDurationSwitchesToSecondsFromOneSecond() {
        #expect(NetworkEntry.compactDuration(0) == "0 ms")
        #expect(NetworkEntry.compactDuration(830) == "830 ms")
        #expect(NetworkEntry.compactDuration(999) == "999 ms")
        #expect(NetworkEntry.compactDuration(1000) == "1.0 s")
        #expect(NetworkEntry.compactDuration(2266) == "2.3 s")
        #expect(NetworkEntry.compactDuration(15959) == "16.0 s")
        #expect(NetworkEntry.compactDuration(99_949) == "99.9 s")
        #expect(NetworkEntry.compactDuration(125_000) == "125 s")
    }

    @Test
    func sizeTiersGreyYellowRed() {
        // Grey under 50 KB, yellow 50–100 KB, red from 100 KB — which includes every body the SDK cut.
        #expect(e(#"{"url":"https://a.io","responseBody":"ok"}"#).tableSizeTier == .normal)
        #expect(e(#"{"url":"https://a.io"}"#).tableSizeTier == .normal)
        #expect(e(#"{"url":"https://a.io","responseBodySize":49999,"responseBody":"x"}"#).tableSizeTier == .normal)
        #expect(e(#"{"url":"https://a.io","responseBodySize":50000,"responseBody":"x"}"#).tableSizeTier == .attention)
        #expect(e(#"{"url":"https://a.io","responseBodySize":99999,"responseBody":"x"}"#).tableSizeTier == .attention)
        #expect(e(#"{"url":"https://a.io","responseBodySize":100000,"responseBody":"x"}"#).tableSizeTier == .critical)
        #expect(e(#"{"url":"https://a.io","responseBody":"{\"a\":1... [TRUNCATED]"}"#).tableSizeTier == .critical)
        #expect(e(#"{"url":"https://a.io","responseBodySize":5000,"responseBody":"x... [TRUNCATED]"}"#).tableSizeTier == .normal)
    }

    @Test
    func headersSortIgnoringCase() {
        let rows = NetworkEntry.sortedHeaders(["x-b": "2", "Content-Type": "j", "Accept": "a", "age": "1"])
        #expect(rows.map(\.name) == ["Accept", "age", "Content-Type", "x-b"])
        #expect(rows.map(\.value) == ["a", "1", "j", "2"])
    }
}
