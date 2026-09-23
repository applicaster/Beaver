import Testing
import Foundation
import SwiftUI
@testable import BeaverCore

@Suite("Highlighting")
struct HighlightingTests {

    /// The painted stretches, as text.
    private static func painted(_ s: AttributedString) -> [String] {
        s.runs.compactMap { run in
            run.backgroundColor == nil ? nil : String(s[run.range].characters)
        }
    }

    @Test
    func paintsEveryCaseInsensitiveHit() {
        let out = Highlighting.highlight("Player pLAYs — playlist", term: "play")
        #expect(Self.painted(out) == ["Play", "pLAY", "play"])
    }

    @Test
    func keepsPositionsPastWideCharacters() {
        // Emoji and combining marks are several scalars but one Character;
        // an off-by-scalar translation would paint the wrong letters.
        let out = Highlighting.highlight("👩‍👩‍👧 é ab 👍🏽 AB", term: "ab")
        #expect(Self.painted(out) == ["ab", "AB"])
    }

    @Test
    func regexHitsIncludingEmptyOnes() {
        #expect(Self.painted(Highlighting.highlight("id=12, n=345", term: #"\d+"#, isRegex: true)) == ["12", "345"])
        // `x*` matches empty at every position — must not trap or loop.
        _ = Highlighting.highlight("abc", term: "x*", isRegex: true)
    }

    @Test
    func marksMatchesOverExistingStyle() {
        var styled = AttributedString("\"key\": \"Value value\"")
        Highlighting.markMatches(in: &styled, term: "VALUE")
        #expect(Self.painted(styled) == ["Value", "value"])
    }

    /// A 160 KB value with a one-letter term — typing the first letter of
    /// any search. This was quadratic and took minutes.
    @Test(.timeLimit(.minutes(1)))
    func longValueWithManyHitsIsLinear() {
        let text = String(repeating: "lorem ipsum dolor sit amet, ", count: 6_000)
        let start = Date()
        let out = Highlighting.highlight(text, term: "a")
        #expect(Self.painted(out).count == 6_000)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}
