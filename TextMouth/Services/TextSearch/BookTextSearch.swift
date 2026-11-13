import Foundation

// MARK: - What a Search Looks For

/// The options of a search of a book's text, which Search in Book and Search
/// Library share: whether letters must match in case, and whether the query
/// is a regular expression. Both are off by default, as Search in Book always
/// searched: a search ignores case and looks for the text as typed.
struct TextSearchOptions: Equatable, Hashable, Sendable, Codable {
    /// Whether a match must have the query's letters in the query's case.
    var matchCase = false
    /// Whether the query is an ICU regular expression (`NSRegularExpression`).
    var isRegularExpression = false

    /// The options with nothing switched on.
    init() {}

    /// The options `matchCase` and `isRegularExpression` name.
    init(matchCase: Bool, isRegularExpression: Bool) {
        self.matchCase = matchCase
        self.isRegularExpression = isRegularExpression
    }
}

// MARK: - The One Matcher

/// The matching that book search shares, Search in Book's and Search
/// Library's alike: literal text, or a regular expression, ignoring case or
/// matching it. Ranges are UTF-16 `NSRange`s, TextMouth's text coordinate
/// system (see `OffsetMap.swift`).
///
/// What counts as a match is Foundation's, so both searches agree by
/// construction:
/// - Literal text is found by `NSString.range(of:options:range:)`, with
///   `.caseInsensitive` unless case must match, and never `.literal`: a
///   precomposed letter and the same letter written with a combining mark
///   match each other, as they always did in Search in Book.
/// - A regular expression is an `NSRegularExpression`, with
///   `.caseInsensitive` unless case must match.
enum BookTextSearch {
    /// How many Characters of context a result shows on each side of its
    /// match.
    static let contextLength = 30

    /// Every match of `query` in `text`, in reading order. An empty query
    /// matches nothing; an invalid regular expression throws.
    static func ranges(in text: String, query: String, useRegex: Bool, matchCase: Bool = false) throws -> [NSRange] {
        let options = TextSearchOptions(matchCase: matchCase, isRegularExpression: useRegex)
        guard let matcher = try Matcher(query: query, options: options) else { return [] }
        var ranges: [NSRange] = []
        matcher.enumerateRanges(in: text) { range in
            ranges.append(range)
            return true
        }
        return ranges
    }

    /// A query compiled once, so a search across many chapters, or many
    /// books, parses its regular expression a single time, and whose
    /// matching can stop early: at a result limit, or when the search is
    /// cancelled. Immutable, so one matcher serves every thread of a search.
    struct Matcher: Sendable {
        /// The compiled form of a non-empty query.
        private enum Pattern: Sendable {
            /// Text to find with NSString's search, and the compare options
            /// that search takes.
            case literal(String, NSString.CompareOptions)
            /// A compiled regular expression.
            case regex(NSRegularExpression)
        }

        /// The query as it was typed.
        let query: String
        /// The options it was compiled with.
        let options: TextSearchOptions
        private let pattern: Pattern

        /// Compile `query` ignoring case, or matching it when `matchCase` is
        /// set; nil for an empty query, which matches nothing. Throws when
        /// `useRegex` is set and `query` is not a valid regular expression.
        init?(query: String, useRegex: Bool, matchCase: Bool = false) throws {
            try self.init(query: query, options: TextSearchOptions(matchCase: matchCase, isRegularExpression: useRegex))
        }

        /// Compile `query` with `options`; nil for an empty query, which
        /// matches nothing. Throws when the options make it a regular
        /// expression and it is not a valid one.
        init?(query: String, options: TextSearchOptions) throws {
            guard !query.isEmpty else { return nil }
            self.query = query
            self.options = options
            if options.isRegularExpression {
                let regexOptions: NSRegularExpression.Options = options.matchCase ? [] : [.caseInsensitive]
                pattern = .regex(try NSRegularExpression(pattern: query, options: regexOptions))
            } else {
                pattern = .literal(query, Self.compareOptions(matchCase: options.matchCase))
            }
        }

        /// NSString's compare options for a literal search: `.caseInsensitive`
        /// unless case must match. Never `.literal`, so canonically equivalent
        /// spellings match.
        static func compareOptions(matchCase: Bool) -> NSString.CompareOptions {
            matchCase ? [] : [.caseInsensitive]
        }

        /// Whether the query is literal text rather than a regular expression.
        var isLiteral: Bool {
            if case .literal = pattern { return true }
            return false
        }

