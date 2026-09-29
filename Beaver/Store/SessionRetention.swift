//
//  SessionRetention.swift
//  Beaver
//

import Foundation

/// "Delete sessions older than" in Settings → General (D83, D92). Kept in
/// `UserDefaults` as a number of days; 0 is Never.
public enum SessionRetention: Int, CaseIterable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90
    case never = 0

    public static let key = "sessionRetentionDays"
    /// Set by the first pass after upgrade, which only announces: nothing
    /// is deleted before this date.
    public static let startsAtKey = "sessionRetentionStartsAt"
    public static let `default` = SessionRetention.month

    public static func current(_ defaults: UserDefaults = .standard) -> SessionRetention {
        guard defaults.object(forKey: key) != nil else { return .default }
        return SessionRetention(rawValue: defaults.integer(forKey: key)) ?? .default
    }

    public var title: String { self == .never ? "Never" : "\(rawValue) Days" }

    /// One session as the purge sees it (`LogStore.retentionCandidates`).
    public struct Candidate: Sendable, Equatable {
        public let id: Int64
        public let source: Session.Source
        public let lastActivity: Date
        public let bookmarked: Bool
    }

    /// Sessions to delete: live ones (not imported), not connected now,
    /// without bookmarks, last active before `cutoff`.
    public static func expired(_ candidates: [Candidate], before cutoff: Date, live: Set<Int64>) -> [Int64] {
        candidates
            .filter { $0.source == .live && !$0.bookmarked && !live.contains($0.id) && $0.lastActivity < cutoff }
            .map(\.id)
    }

    public enum Outcome: Sendable, Equatable {
        case nothing
        /// First pass after upgrade: `pending` sessions go from tomorrow.
        case notice(pending: Int)
        case deleted(count: Int, freedBytes: Int64)
    }

    /// One pass, at launch and daily (D83). `live`: the sessions of the
    /// connected devices.
    public static func run(store: LogStore, live: Set<Int64>, now: Date = Date(),
                           defaults: UserDefaults = .standard) async throws -> Outcome {
        let retention = current(defaults)
        guard retention != .never else { return .nothing }
        let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
        let ids = expired(try await store.retentionCandidates(), before: cutoff, live: live)
        guard let startsAt = defaults.object(forKey: startsAtKey) as? Date else {
            defaults.set(now.addingTimeInterval(86_400), forKey: startsAtKey)
            return ids.isEmpty ? .nothing : .notice(pending: ids.count)
        }
        guard now >= startsAt, !ids.isEmpty else { return .nothing }
        let before = try await store.databaseSize()
        // A pass that overlaps another (the menu changed mid-pass) finds them gone.
        let count = try await store.deleteSessions(ids: ids)
        guard count > 0 else { return .nothing }
        try await store.reclaimSpace()
        return .deleted(count: count, freedBytes: max(0, before - (try await store.databaseSize())))
    }
}
