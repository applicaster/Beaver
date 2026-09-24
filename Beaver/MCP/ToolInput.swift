//
//  ToolInput.swift
//  Beaver
//
//  Forgiving inputs (design M30): whatever a weak agent writes, resolve
//  it to what it most likely meant, and say what it was resolved to.

import Foundation

public enum ToolInput {

    public static func level(_ json: JSON) -> LogLevel? {
        if let n = json.int { return LogLevel(numericLevel: n) }
        guard let s = json.string?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if let n = Int(s) { return LogLevel(numericLevel: n) }
        switch s {
        case "v", "verbose", "trace", "all": return .verbose
        case "d", "debug": return .debug
        case "i", "info": return .info
        case "w", "warn", "warning": return .warning
        case "e", "err", "error", "fatal": return .error
        default: return nil
        }
    }

    /// `"30s"`, `"5m"`, `"2h"`, `"1d"` back from `now`, or an ISO 8601 time.
    public static func time(_ text: String, now: Date) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = t.wholeMatch(of: /(\d+(?:\.\d+)?)\s*(ms|s|m|h|d)/),
           let value = Double(match.1) {
            let seconds: Double = switch match.2 {
            case "ms": value / 1000
            case "s": value
            case "m": value * 60
            case "h": value * 3600
            default: value * 86_400
            }
            return now.addingTimeInterval(-seconds)
        }
        return try? Date(text.trimmingCharacters(in: .whitespaces), strategy: .iso8601)
    }

    public static func resolveNames(_ patterns: [String], among available: [String]) -> NameResolution {
        var resolved: [String] = []
        var misses: [NameResolution.Miss] = []
        for raw in patterns {
            let p = raw.trimmingCharacters(in: .whitespaces)
            let matches: [String]
            if available.contains(p) {
                matches = [p]
            } else if p.contains("*") || p.contains("?") {
                matches = available.filter { globMatches(p, $0) }
            } else {
                let sameCase = available.filter { $0.caseInsensitiveCompare(p) == .orderedSame }
                matches = sameCase.isEmpty
                    ? available.filter { $0.localizedCaseInsensitiveContains(p) }
                    : sameCase
            }
            if matches.isEmpty {
                misses.append(.init(pattern: p, closest: closest(to: p, in: available)))
            }
            for m in matches where !resolved.contains(m) { resolved.append(m) }
        }
        return NameResolution(resolved: resolved, misses: misses)
    }

    static func globMatches(_ pattern: String, _ value: String) -> Bool {
        let regex = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^" + regex + "$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Up to three names nearest to `p`, comparing against the whole name
    /// and each dotted / slashed part (so "autth" finds "com.app.auth").
    static func closest(to p: String, in available: [String], count: Int = 3) -> [String] {
        let q = p.lowercased()
        func score(_ name: String) -> Int {
            let lower = name.lowercased()
            let parts = lower.split(whereSeparator: { "./_-".contains($0) }).map(String.init)
            return ([lower] + parts).map { distance(q, $0) }.min() ?? Int.max
        }
        let scored = available.map { ($0, score($0)) }
        return scored.sorted { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }.prefix(count).map(\.0)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1,
                                       previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

public struct NameResolution: Sendable, Equatable {
    public struct Miss: Sendable, Equatable {
        public let pattern: String
        public let closest: [String]
    }
    public var resolved: [String]
    public var misses: [Miss]
}

public struct ResolvedSession: Sendable {
    public enum How: String, Sendable { case given, live, viewed, latest }
    public let id: Int64
    public let session: Session
    public let how: How

    /// `#13 (live)`, `#12 (viewed)`, `#9 (imported)`, `#7 (most recent, live)`.
    /// `.latest` always says "most recent" — an old live session that's no
    /// longer the one connected must not read as simply "(live)", which
    /// would look like the current one.
    public var label: String {
        switch how {
        case .given: "#\(id) (\(session.source.rawValue))"
        case .latest: "#\(id) (most recent, \(session.source.rawValue))"
        case .live, .viewed: "#\(id) (\(how.rawValue))"
        }
    }
}

public struct ResolvedFilter: Sendable {
    public let filter: Filter
    public let notes: [String]
}

public struct IdRange: Sendable, Equatable {
    public var afterId: Int64?
    public var beforeId: Int64?
    public var notes: [String]
}

extension ToolContext {

    /// Design M9: given → live → viewed → most recent.
    public func resolveSession(_ args: ToolArguments) async throws -> ResolvedSession {
        let sessions = try await store.sessions()   // newest first
        if let wanted = try args.int64("sessionId") {
            guard let s = sessions.first(where: { $0.id == wanted }) else {
                throw ToolError("No session #\(wanted). Example: sessions_list() shows the ids that exist.")
            }
            return ResolvedSession(id: wanted, session: s, how: .given)
        }
        let host = await ui.snapshot()
        if let id = host.liveSessionId, let s = sessions.first(where: { $0.id == id }) {
            return ResolvedSession(id: id, session: s, how: .live)
        }
        if let id = host.viewingSessionId, let s = sessions.first(where: { $0.id == id }) {
            return ResolvedSession(id: id, session: s, how: .viewed)
        }
        if let s = sessions.first {
            return ResolvedSession(id: s.id, session: s, how: .latest)
        }
        throw ToolError("Beaver has no sessions yet. Ask the user to connect the app to Beaver"
            + (host.deviceURL.map { " at \($0)" } ?? "")
            + " (remote assistance on the device), then call beaver_status().")
    }

    /// Design M30: a weak agent often writes `logs_query(minLevel: "error")`
    /// instead of `logs_query(filter: {minLevel: "error"})`. Lifts any of
    /// `Filter`'s keys found at the top level into `filter`, when `filter`
    /// doesn't already have that key, and notes the resolution — used by
    /// `logs_facets`, `logs_query` and `logs_wait`, the three tools that take
    /// both a top-level argument set and a `filter` object.
    public func resolveFilter(_ args: ToolArguments, sessionId: Int64) async throws -> ResolvedFilter {
        var object = args["filter"]?.object ?? [:]
        var lifted: [String] = []
        for key in Self.filterKeys {
            guard object[key] == nil, let value = args[key] else { continue }
            object[key] = value
            lifted.append("\(key) → filter.\(key)")
        }
        let resolved = try await resolveFilter(object.isEmpty ? nil : .object(object), sessionId: sessionId)
        return ResolvedFilter(filter: resolved.filter, notes: lifted + resolved.notes)
    }

    static let filterKeys = [
        "minLevel", "search", "searchIsRegex", "exclude", "excludeIsRegex",
        "searchPayloads", "subsystems", "excludeSubsystems", "categories", "excludeCategories",
    ]

    public func resolveFilter(_ json: JSON?, sessionId: Int64) async throws -> ResolvedFilter {
        guard let json, json != .null else { return ResolvedFilter(filter: .none, notes: []) }
        guard let object = json.object else {
            throw ToolError("filter must be an object. Example: filter: {minLevel: \"warning\", subsystems: [\"*auth*\"]}.")
        }
        let a = ToolArguments(object)
        var f = Filter()
        if let raw = a["minLevel"] {
            guard let level = ToolInput.level(raw) else {
                throw ToolError("Unknown level \(raw.text). Use verbose, debug, info, warning or error.")
            }
            f.minLevel = level
        }
        f.search = try a.string("search").flatMap(Self.trimmedNonEmpty)
        f.searchIsRegex = try a.bool("searchIsRegex") ?? false
        f.exclude = try a.string("exclude").flatMap(Self.trimmedNonEmpty)
        f.excludeIsRegex = try a.bool("excludeIsRegex") ?? false
        f.searchPayloads = try a.bool("searchPayloads") ?? false
        for (term, isRegex, key) in [(f.search, f.searchIsRegex, "search"), (f.exclude, f.excludeIsRegex, "exclude")] {
            if isRegex, let term, !Filter.isValidRegex(term) {
                throw ToolError("\(key) \"\(term)\" is not a valid regular expression. Drop \(key)IsRegex to search for the text as is.")
            }
        }

        var notes: [String] = []
        let facets: [(String, Filter.Facet, WritableKeyPath<Filter, Set<String>>, Bool)] = [
            ("subsystems", .subsystem, \.subsystems, true),
            ("excludeSubsystems", .subsystem, \.excludedSubsystems, false),
            ("categories", .category, \.categories, true),
            ("excludeCategories", .category, \.excludedCategories, false),
        ]
        for (key, facet, path, isInclude) in facets {
            guard let patterns = try a.strings(key), !patterns.isEmpty else { continue }
            let available = try await store.facetCounts(sessionId: sessionId, facet: facet, filter: .none).map(\.value)
            let r = ToolInput.resolveNames(patterns, among: available)
            if isInclude, let miss = r.misses.first {
                let noun = facet == .subsystem ? "subsystem" : "category"
                throw ToolError("No \(noun) matches \"\(miss.pattern)\" in session #\(sessionId). "
                    + "Closest: \(miss.closest.joined(separator: ", ")). Example: logs_facets() lists them all.")
            }
            f[keyPath: path] = Set(r.resolved)
            if r.resolved.sorted() != patterns.sorted() {
                notes.append("\(key) \(patterns.joined(separator: ", ")) → \(r.resolved.isEmpty ? "nothing" : r.resolved.joined(separator: ", "))")
            }
        }
        return ResolvedFilter(filter: f, notes: notes)
    }

    public func resolveRange(_ args: ToolArguments, sessionId: Int64) async throws -> IdRange {
        var r = IdRange(afterId: try args.int64("afterId"), beforeId: try args.int64("beforeId"), notes: [])
        if let since = try args.string("since") {
            guard let date = ToolInput.time(since, now: now()) else {
                throw ToolError("since \"\(since)\" is not a duration (30s, 5m, 2h, 1d) or an ISO 8601 time.")
            }
            let first = try await store.firstEventId(sessionId: sessionId, atOrAfterMillis: Self.millis(date))
            let latest = try await store.latestEventId(sessionId: sessionId) ?? 0
            let after = (first ?? latest + 1) - 1
            r.afterId = Swift.max(r.afterId ?? 0, after)
            r.notes.append("since \(since) → after #\(after)")
        }
        if let until = try args.string("until") {
            guard let date = ToolInput.time(until, now: now()) else {
                throw ToolError("until \"\(until)\" is not a duration (30s, 5m, 2h, 1d) or an ISO 8601 time.")
            }
            if let first = try await store.firstEventId(sessionId: sessionId, atOrAfterMillis: Self.millis(date)) {
                r.beforeId = Swift.min(r.beforeId ?? Int64.max, first)
                r.notes.append("until \(until) → before #\(first)")
            }
        }
        return r
    }

    static func millis(_ date: Date) -> UInt64 {
        UInt64(Swift.max(0, date.timeIntervalSince1970 * 1000))
    }

    static func trimmedNonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

public enum ToolText {
    public static let payloadCap = 256 * 1024
    public static let messageCap = 500

    /// `#48211 14:03:12.482 ERROR com.app.auth/token: refresh failed 401`
    public static func eventLine(_ e: EventRecord) -> String {
        let source = e.category.isEmpty ? e.subsystem : "\(e.subsystem)/\(e.category)"
        var message = e.message
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
        if message.count > messageCap {
            message = String(message.prefix(messageCap))
                + "… (+\(message.count - messageCap) chars, logs_get for all)"
        }
        return "#\(e.id) \(e.timeOfDayWithMillis) \(e.level.rawValue.uppercased()) \(source): \(message)"
    }

    public static func describe(_ f: Filter) -> String {
        var parts: [String] = []
        if f.minLevel != .verbose { parts.append("level ≥ \(f.minLevel.rawValue)") }
        if let s = f.search {
            parts.append((f.searchIsRegex ? "regex" : "search") + " \"\(s)\"" + (f.searchPayloads ? " incl. payloads" : ""))
        }
        if let e = f.exclude { parts.append("exclude \"\(e)\"") }
        if !f.subsystems.isEmpty { parts.append("subsystems " + f.subsystems.sorted().joined(separator: ", ")) }
        if !f.excludedSubsystems.isEmpty { parts.append("not subsystems " + f.excludedSubsystems.sorted().joined(separator: ", ")) }
        if !f.categories.isEmpty { parts.append("categories " + f.categories.sorted().joined(separator: ", ")) }
        if !f.excludedCategories.isEmpty { parts.append("not categories " + f.excludedCategories.sorted().joined(separator: ", ")) }
        return parts.isEmpty ? "no filter" : parts.joined(separator: "; ")
    }

    /// At most `maxBytes` of UTF-8, cut on a character boundary.
    public static func capped(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while !text.indices.contains(end) && end > text.startIndex {
            end = text.utf8.index(before: end)
        }
        return (String(text[..<end]), true)
    }
}
