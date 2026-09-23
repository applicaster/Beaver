//
//  StorageRecord.swift
//  Beaver
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
    /// What the value actually is — string / number / bool / null /
    /// container. Set by `build(...)` for proper syntax-colouring in
    /// the detail pane (StoragesView). Containers carry their child
    /// count so the row can render `{ N }` / `[ N ]` without re-counting.
    public let kind: JSONKind

    public var isContainer: Bool { children != nil }
    public var itemCount: Int { children?.count ?? 0 }

    public init(
        id: String,
        key: String,
        valueText: String? = nil,
        children: [StorageRecord]? = nil,
        kind: JSONKind = .null
    ) {
        self.id = id
        self.key = key
        self.valueText = valueText
        self.children = children
        self.kind = kind
    }

    // MARK: - Parsing

    /// Decode the snapshot's JSON blob and return its top-level rows
    /// (one per key in the root object). Sorted alphabetically.
    /// Parse a whole JSON document into a single labelled root.
    ///
    /// Used by the log detail pane, where DATA / CONTEXT are rendered as
    /// one tree. The storage screen uses `parseTopLevel` instead, because
    /// there the top-level keys are namespaces and each gets its own
    /// section.
    public static func parse(_ json: String, rootKey: String = "root") -> StorageRecord? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        return build(key: rootKey, value: raw, path: "$")
    }

    public static func parseTopLevel(_ json: String) -> [StorageRecord] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return [] }
        return parsed.keys.sorted().map { key in
            build(key: key, value: unwrapUndefined(parsed[key]!), path: key)
        }
    }

    /// The SDK groups keys by splitting on the namespace separator; a
    /// key with no separator comes out as `{"player-storage": {"undefined": v}}`.
    /// It is really a plain top-level key, so show it as one — that also
    /// makes edit / delete target `player-storage` itself instead of a
    /// bogus `undefined` key inside it.
    private static func unwrapUndefined(_ value: Any) -> Any {
        guard let dict = value as? [String: Any], dict.count == 1,
              let inner = dict["undefined"] else { return value }
        return inner
    }

    /// Ids of the rows the Storages screen shows (top-level records and
    /// their direct children) that are new or hold a different value in
    /// `new` than in `old`. A top-level row counts as changed when
    /// anything inside it did, so a collapsed namespace still signals.
    public static func changedRowIds(from old: [StorageRecord],
                                     to new: [StorageRecord]) -> Set<String> {
        func rows(_ records: [StorageRecord]) -> [String: StorageRecord] {
            var out: [String: StorageRecord] = [:]
            for r in records {
                out[r.id] = r
                for c in r.children ?? [] { out[c.id] = c }
            }
            return out
        }
        let before = rows(old)
        return Set(rows(new).compactMap { id, record in
            before[id] == record ? nil : id
        })
    }

    /// Build a record from an already-parsed `JSONSerialization` value.
    ///
    /// Exposed for `LeafDecoder`, which decodes a wrapped value (Base64 /
    /// JWT / JSON text) into a plain object graph and needs it rendered
    /// with the same tree the rest of the storage screen uses.
    public static func make(key: String, value: Any, path: String) -> StorageRecord {
        build(key: key, value: value, path: path)
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
                children: children.isEmpty ? nil : children,
                kind: .object(count: children.count)
            )
        case let array as [Any]:
            let children = array.enumerated().map { (i, v) in
                build(key: "[\(i)]", value: v, path: "\(path)[\(i)]")
            }
            return StorageRecord(
                id: path,
                key: key,
                valueText: nil,
                children: children.isEmpty ? nil : children,
                kind: .array(count: children.count)
            )
        case is NSNull:
            return StorageRecord(id: path, key: key, valueText: "null", kind: .null)
        // Checked by CF type, not `as Bool`: that cast also succeeds for
        // an NSNumber 0 or 1, which turned a JSON `1` into `true`.
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
            let b = n.boolValue
            return StorageRecord(
                id: path,
                key: key,
                valueText: b ? "true" : "false",
                kind: .bool(b)
            )
        case let n as NSNumber:
            return StorageRecord(
                id: path,
                key: key,
                valueText: n.stringValue,
                kind: .number(n.stringValue)
            )
        case let s as String:
            // Deliberately NOT unwrapped here. A device stores almost
            // everything as text, so a string is very often JSON, Base64
            // or a token — but the raw string has to stay the source of
            // truth for copy and edit. `LeafDecoder` builds the Formatted
            // view at render time, alongside the raw one.
            return StorageRecord(id: path, key: key, valueText: s, kind: .string(s))
        default:
            let described = String(describing: value)
            return StorageRecord(
                id: path,
                key: key,
                valueText: described,
                kind: .string(described)
            )
        }
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

    /// Pretty-print a record back to JSON — the copy action on every
    /// tree row.
    ///
    /// Dispatches on `kind` rather than inspecting the children's key
    /// shape: a lone object key literally named `[0]` would otherwise be
    /// emitted as an array, and an empty container as `null`.
    public static func serializeJSON(_ record: StorageRecord, indent: Int = 0) -> String {
        let pad      = String(repeating: "  ", count: indent)
        let innerPad = String(repeating: "  ", count: indent + 1)

        switch record.kind {
        case .null:          return "null"
        case .bool(let b):   return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return escapedLiteral(s)
        case .object:
            guard let children = record.children, !children.isEmpty else { return "{}" }
            let parts = children.map { child in
                "\(innerPad)\(escapedLiteral(child.key)): \(serializeJSON(child, indent: indent + 1))"
            }
            return "{\n" + parts.joined(separator: ",\n") + "\n\(pad)}"
        case .array:
            guard let children = record.children, !children.isEmpty else { return "[]" }
            let parts = children.map { child in
                "\(innerPad)\(serializeJSON(child, indent: indent + 1))"
            }
            return "[\n" + parts.joined(separator: ",\n") + "\n\(pad)]"
        }
    }

    /// A JSON string literal for `raw`, `"`/`\` and control characters
    /// (newline, tab, …) all escaped. Delegates to `JSONSerialization`
    /// rather than hand-rolling the control-character table.
    private static func escapedLiteral(_ raw: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: raw, options: [.fragmentsAllowed, .withoutEscapingSlashes]
        ) else {
            // Every String is representable as a JSON string; this is
            // unreachable in practice, but fall back to the old
            // (unsafe-for-control-characters) escaping rather than crash.
            let escaped = raw
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
