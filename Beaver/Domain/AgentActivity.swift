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

/// What a journal entry points at (design §5.9). Stored in `links_json`
/// as `[{"eventId":48211},{"networkId":391},{"sessionId":13},{"savedFilter":"Auth"}]`.
public enum JournalLink: Sendable, Hashable {
    case session(Int64)
    case event(Int64)
    case network(Int64)
    case savedFilter(String)

    /// `event #48211`, `request #391`, `session #13`, `filter “Auth”`.
    public var label: String {
        switch self {
        case .session(let id): "session #\(id)"
        case .event(let id): "event #\(id)"
        case .network(let id): "request #\(id)"
        case .savedFilter(let name): "filter “\(name)”"
        }
    }

    public var json: JSON {
        switch self {
        case .session(let id): ["sessionId": JSON(id)]
        case .event(let id): ["eventId": JSON(id)]
        case .network(let id): ["networkId": JSON(id)]
        case .savedFilter(let name): ["savedFilter": .string(name)]
        }
    }

    public init?(json: JSON) {
        if let id = json["eventId"]?.int64 { self = .event(id) }
        else if let id = json["networkId"]?.int64 { self = .network(id) }
        else if let id = json["sessionId"]?.int64 { self = .session(id) }
        else if let name = json["savedFilter"]?.string { self = .savedFilter(name) }
        else { return nil }
    }

    public static func encode(_ links: [JournalLink]) -> String? {
        links.isEmpty ? nil : JSON.array(links.map(\.json)).text
    }

    public static func decode(_ text: String?) -> [JournalLink] {
        guard let text, let items = (try? JSON.parse(Data(text.utf8)))?.array else { return [] }
        return items.compactMap(JournalLink.init(json:))
    }
}

/// A toast in Beaver's window for a journal entry (design §7.2): only
/// destructive calls and attention notes interrupt.
public struct AgentToast: Sendable, Equatable {
    public enum Button: Sendable, Equatable {
        /// Opens the Agent panel.
        case journal
        /// Brings Beaver forward on what the note points at.
        case show(JournalLink)
    }
    public let message: String
    public let button: Button
}

extension AgentActivity {
    public static let attention = "attention"

    public var links: [JournalLink] { JournalLink.decode(linksJSON) }

    /// What the Agent panel links the row to: its stored links, else the
    /// session the call was about.
    public var shownLinks: [JournalLink] {
        let stored = links
        return stored.isEmpty ? sessionId.map { [.session($0)] } ?? [] : stored
    }

    /// A `journal_note(level: attention)`, or a watch that fired.
    public var isAttention: Bool { kind == .note && level == Self.attention }

    public var toast: AgentToast? {
        guard !isError else { return nil }
        if kind == .destructive { return AgentToast(message: "Agent: \(summary)", button: .journal) }
        if isAttention { return AgentToast(message: summary, button: links.first.map { .show($0) } ?? .journal) }
        return nil
    }
}

public enum AgentActivityText {
    public static func visible(_ entries: [AgentActivity], hideReads: Bool) -> [AgentActivity] {
        hideReads ? entries.filter { $0.kind != .read || $0.isError } : entries
    }

    /// `14:03:12 claude-code logs_query — 41 events`, links after `→`,
    /// `✗` on failures, a notice (why a note wasn't notified) in brackets.
    public static func line(_ a: AgentActivity) -> String {
        let who = a.client ?? "agent"
        let what = a.tool ?? a.kind.rawValue
        var text = "\(timeFormatter.string(from: a.at)) \(who) \(what) — \(a.summary)"
        let links = a.links
        if !links.isEmpty { text += " → " + links.map(\.label).joined(separator: ", ") }
        if a.isError {
            text += " ✗"
        } else if let notice = a.error {
            text += " (\(notice))"
        }
        return text
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
