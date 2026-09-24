//
//  AgentJournal.swift
//  Beaver
//

import Foundation

/// Writes every tool call to the agent activity journal (design M17).
/// The dispatcher calls it, so no tool can forget to.
public struct AgentJournal: Sendable {
    let store: LogStore

    public init(store: LogStore) { self.store = store }

    func record(tool: MCPTool, client: String?, result: ToolResult?, error: String?) async {
        let summary = result?.summary ?? error ?? ""
        _ = try? await store.recordAgentActivity(NewAgentActivity(
            client: Self.clientName(client),
            tool: tool.name,
            kind: tool.kind,
            summary: String(summary.prefix(300)),
            isError: error != nil,
            error: error,
            sessionId: result?.sessionId
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
