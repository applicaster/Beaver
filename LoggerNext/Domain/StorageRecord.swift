//
//  StorageRecord.swift
//  LoggerNext
//

import Foundation

/// One row in the Storages screen — a key/value pair from the
/// device's session / local / keychain storage. Containers (objects /
/// arrays) carry their children for the OutlineGroup detail view.
///
/// Built from the raw `dataJSON` blob in a `StorageSnapshot` via
/// `parseTopLevel(...)`. Each record's `id` is its JSON path
/// (`"foo.bar[0]"`) — unique and stable across rebuilds, so SwiftUI
/// selection survives a snapshot refresh on the same key set.
public struct StorageRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let valueText: String?
    public let children: [StorageRecord]?

    public var isContainer: Bool { children != nil }
    public var itemCount: Int { children?.count ?? 0 }

    public init(
        id: String,
        key: String,
        valueText: String? = nil,
        children: [StorageRecord]? = nil
    ) {
        self.id = id
        self.key = key
        self.valueText = valueText
        self.children = children
    }

    // MARK: - Parsing

    /// Decode the snapshot's JSON blob and return its top-level rows
    /// (one per key in the root object). Sorted alphabetically.
    public static func parseTopLevel(_ json: String) -> [StorageRecord] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return [] }
        return parsed.keys.sorted().map { key in
            build(key: key, value: parsed[key]!, path: key)
        }
    }

    private static func build(key: String, value: Any, path: String) -> StorageRecord {
        switch value {
        case let dict as [String: Any]:
            let children = dict.keys.sorted().map { k in
                build(key: k, value: dict[k]!, path: "\(path).\(k)")
            }
            return StorageRecord(
                id: path,
                key: key,
                valueText: nil,
                children: children.isEmpty ? nil : children
            )
        case let array as [Any]:
            let children = array.enumerated().map { (i, v) in
                build(key: "[\(i)]", value: v, path: "\(path)[\(i)]")
            }
            return StorageRecord(
                id: path,
                key: key,
                valueText: nil,
                children: children.isEmpty ? nil : children
            )
        case is NSNull:
            return StorageRecord(id: path, key: key, valueText: "null")
        case let b as Bool:
            return StorageRecord(id: path, key: key, valueText: b ? "true" : "false")
        case let n as NSNumber:
            return StorageRecord(id: path, key: key, valueText: n.stringValue)
        case let s as String:
            // Auto-expand: if the string is itself a JSON document
            // (an object or an array), parse it and render as a
            // sub-tree. Helps with the common case of stringified
            // JSON in storage values (`featureFlags`, JWT payloads,
            // etc.). We rebuild against the parsed value so nested
            // stringified-JSON keeps expanding too.
            if let expanded = expandedFromJSONString(s, key: key, path: path) {
                return expanded
            }
            return StorageRecord(id: path, key: key, valueText: s)
        default:
            return StorageRecord(id: path, key: key, valueText: String(describing: value))
        }
    }

    /// Try to parse a stored String as an object/array JSON
    /// literal. Returns a built StorageRecord if successful, nil if
    /// the string isn't JSON-shaped. Only triggers on values that
    /// start with `{` or `[` (after trimming) so we don't accidentally
    /// expand simple scalars like `"true"` or `"42"`.
    private static func expandedFromJSONString(
        _ raw: String,
        key: String,
        path: String
    ) -> StorageRecord? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        // Only treat as expandable if it parsed into a container.
        guard parsed is [String: Any] || parsed is [Any] else { return nil }
        return build(key: key, value: parsed, path: path)
    }

    /// Flat list of self + all descendants — used to find a selected
    /// record by id when the table only shows top-level rows but the
    /// detail pane may need to address any nested node.
    public func allDescendants() -> [StorageRecord] {
        var result = [self]
        if let children {
            for child in children { result.append(contentsOf: child.allDescendants()) }
        }
        return result
    }

    /// Serialize a subtree as pretty-printed JSON for the copy
    /// button in the detail pane. Mirrors what `JSONTreeNode` does
    /// for log-event data/context; the two could be unified into a
    /// shared protocol later if a third tree consumer shows up.
    public static func serializeJSON(_ record: StorageRecord, indent: Int = 0) -> String {
        let pad      = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)

        if let value = record.valueText {
            return jsonLiteral(value)
        }
        guard let children = record.children, !children.isEmpty else {
            return "null"
        }
        // Detect "is this an array?" by checking whether every child
        // label looks like `[0]`, `[1]`, … (the convention used by
        // StorageRecord.build for array elements).
        let isArray = children.allSatisfy {
            $0.key.hasPrefix("[") && $0.key.hasSuffix("]")
        }
        if isArray {
            let parts = children.map { child in
                "\(innerPad)\(serializeJSON(child, indent: indent + 1))"
            }
            return "[\n" + parts.joined(separator: ",\n") + "\n\(pad)]"
        } else {
            let parts = children.map { child in
                let escapedKey = child.key
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\(innerPad)\"\(escapedKey)\": \(serializeJSON(child, indent: indent + 1))"
            }
            return "{\n" + parts.joined(separator: ",\n") + "\n\(pad)}"
        }
    }

    /// Convert a stored `valueText` back to a JSON literal. The
    /// values we hold come pre-stringified from `build(...)` — we
    /// detect numbers / bools / null and emit them as-is, otherwise
    /// treat as a JSON string and escape + quote.
    private static func jsonLiteral(_ value: String) -> String {
        switch value {
        case "null", "true", "false":
            return value
        default:
            break
        }
        // Try numeric — int first, then double.
        if Int64(value) != nil { return value }
        if Double(value) != nil { return value }
        // String — escape and quote.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
