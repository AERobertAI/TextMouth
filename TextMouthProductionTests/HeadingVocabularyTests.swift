import Combine
import XCTest
@testable import TextMouth

/// Every user-facing location is described by headings — the list the
/// headings panel shows — and never by internal content units (EPUB spine
/// documents, audio files, whole text files). These tests pin the shared
/// position lookup and its wording so each surface speaks the same numbers.
final class HeadingPositionTests: XCTestCase {
    /// Two content units: the first holds three headings, the second one
    /// heading part-way in, and a third unit holds none. Positions can then
    /// precede, match, sit between, and cross unit boundaries.
    private let headings = [
        Heading(level: 1, text: "Part One", chapterIndex: 0, characterOffset: 10),
        Heading(level: 2, text: "Arrival", chapterIndex: 0, characterOffset: 200),
        Heading(level: 2, text: "Departure", chapterIndex: 0, characterOffset: 500),
        Heading(level: 1, text: "Part Two", chapterIndex: 1, characterOffset: 300),
    ]

    /// Shorthand for locating a position within the shared fixture.
    private func position(chapter: Int, offset: Int) -> HeadingPosition {
        HeadingPosition(in: headings, chapterIndex: chapter, characterOffset: offset)
    }

    func testPositionBeforeFirstHeadingHasNoContainingHeading() {
        let position = position(chapter: 0, offset: 9)

        XCTAssertNil(position.heading)
        XCTAssertNil(position.number)
        XCTAssertEqual(position.count, 4)
        XCTAssertEqual(position.label, "Before heading 1 of 4")
    }

    func testPositionExactlyAtHeadingBelongsToThatHeading() {
        let position = position(chapter: 0, offset: 200)

        XCTAssertEqual(position.heading?.text, "Arrival")
        XCTAssertEqual(position.number, 2)
        XCTAssertEqual(position.label, "Heading 2 of 4")
    }

    func testPositionBetweenHeadingsBelongsToTheEarlierHeading() {
        let position = position(chapter: 0, offset: 499)

        XCTAssertEqual(position.heading?.text, "Arrival")
        XCTAssertEqual(position.label, "Heading 2 of 4")
    }

    func testPositionAfterLastHeadingBelongsToTheLastHeading() {
        let position = position(chapter: 1, offset: 10_000)

        XCTAssertEqual(position.heading?.text, "Part Two")
        XCTAssertEqual(position.label, "Heading 4 of 4")
    }

    /// The start of a content unit whose first heading comes later is still
    /// inside the previous unit's last heading, exactly as the panel shows it.
    func testLaterContentUnitStartBelongsToThePreviousUnitsLastHeading() {
        let position = position(chapter: 1, offset: 0)

        XCTAssertEqual(position.heading?.text, "Departure")
        XCTAssertEqual(position.label, "Heading 3 of 4")
    }

    func testContentUnitWithoutHeadingsBelongsToTheLastEarlierHeading() {
        let position = position(chapter: 2, offset: 50)

        XCTAssertEqual(position.heading?.text, "Part Two")
        XCTAssertEqual(position.label, "Heading 4 of 4")
    }

    /// Heading numbers count headings, so a book with many headings in few
    /// content units reports the heading total rather than the unit total.
    func testCountReflectsHeadingsNotContentUnits() {
        let manyHeadings = (0..<400).map {
            Heading(level: 2, text: "Section \($0 + 1)", chapterIndex: $0 / 5, characterOffset: ($0 % 5) * 100)
        }

        let position = HeadingPosition(in: manyHeadings, chapterIndex: 25, characterOffset: 250)

        XCTAssertEqual(position.heading?.text, "Section 128")
        XCTAssertEqual(position.label, "Heading 128 of 400")
    }

    func testBookWithoutHeadingsHasAnEmptyLabel() {
        let position = HeadingPosition(in: [], chapterIndex: 0, characterOffset: 500)

        XCTAssertNil(position.heading)
        XCTAssertNil(position.number)
        XCTAssertEqual(position.count, 0)
        XCTAssertEqual(position.label, "")
    }

