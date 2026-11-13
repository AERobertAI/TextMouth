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

/// The Unicode chapters as a book. The first heading starts partway into the
/// first chapter, so earlier matches have no location; headings carry over
/// into later chapters; the last heading's text is blank, so matches under
/// it have no location to name either.
private let unicodeCorpus = BookSearchCorpus(
    chapterTexts: unicodeChapters,
    chapterTitles: ["Cafés", "Emoji", "Folding", "Blank", "Plain"],
    headings: [
        Heading(level: 1, text: "Morning", chapterIndex: 0, characterOffset: 12),
        Heading(level: 2, text: "Pictures", chapterIndex: 1, characterOffset: 10),
        Heading(level: 1, text: "Fine print", chapterIndex: 2, characterOffset: 0),
        Heading(level: 1, text: "   ", chapterIndex: 4, characterOffset: 5),
    ],
    bookTitle: "Parity Fixture"
)

/// A book of `chapters` identical chapters, each holding "tock"
/// `matchesPerChapter` times, for exercising the result limit.
private func repeatedCorpus(chapters: Int, matchesPerChapter: Int) -> BookSearchCorpus {
    BookSearchCorpus(
        chapterTexts: Array(repeating: String(repeating: "tick tock ", count: matchesPerChapter), count: chapters),
        chapterTitles: Array(repeating: "", count: chapters),
        headings: [],
        bookTitle: "Metronome"
    )
}

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

/// The whole-book search `BookSearchView` ran synchronously in its body
/// before searching moved off the main actor, kept verbatim apart from
/// reading its inputs from a corpus and matching with `LegacyMatching`. It
/// is the oracle for parity tests: below the result limit, the engine must
/// produce exactly these results.
private enum LegacySynchronousSearch {
    /// The fields of the old view's result type.
    struct Result: Equatable {
        let chapterIndex: Int
        let characterOffset: Int
        let matchedText: String
        let contextSnippet: String
        let globalOffset: Int
        var locationTitle: String?
    }

    enum Outcome: Equatable {
        case empty
        case results([Result])
        case regexError(String)
    }

    static func search(_ searchText: String, useRegex: Bool, in corpus: BookSearchCorpus) -> Outcome {
        guard !searchText.isEmpty else { return .empty }

        var results: [Result] = []
        var cumulativeCount = 0

        for (chapterIndex, chapterText) in corpus.chapterTexts.enumerated() {
            let nsMatches: [NSRange]
            do {
                nsMatches = try LegacyMatching.ranges(
                    in: chapterText,
                    query: searchText,
                    useRegex: useRegex
                )
            } catch {
                return .regexError("Invalid regex: \(error.localizedDescription)")
            }

            for nsMatch in nsMatches {
                guard let matchRange = Range(nsMatch, in: chapterText) else { continue }
                let characterOffset = nsMatch.location
                let globalOffset = cumulativeCount + characterOffset
                let snippet = buildContextSnippet(text: chapterText, matchRange: matchRange)

                results.append(Result(
                    chapterIndex: chapterIndex,
                    characterOffset: characterOffset,
                    matchedText: String(chapterText[matchRange]),
                    contextSnippet: snippet,
                    globalOffset: globalOffset
                ))
            }

            cumulativeCount += chapterText.utf16Length
        }

        // Matches were collected in reading order; name each by its heading.
        let locationTitles = BookSearchView.locationTitles(
            of: results.map { (chapterIndex: $0.chapterIndex, characterOffset: $0.characterOffset) },
            headings: corpus.headings,
            chapterTitles: corpus.chapterTitles,
            bookTitle: corpus.bookTitle
        )
        for index in results.indices {
            results[index].locationTitle = locationTitles[index]
        }

        return results.isEmpty ? .empty : .results(results)
    }

