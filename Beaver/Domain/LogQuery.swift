import Foundation

/// The Log feed's search syntax — the same language as zapp-support's web
/// logger (`src/utils/logQuery.ts`), ported rule for rule (D88).
///
/// Terms are ANDed; `OR` joins its neighbours into one group (it binds
/// tighter than AND, as in Google). Per term: `-x` excludes, `+x` requires
/// (the same as plain), `"a phrase"`, `/regex/`, and the field prefixes
/// `level:` `cat:` `sub:` `msg:`. Unknown prefixes (`foo:bar`) stay text.
/// `LogStore` compiles the parsed query to SQL.
public enum LogQuery {

    public enum Field: String, Sendable {
        case any, level, cat, sub, msg
    }

    public struct Term: Equatable, Sendable {
        public var field: Field
        public var negated: Bool
        /// Lower-cased. For a regex term, the whole `/…/` token — which is
        /// what `level:` compares against, so `level:/x/` matches nothing,
        /// as in zapp-support.
        public var text: String
        /// The pattern between the slashes; `nil` for a text term.
        public var regex: String?
    }

    /// AND of OR-groups.
    public typealias Parsed = [[Term]]

    public static func parse(_ query: String) -> Parsed {
        var groups: Parsed = []
        var orNext = false
        for token in tokens(query) {
            if token.raw == "OR" {
                orNext = !groups.isEmpty
                continue
            }
            var text = token.body
            var regex: String?
            if text.count > 2, text.hasPrefix("/"), text.hasSuffix("/") {
                let pattern = String(text.dropFirst().dropLast())
                // A half-typed regex constrains nothing, like the regex toggle.
                guard Filter.isValidRegex(pattern) else { continue }
                regex = pattern
            } else if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\"") {
                text = String(text.dropFirst().dropLast())
            }
            if text.isEmpty { continue }
            let term = Term(field: token.prefix.flatMap { Field(rawValue: $0.lowercased()) } ?? .any,
                            negated: token.sign == "-", text: text.lowercased(), regex: regex)
            if orNext { groups[groups.count - 1].append(term) } else { groups.append([term]) }
            orNext = false
        }
        return groups
    }

    /// Why the query won't do what it says — an unclosed quote, a regex
    /// that doesn't compile — or `nil`. The query still runs (the quote is
    /// text, the regex is ignored, as in zapp-support); the field is marked.
    public static func problem(in query: String) -> String? {
        for token in tokens(query) {
            let body = token.body
            if body.hasPrefix("\""), body.count < 2 || !body.hasSuffix("\"") {
                return "Unclosed quote: add the closing \""
            }
            if body.count > 2, body.hasPrefix("/"), body.hasSuffix("/"),
               !Filter.isValidRegex(String(body.dropFirst().dropLast())) {
                return "\(body) is not a valid regular expression"
            }
        }
        return nil
    }

    /// `warn` and `warning` are one level, as in zapp-support.
    static func normalizedLevel(_ level: String) -> String {
        let l = level.lowercased()
        return l == "warn" ? "warning" : l
    }

    /// zapp-support's `TOKEN`, unchanged: sign, field prefix, then a
    /// `"phrase"`, a `/regex/` ending at whitespace (so `/var/log` is a
    /// path), or a run of non-space.
    private static let token = try! NSRegularExpression(
        pattern: #"([-+])?(?:(level|cat|sub|msg):)?("[^"]*"|/(?:\\.|[^/\\])+/(?=\s|$)|\S+)"#,
        options: [.caseInsensitive]
    )

    private static func tokens(_ query: String) -> [(raw: String, sign: String?, prefix: String?, body: String)] {
        let ns = query as NSString
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        return token.matches(in: query, range: NSRange(location: 0, length: ns.length)).map { m in
            (ns.substring(with: m.range), group(m, 1), group(m, 2), group(m, 3) ?? "")
        }
    }
}
