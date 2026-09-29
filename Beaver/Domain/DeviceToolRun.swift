//
//  DeviceToolRun.swift
//  Beaver
//
//  D91: a person runs a connected app's toolbox tool from the device
//  popover. The call itself (params, reply, failures) is shared with the
//  agents' `tools_call` (D75); the form, the confirmation rule and the Log
//  feed line are the person's side.

import Foundation

// MARK: - The call

public enum DeviceToolCall {
    /// `tools/call`'s params.
    public static func params(name: String, arguments: [String: JSON]) -> JSON {
        ["name": .string(name), "arguments": .object(arguments)]
    }

    /// A `tools/call` result (MCP): its text items, structuredContent, the
    /// types of any non-text items, and isError.
    public struct Reply: Sendable, Equatable {
        public let text: String
        public let structuredContent: JSON?
        public let otherTypes: [String]
        public let isError: Bool

        public init(_ reply: JSON) {
            let content = reply["content"]?.array ?? []
            text = content.compactMap { $0["text"]?.string }.joined(separator: "\n")
            structuredContent = reply["structuredContent"]
            otherTypes = content.filter { $0["type"]?.string != "text" }.map { $0["type"]?.string ?? "unknown" }
            isError = reply["isError"]?.bool == true
        }

        /// What to show: structuredContent, else the text if it is JSON, else the text.
        public var value: JSON {
            if let structuredContent { return structuredContent }
            if let parsed = try? JSON.parse(Data(text.utf8)), parsed.object != nil || parsed.array != nil {
                return parsed
            }
            return .string(text)
        }
    }

    /// Why a run didn't give an answer, said for a person.
    public enum Failure: Error, Sendable, Equatable {
        /// Never sent to the app: nothing ran.
        case notSent(String)
        /// Sent, then no answer (timeout, disconnect): it may still have run.
        case mayHaveRun(String)
        /// The app ran it and answered with isError.
        case appError(String)
        /// The app doesn't serve MCP.
        case unsupported
        /// The app's JSON-RPC error.
        case refused(String)

        public var message: String {
            switch self {
            case .notSent(let reason): "Didn't reach the app: \(reason). Nothing ran."
            case .mayHaveRun(let why): "\(why) It may still have run."
            case .appError(let text): "The app says: " + (text.isEmpty ? "error (no text)" : text)
            case .unsupported: "This app doesn't answer MCP — it needs quick-brick-xray's native WebSocket sink."
            case .refused(let message): "The app refused the call: \(message)."
            }
        }

        /// For the Log feed line's data.
        public var kind: String {
            switch self {
            case .notSent: "notSent"
            case .mayHaveRun: "mayHaveRun"
            case .appError: "appError"
            case .unsupported: "unsupported"
            case .refused: "refused"
            }
        }

        public init(_ error: DeviceMCPError) {
            switch error {
            case .notSent(let reason): self = .notSent(reason)
            case .timeout: self = .mayHaveRun("The app didn't answer in time.")
            case .disconnected: self = .mayHaveRun("The app disconnected before answering.")
            case .unsupported: self = .unsupported
            case .rpc(_, let message): self = .refused(message)
            }
        }
    }

    /// One `tools/call` through the app's MCP queue (one request at a time
    /// per app, `DeviceMCPClient.callTimeout`); never throws.
    public static func run(_ name: String, arguments: [String: JSON], on device: any DeviceLink,
                           sessionId: Int64) async -> Result<Reply, Failure> {
        do {
            let raw = try await device.mcp("tools/call", params: params(name: name, arguments: arguments),
                                           to: sessionId, timeout: DeviceMCPClient.callTimeout)
            let reply = Reply(raw)
            return reply.isError ? .failure(.appError(reply.text)) : .success(reply)
        } catch let error as DeviceMCPError {
            return .failure(Failure(error))
        } catch {
            return .failure(.notSent(error.localizedDescription))
        }
    }

    // MARK: Confirmation

    /// A tool whose name (after its toolbox) contains one of these, in any
    /// case, asks before it runs.
    public static let confirmWords = ["restart", "kill", "delete", "remove", "clear", "reset", "set", "logout", "wipe"]

    public static func needsConfirmation(_ name: String) -> Bool {
        let local = (name.lastIndex(of: ".").map { name[name.index(after: $0)...] } ?? name[...]).lowercased()
        return confirmWords.contains { local.contains($0) }
    }

    // MARK: Log feed line

    public static let subsystem = "beaver.tools"
    /// The result kept in the line's data, in characters of its JSON.
    public static let resultCap = 16_000
    /// The arguments shown in the message.
    static let messageArgumentsCap = 200

