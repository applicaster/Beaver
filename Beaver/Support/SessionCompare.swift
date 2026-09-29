//
//  SessionCompare.swift
//  Beaver
//
//  Two sessions side by side (D81): "it works on 4.5, not on 4.6", "works
//  on device A, not on B". A is the one that works, B the one that doesn't.
//  The Sessions tab's Compare sheet and `sessions_compare` both read this.

import Foundation

public enum SessionCompare {

    /// Storage and App Info are asked for but not compared yet: they come
    /// with the storage diff engine (D80) and App Info (D79). Add them in
    /// `run` and the result's `pending` empties itself.
    public enum Section: String, CaseIterable, Sendable {
        case logs, network, storage, appInfo
    }

    public struct Result: Sendable {
        public let a: Int64
        public let b: Int64
        public var logs: Logs?
        public var network: Network?
        /// Sections asked for that Beaver can't compare yet.
        public var pending: [Section] = []
    }

    // MARK: - Logs

    /// Log lines of one subsystem that share a pattern.
    public struct PatternCount: Sendable, Hashable {
        public let subsystem: String
        public let pattern: String
        /// The worst level among them.
        public let level: LogLevel
        public let count: Int
        public let firstId: Int64
    }

    /// Warnings or errors of one subsystem, A vs B.
    public struct LevelCount: Sendable, Hashable {
        public let subsystem: String
        public let level: LogLevel
        public let a: Int
        public let b: Int
        public var increased: Bool { b > a }
    }

    public struct Logs: Sendable {
        public var onlyInA: [PatternCount]
        public var onlyInB: [PatternCount]
        /// Only the subsystems whose counts differ, increases first.
        public var levels: [LevelCount]
        /// A session had more than `patternCap` patterns: the rarest weren't read.
        public var capped: Bool
    }

    /// Distinct patterns read per session, worst level and most frequent first.
    public static let patternCap = 20_000

    // MARK: - Network

    /// Requests with the same `requestKey`.
    public struct RequestGroup: Sendable, Hashable {
        public let key: String
        public let count: Int
        public let firstId: Int64
        public let classes: [NetworkEntry.StatusClass: Int]
        public let medianMs: Int?

        /// `2xx×3, 5xx×1`, 2xx first.
        public var statusText: String {
            NetworkEntry.StatusClass.allCases.compactMap { c in
                classes[c].map { "\(c.displayName)×\($0)" }
            }.joined(separator: ", ")
        }
    }

    public struct RequestPair: Sendable, Hashable {
        public let a: RequestGroup
        public let b: RequestGroup
        public var key: String { a.key }
    }

    public struct Network: Sendable {
        public var onlyInA: [RequestGroup]
        public var onlyInB: [RequestGroup]
        /// Same request, a different set of status classes (2xx → 5xx, failed).
        public var statusChanged: [RequestPair]
        /// Median duration at least `slowerFactor`× apart and `slowerMinMs` ms.
        public var durationChanged: [RequestPair]
    }

    public static let slowerFactor = 2.0
    public static let slowerMinMs = 100

    // MARK: - Run

    /// Only sessions of one app compare: its versions and devices may
    /// differ — that's the point — but two different apps have nothing
    /// to learn from each other. Same bundle id when both sessions know
    /// it, else the same app name; an app Beaver can't name matches nothing.
    public static func sameApp(_ a: Session, _ b: Session) -> Bool {
        if let pa = a.appPackage, let pb = b.appPackage { return pa == pb }
        if let na = a.appName, let nb = b.appName { return na == nb }
        return false
    }

    public struct DifferentApps: LocalizedError {
        public let errorDescription: String?
    }

    public static func run(store: LogStore, a: Int64, b: Int64,
                           sections: Set<Section> = Set(Section.allCases)) async throws -> Result {
        let sessions = try await store.sessions()
        if let sa = sessions.first(where: { $0.id == a }), let sb = sessions.first(where: { $0.id == b }),
           !sameApp(sa, sb) {
            func name(_ s: Session) -> String {
                s.appName.map { $0 + (s.appPackage.map { " (\($0))" } ?? "") } ?? s.appPackage ?? "an unnamed app"
            }
            throw DifferentApps(errorDescription:
                "#\(a) is \(name(sa)) and #\(b) is \(name(sb)): only sessions of the same app can be compared.")
        }
        var r = Result(a: a, b: b)
        if sections.contains(.logs) {
            let pa = try await store.messagePatterns(sessionId: a, limit: patternCap)
            let pb = try await store.messagePatterns(sessionId: b, limit: patternCap)
            r.logs = compareLogs(pa, pb,
                                 levelsA: try await store.problemCounts(sessionId: a),
                                 levelsB: try await store.problemCounts(sessionId: b),
                                 capped: max(pa.count, pb.count) >= patternCap)
        }
        if sections.contains(.network) {
            r.network = compareNetwork(try await store.networkEntries(sessionId: a),
                                       try await store.networkEntries(sessionId: b))
        }
        r.pending = Section.allCases.filter { [.storage, .appInfo].contains($0) && sections.contains($0) }
        return r
    }

