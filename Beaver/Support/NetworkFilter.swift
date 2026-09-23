//
//  NetworkFilter.swift
//  Beaver
//

import Foundation

/// Filter state of the Network tab. Method, status and host each pick one
/// value (nil = All); the excluded sets back the "Hide …" chips. Facets
/// combine with AND, and an excluded value beats an included one.
public struct NetworkFilter: Equatable, Sendable {
    /// One status to show: an exact code (NSURLError codes such as -999
    /// included) or entries that have no status at all. Not `.none`, which
    /// would read as `Optional.none` on `status`.
    public enum StatusPick: Hashable, Sendable {
        case code(Int), noStatus

        public init(_ status: Int?) { self = status.map(Self.code) ?? .noStatus }
    }

    public var search = ""
    /// `search` is an ICU regex, matched case-insensitively. An invalid
    /// pattern matches nothing. Like the Log feed, the toggle on its own
    /// (empty search) restricts nothing, so it doesn't make the filter
    /// non-empty.
    public var searchIsRegex = false
    public var method: String?
    public var excludedMethods: Set<String> = []
    public var status: StatusPick?
    public var excludedStatusClasses: Set<NetworkEntry.StatusClass> = []
    public var host: String?
    public var excludedHosts: Set<String> = []

    public init() {}

    public var isEmpty: Bool { search.isEmpty && !hasFacets }

    /// Any method, status or host pick or exclusion.
    public var hasFacets: Bool {
        !(method == nil && excludedMethods.isEmpty && status == nil
            && excludedStatusClasses.isEmpty && host == nil && excludedHosts.isEmpty)
    }

    /// Drops every pick and exclusion and keeps the search.
    public mutating func clearFacets() {
        method = nil; excludedMethods = []
        status = nil; excludedStatusClasses = []
        host = nil; excludedHosts = []
    }

    public func matches(_ e: NetworkEntry) -> Bool {
        if excludedMethods.contains(e.method) { return false }
        if let method, method != e.method { return false }
        if excludedStatusClasses.contains(e.statusClass) { return false }
        if let status, status != StatusPick(e.status) { return false }
        let host = e.host
        if excludedHosts.contains(host) { return false }
        if let picked = self.host, picked != host { return false }
        guard !search.isEmpty else { return true }
        // Decoded fields, not payloadJSON: JSONSerialization writes `/` as `\/`.
        let haystack: [String?] = [
            e.url, e.method, e.status.map(String.init), e.statusText, e.error,
            e.requestBody, e.responseBody,
        ] + e.requestHeaders.flatMap { [$0.key, $0.value] }
          + e.responseHeaders.flatMap { [$0.key, $0.value] }
        guard searchIsRegex else {
            return haystack.contains { $0?.localizedCaseInsensitiveContains(search) == true }
        }
        guard let regex = LogStore.compiledRegex("(?i)" + search) else { return false }
        return haystack.contains { field in
            guard let field else { return false }
            return regex.firstMatch(in: field, range: NSRange(field.startIndex..., in: field)) != nil
        }
    }

    // MARK: Facets

    /// Each facet counts the entries that match every criterion except its
    /// own, so picking GET narrows the statuses but still lists POST. The
    /// current pick is always listed, with 0 when nothing matches it.
    public func availableMethods(in entries: [NetworkEntry]) -> [FacetOption<String>] {
        var f = self; f.method = nil
        return Self.options(entries.filter(f.matches).map(\.method), keeping: method)
            .sorted { ($0.count, $1.value) > ($1.count, $0.value) }
    }

    public func availableStatuses(in entries: [NetworkEntry]) -> [FacetOption<StatusPick>] {
        var f = self; f.status = nil
        return Self.options(entries.filter(f.matches).map { StatusPick($0.status) }, keeping: status)
            .sorted { a, b in
                switch (a.value, b.value) {
                case let (.code(x), .code(y)): x < y
                case (.code, .noStatus): true
                default: false
                }
            }
    }

    public func availableHosts(in entries: [NetworkEntry]) -> [FacetOption<String>] {
        var f = self; f.host = nil
        return Self.options(entries.filter(f.matches).map(\.host), keeping: host)
            .sorted { ($0.count, $1.value) > ($1.count, $0.value) }
    }

    private static func options<V: Hashable>(_ values: [V], keeping pick: V?) -> [FacetOption<V>] {
        var counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        if let pick, counts[pick] == nil { counts[pick] = 0 }
        return counts.map { FacetOption(value: $0.key, count: $0.value) }
    }
}

/// One row of a facet dropdown: a value and how many entries have it.
public struct FacetOption<Value: Hashable & Sendable>: Hashable, Sendable {
    public let value: Value
    public let count: Int

    public init(value: Value, count: Int) {
        self.value = value
        self.count = count
    }
}

/// The Network tab's results bar. Like zapp-support, the success ratio
/// only counts requests that got an HTTP response: a timeout or a
/// cancelled request (-999) is neither a success nor a failure here.
public struct NetworkStats: Equatable, Sendable {
    public let count: Int
    /// 2xx responses.
    public let successCount: Int
    /// Entries with an HTTP status (>= 100).
    public let httpCount: Int
    public let averageDurationMillis: Int?

    public var successRate: Double? { httpCount == 0 ? nil : Double(successCount) / Double(httpCount) }

    public init(_ entries: [NetworkEntry]) {
        count = entries.count
        httpCount = entries.filter { ($0.status ?? 0) >= 100 }.count
        successCount = entries.filter { $0.statusClass == .success }.count
        let durations = entries.compactMap(\.durationMillis)
        averageDurationMillis = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
    }
}
