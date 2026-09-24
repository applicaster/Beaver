//
//  TruncatedJSON.swift
//  Beaver
//

import Foundation

/// Best-effort repair of a JSON body the SDK cut at 100 000 characters.
enum TruncatedJSON {

    static let marker = "... [TRUNCATED]"
    /// Characters the SDK keeps before appending `marker`.
    static let limit = 100_000

    /// The document up to its last complete value, with the open containers
    /// closed: `{"a":1,"b":"hal` → `{"a":1}`. A dangling `,`, key or `key:`
    /// is dropped, and so is a trailing number or literal, which may be
    /// cut short. `nil` unless the text starts with `{` or `[` and the
    /// result parses.
    static func repair(_ text: String) -> String? {
        var bytes = Array((text.hasSuffix(marker) ? String(text.dropLast(marker.count)) : text).utf8)
        guard let first = bytes.firstIndex(where: { !isSpace($0) }), bytes[first] == UInt8(ascii: "{")
                || bytes[first] == UInt8(ascii: "[") else { return nil }

        enum State { case key, colon, value, afterValue }
        var stack: [UInt8] = []
        var state = State.value
        var inString = false, isKey = false, escaped = false, inScalar = false
        // Where a complete element ends, and the containers open there.
        var cut = 0, cutStack: [UInt8] = []

        scan: for i in first..<bytes.count {
            let c = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if c == UInt8(ascii: "\\") { escaped = true }
                else if c == UInt8(ascii: "\"") {
                    inString = false
                    if isKey { state = .colon } else { state = .afterValue; (cut, cutStack) = (i + 1, stack) }
                }
                continue
            }
            if inScalar {
                guard isSpace(c) || c == UInt8(ascii: ",") || c == UInt8(ascii: "}") || c == UInt8(ascii: "]")
                else { continue }
                inScalar = false
                state = .afterValue
                (cut, cutStack) = (i, stack)
            }
            switch c {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                stack.append(c)
                state = c == UInt8(ascii: "{") ? .key : .value
                (cut, cutStack) = (i + 1, stack)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                stack.removeLast()
                state = .afterValue
                (cut, cutStack) = (i + 1, stack)
                if stack.isEmpty { break scan }
            case UInt8(ascii: "\""):
                inString = true
                isKey = state == .key
            case UInt8(ascii: ":"):
                state = .value
            case UInt8(ascii: ","):
                state = stack.last == UInt8(ascii: "{") ? .key : .value
            default:
                if !isSpace(c) { inScalar = true }
            }
        }

        bytes.removeSubrange(cut...)
        bytes += cutStack.reversed().map { $0 == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]") }
        guard (try? JSONSerialization.jsonObject(with: Data(bytes))) != nil else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
    }
}