    static func compareLogs(_ pa: [PatternCount], _ pb: [PatternCount],
                            levelsA: [LevelKey: Int], levelsB: [LevelKey: Int], capped: Bool) -> Logs {
        func key(_ p: PatternCount) -> String { p.subsystem + "\u{1F}" + p.pattern }
        let keysA = Set(pa.map(key)), keysB = Set(pb.map(key))
        func worstFirst(_ x: PatternCount, _ y: PatternCount) -> Bool {
            (x.level, x.count, y.firstId) > (y.level, y.count, x.firstId)
        }
        let levels = Set(levelsA.keys).union(levelsB.keys).compactMap { k -> LevelCount? in
            let (a, b) = (levelsA[k] ?? 0, levelsB[k] ?? 0)
            return a == b ? nil : LevelCount(subsystem: k.subsystem, level: k.level, a: a, b: b)
        }.sorted { ($0.b - $0.a, $0.level, $1.subsystem) > ($1.b - $1.a, $1.level, $0.subsystem) }
        return Logs(onlyInA: pa.filter { !keysB.contains(key($0)) }.sorted(by: worstFirst),
                    onlyInB: pb.filter { !keysA.contains(key($0)) }.sorted(by: worstFirst),
                    levels: levels, capped: capped)
    }

    static func compareNetwork(_ ea: [NetworkEntry], _ eb: [NetworkEntry]) -> Network {
        let ga = groups(ea), gb = groups(eb)
        let pairs = ga.keys.filter { gb[$0] != nil }.sorted().map { RequestPair(a: ga[$0]!, b: gb[$0]!) }
        func byCount(_ x: RequestGroup, _ y: RequestGroup) -> Bool { (x.count, y.key) > (y.count, x.key) }
        return Network(
            onlyInA: ga.values.filter { gb[$0.key] == nil }.sorted(by: byCount),
            onlyInB: gb.values.filter { ga[$0.key] == nil }.sorted(by: byCount),
            statusChanged: pairs.filter { Set($0.a.classes.keys) != Set($0.b.classes.keys) },
            durationChanged: pairs.filter { p in
                guard let x = p.a.medianMs, let y = p.b.medianMs else { return false }
                return abs(y - x) >= slowerMinMs && Double(max(x, y)) >= slowerFactor * Double(max(min(x, y), 1))
            }.sorted { abs($0.b.medianMs! - $0.a.medianMs!) > abs($1.b.medianMs! - $1.a.medianMs!) }
        )
    }

    static func groups(_ entries: [NetworkEntry]) -> [String: RequestGroup] {
        Dictionary(grouping: entries, by: requestKey).mapValues { es in
            let ms = es.compactMap(\.durationMillis).sorted()
            let median = ms.isEmpty ? nil : (ms[(ms.count - 1) / 2] + ms[ms.count / 2]) / 2
            return RequestGroup(key: requestKey(es[0]), count: es.count, firstId: es[0].id,
                                classes: Dictionary(grouping: es, by: \.statusClass).mapValues(\.count),
                                medianMs: median)
        }
    }

    // MARK: - Normalising

    /// `GET api.x.io/users/:id/posts`: the query dropped, and path segments
    /// that are ids — numbers, UUIDs, hex of 8+, opaque tokens of 16+ with a
    /// digit — replaced by `:id`. `v2` stays.
    public static func requestKey(_ e: NetworkEntry) -> String {
        let path = e.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { s in
            isId(s) ? ":id" : String(s)
        }
        return "\(e.method) \(e.host)\(segments.joined(separator: "/"))"
    }

