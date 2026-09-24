import Foundation

/// The SDK's storage edit commands (PROTOCOL.md §3.2):
///
///     storage.<layer>.set <key> <value> [namespace]
///     storage.<layer>.delete <key> [namespace]
///
/// Both SDKs split the whole argument string on spaces with no
/// quoting, so a space anywhere in the value moves every later argument
/// over by one: `set k a b ns` stores `a` in a namespace named `b`.
/// Nothing here can change that, so values with whitespace are refused
/// before sending (`valueProblem`), and JSON is sent compact.
///
/// The SDK answers only with a log line, so the result is read back from
/// the next storage snapshot (`storedValue`, `matches`).
public enum StorageCommand {

    public enum Action: String, Sendable {
        case set, delete
    }

    /// The name the SDK lists in its `cmdlist` reply.
    public static func name(_ action: Action, in layer: StorageSnapshot.Namespace) -> String {
        "storage.\(layer.wireKey).\(action.rawValue)"
    }

    /// Whether the device's `cmdlist` reply lists the command. An empty
    /// list means no reply yet (or an SDK without `cmdlist`) — then
    /// nothing is hidden on a guess.
    public static func isSupported(_ action: Action,
                                   in layer: StorageSnapshot.Namespace,
                                   by names: [String]) -> Bool {
        names.isEmpty || names.contains(name(action, in: layer))
    }

    public static func set(_ layer: StorageSnapshot.Namespace,
                           key: String, value: String, parent: String?) -> String {
        command(.set, layer, [trimmed(key), value], parent)
    }

    public static func delete(_ layer: StorageSnapshot.Namespace,
                              key: String, parent: String?) -> String {
        command(.delete, layer, [trimmed(key)], parent)
    }

    /// What actually goes on the wire for a typed value: JSON objects and
    /// arrays compacted (whitespace outside strings dropped), anything
    /// else exactly as typed.
    public static func wireValue(_ value: String) -> String {
        JSONText.compact(value) ?? value
    }

    /// Why `wireValue` can't be sent as-is — spelled out as what the
    /// device would really do — or `nil` when it's safe.
    public static func valueProblem(_ wireValue: String, parent: String?) -> String? {
        // Split exactly like both SDKs: on single spaces, empties dropped.
        let words = wireValue.split(separator: " ").map(String.init)
        guard wireValue.contains(where: { !$0.isWhitespace }), let first = words.first else {
            return "The device needs a value. To remove the key, use Delete."
        }
        guard wireValue.contains(where: \.isWhitespace) else { return nil }
        guard wireValue.contains(" ") else {
            return "Tabs and line breaks can't be sent in a storage command. Remove them."
        }
        guard words.count > 1 else {
            return "The device drops surrounding spaces: it would store \"\(first)\"."
        }
        let ignored = Array(words.dropFirst(2)) + (normalized(parent).map { [$0] } ?? [])
        var outcome = "it would store \"\(first)\" in a namespace named \"\(words[1])\""
        if !ignored.isEmpty {
            outcome += " and ignore \"\(ignored.joined(separator: " "))\""
        }
        if JSONText.compact(wireValue) != nil {
            return "A JSON string here contains a space, which can't be sent: "
                + "the device splits commands on spaces, so \(outcome)."
        }
        return "The device splits commands on spaces: \(outcome)."
    }

    /// Where both SDKs put a key sent without a namespace.
    public static let defaultNamespace = "applicaster.v2"

    /// The key's stored text in a parsed layer, or `nil` when absent.
    /// `parent` is the namespace, as passed to `set` / `delete`.
    public static func storedValue(in records: [StorageRecord],
                                   parent: String?, key: String) -> String? {
        let namespace = normalized(parent) ?? defaultNamespace
        let scope = records.first { $0.key == namespace }?.children ?? []
        guard let record = scope.first(where: { $0.key == trimmed(key) }) else { return nil }
        switch record.kind {
        case .string(let s):  return s
        case .number(let n):  return n
        case .bool(let b):    return b ? "true" : "false"
        case .null:           return "null"
        case .object, .array: return StorageRecord.serializeJSON(record)
        }
    }