    /// A part heading and its first chapter heading often share an offset;
    /// the later, more specific heading wins, matching the panel.
    func testHeadingsSharingAPositionResolveToTheLastListed() {
        let shared = [
            Heading(level: 1, text: "Book One", chapterIndex: 0, characterOffset: 0),
            Heading(level: 2, text: "Opening", chapterIndex: 0, characterOffset: 0),
        ]

        let position = HeadingPosition(in: shared, chapterIndex: 0, characterOffset: 0)

        XCTAssertEqual(position.heading?.text, "Opening")
        XCTAssertEqual(position.label, "Heading 2 of 2")
    }

    /// The navigation helper and the numbered position share one lookup.
    func testCurrentHeadingMatchesHeadingPositionEverywhere() {
        let probes = [(0, 0), (0, 10), (0, 350), (0, 500), (1, 0), (1, 299), (1, 300), (2, 0)]
        for (chapter, offset) in probes {
            XCTAssertEqual(
                ReaderViewModel.currentHeading(in: headings, chapterIndex: chapter, characterOffset: offset),
                position(chapter: chapter, offset: offset).heading,
                "Mismatch at chapter \(chapter), offset \(offset)"
            )
        }
    }

    func testHeadingTextIsPresentOnlyInsideAHeading() {
        XCTAssertEqual(position(chapter: 0, offset: 600).headingText, "Departure")
        XCTAssertNil(position(chapter: 0, offset: 0).headingText)
        XCTAssertNil(HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0).headingText)
    }

    func testTitleIsTheContainingHeadingText() {
        XCTAssertEqual(
            position(chapter: 0, offset: 250).title(contentTitle: "Chapter 1", bookTitle: "Travels"),
            "Arrival"
        )
    }

    /// When headings exist, the content unit's title is never substituted,
    /// even before the first heading; the label already says where we are.
    func testTitleIsOmittedBeforeTheFirstHeading() {
        XCTAssertNil(position(chapter: 0, offset: 0).title(contentTitle: "Cover", bookTitle: "Travels"))
    }

    func testTitleFallsBackToTheContentTitleOnlyWithoutHeadings() {
        let position = HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)

        XCTAssertEqual(position.title(contentTitle: "Field Notes", bookTitle: "Travels"), "Field Notes")
    }

    func testFallbackTitleThatRepeatsTheBookTitleIsOmitted() {
        let position = HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)

        XCTAssertNil(position.title(contentTitle: " travels ", bookTitle: "Travels"))
        XCTAssertNil(position.title(contentTitle: nil, bookTitle: "Travels"))
    }

    func testBlankTitlesAreOmitted() {
        let blank = [Heading(level: 1, text: "  ", chapterIndex: 0, characterOffset: 0)]

        let position = HeadingPosition(in: blank, chapterIndex: 0, characterOffset: 5)

        XCTAssertNil(position.headingText)
        XCTAssertNil(position.title(contentTitle: "Unit", bookTitle: "Travels"))
        XCTAssertEqual(position.label, "Heading 1 of 1")
        XCTAssertNil(HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)
            .title(contentTitle: "\n", bookTitle: "Travels"))
    }
}

/// Reader-level wiring: locations are computed from the reader's published
/// heading list, which always mirrors the content the reader holds.
@MainActor
final class ReaderHeadingLocationTests: XCTestCase {
    /// Three content units: the first opens with a heading, the second has a
    /// heading part-way through, and the third has none. Each unit holds
    /// several sentences so navigation can cross unit boundaries.
    private func threeUnitContent() -> DocumentContent {
        DocumentContent(
            title: "Fixture",
            author: "Tester",
            chapters: [
                Chapter(
                    title: "Unit One",
                    text: "Opening words. More words.",
                    headings: [Heading(level: 1, text: "Opening", characterOffset: 0)]
                ),
                Chapter(
                    title: "Unit Two",
                    text: "Lead in. Middle words. More middle.",
                    headings: [Heading(level: 2, text: "Middle", characterOffset: 9)]
                ),
                Chapter(title: "Unit Three", text: "Closing words. Final words."),
            ]
        )
    }

