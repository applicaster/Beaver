//
//  JSONFieldPatch.swift
//  Beaver
//

import Foundation

/// Rewrites one field of a JSON document stored as text — how a storage
/// value like `{"volume":0.8}` gets a single field edited or removed.
/// The SDK can only replace a whole key, so the caller sends the result
/// as the key's new value.
///
/// A field is addressed by its `StorageRecord.id` in the tree
/// `LeafDecoder` builds for the text (root path `""`, so `.volume`,
/// `.list[2]`, `.a.b`).
public enum JSONFieldPatch {

    /// Sets the field to `newValue`. A string field takes the text as-is;
    /// any other field reads it as JSON (`0.5`, `true`, `null`,
    /// `{"a":1}`) and falls back to a string when it isn't.
    /// `nil` when the text isn't a JSON object/array or has no such field.
    public static func setting(_ id: String, to newValue: String, in json: String) -> String? {
        patch(json, id, .set(newValue))
    }

    /// Removes the field. `nil` when there is no such field.
    public static func removing(_ id: String, in json: String) -> String? {
        patch(json, id, .remove)
    }

    // MARK: - Internals

    private enum Op {
        case set(String)
        case remove
    }

    private static func patch(_ json: String, _ id: String, _ op: Op) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              root is [String: Any] || root is [Any],
              let patched = apply(op, to: id, in: root, path: "")
        else { return nil }
        return compact(patched)
    }

    /// Compact JSON, keys sorted for a stable result. Hand-written because
    /// `JSONSerialization` prints doubles at full precision — `0.8` came
    /// back as `0.80000000000000004`, rewriting every untouched number.
    private static func compact(_ value: Any) -> String {
        switch value {
        case let dict as [String: Any]:
            let fields = dict.keys.sorted().map { "\(literal($0)):\(compact(dict[$0]!))" }
            return "{" + fields.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(compact).joined(separator: ",") + "]"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let s as String:
            return literal(s)
        default:
            return "null"
        }
    }

    /// A JSON string literal; slashes left unescaped so URLs stay readable
    /// in the command preview.
    private static func literal(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(
                  withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let out = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return out
    }

    /// `value` with the node at `target` changed, or `nil` if not found.
    /// Child paths are built exactly like `StorageRecord.build`.
    private static func apply(_ op: Op, to target: String, in value: Any, path: String) -> Any? {
        if var dict = value as? [String: Any] {
            for (k, v) in dict {
                let child = "\(path).\(k)"
                if child == target {
                    switch op {
                    case .set(let text): dict[k] = newValue(text, replacing: v)
                    case .remove:        dict.removeValue(forKey: k)
                    }
                    return dict
                }
                if target.hasPrefix(child), let patched = apply(op, to: target, in: v, path: child) {
                    dict[k] = patched
                    return dict
                }
            }
        } else if var array = value as? [Any] {
            for (i, v) in array.enumerated() {
                let child = "\(path)[\(i)]"
                if child == target {
                    switch op {
                    case .set(let text): array[i] = newValue(text, replacing: v)
                    case .remove:        array.remove(at: i)
                    }
                    return array
                }
                if target.hasPrefix(child), let patched = apply(op, to: target, in: v, path: child) {
                    array[i] = patched
                    return array
                }
            }
        }
        return nil
    }

    private static func newValue(_ text: String, replacing old: Any) -> Any {
        if old is String { return text }
        if let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            return parsed
        }
        return text
    }
}