        /// Report each match in `text` to `visit`, in reading order, until
        /// `visit` returns false, `shouldStop` returns true, or the text ends.
        ///
        /// How promptly a stop request is heard:
        /// - Literal text: before each lookup. One lookup scans only as far as
        ///   the next match, which takes tens of milliseconds even across a
        ///   whole plain-text book held as a single chapter.
        /// - Regular expression: `.reportProgress` makes Foundation call the
        ///   block periodically during long-running matching, not only when a
        ///   match is found. ICU calls back between match attempts and from
        ///   inside a long backtracking attempt, so even a runaway pattern
        ///   normally stops promptly.
        ///
        /// Known limitation: how often Foundation calls back is undocumented,
        /// so a single pathological match attempt (catastrophic backtracking)
        /// is not guaranteed to be interruptible mid-backtrack. The interface
        /// stays responsive regardless: searches run off the main actor, and
        /// a search superseded by a newer query is cancelled and its results
        /// are discarded.
        func enumerateRanges(
            in text: String,
            shouldStop: () -> Bool = { false },
            visit: (NSRange) -> Bool
        ) {
            let fullRange = NSRange(location: 0, length: text.utf16Length)
            switch pattern {
            case .regex(let regex):
                // Progress callbacks arrive without a result; like every
                // match, each one is a chance to stop.
                regex.enumerateMatches(in: text, options: [.reportProgress], range: fullRange) { result, _, stop in
                    if shouldStop() {
                        stop.pointee = true
                    } else if let result, !visit(result.range) {
                        stop.pointee = true
                    }
                }

            case .literal:
                enumerateLiteralRanges(in: text as NSString, within: fullRange, shouldStop: shouldStop, visit: visit)
            }
        }

        /// Report each literal match that lies wholly in `range` of `text`,
        /// in reading order, as `enumerateRanges(in:shouldStop:visit:)`
        /// reports a whole text's: the first match at or after the range's
        /// start, then the first at or after that match's end, and so on.
        /// Does nothing for a regular expression, whose matches depend on the
        /// whole text it runs over (anchors, look-behind), so it is only ever
        /// run over a whole chapter.
        ///
        /// Search Library runs this over the lines of a chapter that may hold
        /// a match: a literal query that holds no line feed or carriage
        /// return can match no line feed, so each of its matches lies within
        /// one line, and the matches a line holds are those the chapter's
        /// search finds there (`LibrarySearchScanner`).
        func enumerateLiteralRanges(
            in text: NSString,
            within range: NSRange,
            shouldStop: () -> Bool = { false },
            visit: (NSRange) -> Bool
        ) {
            guard case .literal(let query, let compareOptions) = pattern else { return }
            let end = NSMaxRange(range)
            var remaining = range
            while remaining.length > 0, !shouldStop() {
                let match = text.range(of: query, options: compareOptions, range: remaining)
                guard match.location != NSNotFound, visit(match) else { return }
                // Resume after the match, always moving forward so the loop
                // ends even if a lookup ever returned an empty range.
                let nextLocation = max(NSMaxRange(match), match.location + 1)
                remaining = NSRange(location: nextLocation, length: max(0, end - nextLocation))
            }
        }
    }

    // MARK: - Context

    /// The match at `matchRange` of `text` with up to `contextLength`
    /// Characters of context on each side, marking with "..." any text cut
    /// off before or after: what a result's row shows and speaks.
    static func contextSnippet(in text: String, around matchRange: Range<String.Index>) -> String {
        // A whole text has nothing beyond its ends, so a snippet always fits.
        contextSnippet(in: text[...], around: matchRange, textGoesOnBefore: false, textGoesOnAfter: false) ?? ""
    }

    /// The snippet `contextSnippet(in:around:)` makes from a whole text,
    /// made from `window`, a stretch of that text holding the match, or nil
    /// when the window is too short to tell it.
    ///
    /// The window must begin and end where the whole text's Characters do,
    /// as it does at the start of a line or of the text and after a line
    /// feed (Unicode's grapheme rules always break after a line feed, and
    /// none looks back across one). `textGoesOnBefore` and `textGoesOnAfter`
    /// say whether the whole text holds more beyond each end of the window.
    /// The snippet is the whole text's whenever the window holds
    /// `contextLength` Characters on each side of the match where the text
    /// goes on; nil otherwise, so the caller widens the window and asks again.
    static func contextSnippet(
        in window: Substring,
        around matchRange: Range<String.Index>,
        textGoesOnBefore: Bool,
        textGoesOnAfter: Bool
    ) -> String? {
        let before = window.index(matchRange.lowerBound, offsetBy: -contextLength, limitedBy: window.startIndex)
        let after = window.index(matchRange.upperBound, offsetBy: contextLength, limitedBy: window.endIndex)
        // Fewer Characters than the context takes, on a side where the text
        // goes on beyond the window: the whole text's snippet reaches further.
        if (before == nil && textGoesOnBefore) || (after == nil && textGoesOnAfter) {
            return nil
        }
        let beforeStart = before ?? window.startIndex
        let afterEnd = after ?? window.endIndex
        // Text is cut off before the snippet when the snippet starts later
        // than the window, or at the window's start with more text before it.
        let prefix = beforeStart > window.startIndex || (textGoesOnBefore && beforeStart == window.startIndex) ? "..." : ""
        let suffix = afterEnd < window.endIndex || (textGoesOnAfter && afterEnd == window.endIndex) ? "..." : ""
        return prefix + String(window[beforeStart..<afterEnd]) + suffix
    }
}
