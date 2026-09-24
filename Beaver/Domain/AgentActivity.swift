//
//  AgentActivity.swift
//  Beaver
//

import Foundation

/// One line of the agent activity journal (design §7.2, M17): a tool
/// call, an agent's note, or a system event. Stored in `agent_activity`,
/// never part of a session export.
public struct AgentActivity: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case read, change, destructive, note, system
    }

    public let id: Int64
    public let at: Date
    public let client: String?
    public let tool: String?
    public let kind: Kind
    public let summary: String
    public let level: String?
    public let isError: Bool
    public let error: String?
    public let linksJSON: String?
    public let sessionId: Int64?
    public let seen: Bool

    public init(id: Int64, at: Date, client: String?, tool: String?, kind: Kind,
                summary: String, level: String?, isError: Bool, error: String?,
                linksJSON: String?, sessionId: Int64?, seen: Bool) {
        self.id = id; self.at = at; self.client = client; self.tool = tool
        self.kind = kind; self.summary = summary; self.level = level
        self.isError = isError; self.error = error; self.linksJSON = linksJSON
        self.sessionId = sessionId; self.seen = seen
    }
}

/// What the dispatcher (or, later, a note or system event) writes.
public struct NewAgentActivity: Sendable {
    public let client: String?
    public let tool: String?
    public let kind: AgentActivity.Kind
    public let summary: String
    public let level: String?
    public let isError: Bool
    public let error: String?
    public let linksJSON: String?
    public let sessionId: Int64?

    public init(client: String?, tool: String?, kind: AgentActivity.Kind, summary: String,
                level: String? = nil, isError: Bool = false, error: String? = nil,
                linksJSON: String? = nil, sessionId: Int64? = nil) {
        self.client = client; self.tool = tool; self.kind = kind; self.summary = summary
        self.level = level; self.isError = isError; self.error = error
        self.linksJSON = linksJSON; self.sessionId = sessionId
    }
}

public enum AgentActivityText {
    public static func visible(_ entries: [AgentActivity], hideReads: Bool) -> [AgentActivity] {
        hideReads ? entries.filter { $0.kind != .read } : entries
    }

    /// `14:03:12 claude-code logs_query — 41 events`, `✗` on failures.
    public static func line(_ a: AgentActivity) -> String {
        let who = a.client ?? "agent"
        let what = a.tool ?? a.kind.rawValue
        return "\(timeFormatter.string(from: a.at)) \(who) \(what) — \(a.summary)" + (a.isError ? " ✗" : "")
    }

    public static func copyText(_ entries: [AgentActivity]) -> String {
        entries.map(line).joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = .init(identifier: "en_US_POSIX")
        return f
    }()
}
