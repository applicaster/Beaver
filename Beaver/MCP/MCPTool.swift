//
//  MCPTool.swift
//  Beaver
//

import Foundation

/// A failure the agent can act on. The message says what to do, with an
/// example call (design M30).
public struct ToolError: Error, Sendable, Equatable {
    public let message: String
    /// The journal kind when it isn't the tool's own: a destructive app
    /// tool that timed out may still have run.
    public let journalKind: AgentActivity.Kind?
    public init(_ message: String, journalKind: AgentActivity.Kind? = nil) {
        self.message = message; self.journalKind = journalKind
    }

    /// The message without its example call, for a toast a person reads.
    public var personMessage: String {
        message.range(of: " Example:").map { String(message[..<$0.lowerBound]) } ?? message
    }
}

public struct ToolResult: Sendable {
    /// First line the agent reads; also the journal line.
    public var summary: String
    /// One row per line, may be empty.
    public var body: String
    public var structured: JSON
    /// Suggested next calls, arguments filled in.
    public var next: [String]
    /// The session the call was about, for the journal's link.
    public var sessionId: Int64?
    /// Journal extras, for notes: `info` / `attention`, what the entry
    /// links to, and a notice shown under it (why a note wasn't notified).
    public var level: String?
    public var links: [JournalLink]
    public var notice: String?
    /// The journal kind when it isn't the tool's own: `tools_call` runs
    /// tools of any kind (a destructive app tool gets the destructive toast).
    public var journalKind: AgentActivity.Kind?

    public init(summary: String, body: String = "", structured: JSON = .object([:]),
                next: [String] = [], sessionId: Int64? = nil,
                level: String? = nil, links: [JournalLink] = [], notice: String? = nil,
                journalKind: AgentActivity.Kind? = nil) {
        self.summary = summary; self.body = body; self.structured = structured
        self.next = next; self.sessionId = sessionId
        self.level = level; self.links = links; self.notice = notice
        self.journalKind = journalKind
    }

    public var text: String {
        var parts = [summary]
        if !body.isEmpty { parts.append(body) }
        if !next.isEmpty { parts.append("Next: " + next.joined(separator: "; ")) }
        return parts.joined(separator: "\n\n")
    }
}

/// A tool's `arguments`, read forgivingly: numbers may arrive as strings,
/// a list may arrive as one value, `null` means absent.
public struct ToolArguments: Sendable {
    public let values: [String: JSON]

    public init(_ values: [String: JSON] = [:]) { self.values = values }

    public subscript(key: String) -> JSON? {
        guard let v = values[key], v != .null else { return nil }
        return v
    }

    public func string(_ key: String) throws -> String? {
        guard let v = self[key] else { return nil }
        if let s = v.string { return s }
        if let n = v.double { return JSON.number(n).text }
        throw ToolError("\(key) must be a string, e.g. \(key): \"…\".")
    }

    public func int(_ key: String) throws -> Int? {
        guard let v = self[key] else { return nil }
        if let i = v.int { return i }
        if let s = v.string, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        throw ToolError("\(key) must be a number, e.g. \(key): 100.")
    }

    public func int64(_ key: String) throws -> Int64? { try int(key).map(Int64.init) }

    public func bool(_ key: String) throws -> Bool? {
        guard let v = self[key] else { return nil }
        if let b = v.bool { return b }
        if let s = v.string?.lowercased(), ["true", "false"].contains(s) { return s == "true" }
        throw ToolError("\(key) must be true or false.")
    }

    public func strings(_ key: String) throws -> [String]? {
        guard let v = self[key] else { return nil }
        let items = v.array ?? [v]
        return try items.map { item in
            if let s = item.string { return s }
            if let n = item.double { return JSON.number(n).text }
            throw ToolError("\(key) must be a list of strings, e.g. \(key): [\"a\", \"b\"].")
        }
    }

    public func int64s(_ key: String) throws -> [Int64]? {
        guard let v = self[key] else { return nil }
        let items = v.array ?? [v]
        return try items.map { item in
            if let i = item.int64 { return i }
            if let s = item.string, let i = Int64(s) { return i }
            throw ToolError("\(key) must be a list of ids, e.g. \(key): [48211, 48212].")
        }
    }

    public func limit(_ key: String = "limit", default fallback: Int, max: Int) throws -> Int {
        let requested = try int(key) ?? fallback
        return Swift.min(max, Swift.max(1, requested))
    }
}

