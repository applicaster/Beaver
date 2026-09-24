//
//  AgentActivityViewModel.swift
//  Beaver
//

import AppKit
import Observation
import SwiftUI

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
    private let toasts: ToastCenter
    private var task: Task<Void, Never>?
    /// Newest id already signalled; nil until the first load, so entries
    /// from before this launch never toast.
    private var signalledThrough: Int64?

    init(store: LogStore, toasts: ToastCenter) {
        self.store = store
        self.toasts = toasts
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
        if let through = signalledThrough {
            for entry in entries.prefix(while: { $0.id > through }).reversed() { signal(entry) }
        }
        signalledThrough = max(signalledThrough ?? 0, entries.first?.id ?? 0)
        unseen = (try? await store.unseenAgentActivityCount()) ?? 0
        // Design §7.2: the Dock badge counts unseen attention notes only.
        let attention = entries.filter { !$0.seen && $0.isAttention }.count
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
        if isOpen && unseen > 0 { markSeen() }
    }

    /// Destructive calls and attention notes get a 6 s toast (design §7.2).
    private func signal(_ entry: AgentActivity) {
        guard let toast = entry.toast else { return }
        let action: ToastAction = switch toast.button {
        case .journal: ToastAction(title: "Journal") { AgentNotifier.shared.openPanel() }
        case .show(let link): ToastAction(title: "Show") { AgentNotifier.shared.show([link]) }
        }
        let destructive = entry.kind == .destructive
        toasts.show(toast.message,
                    icon: destructive ? "exclamationmark.triangle.fill" : "sparkles",
                    tint: destructive ? .orange : .accentColor,
                    duration: 6, action: action)
    }

    func markSeen() { Task { try? await store.markAgentActivitySeen() } }

    func clear() { Task { try? await store.clearAgentActivity() } }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentActivityText.copyText(visible), forType: .string)
    }
}
