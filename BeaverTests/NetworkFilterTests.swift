//
//  NetworkFilterTests.swift
//  BeaverTests
//

import Testing
import Foundation
@testable import BeaverCore

@Suite("NetworkFilter")
struct NetworkFilterTests {

    private func e(_ json: String) -> NetworkEntry { NetworkEntry.parse(json, fallbackMillis: 0)! }

    private var ok: NetworkEntry {
        e(#"{"url":"https:\/\/api.io\/v1\/feed","method":"GET","status":200,"timing":{"startTime":1,"duration":100},"responseHeaders":{"X-Trace":"abc123"}}"#)
    }
    private var notFound: NetworkEntry {
        e(#"{"url":"https://cdn.io/img.png","method":"GET","status":404,"timing":{"startTime":2,"duration":300}}"#)
    }
    private var timeout: NetworkEntry {
        e(#"{"url":"https://api.io/login","method":"POST","error":"The request timed out."}"#)
    }

    @Test
    func emptyFilterMatchesEverything() {
        let f = NetworkFilter()
        #expect(f.isEmpty)
        #expect([ok, notFound, timeout].allSatisfy(f.matches))
    }

    @Test
    func searchMatchesDecodedURLNotRawJSON() {
        var f = NetworkFilter(); f.search = "API.IO/v1"
        #expect(f.matches(ok))
        #expect(!f.matches(notFound))
    }

    @Test
    func searchCoversHeadersBodiesAndError() {
        var f = NetworkFilter()
        f.search = "abc123";    #expect(f.matches(ok))
        f.search = "timed out"; #expect(f.matches(timeout))
    }

    @Test
    func failedClassMatchesErrorWithoutStatus() {
        var f = NetworkFilter(); f.statusClasses = [.failed]
        #expect(f.matches(timeout))
        #expect(!f.matches(ok))
    }

    @Test
    func facetsCombineWithAnd() {
        var f = NetworkFilter()
        f.methods = ["GET"]; f.hosts = ["cdn.io"]
        #expect(f.matches(notFound))
        #expect(!f.matches(ok))
        #expect(!f.matches(timeout))
    }

    @Test
    func excludedHostsWin() {
        var f = NetworkFilter(); f.excludedHosts = ["api.io"]
        #expect(!f.matches(ok))
        #expect(f.matches(notFound))
    }

    @Test
    func statsCountSuccessRateAndAverage() {
        let s = NetworkStats([ok, notFound, timeout])
        #expect(s.count == 3)
        // Only requests with an HTTP response count: the timeout has none.
        #expect(s.successCount == 1)
        #expect(s.httpCount == 2)
        #expect(s.successRate == 1.0 / 2.0)
        #expect(s.averageDurationMillis == 200)   // timeout has no duration: excluded
        #expect(NetworkStats([]).successRate == nil)
        #expect(NetworkStats([timeout]).successRate == nil)
    }

    @Test
    func statsExcludeNonHTTPCodes() {
        let cancelled = e(#"{"url":"https://api.io/x","status":-999,"error":"cancelled"}"#)
        let s = NetworkStats([ok, cancelled])
        #expect(s.httpCount == 1)
        #expect(s.successCount == 1)
        #expect(s.successRate == 1.0)
    }
}