    /// A book whose source file does not exist, so a reader's background load
    /// fails harmlessly and the test assigns content directly. The unique
    /// path keeps fixtures from sharing persisted library state.
    private func missingSourceBook(bookmarks: [Bookmark] = []) -> Book {
        Book(
            title: "Heading Vocabulary",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-heading-vocabulary.txt",
            md5Hash: UUID().uuidString,
            bookmarks: bookmarks
        )
    }

    /// Open `book` in a reader backed by an isolated library and settings.
    private func makeReader(book: Book? = nil) -> ReaderViewModel {
        let book = book ?? missingSourceBook()
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        return ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
    }

    /// Write `text` as a plain-text book inside a disposable package, open it
    /// at `savedOffset`, and wait for the production loader to finish. The
    /// loader leaves the display cursor on the saved position, just as the
    /// reader header sees it. Callers close the returned reader.
    private func loadPlainTextBook(_ text: String, savedOffset: Int) async throws -> ReaderViewModel {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let source = package.appendingPathComponent("book.txt")
        try Data(text.utf8).write(to: source)
        let book = Book(
            title: "Harbor Log",
            format: .txt,
            filePath: source.path,
            md5Hash: UUID().uuidString,
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: savedOffset),
            tmbDirectoryName: packageName
        )
        let reader = makeReader(book: book)
        let loaded = expectation(description: "Content loaded")
        let subscription = reader.$isLoading.filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNil(reader.errorMessage)
        return reader
    }

    func testAssigningContentPublishesItsHeadings() {
        let reader = makeReader()
        defer { reader.close() }

        reader.content = threeUnitContent()

        XCTAssertEqual(reader.headings.map(\.text), ["Opening", "Middle"])
        XCTAssertEqual(reader.headings.map(\.id), reader.content?.allHeadings.map(\.id))

        reader.content = nil

        XCTAssertTrue(reader.headings.isEmpty)
    }

    /// The header names the heading holding the display cursor and numbers
    /// it among every heading, rather than showing a content unit count.
    func testHeaderNamesAndNumbersTheHeadingBeingRead() async throws {
        let prose = String(repeating: "Steady prose continues here. ", count: 20)
        let reader = try await loadPlainTextBook(
            "# Harbor\n\nShort opening.\n\n# Crossing\n\n\(prose)",
            savedOffset: 300
        )
        defer { reader.close() }

        let position = reader.displayHeadingPosition

        XCTAssertEqual(reader.headings.map(\.text), ["Harbor", "Crossing"])
        XCTAssertEqual(position.label, "Heading 2 of 2")
        XCTAssertEqual(reader.locationTitle(for: position, chapterIndex: reader.displayChapterIndex), "Crossing")
    }

    /// A single-unit book without headings shows no heading line at all: its
    /// only content title repeats the book title, and there is no count.
    func testHeaderOmitsHeadingLinesForABookWithoutHeadings() async throws {
        let reader = try await loadPlainTextBook(
            "Just a few sentences of prose. Nothing else is here to find.",
            savedOffset: 20
        )
        defer { reader.close() }

        let position = reader.displayHeadingPosition

        XCTAssertTrue(reader.headings.isEmpty)
        XCTAssertEqual(position.label, "")
        XCTAssertNil(reader.locationTitle(for: position, chapterIndex: reader.displayChapterIndex))
    }

    /// Books without headings still name a content unit whose title adds
    /// something beyond the book title.
    func testLocationTitleFallsBackToADistinctContentTitleWithoutHeadings() {
        let reader = makeReader()
        defer { reader.close() }
        reader.content = DocumentContent(
            title: "Fixture",
            author: "Tester",
            chapters: [Chapter(title: "Appendix Notes", text: "Plain text without headings.")]
        )

        let position = HeadingPosition(in: reader.headings, chapterIndex: 0, characterOffset: 5)

        XCTAssertEqual(reader.locationTitle(for: position, chapterIndex: 0), "Appendix Notes")
        XCTAssertNil(reader.locationTitle(for: position, chapterIndex: 7))
    }

    /// Where Am I reads the live cursor: both detail levels name the heading
    /// being read exactly once and number it among all headings.
    func testWhereAmIDescribesTheLiveCursorByHeading() {
        let reader = makeReader()
        defer { reader.close() }
        let content = threeUnitContent()
        reader.content = content
        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 12

        let brief = reader.buildBriefWhereAmI()
        let full = reader.buildFullWhereAmI(content: content)

        XCTAssertTrue(brief.hasPrefix("Heading Vocabulary. Middle. Heading 2 of 2. "), brief)
        XCTAssertTrue(full.hasPrefix("Heading Vocabulary. Middle. Heading 2 of 2. "), full)
        XCTAssertEqual(full.components(separatedBy: "Middle").count - 1, 1)
        XCTAssertFalse(full.localizedCaseInsensitiveContains("chapter"))
    }

    /// The start of a content unit whose heading comes later still belongs
    /// to the previous unit's heading, as the headings panel shows it.
    func testWhereAmIBeforeAUnitsFirstHeadingNamesTheEarlierHeading() {
        let reader = makeReader()
        defer { reader.close() }
        reader.content = threeUnitContent()
        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 0

        XCTAssertTrue(reader.buildBriefWhereAmI().hasPrefix("Heading Vocabulary. Opening. Heading 1 of 2. "))
    }

    /// Bookmarks are located by the heading containing them, computed from
    /// the reader's content; the panel's rows and rotor share that label.
    func testBookmarksAreLabeledByTheirContainingHeading() {
        let beforeMiddle = Bookmark(number: 1, chapterIndex: 1, characterOffset: 3, label: "Check")
        let inMiddle = Bookmark(number: 2, chapterIndex: 1, characterOffset: 20)
        let inLastUnit = Bookmark(number: 3, chapterIndex: 2, characterOffset: 5)
        let reader = makeReader(book: missingSourceBook(bookmarks: [beforeMiddle, inMiddle, inLastUnit]))
        defer { reader.close() }

        // Before content loads there is no heading to name.
        XCTAssertNil(reader.headingText(forBookmark: inMiddle))

        reader.content = threeUnitContent()
        let panel = BookmarkPanelView(viewModel: reader)

        XCTAssertEqual(reader.headingText(forBookmark: beforeMiddle), "Opening")
        XCTAssertEqual(reader.headingText(forBookmark: inMiddle), "Middle")
        XCTAssertEqual(reader.headingText(forBookmark: inLastUnit), "Middle")
        XCTAssertEqual(
            panel.bookmarkRow(for: beforeMiddle).bookmarkAccessibilityLabel,
            "Bookmark 1, Opening, Note: Check"
        )
        XCTAssertEqual(panel.bookmarkRow(for: inLastUnit).bookmarkAccessibilityLabel, "Bookmark 3, Middle")
    }

    func testBookmarkBeforeTheFirstHeadingOmitsItsLocation() {
        let reader = makeReader()
        defer { reader.close() }
        reader.content = DocumentContent(
            title: "Fixture",
            author: "Tester",
            chapters: [
                Chapter(
                    title: "Cover",
                    text: "Cover text. Then the story.",
                    headings: [Heading(level: 1, text: "Story", characterOffset: 12)]
                ),
            ]
        )
        let bookmark = Bookmark(number: 1, chapterIndex: 0, characterOffset: 2)

        XCTAssertNil(reader.headingText(forBookmark: bookmark))
        XCTAssertEqual(
            BookmarkPanelView(viewModel: reader).bookmarkRow(for: bookmark).bookmarkAccessibilityLabel,
            "Bookmark 1"
        )
    }

    // MARK: Crossing content units by sentence or paragraph

    /// Moving past the last sentence of one unit lands at the start of the
    /// next; the announcement names the heading holding that spot (here the
    /// earlier heading, because the new unit's heading starts later).
    func testNextSentenceIntoANewUnitNamesTheContainingHeading() {
        let reader = makeReader()
        defer { reader.close() }
        reader.content = threeUnitContent()
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 15

        reader.nextSentence()

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        XCTAssertEqual(reader.lastAnnouncement, "Opening")
    }

    func testNextParagraphIntoAUnitWithoutHeadingsNamesTheLastHeading() {
        let reader = makeReader()
        defer { reader.close() }
        reader.content = threeUnitContent()
        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 23

        reader.nextParagraph()

        XCTAssertEqual(reader.currentChapterIndex, 2)
        XCTAssertEqual(reader.lastAnnouncement, "Middle")
    }

    func testPreviousSentenceIntoTheEarlierUnitNamesItsHeading() {
        let reader = makeReader()
        defer { reader.close() }
        reader.content = threeUnitContent()
        reader.currentChapterIndex = 2
        reader.currentCharacterOffset = 0

        reader.previousSentence()

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.lastAnnouncement, "Middle")
    }

    /// With no heading to name, the move is described generically and never
    /// by an internal content-unit number.
    func testCrossingUnitsWithoutHeadingsSaysNextOrPreviousSection() {
        let reader = makeReader()
        defer { reader.close() }
        reader.content = DocumentContent(
            title: "Fixture",
            author: "Tester",
            chapters: [
                Chapter(title: "One", text: "First unit sentence."),
                Chapter(title: "Two", text: "Second unit sentence."),
            ]
        )

        reader.nextSentence()
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.lastAnnouncement, "Next section")

        reader.previousParagraph()
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.lastAnnouncement, "Previous section")
    }
}

