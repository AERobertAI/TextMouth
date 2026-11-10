import XCTest
@testable import TextMouth

/// The phone's Search in Book, in the parts the Mac's test host can run: its
/// words, what each result's row says, and the model that runs its searches
/// over the Mac's own engine. The sheet itself is iOS's alone, and the
/// simulator's UI tests read it (`SearchUITests`).
@MainActor
final class PhoneBookSearchTests: XCTestCase {
    // MARK: - Words

    /// The title is the Mac's command, and the hints say what a control does.
    func testTheWords() {
        XCTAssertEqual(PhoneBookSearchVocabulary.title, "Search in Book")
        XCTAssertEqual(PhoneBookSearchVocabulary.buttonHint, "Opens a search of the book's text.")
        XCTAssertEqual(PhoneBookSearchVocabulary.rowHint, "Goes to this result.")
        XCTAssertEqual(PhoneBookSearchVocabulary.backToBook, "Back to Book")
        XCTAssertEqual(BookSearchWording.backToBookHint, "Close search and return to the book")
    }

    /// The words moved out of the Mac's view are the ones the view had.
    func testTheSharedWordsAreTheMacsOwn() {
        XCTAssertEqual(BookSearchWording.fieldLabel, "Search text")
        XCTAssertEqual(BookSearchWording.fieldHint, "Type to search within the book")
        XCTAssertEqual(BookSearchWording.regexLabel, "Use regular expression")
        XCTAssertEqual(BookSearchWording.regexHint, "When enabled, search text is treated as a regular expression")
        XCTAssertEqual(BookSearchWording.resultsLabel, "Search results")
    }

    /// Typing must pause for a second, as the Library's search waits, before
    /// a count is said: not the Mac's quarter second.
    func testTypingPausesForASecond() {
        XCTAssertEqual(PhoneBookSearchVocabulary.typingPause, .seconds(1))
        XCTAssertNotEqual(PhoneBookSearchVocabulary.typingPause, BookSearchModel.debounceInterval)
    }

    // MARK: - Rows

    /// A text book's result reads its context, its heading, and its place as
    /// a percent of the book, in the Mac's words, and shows the percent.
    func testATextResultsRowReadsItsPlaceAsAPercent() {
        let source = Self.source(totalCharacters: 1_000)
        let result = Self.result(globalOffset: 250, location: "The Crossing")

        let row = source.row(for: result)

        XCTAssertEqual(row.id, result.id)
        XCTAssertEqual(row.context, "...the ferry left late...")
        XCTAssertEqual(row.location, "The Crossing")
        XCTAssertEqual(row.position, "25.0%")
        XCTAssertEqual(row.label, "...the ferry left late..., The Crossing, at 25.0 percent of book")
    }

    /// A result with no heading to name reads without a location.
    func testAResultWithNoHeadingReadsWithoutOne() {
        let row = Self.source(totalCharacters: 1_000).row(for: Self.result(globalOffset: 500, location: nil))

        XCTAssertNil(row.location)
        XCTAssertEqual(row.label, "...the ferry left late..., at 50.0 percent of book")
    }

    /// A transcript's result reads the exact time it is heard, and shows it.
    func testATranscriptResultsRowReadsItsTime() {
        let result = Self.result(globalOffset: 250, location: "Chapter 2", time: 75)

        let row = Self.source(totalCharacters: 1_000).row(for: result)

        XCTAssertEqual(row.label, "...the ferry left late..., Chapter 2, at \(TimeFormatting.spoken(75))")
        XCTAssertEqual(row.position, TimeFormatting.format(75))
    }

    /// The row says what the Mac's own row says for the same result, at the
    /// Mac's default display: the phone doesn't word it a second time.
    func testARowSaysWhatTheMacsRowSays() {
        let source = Self.source(totalCharacters: 4_321, totalWords: 800, wordsPerMinute: 200)
        for offset in [0, 1, 999, 4_000] {
            let result = Self.result(globalOffset: offset, location: "Harbor")
            let mac = SearchResultRow(
                result: result, displayMode: .percentage,
                totalCharacterCount: 4_321, totalWordCount: 800, currentWPM: 200
            )
            XCTAssertEqual(source.row(for: result).label, mac.accessibilityDescription, "offset \(offset)")
            XCTAssertEqual(source.row(for: result).position, mac.positionText, "offset \(offset)")
        }
    }

