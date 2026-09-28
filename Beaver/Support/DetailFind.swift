import Foundation

/// Find inside the log detail pane (D84): which parts of one event match,
/// in the order the pane shows them — the message, then DATA, then CONTEXT.
/// A tree match is a row (key or stored value, as `StorageSearch` matches);
/// the message counts once however often the term occurs in it.
public enum DetailFind {

    public enum Section: Sendable, Hashable {
        case message, data, context
    }

    public struct Match: Sendable, Hashable {
        public let section: Section
        /// The matching row's `StorageRecord.id`; `nil` for the message.
        public let id: String?
        /// Parent id → index of the child on the way down to the match.
        /// Opening each parent and showing its list up to that index puts
        /// the match on screen.
        public let reveal: [String: Int]
    }

    public static func matches(
        message: String,
        data: StorageRecord?,
        context: StorageRecord?,
        term: String,
        isRegex: Bool
    ) -> [Match] {
        let matcher = StorageSearch.matcher(term: term, isRegex: isRegex)
        guard matcher.isFiltering else { return [] }
        var found: [Match] = []
        if matcher.matches(message) {
            found.append(Match(section: .message, id: nil, reveal: [:]))
        }
        var path: [(id: String, index: Int)] = []
        if let data { walk(data, .data, matcher, &path, &found) }
        if let context { walk(context, .context, matcher, &path, &found) }
        return found
    }

    /// Pre-order, so matches come in the order the rows are drawn. The path
    /// is materialised only for a match, not copied per node.
    private static func walk(
        _ node: StorageRecord,
        _ section: Section,
        _ matcher: StorageSearch.Matcher,
        _ path: inout [(id: String, index: Int)],
        _ found: inout [Match]
    ) {
        if StorageSearch.matches(node, matcher) {
            let reveal = Dictionary(path.map { ($0.id, $0.index) }, uniquingKeysWith: { _, last in last })
            found.append(Match(section: section, id: node.id, reveal: reveal))
        }
        for (index, child) in (node.children ?? []).enumerated() {
            path.append((node.id, index))
            walk(child, section, matcher, &path, &found)
            path.removeLast()
        }
    }
}
