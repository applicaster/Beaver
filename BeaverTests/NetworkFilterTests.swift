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
    func noStatusPickMatchesEntriesWithoutStatus() {
        var f = NetworkFilter(); f.status = .noStatus
        #expect(!f.isEmpty)
        #expect(f.matches(timeout))
        #expect(!f.matches(ok))
    }

    @Test
    func codePickMatchesThatExactCode() {
        let cancelled = e(#"{"url":"https://api.io/x","status":-999,"error":"cancelled"}"#)
        var f = NetworkFilter(); f.status = .code(404)
        #expect(f.matches(notFound))
        #expect(!f.matches(ok) && !f.matches(timeout))
        f.status = .code(-999)
        #expect(f.matches(cancelled))
        #expect(!f.matches(timeout))
    }

    @Test
    func facetsCombineWithAnd() {
        var f = NetworkFilter()
        f.method = "GET"; f.host = "cdn.io"
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
    func excludedMethodsAndStatusClassesWin() {
        var f = NetworkFilter(); f.excludedMethods = ["POST"]
        #expect(!f.isEmpty)
        #expect(!f.matches(timeout))
        #expect(f.matches(ok))

        f = NetworkFilter(); f.excludedStatusClasses = [.clientError]
        #expect(!f.isEmpty)
        #expect(!f.matches(notFound))
        #expect(f.matches(ok) && f.matches(timeout))

        // Excluding beats including the same value.
        f = NetworkFilter(); f.method = "GET"; f.excludedMethods = ["GET"]
        #expect(!f.matches(ok))
    }

    @Test
    func regexSearchMatchesFields() {
        var f = NetworkFilter(); f.searchIsRegex = true
        f.search = #"v\d/feed$"#
        #expect(f.matches(ok))
        #expect(!f.matches(notFound))
        f.search = "^x-trace$"        // a header name, any case
        #expect(f.matches(ok))
        f.search = "TIMED\\s+OUT"
        #expect(f.matches(timeout))
    }

    @Test
    func regexSearchIsCaseInsensitive() {
        var f = NetworkFilter(); f.searchIsRegex = true; f.search = "API\\.IO/V1"
        #expect(f.matches(ok))
    }

    @Test
    func invalidRegexMatchesNothing() {
        var f = NetworkFilter(); f.searchIsRegex = true; f.search = "feed("
        #expect(![ok, notFound, timeout].contains(where: f.matches))
        // The same text as a plain search is fine.
        f.searchIsRegex = false
        #expect(!f.matches(ok))
    }

    @Test
    func regexToggleAloneIsNoRestriction() {
        var f = NetworkFilter(); f.searchIsRegex = true
        #expect(f.isEmpty)
        #expect(f.matches(ok))
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

    // MARK: Facets

    private func req(_ method: String, _ status: Int?, host: String = "api.io", path: String = "x") -> NetworkEntry {
        let s = status.map { #","status":\#($0)"# } ?? ""
        return e(#"{"url":"https://\#(host)/\#(path)","method":"\#(method)"\#(s)}"#)
    }

    /// GET: 200 x2, 401 on api.io; POST: 400 on auth.io; one GET without status on cdn.io.
    private var mixed: [NetworkEntry] {
        [req("GET", 200), req("GET", 200), req("GET", 401), req("POST", 400, host: "auth.io"),
         req("GET", nil, host: "cdn.io", path: "img")]
    }

    @Test
    func selectedMethodNarrowsStatuses() {
        var f = NetworkFilter(); f.method = "GET"
        #expect(f.availableStatuses(in: mixed) == [
            opt(.errors, 2),
            opt(.statusClass(.success), 2), opt(.code(200), 2, 1),
            opt(.statusClass(.clientError), 1), opt(.code(401), 1, 1),
            opt(.statusClass(.failed), 1), opt(.noStatus, 1, 1),
        ])
    }

    @Test
    func selectedStatusNarrowsMethods() {
        var f = NetworkFilter(); f.status = .code(400)
        #expect(f.availableMethods(in: mixed) == [FacetOption(value: "POST", count: 1)])
    }

    @Test
    func ownSelectionDoesNotNarrowItsOwnOptions() {
        var f = NetworkFilter(); f.method = "GET"
        #expect(f.availableMethods(in: mixed) == [FacetOption(value: "GET", count: 4),
                                                   FacetOption(value: "POST", count: 1)])
        f = NetworkFilter(); f.host = "auth.io"
        #expect(f.availableHosts(in: mixed).map(\.value) == ["api.io", "auth.io", "cdn.io"])
    }

    @Test
    func searchNarrowsFacets() {
        var f = NetworkFilter(); f.search = "cdn.io"
        #expect(f.availableMethods(in: mixed) == [FacetOption(value: "GET", count: 1)])
        #expect(f.availableStatuses(in: mixed) == [
            opt(.errors, 1), opt(.statusClass(.failed), 1), opt(.noStatus, 1, 1),
        ])
        #expect(f.availableHosts(in: mixed) == [FacetOption(value: "cdn.io", count: 1)])
    }

    @Test
    func regexSearchNarrowsFacets() {
        var f = NetworkFilter(); f.searchIsRegex = true; f.search = "auth\\.io|cdn\\.io"
        #expect(f.availableMethods(in: mixed) == [FacetOption(value: "GET", count: 1),
                                                    FacetOption(value: "POST", count: 1)])
        #expect(f.availableStatuses(in: mixed) == [
            opt(.errors, 2), opt(.statusClass(.clientError), 1), opt(.code(400), 1, 1),
            opt(.statusClass(.failed), 1), opt(.noStatus, 1, 1),
        ])
        #expect(f.availableHosts(in: mixed) == [FacetOption(value: "auth.io", count: 1),
                                                  FacetOption(value: "cdn.io", count: 1)])
    }

    @Test
    func exclusionsNarrowFacets() {
        var f = NetworkFilter(); f.excludedHosts = ["api.io"]
        #expect(f.availableStatuses(in: mixed).map(\.value) == [
            .errors, .statusClass(.clientError), .code(400), .statusClass(.failed), .noStatus,
        ])
        f = NetworkFilter(); f.excludedMethods = ["GET"]
        #expect(f.availableHosts(in: mixed) == [FacetOption(value: "auth.io", count: 1)])
    }

    @Test
    func facetSortOrder() {
        let entries = [req("PUT", 500, host: "b.io"), req("DELETE", 204, host: "a.io"),
                       req("GET", -999, host: "c.io"), req("GET", nil, host: "c.io")]
        let f = NetworkFilter()
        // Count descending, then name.
        #expect(f.availableMethods(in: entries).map(\.value) == ["GET", "DELETE", "PUT"])
        #expect(f.availableHosts(in: entries).map(\.value) == ["c.io", "a.io", "b.io"])
        // Numeric ascending, no status last.
        #expect(f.availableStatuses(in: entries) == [
            opt(.errors, 3),
            opt(.statusClass(.success), 1), opt(.code(204), 1, 1),
            opt(.statusClass(.serverError), 1), opt(.code(500), 1, 1),
            opt(.statusClass(.failed), 2), opt(.code(-999), 1, 1), opt(.noStatus, 1, 1),
        ])
    }

    @Test
    func selectionWithoutMatchesIsStillListedWithZero() {
        var f = NetworkFilter(); f.method = "PATCH"; f.status = .code(404); f.host = "gone.io"
        #expect(f.availableMethods(in: mixed).contains(FacetOption(value: "PATCH", count: 0)))
        #expect(f.availableStatuses(in: mixed).contains(opt(.code(404), 0, 1)))
        #expect(f.availableHosts(in: mixed).contains(FacetOption(value: "gone.io", count: 0)))
    }

    private func opt(_ v: NetworkFilter.StatusPick, _ count: Int, _ depth: Int = 0) -> FacetOption<NetworkFilter.StatusPick> {
        FacetOption(value: v, count: count, depth: depth)
    }

    @Test
    func errorsPickMatchesClientServerAndFailed() {
        var f = NetworkFilter(); f.status = .errors
        #expect(!f.isEmpty)
        for s: Int? in [404, 400, 500, 503, -999, nil] { #expect(f.matches(req("GET", s)), "\(String(describing: s))") }
        for s in [200, 204, 301, 304, 600] { #expect(!f.matches(req("GET", s)), "\(s)") }
    }

    @Test
    func classPickMatchesThatClass() {
        var f = NetworkFilter(); f.status = .statusClass(.clientError)
        #expect(f.matches(notFound) && !f.matches(ok) && !f.matches(timeout))
        f.status = .statusClass(.failed)
        #expect(f.matches(timeout) && f.matches(req("GET", -1009)) && !f.matches(notFound))
        f.status = .statusClass(.success)
        #expect(f.matches(ok) && !f.matches(notFound))
    }

    @Test
    func errorsSelectionNarrowsMethods() {
        var f = NetworkFilter(); f.status = .errors
        #expect(f.availableMethods(in: mixed) == [FacetOption(value: "GET", count: 2), FacetOption(value: "POST", count: 1)])
    }

    @Test
    func errorsRowOmittedWhenZeroUnlessSelected() {
        let fine = [req("GET", 200), req("GET", 204)]
        var f = NetworkFilter()
        #expect(f.availableStatuses(in: fine) == [
            opt(.statusClass(.success), 2), opt(.code(200), 1, 1), opt(.code(204), 1, 1),
        ])
        f.status = .errors
        #expect(f.availableStatuses(in: fine).first == opt(.errors, 0))
    }

    @Test
    func staleCodeIsListedUnderZeroCountClass() {
        var f = NetworkFilter(); f.status = .code(503)
        #expect(f.availableStatuses(in: mixed) == [
            opt(.errors, 3),
            opt(.statusClass(.success), 2), opt(.code(200), 2, 1),
            opt(.statusClass(.clientError), 2), opt(.code(400), 1, 1), opt(.code(401), 1, 1),
            opt(.statusClass(.serverError), 0), opt(.code(503), 0, 1),
            opt(.statusClass(.failed), 1), opt(.noStatus, 1, 1),
        ])
    }

    @Test
    func staleClassIsListedInItsPlace() {
        var f = NetworkFilter(); f.status = .statusClass(.redirect)
        #expect(f.availableStatuses(in: mixed).map(\.value).prefix(4) == [
            .errors, .statusClass(.success), .code(200), .statusClass(.redirect),
        ])
    }

    @Test
    func negativeCodesSortNumericallyUnderFailed() {
        let entries = [req("GET", -999), req("GET", -1009), req("GET", nil)]
        #expect(NetworkFilter().availableStatuses(in: entries).map(\.value) == [
            .errors, .statusClass(.failed), .code(-1009), .code(-999), .noStatus,
        ])
    }

    @Test
    func hierarchicalStatusLabels() {
        #expect(NetworkEntry.statusLabel(for: .errors) == "Errors")
        #expect(NetworkEntry.statusLabel(for: .statusClass(.success)) == "2xx")
        #expect(NetworkEntry.statusLabel(for: .statusClass(.failed)) == "Failed")
        #expect(NetworkEntry.statusLabel(for: .statusClass(.other)) == "Other")
        #expect(NetworkEntry.statusLabel(for: .code(401)) == "401 Unauthorized")
        let names = [-999: "cancelled", -1001: "timed out", -1003: "host not found", -1004: "cannot connect",
                     -1005: "connection lost", -1009: "offline", -1200: "TLS error", -1202: "bad certificate"]
        for (code, name) in names { #expect(NetworkEntry.statusLabel(for: .code(code)) == "\(code) \(name)") }
        #expect(NetworkEntry.statusLabel(for: .code(-42)) == "-42")
    }

    @Test
    func statusLabels() {
        #expect(NetworkEntry.statusLabel(for: .code(200)) == "200 OK")
        #expect(NetworkEntry.statusLabel(for: .code(404)) == "404 Not Found")
        #expect(NetworkEntry.statusLabel(for: .code(299)) == "299")
        #expect(NetworkEntry.statusLabel(for: .noStatus) == "No status")
    }
}
