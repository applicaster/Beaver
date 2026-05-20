//
//  CommandBarViewModel.swift
//  Beaver
//

import Foundation

/// Drives the bottom command bar (D9). Holds the current input text and
/// an in-memory history of previously-sent commands. On submit, dispatches
/// to `WSServer.send(command:)` and pushes the command onto history.
///
/// Persistent on-disk history + autocomplete from `cmdlist` are tracked
/// for a follow-up pass. For now: in-memory ring buffer.
@Observable
@MainActor
final class CommandBarViewModel {

    var input: String = ""

    /// Most recent commands, newest first. Capped at 50 for memory.
    private(set) var history: [String] = []

    /// Index into `history` while the user is arrow-navigating.
    /// nil means "user is typing fresh input".
    private var historyCursor: Int?

    private let server: WSServer
    private let historyLimit = 50

    init(server: WSServer) {
        self.server = server
    }

    // MARK: - Send

    func submit() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        // Push to history (deduped, newest first).
        history.removeAll { $0 == command }
        history.insert(command, at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }

        // Send via the server.
        Task { [server, command] in
            await server.send(command: command)
        }

        // Reset input + cursor.
        input = ""
        historyCursor = nil
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