    private static func buildContextSnippet(text: String, matchRange: Range<String.Index>) -> String {
        let beforeStart = text.index(matchRange.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let afterEnd = text.index(matchRange.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex

        let prefix = beforeStart > text.startIndex ? "..." : ""
        let suffix = afterEnd < text.endIndex ? "..." : ""

        let before = String(text[beforeStart..<matchRange.lowerBound])
        let matched = String(text[matchRange])
        let after = String(text[matchRange.upperBound..<afterEnd])

        return "\(prefix)\(before)\(matched)\(after)\(suffix)"
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

// MARK: - Engine

/// Whole-book search: parity with the old synchronous search, the result
/// limit, and cancellation.
final class BookSearchEngineTests: XCTestCase {
    /// Below the result limit, the engine finds exactly what the old
    /// synchronous search found: the same chapters, UTF-16 offsets, matched
    /// text, context, global offsets, locations, and stable ids.
    func testSearchMatchesThePreviousSynchronousSearch() throws {
        var comparedResults = 0
        for (queries, useRegex) in [(literalQueries, false), (regexQueries, true)] {
            for query in queries + [""] {
                let context = "\(useRegex ? "Regex" : "Literal") \(query.debugDescription)"
                let outcome = try BookSearchEngine.search(query: query, useRegex: useRegex, in: unicodeCorpus)
                switch (outcome, LegacySynchronousSearch.search(query, useRegex: useRegex, in: unicodeCorpus)) {
                case (.matches(let results, isTruncated: false), .empty):
                    XCTAssertEqual(results, [], context)
                case (.matches(let results, isTruncated: false), .results(let legacy)):
                    XCTAssertEqual(results.map(Self.legacyFields), legacy, context)
                    XCTAssertEqual(
                        results.map(\.id),
                        legacy.map { "\($0.chapterIndex):\($0.characterOffset):\($0.matchedText.utf16Length)" },
                        context
                    )
                    comparedResults += legacy.count
                case (.invalidPattern(let message), .regexError(let legacyMessage)):
                    XCTAssertEqual("Invalid regex: \(message)", legacyMessage, context)
                default:
                    XCTFail("\(context): the outcomes differ")
                }
            }
        }
        // Guard against a fixture that silently stops exercising anything.
        XCTAssertGreaterThan(comparedResults, 500)
    }

    /// Every result sits exactly where the shared matcher,
    /// `BookTextSearch.ranges`, finds a match: the same UTF-16 offset and
    /// length within its chapter, and that offset plus the UTF-16 length of
    /// every earlier chapter across the whole book.
    func testResultsSitWhereTheSharedMatcherFindsThem() throws {
        /// Where a match sits, in UTF-16 units.
        struct Placement: Equatable {
            let chapterIndex: Int
            let characterOffset: Int
            let length: Int
            let globalOffset: Int
        }

        var comparedResults = 0
        for (queries, useRegex) in [(literalQueries, false), (regexQueries, true)] {
            for query in queries {
                let context = "\(useRegex ? "Regex" : "Literal") \(query.debugDescription)"
                let outcome = try BookSearchEngine.search(query: query, useRegex: useRegex, in: unicodeCorpus)
                // Invalid patterns have no ranges; other tests cover them.
                guard case .matches(let results, isTruncated: false) = outcome else { continue }

                var expected: [Placement] = []
                var chapterStart = 0
                for (chapterIndex, text) in unicodeCorpus.chapterTexts.enumerated() {
                    // Search lists only ranges that have a String equivalent.
                    for range in try BookTextSearch.ranges(in: text, query: query, useRegex: useRegex)
                    where Range(range, in: text) != nil {
                        expected.append(Placement(
                            chapterIndex: chapterIndex,
                            characterOffset: range.location,
                            length: range.length,
                            globalOffset: chapterStart + range.location
                        ))
                    }
                    chapterStart += text.utf16Length
                }

                let placements = results.map {
                    Placement(
                        chapterIndex: $0.chapterIndex,
                        characterOffset: $0.characterOffset,
                        length: $0.matchedText.utf16Length,
                        globalOffset: $0.globalOffset
                    )
                }
                XCTAssertEqual(placements, expected, context)
                comparedResults += expected.count
            }
        }
        XCTAssertGreaterThan(comparedResults, 500)
    }

    /// The documented limit, which the status line reports when reached:
    /// 500 since TODO A10, when the sheet began keeping every row it lists
    /// alive for VoiceOver.
    func testResultLimitIsFiveHundred() {
        XCTAssertEqual(BookSearchEngine.resultLimit, 500)
    }

    /// A query with more matches than the limit lists the first 500, the
    /// same ones the old search listed first, and says more exist.
    func testSearchStopsAtTheResultLimit() throws {
        let corpus = repeatedCorpus(chapters: 3, matchesPerChapter: 1_000)
        let outcome = try BookSearchEngine.search(query: "tock", useRegex: false, in: corpus)
        guard case .matches(let results, let isTruncated) = outcome,
              case .results(let legacy) = LegacySynchronousSearch.search("tock", useRegex: false, in: corpus)
        else { return XCTFail("Both searches should find matches") }

        XCTAssertTrue(isTruncated)
        XCTAssertEqual(legacy.count, 3_000)
        XCTAssertEqual(results.map(Self.legacyFields), Array(legacy.prefix(BookSearchEngine.resultLimit)))
    }

    /// Exactly as many matches as the limit is a complete list, not a
    /// truncated one, for literal text and regular expressions alike.
    func testExactlyTheLimitIsACompleteList() throws {
        let corpus = repeatedCorpus(chapters: 2, matchesPerChapter: BookSearchEngine.resultLimit / 2)
        for useRegex in [false, true] {
            let outcome = try BookSearchEngine.search(query: "tock", useRegex: useRegex, in: corpus)
            let found = try XCTUnwrap(matchedTexts(outcome))
            XCTAssertEqual(found.texts.count, BookSearchEngine.resultLimit, "useRegex \(useRegex)")
            XCTAssertFalse(found.isTruncated, "useRegex \(useRegex)")
        }
    }

    /// A range with no String equivalent is skipped, as before, and neither
    /// counts toward the limit nor marks the list truncated. Real matchers
    /// only report ranges inside the text, so this reports some past its end.
    func testSkippedRangesNeverCountTowardTheLimit() throws {
        let ranges = [
            NSRange(location: 0, length: 1),
            NSRange(location: 4, length: 9),
            NSRange(location: 2, length: 1),
            NSRange(location: 50, length: 1),
            NSRange(location: 4, length: 1),
        ]
        let reportRanges: (String, (NSRange) -> Bool) -> Void = { _, visit in
            for range in ranges {
                guard visit(range) else { return }
            }
        }

        let complete = try BookSearchEngine.collectResults(
            in: ["x x x"],
            limit: 3,
            isCancelled: { false },
            enumerateMatches: reportRanges
        )
        XCTAssertEqual(complete.results.map(\.characterOffset), [0, 2, 4])
        XCTAssertFalse(complete.isTruncated)

        let limited = try BookSearchEngine.collectResults(
            in: ["x x x"],
            limit: 2,
            isCancelled: { false },
            enumerateMatches: reportRanges
        )
        XCTAssertEqual(limited.results.map(\.characterOffset), [0, 2])
        XCTAssertTrue(limited.isTruncated)
    }

    /// Cancellation stops the search between chapters: cancelled while the
    /// third of fifty chapters is scanned, it never visits a fourth, and it
    /// reports nothing rather than partial results.
    func testCancellationStopsChapterIteration() {
        var visitedChapters = 0
        XCTAssertThrowsError(try BookSearchEngine.collectResults(
            in: Array(repeating: "tick tock", count: 50),
            limit: BookSearchEngine.resultLimit,
            isCancelled: { visitedChapters >= 3 }
        ) { _, visit in
            visitedChapters += 1
            _ = visit(NSRange(location: 5, length: 4))
        }) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(visitedChapters, 3)
    }

    /// Cancellation that cuts the final chapter's scan short still throws,
    /// instead of returning what the partial scan found.
    func testCancellationDuringTheLastChapterReportsNothing() {
        var isCancelled = false
        XCTAssertThrowsError(try BookSearchEngine.collectResults(
            in: ["tick tock"],
            limit: BookSearchEngine.resultLimit,
            isCancelled: { isCancelled }
        ) { _, visit in
            _ = visit(NSRange(location: 5, length: 4))
            isCancelled = true
        }) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// By default the engine follows the cancellation of the task running
    /// it, so cancelling that task stops the search.
    func testSearchFollowsTheRunningTasksCancellation() async {
        let corpus = repeatedCorpus(chapters: 4, matchesPerChapter: 100)
        let search = Task.detached { () throws -> BookSearchOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return try BookSearchEngine.search(query: "tock", useRegex: false, in: corpus)
        }
        do {
            let outcome = try await search.value
            XCTFail("A cancelled search reported \(outcome)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// An invalid regular expression is an outcome to show, not an error to
    /// throw, and it explains itself.
    func testInvalidRegexIsAnOutcome() throws {
        let outcome = try BookSearchEngine.search(query: "caf(", useRegex: true, in: unicodeCorpus)
        guard case .invalidPattern(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(message.isEmpty)
    }

    /// A result as the old view's result type saw it, for comparison with
    /// the oracle.
    private static func legacyFields(_ result: BookSearchResult) -> LegacySynchronousSearch.Result {
        LegacySynchronousSearch.Result(
            chapterIndex: result.chapterIndex,
            characterOffset: result.characterOffset,
            matchedText: result.matchedText,
            contextSnippet: result.contextSnippet,
            globalOffset: result.globalOffset,
            locationTitle: result.locationTitle
        )
    }

    /// The matched texts and truncation flag of an outcome that should have
    /// found matches; nil, after recording a failure, otherwise.
    private func matchedTexts(
        _ outcome: BookSearchOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (texts: [String], isTruncated: Bool)? {
        guard case .matches(let results, let isTruncated) = outcome else {
            XCTFail("Expected matches, got \(outcome)", file: file, line: line)
            return nil
        }
        return (results.map(\.matchedText), isTruncated)
    }
}

// MARK: - Model

/// A thread-safe log of the searches a fake `BookSearchModel.Search` ran.
/// Fakes run on background threads while tests read the log on the main
/// actor, so every access takes the lock.
private final class SearchLog: @unchecked Sendable {
    /// One search a fake received.
    struct Entry: Equatable {
        let query: String
        let useRegex: Bool
        /// Whether the search ran on the main thread; it never should.
        let ranOnMainThread: Bool
    }

    private let lock = NSLock()
    private var recordedEntries: [Entry] = []
    private var recordedCancellations: [Bool] = []

    /// Note a search starting. Call from inside the fake search.
    func recordSearch(query: String, useRegex: Bool) {
        let entry = Entry(query: query, useRegex: useRegex, ranOnMainThread: Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        recordedEntries.append(entry)
    }

    /// Note whether a fake search's task had been cancelled by the time it
    /// finished.
    func recordCancellation(_ isCancelled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        recordedCancellations.append(isCancelled)
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEntries
    }

    var queries: [String] {
        entries.map(\.query)
    }

    var cancellations: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCancellations
    }
}

/// Waits, on a fake search's background thread, until the task running it
/// is cancelled or `timeout` seconds pass, and returns whether it was
/// cancelled. `BookSearchModel` installs its cancellation handler just
/// after it starts the detached search, so a cancellation made in between
/// reaches the search a moment after `cancelSearch()` returns: a test that
/// asks whether the search was told to stop waits for that, not for a
/// guess about time. A search never told to stop answers false after
/// `timeout`, which fails the test.
private func waitUntilCancelled(timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !Task.isCancelled {
        guard Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return true
}

/// Records what a model announces through VoiceOver.
@MainActor
private final class AnnouncementLog {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}

/// A result whose matched text is the query that produced it, so a test can
/// tell which search's results are listed.
private func fakeResult(for query: String) -> BookSearchResult {
    BookSearchResult(chapterIndex: 0, characterOffset: 0, matchedText: query, contextSnippet: query, globalOffset: 0)
}

/// Debouncing, cancellation, and what the search sheet lists, shows in its
/// status line, and announces.
@MainActor
final class BookSearchModelTests: XCTestCase {
    /// Keeps tests fast; tests about debouncing itself choose their own.
    private let quickDebounce: Duration = .milliseconds(10)

    /// The sheet's own configuration: the real engine after a quarter-second
    /// pause, announcing what it found.
    func testDefaultConfigurationSearchesTheBookAfterAQuarterSecondPause() async throws {
        XCTAssertEqual(BookSearchModel.debounceInterval, .milliseconds(250))
        let announcements = AnnouncementLog()
        let model = BookSearchModel(corpus: unicodeCorpus, announce: announcements.record)

        model.query = "the"
        XCTAssertEqual(model.status, .searching)
        await model.searchTask?.value

        let expected = try BookSearchEngine.search(query: "the", useRegex: false, in: unicodeCorpus)
        guard case .matches(let results, isTruncated: false) = expected, !results.isEmpty else {
            return XCTFail("The fixture should hold complete matches for \"the\": \(expected)")
        }
        XCTAssertEqual(model.results, results)
        XCTAssertEqual(model.status, .found(count: results.count))
        XCTAssertEqual(announcements.messages, [model.status.text])
        XCTAssertNil(model.searchTask)
    }

    /// Steady typing runs one search, for the final text, however many edits
    /// it took, and announces once.
    func testDebounceCoalescesRapidEditsIntoOneSearch() async throws {
        let log = SearchLog()
        let announcements = AnnouncementLog()
        // Generous beside the pauses between edits, so a busy machine cannot
        // split the burst.
        let model = BookSearchModel(debounceInterval: .seconds(1), announce: announcements.record) { query, options in
            log.recordSearch(query: query, useRegex: options.isRegularExpression)
            return .matches([], isTruncated: false)
        }

        for query in ["f", "fe", "fer", "ferr", "ferry"] {
            model.query = query
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.searchTask?.value

        XCTAssertEqual(log.queries, ["ferry"])
        XCTAssertEqual(model.status, .found(count: 0))
        XCTAssertEqual(announcements.messages, ["No matches"])
    }

    /// Edits separated by more than the debounce interval each get a search.
    func testEditsAfterAPauseSearchAgain() async {
        let log = SearchLog()
        let model = BookSearchModel(debounceInterval: quickDebounce, announce: { _ in }) { query, options in
            log.recordSearch(query: query, useRegex: options.isRegularExpression)
            return .matches([], isTruncated: false)
        }

        model.query = "ferry"
        await model.searchTask?.value
        model.query = "ferryman"
        await model.searchTask?.value

        XCTAssertEqual(log.queries, ["ferry", "ferryman"])
    }

    /// A newer query cancels the older search, and the older search's
    /// completion never publishes, even when, like a runaway regular
    /// expression, it ignores cancellation and finishes last. The old
    /// search's fake waits until the cancellation reaches it, as the
    /// cancellation handler passes it on a moment after the newer query.
    func testNewerQueryCancelsTheOlderSearchWhoseLateCompletionNeverPublishes() async throws {
        let log = SearchLog()
        let announcements = AnnouncementLog()
        let oldSearchStarted = expectation(description: "The old search started")
        let releaseOldSearch = DispatchSemaphore(value: 0)
        // Never leave a background thread blocked, whatever fails below.
        defer { releaseOldSearch.signal() }

        let model = BookSearchModel(debounceInterval: quickDebounce, announce: announcements.record) { query, options in
            log.recordSearch(query: query, useRegex: options.isRegularExpression)
            if query == "old" {
                oldSearchStarted.fulfill()
                releaseOldSearch.wait()
                log.recordCancellation(waitUntilCancelled())
            }
            return .matches([fakeResult(for: query)], isTruncated: false)
        }

        model.query = "old"
        await fulfillment(of: [oldSearchStarted], timeout: 5)
        let oldSearch = try XCTUnwrap(model.searchTask)

        model.query = "new"
        await model.searchTask?.value
        XCTAssertEqual(model.results.map(\.matchedText), ["new"])

        // Let the old search finish after the new one has been published.
        releaseOldSearch.signal()
        await oldSearch.value

        XCTAssertEqual(log.queries, ["old", "new"])
        XCTAssertEqual(log.cancellations, [true], "The old search should have been told to stop")
        XCTAssertEqual(model.results.map(\.matchedText), ["new"])
        XCTAssertEqual(model.status, .found(count: 1))
        XCTAssertEqual(announcements.messages, ["1 match"])
    }

    /// Stopping the search, as closing the sheet does, publishes and
    /// announces nothing, even from a search that finishes anyway. The fake
    /// waits until the cancellation reaches it, as the cancellation handler
    /// passes it on a moment after `cancelSearch()` returns.
    func testCancelledSearchPublishesNothing() async throws {
        let log = SearchLog()
        let announcements = AnnouncementLog()
        let searchStarted = expectation(description: "The search started")
        let releaseSearch = DispatchSemaphore(value: 0)
        defer { releaseSearch.signal() }

        let model = BookSearchModel(debounceInterval: quickDebounce, announce: announcements.record) { query, options in
            log.recordSearch(query: query, useRegex: options.isRegularExpression)
            searchStarted.fulfill()
            releaseSearch.wait()
            log.recordCancellation(waitUntilCancelled())
            return .matches([fakeResult(for: query)], isTruncated: false)
        }

        model.query = "ferry"
        await fulfillment(of: [searchStarted], timeout: 5)
        let search = try XCTUnwrap(model.searchTask)
        model.cancelSearch()
        releaseSearch.signal()
        await search.value

        XCTAssertEqual(log.cancellations, [true])
        XCTAssertEqual(model.results, [])
        XCTAssertEqual(announcements.messages, [])
        XCTAssertNil(model.searchTask)
    }

    /// With more matches than the limit, the first 500 are listed and the
    /// status line and announcement ask for a narrower search.
    func testResultLimitIsReportedInStatusAndAnnouncement() async {
        let (model, announcements) = makeModel(searching: repeatedCorpus(chapters: 3, matchesPerChapter: 1_000))

        model.query = "tock"
        await model.searchTask?.value

        XCTAssertEqual(model.results.count, BookSearchEngine.resultLimit)
        XCTAssertEqual(model.status, .truncated(shown: BookSearchEngine.resultLimit))
        XCTAssertEqual(model.status.text, "Showing the first 500 matches; refine your search")
        XCTAssertEqual(announcements.messages, [model.status.text])
    }

    /// Every status reads as a complete phrase, with singular and plural
    /// counts, and only an invalid pattern counts as an error.
    func testStatusTexts() {
        typealias Status = BookSearchModel.Status
        XCTAssertEqual(Status.idle.text, "Enter a search term above.")
        XCTAssertEqual(Status.searching.text, "Searching…")
        XCTAssertEqual(Status.found(count: 0).text, "No matches")
        XCTAssertEqual(Status.found(count: 1).text, "1 match")
        XCTAssertEqual(Status.found(count: 12).text, "12 matches")
        XCTAssertEqual(Status.found(count: 1_234).text, "\(1_234.formatted()) matches")
        XCTAssertEqual(
            Status.truncated(shown: 2_000).text,
            "Showing the first \(2_000.formatted()) matches; refine your search"
        )
        XCTAssertEqual(
            Status.invalidPattern("The value “[” is invalid.").text,
            "Invalid regular expression: The value “[” is invalid."
        )

        XCTAssertTrue(Status.invalidPattern("The value “[” is invalid.").isError)
        for status in [Status.idle, .searching, .found(count: 0), .truncated(shown: 2_000)] {
            XCTAssertFalse(status.isError, "\(status)")
        }
    }

    /// An invalid regular expression is reported in words once its search
    /// runs, and the next edit searches normally.
    func testInvalidRegexIsReportedAndTypingCarriesOn() async {
        let (model, announcements) = makeModel(searching: unicodeCorpus)
        model.useRegex = true

        model.query = "caf("
        await model.searchTask?.value
        guard case .invalidPattern(let message) = model.status else {
            return XCTFail("Expected an invalid-pattern status, got \(model.status)")
        }
        XCTAssertEqual(model.status.text, "Invalid regular expression: \(message)")
        XCTAssertEqual(model.results, [])
        XCTAssertEqual(announcements.messages, [model.status.text])

        model.query = "caf(e|é)"
        XCTAssertEqual(model.status, .searching)
        await model.searchTask?.value
        guard case .found(let count) = model.status else {
            return XCTFail("Expected matches, got \(model.status)")
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(model.results.count, count)
    }

    /// Clearing the field stops the pending search and resets the sheet at
    /// once, without searching or announcing anything.
    func testClearingTheQueryStopsThePendingSearch() async throws {
        let log = SearchLog()
        let announcements = AnnouncementLog()
        let model = BookSearchModel(debounceInterval: .seconds(1), announce: announcements.record) { query, options in
            log.recordSearch(query: query, useRegex: options.isRegularExpression)
            return .matches([fakeResult(for: query)], isTruncated: false)
        }

        model.query = "ferry"
        let pending = try XCTUnwrap(model.searchTask)
        model.query = ""

        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.searchTask)
        // Cancelled during its debounce, the search ends without running.
        await pending.value
        XCTAssertEqual(log.queries, [])
        XCTAssertEqual(announcements.messages, [])
    }

    /// Clearing the field after a search removes its results at once.
    func testClearingTheQueryRemovesResults() async {
        let (model, _) = makeModel(searching: unicodeCorpus)
        model.query = "the"
        await model.searchTask?.value
        XCTAssertFalse(model.results.isEmpty)

        model.query = ""

        XCTAssertEqual(model.results, [])
        XCTAssertEqual(model.status, .idle)
    }

    /// While a newer search runs, the previous results stay listed, so rows
    /// do not vanish and reappear at every keystroke, and the status line
    /// says a search is under way.
    func testPreviousResultsStayListedWhileANewerSearchRuns() async throws {
        let (model, _) = makeModel(searching: unicodeCorpus)
        model.query = "the"
        await model.searchTask?.value
        let earlierResults = model.results
        XCTAssertFalse(earlierResults.isEmpty)

        model.query = "the c"
        XCTAssertEqual(model.status, .searching)
        XCTAssertEqual(model.results, earlierResults)

        await model.searchTask?.value
        let expected = try BookSearchEngine.search(query: "the c", useRegex: false, in: unicodeCorpus)
        XCTAssertEqual(.matches(model.results, isTruncated: false), expected)
        XCTAssertNotEqual(model.results, earlierResults)
    }

    /// Turning Use Regex on searches the same text again, now as a pattern.
    func testTogglingRegexSearchesAgain() async {
        let (model, announcements) = makeModel(searching: unicodeCorpus)
        model.query = "c[aou]t"
        await model.searchTask?.value
        XCTAssertEqual(model.status, .found(count: 0))

        model.useRegex = true
        XCTAssertEqual(model.status, .searching)
        await model.searchTask?.value

        XCTAssertEqual(model.results.map(\.matchedText), ["cat", "cot", "cut"])
        XCTAssertEqual(announcements.messages, ["No matches", "3 matches"])
    }

    /// Setting the same values again, as SwiftUI may while refreshing the
    /// field, starts no new search.
    func testUnchangedInputsDoNotSearchAgain() async {
        let log = SearchLog()
        let model = BookSearchModel(debounceInterval: quickDebounce, announce: { _ in }) { query, options in
            log.recordSearch(query: query, useRegex: options.isRegularExpression)
            return .matches([], isTruncated: false)
        }

        model.query = "ferry"
        await model.searchTask?.value
        model.query = "ferry"
        model.useRegex = false

        XCTAssertNil(model.searchTask)
        XCTAssertEqual(log.queries, ["ferry"])
    }

    /// Searches run off the main thread, so typing and VoiceOver stay
    /// responsive however long one takes.
    func testSearchesRunOffTheMainThread() async {
        let log = SearchLog()
        let model = BookSearchModel(debounceInterval: quickDebounce, announce: { _ in }) { query, options in
            log.recordSearch(query: query, useRegex: options.isRegularExpression)
            return .matches([], isTruncated: false)
        }

        model.useRegex = true
        model.query = "ferr(y|ies)"
        await model.searchTask?.value

        XCTAssertEqual(log.entries, [SearchLog.Entry(query: "ferr(y|ies)", useRegex: true, ranOnMainThread: false)])
    }

    /// A model searching `corpus` with the real engine and a short debounce,
    /// with a log of what it announces.
    private func makeModel(searching corpus: BookSearchCorpus) -> (BookSearchModel, AnnouncementLog) {
        let announcements = AnnouncementLog()
        let model = BookSearchModel(debounceInterval: quickDebounce, announce: announcements.record) { query, options in
            try BookSearchEngine.search(query: query, options: options, in: corpus)
        }
        return (model, announcements)
    }
}
