import Foundation

/// Reformats JSON object/array text without parsing it into values, so
/// key order and number spelling (`0.80`) survive — re-serializing
/// would sort keys and print `0.8` as `0.80000000000000004`.
public enum JSONText {

    /// First non-blank character opens an object or array — the user
    /// means JSON, so it has to parse.
    public static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    public static func isValid(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    /// Whitespace outside strings removed. `nil` unless `text` is a
    /// valid JSON object or array.
    public static func compact(_ text: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              root is [String: Any] || root is [Any]
        else { return nil }
        var out = ""
        var inString = false, escaped = false
        for c in text {
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
                out.append(c)
            } else if !c.isWhitespace {
                out.append(c)
            }
        }
        return out
    }

    /// Two-space indented, `"key": value`. `nil` unless `text` is a
    /// valid JSON object or array.
    public static func pretty(_ text: String) -> String? {
        guard let compact = compact(text) else { return nil }
        let chars = Array(compact)
        var out = ""
        var depth = 0
        var inString = false, escaped = false
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        for (i, c) in chars.enumerated() {
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                out.append(c)
                // Valid JSON never ends on an opener, so i + 1 exists.
                if chars[i + 1] != "}" && chars[i + 1] != "]" {
                    depth += 1
                    newline()
                }
            case "}", "]":
                // Outside a string the previous character is an opener
                // only for an empty container.
                if chars[i - 1] != "{" && chars[i - 1] != "[" {
                    depth -= 1
                    newline()
                }
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out += ": "
            default:
                out.append(c)
            }
        }
        return out
    }
}
