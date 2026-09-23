//
//  NetworkFilter.swift
//  Beaver
//

import Foundation

/// Filter state of the Network tab. Empty sets mean "no restriction";
/// facets combine with AND.
public struct NetworkFilter: Equatable, Sendable {
    public var search = ""
    public var methods: Set<String> = []
    public var statusClasses: Set<NetworkEntry.StatusClass> = []
    public var hosts: Set<String> = []
    public var excludedHosts: Set<String> = []

    public init() {}

    public var isEmpty: Bool {
        search.isEmpty && methods.isEmpty && statusClasses.isEmpty
            && hosts.isEmpty && excludedHosts.isEmpty
    }

    public func matches(_ e: NetworkEntry) -> Bool {
        if !methods.isEmpty, !methods.contains(e.method) { return false }
        if !statusClasses.isEmpty, !statusClasses.contains(e.statusClass) { return false }
        let host = e.host
        if excludedHosts.contains(host) { return false }
        if !hosts.isEmpty, !hosts.contains(host) { return false }
        guard !search.isEmpty else { return true }
        // Decoded fields, not payloadJSON: JSONSerialization writes `/` as `\/`.
        let haystack: [String?] = [
            e.url, e.method, e.status.map(String.init), e.statusText, e.error,
            e.requestBody, e.responseBody,
        ] + e.requestHeaders.flatMap { [$0.key, $0.value] }
          + e.responseHeaders.flatMap { [$0.key, $0.value] }
        return haystack.contains { $0?.localizedCaseInsensitiveContains(search) == true }
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
