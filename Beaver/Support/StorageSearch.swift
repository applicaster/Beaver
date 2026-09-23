import Foundation

/// The Discover predicate for the storage inspector: plain substring or
/// regular expression, matched against group names, keys and values
/// alike — the same three targets the web viewer searches.
///
/// Pure and separate from the view model so the awkward parts (a pattern
/// that doesn't compile, match ordering) are testable.
public enum StorageSearch {

    /// Compiled once per pass rather than once per node.
    public enum Matcher {
        /// Empty search — everything passes.
        case all
        case plain(String)
        case regex(Regex<AnyRegexOutput>)
        /// `.*` is on and the pattern doesn't compile.
        case invalid

        public var isInvalid: Bool {
            if case .invalid = self { return true }
            return false
        }

        /// True when the matcher narrows anything at all.
        public var isFiltering: Bool {
            switch self {
            case .plain, .regex: return true
            case .all, .invalid: return false
            }
        }

        public func matches(_ text: String) -> Bool {
            switch self {
            case .all:               return true
            case .plain(let needle): return text.lowercased().contains(needle)
            case .regex(let regex):  return text.firstRange(of: regex) != nil
            case .invalid:           return false
            }
        }
    }

    public static func matcher(term: String, isRegex: Bool) -> Matcher {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .all }
        guard isRegex else { return .plain(trimmed.lowercased()) }
        guard let regex = try? Regex(trimmed).ignoresCase() else { return .invalid }
        return .regex(regex)
    }

    /// A node matches on its key or its value. A top-level record's key
    /// is the group name, so group names are covered by the same pass.
    public static func matches(_ node: StorageRecord, _ matcher: Matcher) -> Bool {
        if matcher.matches(node.key) { return true }
        if let value = node.valueText, matcher.matches(value) { return true }
        return false
    }

    /// Top-level records holding at least one match.
    ///
    /// A pattern that doesn't compile returns everything rather than
    /// nothing: the user is mid-keystroke, and emptying the list would
    /// lose their place.
    public static func filter(
        _ records: [StorageRecord],
        with matcher: Matcher
    ) -> [StorageRecord] {
        guard matcher.isFiltering else { return records }
        return records.filter { record in
            record.allDescendants().contains { matches($0, matcher) }
        }
    }

    /// Every matching node in document order, each paired with the
    /// top-level record it lives under and the row that shows it — the
    /// record itself, or the first-level child it sits in. Jumping to a
    /// match expands both and scrolls to that row; the owner alone left a
    /// deep match collapsed and a far-down one off screen.
    public static func collectMatches(
        in records: [StorageRecord],
        with matcher: Matcher
    ) -> [(id: String, ownerId: String, rowId: String)] {
        guard matcher.isFiltering else { return [] }
        var found: [(id: String, ownerId: String, rowId: String)] = []
        for top in filter(records, with: matcher) {
            if matches(top, matcher) {
                found.append((id: top.id, ownerId: top.id, rowId: top.id))
            }
            for child in top.children ?? [] {
                for node in child.allDescendants() where matches(node, matcher) {
                    found.append((id: node.id, ownerId: top.id, rowId: child.id))
                }
            }
        }
        return found
    }
}
