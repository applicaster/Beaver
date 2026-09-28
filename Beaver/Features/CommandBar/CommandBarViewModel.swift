//
//  CommandBarViewModel.swift
//  Beaver
//

import Foundation

/// Drives the bottom command bar (D9). Holds the current input text and
/// the history of sent commands, kept in the store across launches. On
/// submit, dispatches to the viewed device via
/// `DeviceLink.send(command:to:)` and pushes the command onto history.
@Observable
@MainActor
final class CommandBarViewModel {

    var input: String = ""

    /// Most recent commands, newest first. Capped at
    /// `LogStore.commandHistoryLimit`.
    private(set) var history: [String] = []

    /// Index into `history` while the user is arrow-navigating.
    /// nil means "user is typing fresh input".
    private var historyCursor: Int?

    private let device: any DeviceLink
    private let store: LogStore

    init(device: any DeviceLink, store: LogStore) {
        self.device = device
        self.store = store
    }

    /// Loads the history saved by earlier launches.
    func loadHistory() async {
        guard let saved = try? await store.commandHistory() else { return }
        // A command sent while loading is newer than anything saved.
        history += saved.filter { !history.contains($0) }
    }

    // MARK: - Send

    func submit(to sessionId: Int64?) {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, let sessionId else { return }
        remember(command)

        // Send to that session's device.
        Task { [device, command] in
            await device.send(command: command, to: sessionId)
        }

        // Reset input + cursor.
        input = ""
        historyCursor = nil
    }

    /// Push onto history (deduped, newest first). Also called for commands
    /// sent from outside the bar — see `Notification.Name.beaverCommandSent`.
    func remember(_ command: String) {
        history.removeAll { $0 == command }
        history.insert(command, at: 0)
        if history.count > LogStore.commandHistoryLimit {
            history.removeLast(history.count - LogStore.commandHistoryLimit)
        }
        Task { [store] in try? await store.recordCommand(command) }
    }

    // MARK: - History navigation

    /// Step backwards through history (older).
    func previousHistory() {
        guard !history.isEmpty else { return }
        let next = (historyCursor ?? -1) + 1
        guard next < history.count else { return }
        historyCursor = next
        input = history[next]
    }

    /// Step forwards through history (newer). Going past the latest
    /// returns the field to an empty / pre-history state.
    func nextHistory() {
        guard let cursor = historyCursor else { return }
        if cursor <= 0 {
            historyCursor = nil
            input = ""
            return
        }
        historyCursor = cursor - 1
        input = history[cursor - 1]
    }
}

extension Notification.Name {
    /// Posted with `object: String` when a command reached the device from
    /// outside the command bar, so it joins the bar's history.
    static let beaverCommandSent = Notification.Name("BeaverCommandSent")
}
