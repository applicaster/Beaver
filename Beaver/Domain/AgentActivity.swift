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

/// What a journal entry points at (design §5.9, §7.2): one of the fields
/// is set. Stored in `links_json` as `[{"eventId":48211}]` — the shape
/// `journal_note(links:)` takes — and opened through `ui_show`'s path
/// (`UITools.open`).
public struct AgentLink: Codable, Hashable, Sendable {
    public var sessionId: Int64?
    public var eventId: Int64?
    public var networkId: Int64?
    public var savedFilter: String?

    public init(sessionId: Int64? = nil, eventId: Int64? = nil,
                networkId: Int64? = nil, savedFilter: String? = nil) {
        self.sessionId = sessionId; self.eventId = eventId
        self.networkId = networkId; self.savedFilter = savedFilter
    }

    /// `Event #48211`, `Request #391`, `Filter “Auth”`, `Session #13`.
    public var label: String {
        if let eventId { return "Event #\(eventId)" }
        if let networkId { return "Request #\(networkId)" }
        if let savedFilter { return "Filter “\(savedFilter)”" }
        if let sessionId { return "Session #\(sessionId)" }
        return "Link"
    }

    /// `nil` for no links, so the column stays NULL.
    public static func encode(_ links: [AgentLink]) -> String? {
        guard !links.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(links)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Unreadable JSON is no links, never a crash: rows outlive app versions.
    public static func decode(_ json: String?) -> [AgentLink] {
        guard let data = json?.data(using: .utf8),
              let links = try? JSONDecoder().decode([AgentLink].self, from: data)
        else { return [] }
        return links.filter { $0 != AgentLink() }
    }
}

extension AgentActivity {
    /// What the row links to: its stored links, else the session the call
    /// was about.
    public var links: [AgentLink] {
        let stored = AgentLink.decode(linksJSON)
        if !stored.isEmpty { return stored }
        return sessionId.map { [AgentLink(sessionId: $0)] } ?? []
    }
}

public enum AgentActivityText {
    public static func visible(_ entries: [AgentActivity], hideReads: Bool) -> [AgentActivity] {
        hideReads ? entries.filter { $0.kind != .read || $0.isError } : entries
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