/// Small JSON Schema builders for `inputSchema`. Properties stay open
/// (no `additionalProperties: false`): an extra key from a weak agent is
/// ignored, not an error.
public enum ToolSchema {
    public static func object(_ properties: [String: JSON], required: [String] = []) -> JSON {
        var o: [String: JSON] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { o["required"] = .array(required.map(JSON.string)) }
        return .object(o)
    }

    public static func string(_ description: String, oneOf: [String]? = nil) -> JSON {
        var o: [String: JSON] = ["type": "string", "description": .string(description)]
        if let oneOf { o["enum"] = .array(oneOf.map(JSON.string)) }
        return .object(o)
    }

    public static func integer(_ description: String) -> JSON {
        ["type": "integer", "description": .string(description)]
    }

    public static func boolean(_ description: String) -> JSON {
        ["type": "boolean", "description": .string(description)]
    }

    public static func strings(_ description: String) -> JSON {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    public static func integers(_ description: String) -> JSON {
        ["type": "array", "items": ["type": "integer"], "description": .string(description)]
    }

    public static let sessionId = integer(
        "Session id. Omit it for the live session (with several devices, the viewed one if live, else the newest), else the one the user is viewing, else the most recent.")

    public static let deviceId = string(
        "Which connected app: its deviceId from beaver_status. Omit it for the default device (devices_set_default), or the only connected one.")

    public static let range: [String: JSON] = [
        "afterId": integer("Only events with a larger id (a cursor from an earlier result)."),
        "beforeId": integer("Only events with a smaller id."),
        "since": string("Only events from this time on: a duration back from now (\"30s\", \"5m\", \"2h\", \"1d\") or an ISO 8601 time."),
        "until": string("Only events before this time; same forms as since."),
    ]

    public static let filter: JSON = object([
        "minLevel": string("Lowest level: verbose, debug, info, warning, error. Aliases: warn, err, e, 0–4."),
        "search": string("A query in the Log feed's syntax, the same as zapp-support's web logger; case-insensitive. Words are ANDed and each is found in message, subsystem or category (plus data with searchPayloads); OR joins alternatives, -word excludes, \"a phrase\", /regex/, and level:error (exactly that level; warn = warning), sub:, cat: (* globs), msg:. Example: \"level:error sub:*auth* -heartbeat\"."),
        "searchIsRegex": boolean("Treat the whole search as one regular expression, without the query syntax."),
        "exclude": string("Hide events containing this text."),
        "excludeIsRegex": boolean("Treat exclude as a regular expression."),
        "searchPayloads": boolean("Also search the data payload. Slower on big sessions."),
        "subsystems": strings("Only these subsystems. * globs, name fragments and any case work; the result says what they matched."),
        "excludeSubsystems": strings("Hide these subsystems; same matching as subsystems."),
        "categories": strings("Only these categories; same matching as subsystems."),
        "excludeCategories": strings("Hide these categories; same matching as subsystems."),
    ])
}

public struct MCPTool: Sendable {
    public let name: String
    public let title: String
    /// Starts with "Use when…" (design §8).
    public let description: String
    public let kind: AgentActivity.Kind
    public let idempotent: Bool
    public let inputSchema: JSON
    /// `destructiveHint` when it isn't the kind's: `tools_call` is a change
    /// by default but asks the client to confirm (it runs any app tool).
    public let destructiveHint: Bool?
    public let run: @Sendable (ToolArguments, ToolContext) async throws -> ToolResult

    public init(name: String, title: String, description: String, kind: AgentActivity.Kind,
                idempotent: Bool = false, destructiveHint: Bool? = nil, inputSchema: JSON,
                run: @escaping @Sendable (ToolArguments, ToolContext) async throws -> ToolResult) {
        self.name = name; self.title = title; self.description = description
        self.kind = kind; self.idempotent = idempotent; self.destructiveHint = destructiveHint
        self.inputSchema = inputSchema; self.run = run
    }

    /// The `tools/list` entry.
    public var listing: JSON {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(kind == .read),
                "destructiveHint": .bool(destructiveHint ?? (kind == .destructive)),
                "idempotentHint": .bool(kind == .read || idempotent),
                "openWorldHint": false,
            ],
        ]
    }
}
