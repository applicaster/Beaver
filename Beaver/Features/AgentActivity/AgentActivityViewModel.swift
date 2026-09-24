//
//  AgentActivityViewModel.swift
//  Beaver
//

import AppKit
import Observation

@MainActor
@Observable
final class AgentActivityViewModel {
    private(set) var entries: [AgentActivity] = []
    private(set) var unseen = 0
    /// Bumped on every new entry so the toolbar icon can pulse once.
    private(set) var arrivals = 0
    var hideReads = false

    /// While the panel is open, everything that arrives counts as seen.
    var isOpen = false {
        didSet { if isOpen { markSeen() } }
    }

    var visible: [AgentActivity] { AgentActivityText.visible(entries, hideReads: hideReads) }

    private let store: LogStore
    private var task: Task<Void, Never>?

    init(store: LogStore) {
        self.store = store
        task = Task { [weak self, store] in
            await self?.reload()
            for await change in await store.changes() {
                guard case .agentActivityChanged = change else { continue }
                guard let self else { return }
                await self.reload()
            }
        }
    }

    func reload() async {
        let newest = entries.first?.id
        entries = (try? await store.agentActivity()) ?? []
        if let first = entries.first?.id, first != newest { arrivals += 1 }
        unseen = (try? await store.unseenAgentActivityCount()) ?? 0
        if isOpen && unseen > 0 { markSeen() }
    }

    func markSeen() { Task { try? await store.markAgentActivitySeen() } }

    func clear() { Task { try? await store.clearAgentActivity() } }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentActivityText.copyText(visible), forType: .string)
    }
}