    static func isId(_ s: Substring) -> Bool {
        let digits = s.filter { $0.isASCII && $0.isNumber }.count
        guard digits > 0 else { return false }
        if digits == s.count { return true }
        if s.count >= 8, s.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return true }
        return s.count >= 16 && s.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    /// What varies between runs of the same log line, replaced by
    /// placeholders: `Loaded 42 items in 118ms` and `Loaded 7 items in
    /// 95ms` are both `Loaded <n> items in <n>ms`. URL query values → `<*>`,
    /// UUIDs → `<uuid>`, dates and clock times → `<time>`, 0x… and hex words
    /// of 8+ with a digit and a letter → `<hex>`, other numbers (1.5, 4.6.0)
    /// → `<n>`. A byte scanner, not a regex: SQLite calls it once per
    /// distinct line, and a regex took 15 µs a line (3 s for 200k).
    public static func pattern(_ message: String) -> String {
        let s = Array(message.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "?") || c == UInt8(ascii: "&") {
                out.append(c)
                i += 1
                // key=value → key=<*>
                var k = i
                while k < s.count, !isQueryStop(s[k]), s[k] != UInt8(ascii: "=") { k += 1 }
                if k > i, k < s.count, s[k] == UInt8(ascii: "=") {
                    out += s[i...k]
                    out += "<*>".utf8
                    i = k + 1
                    while i < s.count, !isQueryStop(s[i]) { i += 1 }
                }
                continue
            }
            if isHex(c), i == 0 || !isWord(s[i - 1]), let (end, tag) = token(s, i) {
                out += tag.utf8
                i = end
                continue
            }
            if isDigit(c) {
                i = number(s, i)
                out += "<n>".utf8
                continue
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A UUID, date, clock time or hex word starting at `i`, a word start.
    private static func token(_ s: [UInt8], _ i: Int) -> (Int, String)? {
        func at(_ j: Int) -> UInt8 { j < s.count ? s[j] : 0 }
        func run(_ j: Int, _ test: (UInt8) -> Bool) -> Int {
            var k = j
            while k < s.count, test(s[k]) { k += 1 }
            return k - j
        }
        func wordEnds(_ j: Int) -> Bool { j >= s.count || !isWord(s[j]) }
        func digits(_ j: Int, _ n: Int) -> Bool { run(j, isDigit) >= n }

        // 8-4-4-4-12 hex
        var j = i
        var isUUID = true
        for (n, last) in [(8, false), (4, false), (4, false), (4, false), (12, true)] {
            guard run(j, isHex) == n, last || at(j + n) == UInt8(ascii: "-") else { isUUID = false; break }
            j += n + (last ? 0 : 1)
        }
        if isUUID, wordEnds(j) { return (j, "<uuid>") }

        // 2026-09-28, then optionally T12:34, :56, .789, Z or +02:00
        if run(i, isDigit) == 4, at(i + 4) == UInt8(ascii: "-"), run(i + 5, isDigit) == 2,
           at(i + 7) == UInt8(ascii: "-"), digits(i + 8, 2) {
            j = i + 10
            if at(j) == UInt8(ascii: "T") || at(j) == UInt8(ascii: " "), digits(j + 1, 2),
               at(j + 3) == UInt8(ascii: ":"), digits(j + 4, 2) {
                j += 6
                if at(j) == UInt8(ascii: ":"), digits(j + 1, 2) {
                    j += 3
                    if at(j) == UInt8(ascii: ".") || at(j) == UInt8(ascii: ","), digits(j + 1, 1) {
                        j += 1 + run(j + 1, isDigit)
                    }
                }
                if at(j) == UInt8(ascii: "Z") {
                    j += 1
                } else if at(j) == UInt8(ascii: "+") || at(j) == UInt8(ascii: "-"), digits(j + 1, 2) {
                    let colon = at(j + 3) == UInt8(ascii: ":") ? 1 : 0
                    if digits(j + 3 + colon, 2) { j += 5 + colon }
                }
            }
            return (j, "<time>")
        }

        // 9:15:02, 09:15:02.5
        let h = run(i, isDigit)
        if h <= 2, at(i + h) == UInt8(ascii: ":"), digits(i + h + 1, 2), at(i + h + 3) == UInt8(ascii: ":"),
           digits(i + h + 4, 2) {
            j = i + h + 6
            if at(j) == UInt8(ascii: ".") || at(j) == UInt8(ascii: ","), digits(j + 1, 1) {
                j += 1 + run(j + 1, isDigit)
            }
            return (j, "<time>")
        }

        // 0x7fa3, 5f3a9c2e1b
        if s[i] == UInt8(ascii: "0"), at(i + 1) | 0x20 == UInt8(ascii: "x") {
            let n = run(i + 2, isHex)
            if n > 0, wordEnds(i + 2 + n) { return (i + 2 + n, "<hex>") }
        }
        let n = run(i, isHex)
        if n >= 8, wordEnds(i + n), s[i..<i + n].contains(where: isDigit), s[i..<i + n].contains(where: { !isDigit($0) }) {
            return (i + n, "<hex>")
        }
        return nil
    }

    /// 42, 1.5, 4.6.0, 1,000
    private static func number(_ s: [UInt8], _ i: Int) -> Int {
        var j = i
        while j < s.count, isDigit(s[j]) { j += 1 }
        while j + 1 < s.count, s[j] == UInt8(ascii: ".") || s[j] == UInt8(ascii: ","), isDigit(s[j + 1]) {
            j += 1
            while j < s.count, isDigit(s[j]) { j += 1 }
        }
        return j
    }

    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    private static func isHex(_ b: UInt8) -> Bool { isDigit(b) || (b | 0x20 >= 0x61 && b | 0x20 <= 0x66) }
    /// ASCII letters, digits, `_`, and any non-ASCII byte.
    private static func isWord(_ b: UInt8) -> Bool {
        isDigit(b) || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) || b == UInt8(ascii: "_") || b >= 0x80
    }
    /// Ends a query key or value: whitespace, `&`, `#`, quotes, `<`, `>`.
    private static func isQueryStop(_ b: UInt8) -> Bool {
        b <= 0x20 || b == UInt8(ascii: "&") || b == UInt8(ascii: "#") || b == UInt8(ascii: "\"")
            || b == UInt8(ascii: "'") || b == UInt8(ascii: "<") || b == UInt8(ascii: ">")
    }

    public struct LevelKey: Hashable, Sendable {
        public let subsystem: String
        public let level: LogLevel
    }
}
