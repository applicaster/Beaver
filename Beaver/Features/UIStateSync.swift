//
//  UIStateSync.swift
//  Beaver
//

import SwiftUI

/// Keeps `MainWindow`'s per-session view models and `AppEnvironment`'s
/// window state equal (D54). An agent's `ui_show` writes env and the
/// models follow; the person's own changes in the models are written
/// back, so `ui_state` reports what is on screen. Each side checks for
/// equality first, so a change goes round once and stops.
///
/// Mounted on `MainWindow`, so it works whichever tab is showing — also
/// what `activeFilter` needs for Export (D26).
struct UIStateSync: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let logFeed: LogFeedViewModel?
    let network: NetworkViewModel?
    let storages: StoragesViewModel?

    private struct LogTarget: Equatable { let filter: Filter; let eventId: Int64? }
    private struct NetworkTarget: Equatable { let filter: NetworkFilter; let id: Int64? }

    func body(content: Content) -> some View {
        content
            // env → models. Only the models of the session on screen: right
            // after a switch the old ones are about to go, and MainWindow
            // starts the new ones from env.
            .onChange(of: LogTarget(filter: env.activeFilter, eventId: env.selectedEventId)) { _, target in
                guard let vm = logFeed, vm.sessionId == env.viewingSessionId else { return }
                vm.show(filter: target.filter,
                        select: target.eventId == vm.selectedEventId ? nil : target.eventId)
            }
            .onChange(of: NetworkTarget(filter: env.networkFilter, id: env.selectedNetworkId)) { _, target in
                guard let vm = network, vm.sessionId == env.viewingSessionId else { return }
                vm.show(filter: target.filter, select: target.id == vm.selection ? nil : target.id)
            }
            .onChange(of: env.storageLayer) { _, layer in
                guard let vm = storages, vm.sessionId == env.viewingSessionId else { return }
                if vm.selectedNamespace != layer { vm.selectedNamespace = layer }
            }
            .onChange(of: env.storageSearch) { _, term in
                guard let vm = storages, vm.sessionId == env.viewingSessionId else { return }
                if vm.searchTerm != term { vm.searchTerm = term }
            }
            // models → env: the person's own changes.
            .onChange(of: logFeed?.filter, initial: true) { _, filter in
                if let filter, env.activeFilter != filter { env.activeFilter = filter }
            }
            .onChange(of: logFeed?.selectedEventId) { _, id in
                if logFeed != nil, env.selectedEventId != id { env.selectedEventId = id }
            }
            .onChange(of: network?.filter) { _, filter in
                if let filter, env.networkFilter != filter { env.networkFilter = filter }
            }
            .onChange(of: network?.selection) { _, id in
                if network != nil, env.selectedNetworkId != id { env.selectedNetworkId = id }
            }
            .onChange(of: storages?.selectedNamespace) { _, layer in
                if let layer, env.storageLayer != layer { env.storageLayer = layer }
            }
            .onChange(of: storages?.searchTerm) { _, term in
                if let term, env.storageSearch != term { env.storageSearch = term }
            }
    }
}
