import XCTest
@testable import TextMouth

// MARK: - Fixtures

/// Chapters whose UTF-16 offsets diverge from their characters: precomposed
/// and decomposed accents, emoji (a ZWJ family, a flag, a skin-tone
/// modifier), case folds that change length (ß, the ﬁ ligature), and an
/// empty chapter.
private let unicodeChapters = [
    "Café au lait at the caf\u{E9}; CAFE\u{301} again, then plain cafe.",
    "👩‍👩‍👧 family, 🇨🇦 flag, 👍🏽 thumbs; e\u{301}clair and éclair. 🙂 end 🙂",
    "Straße, STRASSE, strasse; the ﬁne print is fine, FINE.",
    "",
    "Plain chapter: the cat sat on the mat, and the cot was cut.",
]

/// Literal queries: whole words, single letters, a lone combining mark, a
/// precomposed accent, halves of emoji sequences, length-changing case
/// folds, punctuation, and a space.
private let literalQueries = [
    "café", "cafe", "e", "\u{301}", "é", "🙂", "👩", "🇨", "👍", "ss", "fi", "the", "at", ";", " ",
]

/// Regular expressions: classes, combining marks, word boundaries, empty
/// matches, lookahead, an escaped code point, a regional-indicator range,
/// alternation, and two invalid patterns.
private let regexQueries = [
    "caf.", "e\\p{M}?", "\\p{M}", "\\b\\w+\\b", ".", "a*", "(?=t)", "\\x{1F642}", "[🇦-🇿]",
    "stra(ss|ß)e", "c[aou]t", "caf(", "[",
]

// MARK: - Frozen oracles

/// `BookTextSearch.ranges` exactly as it was before searching moved off the
/// main actor, kept as an oracle: the refactored matcher must report the
/// same ranges for every query.
private enum LegacyMatching {
    static func ranges(in text: String, query: String, useRegex: Bool) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let fullRange = NSRange(location: 0, length: text.utf16Length)
        if useRegex {
            let regex = try NSRegularExpression(pattern: query, options: [.caseInsensitive])
            return regex.matches(in: text, range: fullRange).map(\.range)
        }

        let nsText = text as NSString
        var results: [NSRange] = []
        var remaining = fullRange
        while remaining.length > 0 {
            let match = nsText.range(of: query, options: [.caseInsensitive], range: remaining)
            guard match.location != NSNotFound else { break }
            results.append(match)
            let nextLocation = NSMaxRange(match)
            remaining = NSRange(location: nextLocation, length: fullRange.length - nextLocation)
        }
        return results
    }
}

// MARK: - Matcher

/// The shared matcher behind book search: exact parity with the previous
/// implementation, and prompt stopping for result limits and cancellation.
final class BookTextSearchMatcherTests: XCTestCase {
    /// Refactoring the matcher must not move, add, or drop a single match,
    /// in UTF-16 coordinates, for literal text or regular expressions.
    func testRangesAreUnchangedFromThePreviousImplementation() {
        for (chapterIndex, text) in unicodeChapters.enumerated() {
            for query in literalQueries {
                assertSameRanges(in: text, query: query, useRegex: false, "Chapter \(chapterIndex), literal \(query.debugDescription)")
            }
            for query in regexQueries {
                assertSameRanges(in: text, query: query, useRegex: true, "Chapter \(chapterIndex), regex \(query.debugDescription)")
            }
        }
    }

    /// An empty query compiles to nothing, even as a regular expression (an
    /// empty pattern would otherwise match everywhere). An invalid pattern
    /// throws, while the same text is an ordinary literal query.
    func testCompilingEmptyAndInvalidQueries() throws {
        XCTAssertNil(try BookTextSearch.Matcher(query: "", useRegex: false))
        XCTAssertNil(try BookTextSearch.Matcher(query: "", useRegex: true))
        XCTAssertThrowsError(try BookTextSearch.Matcher(query: "[", useRegex: true))
        XCTAssertNotNil(try BookTextSearch.Matcher(query: "[", useRegex: false))
    }

    /// A visitor that wants no more matches ends the scan at once; this is
    /// how a search stops at its result limit.
    func testVisitorCanEndTheScan() throws {
        let text = String(repeating: "tick tock ", count: 100)
        for useRegex in [false, true] {
            let matcher = try XCTUnwrap(BookTextSearch.Matcher(query: "tock", useRegex: useRegex))
            var visited = 0
            matcher.enumerateRanges(in: text) { _ in
                visited += 1
                return visited < 3
            }
            XCTAssertEqual(visited, 3, "useRegex \(useRegex)")
        }
    }

    /// A stop request made between matches ends the scan before the next
    /// match is reported.
    func testStopRequestEndsTheScanBetweenMatches() throws {
        let text = String(repeating: "tick tock ", count: 100)
        for useRegex in [false, true] {
            let matcher = try XCTUnwrap(BookTextSearch.Matcher(query: "tick", useRegex: useRegex))
            var visited = 0
            matcher.enumerateRanges(in: text, shouldStop: { visited == 10 }) { _ in
                visited += 1
                return true
            }
            XCTAssertEqual(visited, 10, "useRegex \(useRegex)")
        }
    }

    /// A regular-expression scan that finds nothing still hears a stop
    /// request: progress callbacks consult it long before the scan reaches
    /// the end of the text, which would take over half a million callbacks.
    func testRegexStopRequestIsHeardWhileNothingMatches() throws {
        let text = String(repeating: "abcdefghij ", count: 50_000)
        let matcher = try XCTUnwrap(BookTextSearch.Matcher(query: "zq+x", useRegex: true))
        var consultations = 0
        matcher.enumerateRanges(in: text, shouldStop: {
            consultations += 1
            return true
        }) { _ in
            XCTFail("Nothing in the text matches")
            return true
        }
        XCTAssertEqual(consultations, 1)
    }

    /// Pins the platform behavior the comment on `enumerateRanges` relies on:
    /// ICU calls back from inside one backtracking attempt, not only between
    /// attempts. `(a+)+b` against a run of a's backtracks exponentially, so
    /// more consultations than there are start positions can only come from
    /// within an attempt. If a future macOS stops doing this, searching
    /// still stays responsive (it runs off the main actor), but that comment
    /// must be updated.
    func testRegexStopRequestIsConsultedInsideABacktrackingAttempt() throws {
        let text = String(repeating: "a", count: 16) + "!"
        let matcher = try XCTUnwrap(BookTextSearch.Matcher(query: "(a+)+b", useRegex: true))
        var consultations = 0
        matcher.enumerateRanges(in: text, shouldStop: {
            consultations += 1
            return false
        }) { _ in
            XCTFail("Nothing in the text matches")
            return true
        }
        XCTAssertGreaterThan(consultations, text.utf16Length)
    }

    /// Assert that the current and legacy matchers find the same ranges, or
    /// that both reject the query as an invalid regular expression.
    private func assertSameRanges(
        in text: String,
        query: String,
        useRegex: Bool,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let current = Result { try BookTextSearch.ranges(in: text, query: query, useRegex: useRegex) }
        let legacy = Result { try LegacyMatching.ranges(in: text, query: query, useRegex: useRegex) }
        switch (current, legacy) {
        case let (.success(currentRanges), .success(legacyRanges)):
            XCTAssertEqual(currentRanges, legacyRanges, context, file: file, line: line)
        case (.failure, .failure):
            break
        default:
            XCTFail("\(context): only one implementation rejected the query", file: file, line: line)
        }
    }
}