/// Wording for sentence and paragraph moves that cross content units.
final class SectionCrossingAnnouncementTests: XCTestCase {
    private let headings = [
        Heading(level: 1, text: "Opening", chapterIndex: 0, characterOffset: 0),
        Heading(level: 2, text: "Middle", chapterIndex: 1, characterOffset: 9),
    ]

    /// Announcement for a move landing at (chapter, offset).
    private func announcement(chapter: Int, offset: Int, forward: Bool, in headings: [Heading]? = nil) -> String {
        ReaderViewModel.sectionCrossingAnnouncement(
            in: headings ?? self.headings,
            chapterIndex: chapter,
            characterOffset: offset,
            forward: forward
        )
    }

    func testLandingOnAHeadingNamesIt() {
        XCTAssertEqual(announcement(chapter: 1, offset: 9, forward: true), "Middle")
    }

    func testLandingBeforeAUnitsHeadingNamesTheEarlierHeading() {
        XCTAssertEqual(announcement(chapter: 1, offset: 0, forward: true), "Opening")
        XCTAssertEqual(announcement(chapter: 2, offset: 0, forward: false), "Middle")
    }

    func testLandingBeforeTheFirstHeadingSaysSection() {
        let later = [Heading(level: 1, text: "Story", chapterIndex: 1, characterOffset: 0)]

        XCTAssertEqual(announcement(chapter: 0, offset: 40, forward: false, in: later), "Previous section")
    }

