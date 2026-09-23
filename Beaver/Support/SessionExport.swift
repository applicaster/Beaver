import Foundation

/// Builds the file both Export buttons write.
///
/// There is one shape and one code path: events plus every storage
/// namespace plus every network entry. Shipping the logs alone left
/// out what a bug report needs — "why didn't his token refresh" is
/// answered by the storage half, "what did that call return" by the
/// network half — and having the two screens write different files
/// meant neither was self-contained.
public enum SessionExport {

    /// How much of the log to include. Storage and network entries
    /// are not scoped: a snapshot is small, and there is no filter on
    /// those screens for a partial one to correspond to.
    public enum Scope: Sendable {
        /// Only the events matching the log feed's current filter.
        case filtered(Filter)
        /// Every event in the session.
        case everything

        var filter: Filter {
            switch self {
            case .filtered(let filter): filter
            case .everything:           .none
            }
        }
    }

    /// Defensive bound. A session past this needs a streaming export
    /// rather than a bigger number here.
    private static let maxEvents = 1_000_000

    public static func make(
        store: LogStore,
        sessionId: Int64,
        scope: Scope
    ) async -> Data? {
        let events = (try? await store.events(
            sessionId: sessionId,
            filter: scope.filter,
            offset: 0,
            limit: maxEvents
        )) ?? []

        var storage: [StorageSnapshot.Namespace: String] = [:]
        for namespace in StorageSnapshot.Namespace.allCases {
            guard let snapshot = try? await store.latestStorageSnapshot(
                sessionId: sessionId,
                namespace: namespace
            ) else { continue }
            storage[namespace] = snapshot.dataJSON
        }

        // Whole, not filtered — same reasoning as storage above.
        let network = (try? await store.networkEntries(sessionId: sessionId)) ?? []

        // Nothing to say at all — don't hand the user an empty file.
        guard !events.isEmpty || !storage.isEmpty || !network.isEmpty else { return nil }
        return try? EventJSON.encode(events, storage: storage, network: network)
    }
}
