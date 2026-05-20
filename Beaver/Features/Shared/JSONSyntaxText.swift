//
//  JSONSyntaxText.swift
//  Beaver
//
//  Shared between the log-event detail pane (DetailPaneView) and the
//  Storages detail pane (StoragesView). Produces a single
//  syntax-highlighted SwiftUI Text for one JSON-tree row:
//
//      "key": "value"
//      "key": 42
//      "key": { 3 }
//      [0]: "value"
//
//  Each segment gets its own foregroundColor so SwiftUI renders them
//  as inline-coloured pieces without us needing an HStack — which
//  preserves natural baseline alignment and lets `textSelection` work
//  per-row.
//

import SwiftUI

/// Colour palette + Text builders for the JSON tree rows. Inline
/// `enum`-as-namespace keeps the names short at call sites
/// (`JSONSyntax.row(...)`).
enum JSONSyntax {

    // MARK: - Palette

    // Picked to read well in both light and dark mode and to match
    // the colour vocabulary you'd see in Xcode's JSON quick-look:
    //   keys in a calm purple, strings in warm orange, numbers blue,
    //   bools magenta, null + punctuation muted.

    /// Quoted property name (object keys).
    static let keyColor    = Color(red: 0.55, green: 0.30, blue: 0.75)
    /// String values (between visible quotes).
    static let stringColor = Color(red: 0.85, green: 0.40, blue: 0.20)
    /// Numeric literals.
    static let numberColor = Color(red: 0.10, green: 0.45, blue: 0.85)
    /// `true` / `false`.
    static let boolColor   = Color(red: 0.60, green: 0.20, blue: 0.55)
    /// `null`.
    static let nullColor   = Color.secondary
    /// Quotes, colons, braces, brackets, container summaries.
    static let punctColor  = Color.secondary

    // MARK: - One-row builder

    /// Render one tree row as `keyText: valueText` using inline colour.
    ///
    /// - `key`: the bare key string (no quotes; no brackets for
    ///   array indices — caller decides via `isArrayIndex`).
    /// - `isArrayIndex`: `true` if the key is an array index like
    ///   `[0]`; those are shown unquoted and in muted colour.
    /// - `kind`: what to print on the right side of the colon.
    static func row(key: String, isArrayIndex: Bool, kind: JSONKind) -> Text {
        keyText(key: key, isArrayIndex: isArrayIndex)
            + punctText(": ")
            + valueText(for: kind)
    }

    /// `"key"` (object property) or `[N]` (array index).
    static func keyText(key: String, isArrayIndex: Bool) -> Text {
        if isArrayIndex {
            // Already comes formatted as `[0]`, `[1]`, … from the
            // build step. Print as-is, no quotes.
            return Text(key).foregroundColor(punctColor)
        }
        return punctText("\"")
            + Text(key).foregroundColor(keyColor)
            + punctText("\"")
    }

    /// The right-hand side after the colon.
    static func valueText(for kind: JSONKind) -> Text {
        switch kind {
        case .string(let raw):
            return punctText("\"")
                + Text(escape(raw)).foregroundColor(stringColor)
                + punctText("\"")
        case .number(let n):
            return Text(n).foregroundColor(numberColor)
        case .bool(let b):
            return Text(b ? "true" : "false").foregroundColor(boolColor)
        case .null:
            return Text("null").italic().foregroundColor(nullColor)
        case .object(let c):
            return Text("{ \(c) }").italic().foregroundColor(punctColor)
        case .array(let c):
            return Text("[ \(c) ]").italic().foregroundColor(punctColor)
        }
    }

    // MARK: - Helpers

    private static func punctText(_ s: String) -> Text {
        Text(s).foregroundColor(punctColor)
    }

    /// Escape the two characters JSON strings must escape inside
    /// quotes — backslash and double quote. Other control chars are
    /// already rendered by SwiftUI as themselves; users primarily
    /// care that the value is readable, not strictly JSON-valid.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Detect array-index labels emitted by the build step (`[0]`, `[12]`,
/// …). Exposed as a small helper so both detail panes use the same
/// rule.
extension String {
    var looksLikeJSONArrayIndex: Bool {
        guard hasPrefix("["), hasSuffix("]"), count >= 3 else { return false }
        let inner = dropFirst().dropLast()
        return inner.allSatisfy(\.isNumber)
    }
}