    func testBookWithoutHeadingsSaysNextOrPreviousSection() {
        XCTAssertEqual(announcement(chapter: 3, offset: 0, forward: true, in: []), "Next section")
        XCTAssertEqual(announcement(chapter: 3, offset: 0, forward: false, in: []), "Previous section")
    }

    func testBlankHeadingTextIsNotAnnounced() {
        let blank = [Heading(level: 1, text: " ", chapterIndex: 0, characterOffset: 0)]

        XCTAssertEqual(announcement(chapter: 1, offset: 0, forward: true, in: blank), "Next section")
    }
}

/// Error messages are read aloud too, so they use the same vocabulary.
final class AudioParseErrorWordingTests: XCTestCase {
    func testInvalidSegmentDescribesASection() {
        XCTAssertEqual(
            AudioParseError.invalidSegment.errorDescription,
            "An audio section refers to a missing file or an invalid time range."
        )
    }

    func testNoAudioErrorMentionsChapters() {
        let errors: [AudioParseError] = [.invalidDuration, .noAudioFiles, .unsupportedFormat, .invalidSegment]
        for error in errors {
            XCTAssertFalse(
                (error.errorDescription ?? "").localizedCaseInsensitiveContains("chapter"),
                "\(error) mentions chapters"
            )
        }
    }
}