    /// Did the device end up holding what was sent? `nil` = no key (a
    /// delete). JSON compares by content, so reformatting isn't a miss.
    public static func matches(stored: String?, sent: String?) -> Bool {
        switch (stored, sent) {
        case (nil, nil):
            return true
        case let (stored?, sent?):
            if stored == sent { return true }
            guard let a = try? JSONSerialization.jsonObject(with: Data(stored.utf8)),
                  let b = try? JSONSerialization.jsonObject(with: Data(sent.utf8))
            else { return false }
            return (a as AnyObject).isEqual(b)
        default:
            return false
        }
    }

    // MARK: - Send and read back (D58)

    public enum Outcome: String, Sendable {
        /// The next snapshot holds what was sent.
        case applied
        /// The device reported back, still holding something else.
        case notApplied
        /// No snapshot arrived — disconnected, or the SDK is stuck.
        case noAnswer
    }

    /// Sends an edit and reads it back. The SDK reports set / delete only as
    /// a log line, so the proof is the next `storage.list` reply. A reply to
    /// a `storage.list` sent just before the edit can still arrive after it
    /// and show the old value, so a mismatch only counts once no matching
    /// snapshot has shown up within ~3 s. The Storages screen and
    /// `storage_set` / `storage_delete` both come through here (M16).
    public static func sendAndVerify(_ command: String, layer: StorageSnapshot.Namespace, parent: String?,
                                     key: String, expected: String?, sessionId: Int64,
                                     store: LogStore, device: any DeviceLink) async -> Outcome {
        let sentAt = wholeMillisecondNow()
        await device.send(command: command)
        await device.send(command: "storage.list")
        var heardBack = false
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let snap = try? await store.latestStorageSnapshot(sessionId: sessionId, namespace: layer),
                  snap.takenAt >= sentAt else { continue }
            heardBack = true
            let now = storedValue(in: StorageRecord.parseTopLevel(snap.dataJSON), parent: parent, key: key)
            if matches(stored: now, sent: expected) { return .applied }
        }
        return heardBack ? .notApplied : .noAnswer
    }

    /// Sends `storage.list` and waits for the answer: the layers of
    /// `layers` that have a snapshot taken after the request. One `storage`
    /// frame carries every layer, so once one lands the rest get 100 ms.
    public static func refresh(_ layers: [StorageSnapshot.Namespace], sessionId: Int64, timeout: Duration,
                               store: LogStore, device: any DeviceLink) async -> Set<StorageSnapshot.Namespace> {
        let sentAt = wholeMillisecondNow()
        await device.send(command: "storage.list")
        func fresh() async -> Set<StorageSnapshot.Namespace> {
            var found = Set<StorageSnapshot.Namespace>()
            for layer in layers {
                if let snap = try? await store.latestStorageSnapshot(sessionId: sessionId, namespace: layer),
                   snap.takenAt >= sentAt { found.insert(layer) }
            }
            return found
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard !(await fresh()).isEmpty else { continue }
            try? await Task.sleep(for: .milliseconds(100))
            return await fresh()
        }
        return []
    }

    /// Snapshot times are stored in whole milliseconds.
    private static func wholeMillisecondNow() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    // MARK: - Internals

    private static func command(_ action: Action, _ layer: StorageSnapshot.Namespace,
                                _ args: [String], _ parent: String?) -> String {
        ([name(action, in: layer)] + args + (normalized(parent).map { [$0] } ?? []))
            .joined(separator: " ")
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    private static func normalized(_ parent: String?) -> String? {
        guard let p = parent.map(trimmed), !p.isEmpty else { return nil }
        return p
    }
}
