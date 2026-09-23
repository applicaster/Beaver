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
        #expect(e.payloadJSON == Self.ios)
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
}
