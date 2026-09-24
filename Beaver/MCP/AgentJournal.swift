//
//  AgentJournal.swift
//  Beaver
//

import Foundation

/// Writes every tool call to the agent activity journal (design M17).
/// The dispatcher calls it, so no tool can forget to.
public struct AgentJournal: Sendable {
    public static let noteCap = 1_000
    public static let lineCap = 300

    let store: LogStore

    public init(store: LogStore) { self.store = store }

    func record(toolName: String, kind: AgentActivity.Kind, client: String?, result: ToolResult?, error: String?) async {
        await write(client: Self.clientName(client), tool: toolName, kind: kind,
                    summary: result?.summary ?? error ?? "", level: result?.level,
                    isError: error != nil, error: error ?? result?.notice,
                    links: result?.links ?? [], sessionId: result?.sessionId)
    }

    /// An entry no tool call wrote: a watch firing (a note), the device
    /// dropping after an agent's command (a system entry).
    public func post(_ kind: AgentActivity.Kind, _ summary: String, tool: String? = nil, level: String? = nil,
                     links: [JournalLink] = [], notice: String? = nil, sessionId: Int64? = nil) async {
        await write(client: nil, tool: tool, kind: kind, summary: summary, level: level,
                    isError: false, error: notice, links: links, sessionId: sessionId)
    }

    private func write(client: String?, tool: String?, kind: AgentActivity.Kind, summary: String,
                       level: String?, isError: Bool, error: String?, links: [JournalLink],
                       sessionId: Int64?) async {
        let cap = kind == .note ? Self.noteCap : Self.lineCap
        _ = try? await store.recordAgentActivity(NewAgentActivity(
            client: client, tool: tool, kind: kind, summary: String(summary.prefix(cap)),
            level: level, isError: isError, error: error,
            linksJSON: JournalLink.encode(links), sessionId: sessionId
        ))
    }

    /// `claude-code/2.1.0 (cli)` → `claude-code`.
    static func clientName(_ userAgent: String?) -> String? {
        guard let first = userAgent?.split(separator: " ").first,
              let name = first.split(separator: "/").first, !name.isEmpty
        else { return nil }
        return String(name)
    }
}
