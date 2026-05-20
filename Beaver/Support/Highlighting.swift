//
//  Highlighting.swift
//  Beaver
//

import SwiftUI

/// Match-highlighting for the log feed (D5).
///
/// Returns an `AttributedString` with the search term painted yellow.
/// Designed to be called once per visible cell per filter change — NOT
/// to be re-walked from inside the table's row body on every render the
/// way the old `LoggerViewModel.highlightedText` did (which is what made
/// 3k+ events freeze the main actor).
///
/// Prev/Next occurrence navigation is explicitly dropped per D5.
public enum Highlighting {

    public static func highlight(
        _ text: String,
        term: String?,
        isRegex: Bool = false
    ) -> AttributedString {
        guard let term, !term.isEmpty else {
            return AttributedString(text)
        }
        var result = AttributedString(text)

        let ranges: [Range<String.Index>] = isRegex
            ? regexRanges(in: text, pattern: term)
            : substringRanges(in: text, term: term)

        for range in ranges {
            guard let attrRange = result.range(from: range, in: text) else { continue }
            result[attrRange].backgroundColor = Color.yellow.opacity(0.3)
            result[attrRange].foregroundColor = .primary
        }
        return result
    }

    // MARK: - Private

    private static func substringRanges(
        in text: String,
        term: String
    ) -> [Range<String.Index>] {
        let lower = text.lowercased()
        let needle = term.lowercased()
        var ranges: [Range<String.Index>] = []
        var searchStart = lower.startIndex
        while let range = lower.range(of: needle, range: searchStart..<lower.endIndex) {
            // Translate the case-folded range back onto the original string.
            let originalStart = text.index(text.startIndex,
                                           offsetBy: lower.distance(from: lower.startIndex,
                                                                    to: range.lowerBound))
            let originalEnd = text.index(text.startIndex,
                                         offsetBy: lower.distance(from: lower.startIndex,
                                                                  to: range.upperBound))
            ranges.append(originalStart..<originalEnd)
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func regexRanges(
        in text: String,
        pattern: String
    ) -> [Range<String.Index>] {
        guard let regex = try? Regex(pattern).ignoresCase() else { return [] }
        return text.ranges(of: regex)
    }
}

private extension AttributedString {
    /// Translate a `Range<String.Index>` on the original String to a
    /// range on `self` by character offset.
    func range(
        from stringRange: Range<String.Index>,
        in source: String
    ) -> Range<AttributedString.Index>? {
        let startOffset = source.distance(from: source.startIndex,
                                          to: stringRange.lowerBound)
        let endOffset   = source.distance(from: source.startIndex,
                                          to: stringRange.upperBound)
        let start = index(startIndex, offsetByCharacters: startOffset)
        let end   = index(startIndex, offsetByCharacters: endOffset)
        return start..<end
    }
}
