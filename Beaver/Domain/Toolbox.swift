//
//  Toolbox.swift
//  Beaver
//
//  D75: a connected app's tools, from its MCP `tools/list`, grouped into
//  toolboxes by the name's prefix (`storage.set` → `storage`). Beaver's
//  own tools are device "beaver", its toolboxes named the same way
//  (`logs_query` → `logs.query`).

import Foundation

public struct ToolParameter: Sendable, Equatable {
    public let name: String
    public let type: String
    public let required: Bool
    public let description: String
    public let enumValues: [String]

    /// `key: string (required) — The key`, `layer: string, one of a|b`.
    public var line: String {
        var s = "\(name): \(type)"
        if required { s += " (required)" }
        if !enumValues.isEmpty { s += ", one of " + enumValues.joined(separator: "|") }
        if !description.isEmpty { s += " — " + description }
        return s
    }
}

public struct DeviceTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSON

    public init(name: String, description: String, inputSchema: JSON) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }

    /// From `inputSchema.properties`: required first, then by name.
    public var parameters: [ToolParameter] {
        let props = inputSchema["properties"]?.object ?? [:]
        let required = Set(inputSchema["required"]?.array?.compactMap(\.string) ?? [])
        func rank(_ key: String) -> (Int, String) { (required.contains(key) ? 0 : 1, key) }
        return props.keys.sorted { rank($0) < rank($1) }.map { key in
            let p = props[key] ?? .null
            return ToolParameter(name: key, type: p["type"]?.string ?? "any", required: required.contains(key),
                                 description: p["description"]?.string ?? "",
                                 enumValues: p["enum"]?.array?.compactMap(\.string) ?? [])
        }
    }

    /// `storage.set(key: string, value: string, namespace?: string)`.
    public var signature: String {
        name + "(" + parameters.map { $0.name + ($0.required ? "" : "?") + ": " + $0.type }
            .joined(separator: ", ") + ")"
    }

    /// `{key: …, value: …}`, the required arguments, for a `Next:` line.
    public var exampleArguments: String {
        "{" + parameters.filter(\.required).map { "\($0.name): …" }.joined(separator: ", ") + "}"
    }
}

public struct Toolbox: Sendable, Equatable {
    public let name: String
    public let tools: [DeviceTool]
}

public enum Toolboxes {
    /// Where a tool name without a prefix goes.
    public static let otherName = "other"

    public static func name(of tool: String) -> String {
        guard let dot = tool.firstIndex(of: "."), dot != tool.startIndex else { return otherName }
        return String(tool[..<dot])
    }

    /// Sorted by toolbox, then by tool name.
    public static func group(_ tools: [DeviceTool]) -> [Toolbox] {
        Dictionary(grouping: tools, by: { name(of: $0.name) })
            .map { Toolbox(name: $0.key, tools: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    /// A `tools/list` result; entries without a name are skipped, and a
    /// name listed twice keeps its first entry.
    public static func tools(fromListResult result: JSON) -> [DeviceTool] {
        var seen = Set<String>()
        return (result["tools"]?.array ?? []).compactMap { entry in
            guard let name = entry["name"]?.string, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return DeviceTool(name: name, description: entry["description"]?.string ?? "",
                              inputSchema: entry["inputSchema"] ?? ["type": "object"])
        }
    }

    /// `logs_query` → `logs.query`.
    public static func beaverName(_ tool: String) -> String { replacingFirst("_", with: ".", in: tool) }

    /// `logs.query` → `logs_query`.
    public static func beaverToolName(_ dotted: String) -> String { replacingFirst(".", with: "_", in: dotted) }

    private static func replacingFirst(_ a: Character, with b: Character, in s: String) -> String {
        guard let i = s.firstIndex(of: a) else { return s }
        var out = s
        out.replaceSubrange(i...i, with: String(b))
        return out
    }
}

/// What the device popover shows under Toolboxes (D75).
public enum ToolboxLoad: Sendable, Equatable {
    case loading
    case loaded([Toolbox])
    /// The app doesn't answer MCP (JS-only sink, older SDK).
    case unsupported
    case failed(String)

    /// Asks the app for its tools now; React toolboxes come and go, so nothing is cached.
    public static func fetch(from device: any DeviceLink, sessionId: Int64) async -> ToolboxLoad {
        do {
            let result = try await device.mcp("tools/list", params: [:], to: sessionId,
                                              timeout: DeviceMCPClient.listTimeout)
            return .loaded(Toolboxes.group(Toolboxes.tools(fromListResult: result)))
        } catch DeviceMCPError.unsupported {
            return .unsupported
        } catch DeviceMCPError.timeout {
            return .failed("The app didn't answer in time.")
        } catch DeviceMCPError.disconnected {
            return .failed("The app disconnected.")
        } catch DeviceMCPError.rpc(_, let message) {
            return .failed(message)
        } catch DeviceMCPError.notSent(let reason) {
            return .failed(reason.prefix(1).uppercased() + reason.dropFirst() + ".")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
