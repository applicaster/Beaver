//
//  StorageDiff.swift
//  Beaver
//

import Foundation

/// One key that differs between two snapshots of a storage layer (D80).
public struct StorageChange: Hashable, Sendable {
    public enum Kind: String, Sendable { case added, removed, changed }

    /// A field inside a JSON value that differs; `path` is like `user.roles[0]`.
    public struct Field: Hashable, Sendable {
        public let path: String
        public let kind: Kind
        public let old: String?
        public let new: String?
    }

    /// The SDK namespace — the layer's top-level key, e.g. `applicaster.v2`.
    public let namespace: String
    /// The key inside it; nil when the namespace holds a plain value.
    public let key: String?
    public let kind: Kind
    /// The value as stored: a string as is, anything else as compact JSON.
    public let old: String?
    public let new: String?
    /// For a changed value that is JSON on both sides — an object or
    /// array, or JSON text in a string, as the SDK stores most things —
    /// the fields inside it that differ. Empty otherwise.
    public let fields: [Field]

    /// `applicaster.v2/userToken`, as `storage_set` names a key.
    public var path: String { key.map { "\(namespace)/\($0)" } ?? namespace }
}

/// Key-level diff of two snapshots' `dataJSON` (`{namespace: {key: value}}`).
public enum StorageDiff {

    /// What changed from `old` to `new`, by namespace then key. JSON that
    /// doesn't parse counts as an empty layer.
    public static func changes(from old: String, to new: String) -> [StorageChange] {
        let before = entries(old), after = entries(new)
        let ids = Set(before.keys).union(after.keys).sorted {
            ($0.namespace, $0.key ?? "") < ($1.namespace, $1.key ?? "")
        }
        return ids.compactMap { id in
            let a = before[id], b = after[id]
            guard a != b else { return nil }
            var fields: [StorageChange.Field] = []
            if let a, let b, let x = container(a), let y = container(b) {
                diff(x, y, at: "", into: &fields)
            }
            return StorageChange(namespace: id.namespace, key: id.key, kind: kind(a, b),
                                 old: a.map(text), new: b.map(text), fields: fields)
        }
    }

    private struct EntryId: Hashable {
        let namespace: String
        let key: String?
    }

    private static func entries(_ json: String) -> [EntryId: JSON] {
        guard let top = (try? JSON.parse(Data(json.utf8)))?.object else { return [:] }
        var out: [EntryId: JSON] = [:]
        for (ns, value) in top {
            // `{"player-storage": {"undefined": v}}` is a plain top-level
            // key (see StorageRecord.unwrapUndefined).
            if let o = value.object, !(o.count == 1 && o["undefined"] != nil) {
                for (k, v) in o { out[EntryId(namespace: ns, key: k)] = v }
            } else {
                out[EntryId(namespace: ns, key: nil)] = value.object?["undefined"] ?? value
            }
        }
        return out
    }

    /// An object or array, or a string holding one.
    private static func container(_ value: JSON) -> JSON? {
        switch value {
        case .object, .array: return value
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{") || t.hasPrefix("["),
                  let parsed = try? JSON.parse(Data(t.utf8)) else { return nil }
            return parsed.object != nil || parsed.array != nil ? parsed : nil
        default: return nil
        }
    }

    private static func diff(_ a: JSON?, _ b: JSON?, at path: String, into out: inout [StorageChange.Field]) {
        guard a != b else { return }
        // JSON text nested inside JSON text is unwrapped too.
        switch (a.map { container($0) ?? $0 }, b.map { container($0) ?? $0 }) {
        case (.object(let x)?, .object(let y)?):
            for k in Set(x.keys).union(y.keys).sorted() {
                diff(x[k], y[k], at: path.isEmpty ? k : "\(path).\(k)", into: &out)
            }
        case (.array(let x)?, .array(let y)?):
            // ponytail: index by index — an item inserted at the front marks
            // every later one as changed. Match items (LCS) if that bites.
            // `as JSON?`: a bare `nil` here would be JSON's own `.null`.
            for i in 0..<max(x.count, y.count) {
                diff(i < x.count ? x[i] as JSON? : nil, i < y.count ? y[i] as JSON? : nil,
                     at: "\(path)[\(i)]", into: &out)
            }
        default:
            out.append(.init(path: path.isEmpty ? "(value)" : path, kind: kind(a, b),
                             old: a.map(text), new: b.map(text)))
        }
    }

    private static func kind(_ a: JSON?, _ b: JSON?) -> StorageChange.Kind {
        a == nil ? .added : b == nil ? .removed : .changed
    }

    private static func text(_ value: JSON) -> String {
        value.string ?? value.text
    }
}
