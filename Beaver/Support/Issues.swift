import Foundation

/// A session's warnings and errors grouped by signature — subsystem plus
/// `SessionCompare.pattern` of the first 300 characters, the grouping
/// Compare uses (D81) — like Sentry, but local (D95).
public enum Issues {

    /// Groups read per session, worst level and most frequent first.
    public static let cap = 500
    /// Bars in a group's histogram, over the session's first to last event.
    public static let buckets = 30

    public struct Group: Sendable, Hashable, Identifiable {
        public let subsystem: String
        public let pattern: String
        /// The worst level among the group's events.
        public let level: LogLevel
        public let count: Int
        public let firstId: Int64
        public let lastId: Int64
        public let firstAt: Date
        public let lastAt: Date
        /// The first event's message.
        public let example: String
        /// `Issues.buckets` counts.
        public let histogram: [Int]
        /// Marked as known noise for this app.
        public let ignored: Bool

        public var id: String { signature }
        public var signature: String { Issues.signature(subsystem: subsystem, pattern: pattern) }

        /// The Log feed filter that shows exactly this group's events:
        /// the subsystem chip, the pattern, and the Issues view's level.
        public func filter(minLevel: LogLevel) -> Filter {
            Filter(minLevel: minLevel, subsystems: [subsystem], pattern: pattern)
        }

        /// What Copy puts on the clipboard.
        public var copyText: String {
            "\(level.rawValue.uppercased()) \(subsystem): \(pattern)\n"
                + "×\(count), first \(Self.stamp(firstAt)) (#\(firstId)), last \(Self.stamp(lastAt)) (#\(lastId))\n"
                + "e.g. \(example)"
        }

        static func stamp(_ d: Date) -> String {
            Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(d)
        }
    }

    public struct Report: Sendable {
        public var groups: [Group]
        /// More than `cap` groups: the rarest were left out.
        public var capped: Bool
        public static let empty = Report(groups: [], capped: false)

        public var shown: [Group] { groups.filter { !$0.ignored } }
        public var errors: Int { shown.filter { $0.level == .error }.count }
        public var warnings: Int { shown.filter { $0.level == .warning }.count }
    }

    public enum Sort: String, CaseIterable, Sendable {
        case newest, frequent, errorsFirst

        public var title: String {
            switch self {
            case .newest: "Newest"
            case .frequent: "Most frequent"
            case .errorsFirst: "Errors first"
            }
        }

        public func sorted(_ groups: [Group]) -> [Group] {
            groups.sorted { a, b in
                switch self {
                case .newest: (a.lastId, a.count) > (b.lastId, b.count)
                case .frequent: (a.count, a.lastId) > (b.count, b.lastId)
                case .errorsFirst: (a.level, a.count, a.lastId) > (b.level, b.count, b.lastId)
                }
            }
        }
    }

    /// One string per group: the ignore list's key and `issues_ignore`'s
    /// argument. U+241F (␟) reads in a tool result and doesn't occur in
    /// subsystem names.
    public static func signature(subsystem: String, pattern: String) -> String {
        subsystem + " ␟ " + pattern
    }

    public static func parse(signature: String) -> (subsystem: String, pattern: String)? {
        guard let r = signature.range(of: " ␟ ") else { return nil }
        return (String(signature[..<r.lowerBound]), String(signature[r.upperBound...]))
    }

    /// Which app an ignore applies to — D81's `sameApp`: the bundle id when
    /// both sides know it, else the app name. Nil when the session names
    /// neither: Beaver can't tell its future sessions apart.
    public static func app(of session: Session) -> (package: String, name: String)? {
        guard session.appPackage != nil || session.appName != nil else { return nil }
        return (session.appPackage ?? "", session.appName ?? "")
    }

    public struct UnknownApp: LocalizedError {
        public let errorDescription: String? =
            "This session doesn't say which app it is (no bundle id or app name), so an ignore couldn't follow the app to its next sessions."
    }

    /// `"3:5,7:1"` (bucket:count) → `buckets` counts.
    static func histogram(_ text: String?) -> [Int] {
        var bars = Array(repeating: 0, count: buckets)
        for pair in (text ?? "").split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let b = Int(parts[0]), let n = Int(parts[1]), bars.indices.contains(b) {
                bars[b] += n
            }
        }
        return bars
    }
}