    /// `You ran app.restart {"hard":true} → ok`, with the arguments and the
    /// (capped) result or error in data.
    public static func logEvent(name: String, arguments: [String: JSON], outcome: Result<Reply, Failure>,
                                at date: Date) -> DecodedEvent {
        var line = "You ran \(name)"
        if !arguments.isEmpty {
            let args = JSON.object(arguments).text
            line += " " + (args.count > messageArgumentsCap ? String(args.prefix(messageArgumentsCap)) + "…" : args)
        }
        var data: [String: JSON] = ["tool": .string(name), "arguments": .object(arguments)]
        switch outcome {
        case .success(let reply):
            line += " → ok"
            data["ok"] = true
            let value = reply.value
            let text = value.text
            if text.count > resultCap {
                data["result"] = .string(String(text.prefix(resultCap)))
                data["resultTruncated"] = true
            } else {
                data["result"] = value
            }
        case .failure(let failure):
            line += " → error: " + failure.message
            data["ok"] = false
            data["error"] = .string(failure.message)
            data["failure"] = .string(failure.kind)
        }
        let isError = if case .failure = outcome { true } else { false }
        return DecodedEvent(timestampMillis: UInt64(max(0, date.timeIntervalSince1970 * 1000)),
                            level: isError ? .warning : .info, subsystem: subsystem, category: "tools",
                            message: line, dataJSON: JSON.object(data).text, contextJSON: nil)
    }
}

// MARK: - History

/// One run a person made; the last `limit` per session stay in memory (D91).
public struct ToolRun: Sendable, Identifiable, Equatable {
    public static let limit = 20

    public let id = UUID()
    public let name: String
    public let arguments: [String: JSON]
    public let at: Date
    /// nil when it ran fine.
    public let error: String?

    public init(name: String, arguments: [String: JSON], at: Date, error: String?) {
        self.name = name; self.arguments = arguments; self.at = at; self.error = error
    }

    /// Newest first, at most `limit`.
    public static func adding(_ run: ToolRun, to runs: [ToolRun]) -> [ToolRun] {
        Array(([run] + runs).prefix(limit))
    }
}

// MARK: - The form

/// One argument's field, from the tool's inputSchema.
public struct ToolFormField: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case text, number, integer, boolean
        case choice([String])
        /// A JSON text field; the schema type: "object", "array" or "any".
        case json(String)
    }

    public let name: String
    public let kind: Kind
    public let required: Bool
    public let help: String
    public let defaultValue: JSON?
    public var id: String { name }

    /// The default, else the type — never a value that gets sent.
    public var placeholder: String {
        if let defaultValue { return "default: " + (defaultValue.string ?? defaultValue.text) }
        switch kind {
        case .text: return required ? "required" : "optional"
        case .number: return "number"
        case .integer: return "whole number"
        case .json(let type): return type == "any" ? "JSON" : "JSON \(type)"
        case .boolean, .choice: return ""
        }
    }
}

public struct ToolFormError: Error, Sendable, Equatable {
    public let field: String
    public let message: String
}

public enum ToolForm {
    /// Required first, then by name (as the popover lists them).
    public static func fields(_ tool: DeviceTool) -> [ToolFormField] {
        let props = tool.inputSchema["properties"]?.object ?? [:]
        return tool.parameters.map { p in
            let schema = props[p.name] ?? .null
            let enumAll = schema["enum"]?.array ?? []
            let kind: ToolFormField.Kind
            if !enumAll.isEmpty, enumAll.count == p.enumValues.count {
                kind = .choice(p.enumValues)
            } else {
                switch p.type {
                case "string": kind = .text
                case "number": kind = .number
                case "integer": kind = .integer
                case "boolean": kind = .boolean
                case "object", "array": kind = .json(p.type)
                default: kind = .json("any")
                }
            }
            return ToolFormField(name: p.name, kind: kind, required: p.required, help: p.description,
                                 defaultValue: schema["default"])
        }
    }

    /// The typed values (booleans as "true"/"false"; "" means not set) as
    /// `tools/call` arguments. Unset optional fields are left out, so the
    /// app applies its own defaults; an unset required checkbox sends its
    /// default, else false.
    public static func arguments(_ values: [String: String], _ fields: [ToolFormField]) throws(ToolFormError)
        -> [String: JSON] {
        var out: [String: JSON] = [:]
        for field in fields {
            let raw = values[field.name] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .boolean = field.kind {
                if !trimmed.isEmpty { out[field.name] = .bool(trimmed == "true") }
                else if field.required { out[field.name] = .bool(field.defaultValue?.bool ?? false) }
                continue
            }
            guard !trimmed.isEmpty else {
                if field.required { throw ToolFormError(field: field.name, message: "\(field.name) is required.") }
                continue
            }
            switch field.kind {
            case .text: out[field.name] = .string(raw)
            case .choice: out[field.name] = .string(trimmed)
            case .number:
                guard let n = Double(trimmed), n.isFinite else {
                    throw ToolFormError(field: field.name, message: "\(field.name) must be a number.")
                }
                out[field.name] = .number(n)
            case .integer:
                guard let n = Int(trimmed) else {
                    throw ToolFormError(field: field.name, message: "\(field.name) must be a whole number.")
                }
                out[field.name] = .number(Double(n))
            case .json(let type):
                let parsed = try? JSON.parse(Data(trimmed.utf8))
                switch (type, parsed) {
                case ("object", let v?) where v.object != nil, ("array", let v?) where v.array != nil:
                    out[field.name] = v
                case ("any", let v?): out[field.name] = v
                case ("any", nil): out[field.name] = .string(raw)
                default:
                    let a = type == "array" ? "an array, e.g. [1, 2]" : "an object, e.g. {\"key\": \"value\"}"
                    throw ToolFormError(field: field.name, message: "\(field.name) must be JSON: \(a).")
                }
            case .boolean: break
            }
        }
        return out
    }
}
