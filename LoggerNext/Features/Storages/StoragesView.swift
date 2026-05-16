//
//  StoragesView.swift
//  LoggerNext
//

import SwiftUI

/// Stub. Real implementation per D6:
/// - Tab bar for session / local / keychain namespaces.
/// - Auto-refresh (issue `storage.list`) on tab activation.
/// - Inline edit + push back to client via `storage.set` (pending SDK
///   confirmation — see PROTOCOL.md §3.2 open question 1).
/// - Recursive `OutlineGroup` over the parsed JSON of the latest snapshot.
struct StoragesView: View {
    var body: some View {
        ContentUnavailableView(
            "Storages — not yet wired",
            systemImage: "externaldrive",
            description: Text("Next: bind to LogStore.latestStorageSnapshot and render via OutlineGroup. See ARCHITECTURE.md §2 and DECISIONS.md D6.")
        )
    }
}
