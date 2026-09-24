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
            // Every handler reads both sides live and ignores the value its
            // onChange captured: an agent's apply and a person's edit can land
            // in the same run-loop turn, and writing captured values would
            // swap env and model back and forth forever. Read live, the
            // handler that runs second sees them equal and stops (last
            // writer wins).
            //
            // env → models. Only the models of the session on screen: right
            // after a switch the old ones are about to go, and MainWindow
            // starts the new ones from env.
            .onChange(of: LogTarget(filter: env.activeFilter, eventId: env.selectedEventId)) {
                guard let vm = logFeed, vm.sessionId == env.viewingSessionId else { return }
                let id = env.selectedEventId
                vm.show(filter: env.activeFilter, select: id == vm.selectedEventId ? nil : id)
            }
            .onChange(of: NetworkTarget(filter: env.networkFilter, id: env.selectedNetworkId)) {
                guard let vm = network, vm.sessionId == env.viewingSessionId else { return }
                let id = env.selectedNetworkId
                vm.show(filter: env.networkFilter, select: id == vm.selection ? nil : id)
            }
            .onChange(of: env.storageLayer) {
                guard let vm = storages, vm.sessionId == env.viewingSessionId else { return }
                if vm.selectedNamespace != env.storageLayer { vm.selectedNamespace = env.storageLayer }
            }
            .onChange(of: env.storageSearch) {
                guard let vm = storages, vm.sessionId == env.viewingSessionId else { return }
                if vm.searchTerm != env.storageSearch { vm.searchTerm = env.storageSearch }
            }
            // models → env: the person's own changes.
            .onChange(of: logFeed?.filter, initial: true) {
                if let filter = logFeed?.filter, env.activeFilter != filter { env.activeFilter = filter }
            }
            .onChange(of: logFeed?.selectedEventId) {
                guard let vm = logFeed else { return }
                if env.selectedEventId != vm.selectedEventId { env.selectedEventId = vm.selectedEventId }
            }
            .onChange(of: network?.filter) {
                if let filter = network?.filter, env.networkFilter != filter { env.networkFilter = filter }
            }
            .onChange(of: network?.selection) {
                guard let vm = network else { return }
                if env.selectedNetworkId != vm.selection { env.selectedNetworkId = vm.selection }
            }
            .onChange(of: storages?.selectedNamespace) {
                if let layer = storages?.selectedNamespace, env.storageLayer != layer { env.storageLayer = layer }
            }
            .onChange(of: storages?.searchTerm) {
                if let term = storages?.searchTerm, env.storageSearch != term { env.storageSearch = term }
            }
    }
}