/// Library rows hold only the Book model (no parsed headings), so they show
/// overall progress in place of the old content-unit number.
@MainActor
final class LibraryProgressTextTests: XCTestCase {
    /// An opened library book with the given saved position and measured size.
    private func book(position: ReadingPosition?, totalCharacters: Int?) -> Book {
        Book(
            title: "Atlas of Canals",
            author: "A. Surveyor",
            format: .epub,
            filePath: "/tmp/\(UUID().uuidString).epub",
            md5Hash: UUID().uuidString,
            lastOpened: Date(),
            readingPosition: position,
            totalCharacterCount: totalCharacters
        )
    }

    func testProgressUsesTheBookWideOffset() {
        let book = book(
            position: ReadingPosition(chapterIndex: 12, characterOffset: 5, globalCharacterOffset: 420),
            totalCharacters: 1_000
        )

        let progress = BookRow.progressText(for: book)

        XCTAssertEqual(progress?.visible, "42%")
        XCTAssertEqual(progress?.spoken, "42 percent")
    }

    /// Legacy positions without a book-wide offset use the same fallback as
    /// the row's time-left estimate, so the two figures never disagree.
    func testProgressFallsBackToTheSavedOffsetLikeTimeRemaining() {
        let book = book(position: ReadingPosition(chapterIndex: 0, characterOffset: 250), totalCharacters: 1_000)

        XCTAssertEqual(book.percentComplete, 25)
        XCTAssertEqual(BookRow.progressText(for: book)?.visible, "25%")
    }

    func testProgressRoundsToWholePercents() {
        let book = book(
            position: ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: 416),
            totalCharacters: 1_000
        )

        XCTAssertEqual(BookRow.progressText(for: book)?.spoken, "42 percent")
    }

    func testProgressIsClampedToTheBook() {
        let pastEnd = book(
            position: ReadingPosition(chapterIndex: 3, characterOffset: 0, globalCharacterOffset: 5_000),
            totalCharacters: 1_000
        )
        let beforeStart = book(
            position: ReadingPosition(chapterIndex: 0, characterOffset: 0, globalCharacterOffset: -20),
            totalCharacters: 1_000
        )

        XCTAssertEqual(BookRow.progressText(for: pastEnd)?.visible, "100%")
        XCTAssertEqual(BookRow.progressText(for: beforeStart)?.visible, "0%")
    }

    /// Without a saved position or a measured size the row omits progress
    /// rather than guessing.
    func testProgressIsOmittedWhenItCannotBeComputed() {
        XCTAssertNil(BookRow.progressText(for: book(position: nil, totalCharacters: 1_000)))
        XCTAssertNil(BookRow.progressText(for: book(position: ReadingPosition(), totalCharacters: nil)))
        XCTAssertNil(BookRow.progressText(for: book(position: ReadingPosition(), totalCharacters: 0)))
    }

    func testRowLabelSpeaksPercentInsteadOfAChapter() {
        let row = BookRow(book: book(
            position: ReadingPosition(chapterIndex: 12, characterOffset: 5, globalCharacterOffset: 420),
            totalCharacters: 1_000
        ))

        XCTAssertTrue(row.rowAccessibilityLabel.contains("42 percent"), row.rowAccessibilityLabel)
        XCTAssertFalse(row.rowAccessibilityLabel.localizedCaseInsensitiveContains("chapter"))
    }

    func testRowLabelOmitsProgressForAnUnmeasuredBook() {
        let row = BookRow(book: book(position: ReadingPosition(chapterIndex: 4), totalCharacters: nil))

        XCTAssertEqual(row.rowAccessibilityLabel, "Atlas of Canals, by A. Surveyor, EPUB")
    }
}
