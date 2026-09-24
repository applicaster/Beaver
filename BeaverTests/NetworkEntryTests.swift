//
//  NetworkEntryTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("NetworkEntry")
struct NetworkEntryTests {

    // Shape emitted by quick-brick-xray iOS (WebSocketSink+NetworkEvent.swift).
    // Note the `\/` — JSONSerialization escapes slashes.
    static let ios = """
    {"requestId":"R1","url":"https:\\/\\/api.example.com\\/v1\\/feed?page=2","method":"GET",
     "timing":{"startTime":1715784000000,"endTime":1715784000250,"duration":250},
     "timestamp":1715784000000,"status":200,"statusText":"no error",
     "requestHeaders":{"Authorization":"[REDACTED]","Accept":"application\\/json"},
     "responseHeaders":{"Content-Type":"application\\/json"},
     "responseBody":"{\\"items\\":[1,2]}"}
    """

    @Test
    func parsesIOSPayload() throws {
        let e = try #require(NetworkEntry.parse(Self.ios, fallbackMillis: 0))
        #expect(e.requestId == "R1")
        #expect(e.url == "https://api.example.com/v1/feed?page=2")
        #expect(e.method == "GET")
        #expect(e.status == 200)
        #expect(e.statusText == "no error")
        #expect(e.startMillis == 1715784000000)
        #expect(e.durationMillis == 250)
        #expect(e.requestHeaders["Authorization"] == "[REDACTED]")
        #expect(e.responseBody == "{\"items\":[1,2]}")
        #expect(e.host == "api.example.com")
        #expect(e.path == "/v1/feed?page=2")
        #expect(e.statusClass == .success)
        #expect(NetworkCapture(Self.ios, fallbackMillis: 0)?.payloadJSON == Self.ios)
    }

    @Test
    func parsesTransportFailureWithoutStatus() throws {
        let json = #"{"url":"https://x.io/a","method":"post","timing":{"startTime":5,"duration":60000},"error":"The request timed out."}"#
        let e = try #require(NetworkEntry.parse(json, fallbackMillis: 0))
        #expect(e.status == nil)
        #expect(e.method == "POST")
        #expect(e.error == "The request timed out.")
        #expect(e.statusClass == .failed)
    }

    @Test
    func missingTimingFallsBackToTimestamp() throws {
        let withTs = try #require(NetworkEntry.parse(#"{"url":"https://x.io","timestamp":42}"#, fallbackMillis: 7))
        #expect(withTs.startMillis == 42)
        #expect(withTs.durationMillis == nil)
        #expect(withTs.method == "GET")

        let bare = try #require(NetworkEntry.parse(#"{"url":"https://x.io"}"#, fallbackMillis: 7))
        #expect(bare.startMillis == 7)
    }

    @Test
    func durationComputedFromEndWhenMissing() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","timing":{"startTime":100,"endTime":130}}"#, fallbackMillis: 0))
        #expect(e.durationMillis == 30)
    }

    @Test
    func zeroDurationIsKept() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","timing":{"startTime":1,"duration":0}}"#, fallbackMillis: 0))
        #expect(e.durationMillis == 0)
    }

    @Test(arguments: [
        (#""404""#, 404),     // numeric string (lenient, e.g. future Android)
        ("503", 503),
    ])
    func statusAcceptsNumberOrNumericString(raw: String, expected: Int) throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","status":\#(raw)}"#, fallbackMillis: 0))
        #expect(e.status == expected)
    }

    @Test
    func booleanStatusIsRejected() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","status":true}"#, fallbackMillis: 0))
        #expect(e.status == nil)
    }

    @Test(arguments: [
        (200, NetworkEntry.StatusClass.success), (301, .redirect),
        (404, .clientError), (500, .serverError), (101, .other),
        // iOS sends NSURLError codes as status: cancelled, offline.
        (-999, .failed), (-1009, .failed), (0, .failed),
    ])
    func statusClassBuckets(status: Int, expected: NetworkEntry.StatusClass) throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","status":\#(status)}"#, fallbackMillis: 0))
        #expect(e.statusClass == expected)
    }

    @Test(arguments: [#"{"method":"GET"}"#, "[]", "not json", #"{"url":42}"#])
    func rejectsPayloadWithoutURL(json: String) {
        #expect(NetworkEntry.parse(json, fallbackMillis: 0) == nil)
    }

    @Test
    func nonStringHeaderValuesAreStringified() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","responseHeaders":{"Content-Length":123}}"#, fallbackMillis: 0))
        #expect(e.responseHeaders["Content-Length"] == "123")
    }

    // MARK: Body size

    @Test(arguments: [
        (#"312450"#, 312450),      // number
        (#""312450""#, 312450),    // numeric string, lenient like status
    ])
    func bodySizeAcceptsNumberOrNumericString(raw: String, expected: Int) throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","requestBodySize":\#(raw),"responseBodySize":\#(raw)}"#, fallbackMillis: 0))
        #expect(e.requestBodySize == expected)
        #expect(e.responseBodySize == expected)
    }

    @Test
    func negativeBodySizeIsRejected() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","requestBodySize":-1,"responseBodySize":-5}"#, fallbackMillis: 0))
        #expect(e.requestBodySize == nil)
        #expect(e.responseBodySize == nil)
    }

    @Test
    func booleanBodySizeIsRejected() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u","responseBodySize":true}"#, fallbackMillis: 0))
        #expect(e.responseBodySize == nil)
    }

    @Test
    func absentBodySizeIsNil() throws {
        let e = try #require(NetworkEntry.parse(#"{"url":"u"}"#, fallbackMillis: 0))
        #expect(e.requestBodySize == nil)
        #expect(e.responseBodySize == nil)
    }

    @Test
    func nonStringBodiesAreStringifiedNotDropped() throws {
        let json = #"{"url":"https://a.io/x","requestBody":{"b":[1,2],"a":"x/y"},"responseBody":[true,null]}"#
        let e = try #require(NetworkEntry.parse(json, fallbackMillis: 0))
        #expect(e.requestBody == #"{"a":"x/y","b":[1,2]}"#)
        #expect(e.responseBody == "[true,null]")

        let scalars = try #require(NetworkEntry.parse(
            #"{"url":"https://a.io/x","requestBody":42,"responseBody":true}"#, fallbackMillis: 0))
        #expect(scalars.requestBody == "42")
        #expect(scalars.responseBody == "true")

        let null = try #require(NetworkEntry.parse(#"{"url":"https://a.io/x","responseBody":null}"#, fallbackMillis: 0))
        #expect(null.responseBody == nil)
    }

    @Test
    func negativeDurationBecomesZero() throws {
        let fromTiming = try #require(NetworkEntry.parse(
            #"{"url":"https://a.io/x","timing":{"startTime":500,"endTime":200}}"#, fallbackMillis: 0))
        #expect(fromTiming.durationMillis == 0)
        let explicit = try #require(NetworkEntry.parse(
            #"{"url":"https://a.io/x","timing":{"startTime":500,"duration":-3}}"#, fallbackMillis: 0))
        #expect(explicit.durationMillis == 0)
    }
}
