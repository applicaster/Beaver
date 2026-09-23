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

        for attrRange in result.ranges(from: ranges, in: text) {
            result[attrRange].backgroundColor = Color.yellow.opacity(0.3)
            result[attrRange].foregroundColor = .primary
        }
        return result
    }

    // MARK: - Private

    /// Paint match backgrounds onto an already-styled string, leaving
    /// its existing colours alone. Lets a syntax-coloured JSON row carry
    /// search highlights without giving up either.
    public static func markMatches(
        in attributed: inout AttributedString,
        term: String?,
        isRegex: Bool = false
    ) {
        guard let term, !term.isEmpty else { return }
        let plain = String(attributed.characters)
        let ranges: [Range<String.Index>] = isRegex
            ? regexRanges(in: plain, pattern: term)
            : substringRanges(in: plain, term: term)

        for attrRange in attributed.ranges(from: ranges, in: plain) {
            attributed[attrRange].backgroundColor = Color.yellow.opacity(0.3)
        }
    }

    /// Searches the original string directly, so no index has to be
    /// translated back from a lowercased copy. Each search resumes where
    /// the last one ended — one pass over the text, however many hits.
    /// (Re-measuring every hit from the start made a 40 KB value with a
    /// one-letter term take 0.4 s, and a 157 KB one minutes.)
    static func substringRanges(
        in text: String,
        term: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: term,
                                     options: .caseInsensitive,
                                     range: searchStart..<text.endIndex) {
            ranges.append(range)
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
    /// Translate ranges on the original String to ranges on `self` by
    /// character offset. Ranges come in document order, so both cursors
    /// only ever move forward and the whole walk is linear.
    func ranges(
        from stringRanges: [Range<String.Index>],
        in source: String
    ) -> [Range<AttributedString.Index>] {
        var sourceCursor = source.startIndex
        var cursor = startIndex
        var result: [Range<AttributedString.Index>] = []
        result.reserveCapacity(stringRanges.count)
        for range in stringRanges where range.lowerBound >= sourceCursor {
            let start = index(cursor, offsetByCharacters: source.distance(from: sourceCursor, to: range.lowerBound))
            let end   = index(start, offsetByCharacters: source.distance(from: range.lowerBound, to: range.upperBound))
            result.append(start..<end)
            sourceCursor = range.lowerBound
            cursor = start
        }
        return result
    }
}