    /// A book of no length, or no source at all, reads 0 percent and never
    /// divides by nothing.
    func testAnEmptySourceReadsZeroPercent() {
        let row = PhoneBookSearchSource.empty.row(for: Self.result(globalOffset: 10, location: nil))

        XCTAssertEqual(row.position, "0.0%")
        XCTAssertFalse(PhoneBookSearchSource.empty.isTranscript)
    }

    // MARK: - The Model

    /// The model searches the book's chapters in reading order, lists what it
    /// found with the Mac's counts, and says the status once, when the search
    /// has run: after the typing pause, not at each letter.
    func testTheModelSearchesTheBookAndSaysTheCountOnce() async throws {
        var said: [String] = []
        let model = Self.source(chapters: ["The ferry left late.", "Nobody minded the ferry."])
            .makeModel { said.append($0) }

        // Typed a letter at a time, faster than the pause.
        for typed in ["f", "fe", "fer", "ferry"] {
            model.query = typed
        }
        XCTAssertEqual(model.status, .searching)
        await model.searchTask?.value

        XCTAssertEqual(model.status, .found(count: 2))
        XCTAssertEqual(model.results.map(\.chapterIndex), [0, 1])
        XCTAssertEqual(said, ["2 matches"], "One count, for the final text")
    }

    /// A word not in the book says "No matches", with no results, and a
    /// pattern that isn't a regular expression says why, with none.
    func testTheModelSaysNoMatchesAndInvalidPatterns() async throws {
        var said: [String] = []
        let model = Self.source(chapters: ["The ferry left late."]).makeModel { said.append($0) }

        model.query = "harbor"
        await model.searchTask?.value
        XCTAssertEqual(model.results, [])
        XCTAssertEqual(said, ["No matches"])

        model.useRegex = true
        model.query = "(unclosed"
        await model.searchTask?.value
        XCTAssertEqual(model.results, [])
        XCTAssertTrue(model.status.isError, "An invalid pattern isn't an error: \(model.status)")
        XCTAssertEqual(said.count, 2)
    }

    /// Closing the sheet stops a search still waiting, so nothing is said for
    /// a sheet that is gone.
    func testCancellingSaysNothing() async throws {
        var said: [String] = []
        let model = Self.source(chapters: ["The ferry left late."]).makeModel { said.append($0) }

        model.query = "ferry"
        let pending = model.searchTask
        model.cancelSearch()
        await pending?.value

        XCTAssertEqual(said, [])
        XCTAssertEqual(model.results, [])
    }

    // MARK: - Support

    /// A result in a book of `totalCharacters`, at `globalOffset`, whose
    /// context reads "...the ferry left late...".
    private static func result(globalOffset: Int, location: String?, time: TimeInterval? = nil) -> BookSearchResult {
        var result = BookSearchResult(
            chapterIndex: 1,
            characterOffset: 4,
            matchedText: "ferry",
            contextSnippet: "...the ferry left late...",
            globalOffset: globalOffset
        )
        result.locationTitle = location
        result.time = time
        return result
    }

    /// A source of a text book `totalCharacters` long.
    private static func source(totalCharacters: Int, totalWords: Int = 100, wordsPerMinute: Double = 200) -> PhoneBookSearchSource {
        PhoneBookSearchSource(
            corpus: BookSearchCorpus(chapterTexts: [], chapterTitles: [], headings: [], bookTitle: "Weather Notes"),
            totalCharacterCount: totalCharacters,
            totalWordCount: totalWords,
            wordsPerMinute: wordsPerMinute
        )
    }

    /// A source whose book holds `chapters`, untitled and without headings.
    private static func source(chapters: [String]) -> PhoneBookSearchSource {
        PhoneBookSearchSource(
            corpus: BookSearchCorpus(
                chapterTexts: chapters,
                chapterTitles: chapters.map { _ in "" },
                headings: [],
                bookTitle: "Weather Notes"
            ),
            totalCharacterCount: chapters.reduce(0) { $0 + $1.utf16Length },
            totalWordCount: 10,
            wordsPerMinute: 200
        )
    }
}
