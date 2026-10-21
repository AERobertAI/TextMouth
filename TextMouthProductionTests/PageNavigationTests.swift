import XCTest
@testable import TextMouth

/// Page as a navigation unit (PG02): the Page skip unit and its place in the
/// unit cycle, Next Page and Previous Page over a book's pages, the pages a
/// skipped section is passed over for, the words VoiceOver hears, and the
/// three actions that carry the commands.
@MainActor
final class PageNavigationTests: XCTestCase {

    // MARK: - The Page Unit

    /// Page sits between Paragraph and Heading in the cycle, has no word
    /// count, draws the document symbol both ways, and is stored by name.
    func testThePageUnitIsBetweenParagraphAndHeading() {
        let units = SkipUnit.allCases
        XCTAssertEqual(units, [
            .seconds10, .seconds15, .seconds30, .seconds60,
            .sentence, .paragraph, .page, .heading, .subheading, .bookmark,
        ])
        XCTAssertNil(SkipUnit.page.wordCount(wpm: 300))
        XCTAssertEqual(SkipUnit.page.iconName(forward: true), "doc.text")
        XCTAssertEqual(SkipUnit.page.iconName(forward: false), "doc.text")
        XCTAssertEqual(SkipUnit(rawValue: "Page"), .page)
        XCTAssertFalse(SkipUnit.page.isTimeBased)
    }

    /// The cycle passes over Page in a book that has no pages.
    func testTheCycleSkipsPageWithoutPages() {
        XCTAssertEqual(ReaderViewModel.unit(after: .paragraph, bookHasPages: true), .page)
        XCTAssertEqual(ReaderViewModel.unit(after: .paragraph, bookHasPages: false), .heading)
        XCTAssertEqual(ReaderViewModel.unit(after: .page, bookHasPages: true), .heading)
        XCTAssertEqual(ReaderViewModel.unit(after: .page, bookHasPages: false), .heading)
        XCTAssertEqual(ReaderViewModel.unit(after: .bookmark, bookHasPages: false), .seconds10)
    }

    /// The reader's own cycle gives Heading after Paragraph in a book without
    /// pages, and Page in a book with them.
    func testTheReaderCyclesThroughPageOnlyWithPages() throws {
        for (withPages, expected) in [(false, SkipUnit.heading), (true, SkipUnit.page)] {
            let settings = try makeIsolatedSettings("page-cycle")
            settings.playbackNavigationUnitControlMode = .none
            settings.skipForwardUnit = .paragraph
            let reader = makePagedReader(pages: withPages ? Self.fivePages : [], settings: settings)
            defer { reader.close() }

            reader.cyclePlaybackSkipUnit(direction: .forward)

            XCTAssertEqual(settings.skipForwardUnit, expected, withPages ? "with pages" : "without pages")
            XCTAssertEqual(reader.playbackSkipForwardUnit, expected)
        }
    }

    // MARK: - Choosing the Page

    /// Pages 1 to 5 at (0, 0), (0, 100), (1, 0), (1, 0), and (1, 50); the two
    /// at (1, 0) are one stop.
    private static let fivePages = [
        PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
        PageBreak(label: "2", chapterIndex: 0, characterOffset: 100),
        PageBreak(label: "3", chapterIndex: 1, characterOffset: 0),
        PageBreak(label: "4", chapterIndex: 1, characterOffset: 0),
        PageBreak(label: "5", chapterIndex: 1, characterOffset: 50),
    ]

    /// The label of the page `nextPage` finds, or "none".
    private func nextLabel(_ chapter: Int, _ offset: Int) -> String {
        ReaderViewModel.nextPage(
            in: BookPages(breaks: Self.fivePages),
            chapterIndex: chapter,
            characterOffset: offset,
            isPassedOver: { _ in false }
        )?.label ?? "none"
    }

    /// The label of the page `previousPage` finds, or "none".
    private func previousLabel(_ chapter: Int, _ offset: Int) -> String {
        ReaderViewModel.previousPage(
            in: BookPages(breaks: Self.fivePages),
            chapterIndex: chapter,
            characterOffset: offset,
            isPassedOver: { _ in false }
        )?.label ?? "none"
    }

    /// Next goes to the first page that starts after the place; pages that
    /// share a place are one stop, and the last page has none after it.
    func testNextPageFindsTheFirstPageAfterThePlace() {
        XCTAssertEqual(nextLabel(0, 0), "2")
        XCTAssertEqual(nextLabel(0, 100), "3")
        XCTAssertEqual(nextLabel(1, 0), "5")
        XCTAssertEqual(nextLabel(1, 50), "none")
    }

    /// Previous goes to the last page that starts more than the grace zone
    /// back, so from inside a page it goes to that page's start; the last of
    /// the pages that share a place is the one found.
    func testPreviousPageFindsThePageStartBeforeThePlace() {
        XCTAssertEqual(previousLabel(1, 55), "4")
        XCTAssertEqual(previousLabel(1, 5), "2")
        XCTAssertEqual(previousLabel(0, 105), "1")
        XCTAssertEqual(previousLabel(0, 5), "none")
    }

    /// A place before the first page has a next page and no previous one.
    func testNextPageFromBeforeTheFirstPage() {
        let pages = BookPages(breaks: [PageBreak(label: "i", chapterIndex: 0, characterOffset: 50)])
        XCTAssertEqual(
            ReaderViewModel.nextPage(in: pages, chapterIndex: 0, characterOffset: 0, isPassedOver: { _ in false })?.label,
            "i"
        )
        XCTAssertNil(ReaderViewModel.previousPage(in: pages, chapterIndex: 0, characterOffset: 0, isPassedOver: { _ in false }))
        XCTAssertNil(ReaderViewModel.nextPage(in: .none, chapterIndex: 0, characterOffset: 0, isPassedOver: { _ in false }))
        XCTAssertNil(ReaderViewModel.previousPage(in: .none, chapterIndex: 0, characterOffset: 9, isPassedOver: { _ in false }))
    }

    // MARK: - The Reader

    /// Next Page moves the cursor and says the page reached, the last of two
    /// that share the place; Previous Page goes back; Go Back returns to
    /// where Next Page started; at the last page nothing moves and nothing
    /// new is said.
    func testNextAndPreviousPageMoveTheCursorAndSayThePage() {
        let reader = makePagedReader(pages: Self.fivePages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 100

        reader.nextPage()
        XCTAssertEqual(pagedPlace(of: reader), "1:0")
        XCTAssertEqual(reader.lastAnnouncement, "Page 4")

        reader.previousPage()
        XCTAssertEqual(pagedPlace(of: reader), "0:100")
        XCTAssertEqual(reader.lastAnnouncement, "Page 2")

        reader.nextPage()
        reader.nextPage()
        XCTAssertEqual(pagedPlace(of: reader), "1:50")
        XCTAssertEqual(reader.lastAnnouncement, "Page 5")

        reader.returnToSavedPosition()
        XCTAssertEqual(pagedPlace(of: reader), "1:0")

        reader.currentCharacterOffset = 50
        reader.lastAnnouncement = "unchanged"
        reader.nextPage()
        XCTAssertEqual(pagedPlace(of: reader), "1:50")
        XCTAssertEqual(reader.lastAnnouncement, "unchanged")
    }

    /// Go Back after Next Page returns to where Next Page started.
    func testGoBackReturnsToWhereNextPageStarted() {
        let reader = makePagedReader(pages: Self.fivePages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 30

        reader.nextPage()
        XCTAssertEqual(pagedPlace(of: reader), "0:100")

        reader.returnToSavedPosition()
        XCTAssertEqual(pagedPlace(of: reader), "0:30")
    }

    /// Next Page and Previous Page pass over a page that begins inside a
    /// skipped section, as speech passes over the section.
    func testPagesInASkippedSectionArePassedOver() throws {
        let headings = [
            Heading(level: 1, text: "One", chapterIndex: 0, characterOffset: 0),
            Heading(level: 1, text: "Two", chapterIndex: 0, characterOffset: 80),
        ]
        let pages = [
            PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 100),
            PageBreak(label: "3", chapterIndex: 1, characterOffset: 0),
        ]
        let reader = makePagedReader(pages: pages, chapterZeroHeadings: headings)
        defer { reader.close() }
        let two = try XCTUnwrap(reader.headings.first { $0.text == "Two" })
        reader.toggleHeadingSkip(two)

        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0
        reader.nextPage()
        XCTAssertEqual(pagedPlace(of: reader), "1:0")
        XCTAssertEqual(reader.lastAnnouncement, "Page 3")

        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 5
        reader.previousPage()
        XCTAssertEqual(pagedPlace(of: reader), "0:0")
        XCTAssertEqual(reader.lastAnnouncement, "Page 1")
    }

    /// With nothing skipped the same pages are not passed over.
    func testWithNothingSkippedNoPageIsPassedOver() {
        let pages = [
            PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 100),
        ]
        let reader = makePagedReader(pages: pages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        reader.nextPage()
        XCTAssertEqual(pagedPlace(of: reader), "0:100")
    }

    /// In a book without pages every page command says so and moves nothing.
    func testABookWithoutPagesSaysSoAndMovesNothing() {
        let reader = makePagedReader(pages: [])
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 50

        reader.performSkip(unit: .page, forward: true)
        XCTAssertEqual(reader.lastAnnouncement, "This book has no pages.")
        XCTAssertEqual(pagedPlace(of: reader), "0:50")

        reader.lastAnnouncement = nil
        reader.nextPage()
        XCTAssertEqual(reader.lastAnnouncement, ReaderPageWording.noPages)
        reader.lastAnnouncement = nil
        reader.previousPage()
        XCTAssertEqual(reader.lastAnnouncement, "This book has no pages.")
        XCTAssertEqual(pagedPlace(of: reader), "0:50")
        XCTAssertFalse(reader.hasPages)
    }

    /// The Page unit skips by page from the playback bar's buttons.
    func testPerformSkipByPageMovesByPage() {
        let reader = makePagedReader(pages: Self.fivePages)
        defer { reader.close() }
        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 5

        reader.performSkip(unit: .page, forward: true)
        XCTAssertEqual(pagedPlace(of: reader), "1:50")
        reader.performSkip(unit: .page, forward: false)
        XCTAssertEqual(pagedPlace(of: reader), "1:0")
    }

    /// The reader describes its place by page, at the cursor and at the
    /// place the screen shows.
    func testThePagePositionsDescribeThePlace() {
        let reader = makePagedReader(pages: Self.fivePages)
        defer { reader.close() }
        XCTAssertTrue(reader.hasPages)
        XCTAssertEqual(reader.bookPages.count, 5)

        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 60
        XCTAssertEqual(reader.currentPagePosition.label, "Page 5 of 5")
    }

    // MARK: - The Actions

    /// The three actions: their titles, group, notifications, keys, and the
    /// scope they work in.
    func testThePageActions() {
        let expected: [(ShortcutAction, String, Notification.Name, KeyBinding)] = [
            (.nextPage, "Next Page", .nextPage, KeyBinding(key: "rightArrow", command: true, option: true)),
            (.previousPage, "Previous Page", .previousPage, KeyBinding(key: "leftArrow", command: true, option: true)),
            (.goToPage, "Go to Page…", .goToPage, KeyBinding(key: "g", command: true, option: true)),
        ]
        for (action, title, notification, binding) in expected {
            XCTAssertEqual(action.title, title)
            XCTAssertEqual(action.category, "Navigation")
            XCTAssertEqual(action.notificationName, notification)
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [binding], title)
            XCTAssertEqual(action.defaultScope, .app, title)
        }
    }

    /// The playback bar's menus name the unit "Page", as they name the others.
    func testThePageUnitIsNamedPage() {
        XCTAssertEqual(
            SkipUnit.page.playbackMenuAccessibilityLabel(direction: .forward),
            "Forward navigation unit: Page"
        )
    }
}

// MARK: - Fixtures

/// The paged readers `PageNavigationTests` and `GoToPageTests` share.
extension XCTestCase {
    /// A stopped reader of a book of two chapters, 200 and 100 characters of
    /// five-character words (so every offset used here is a word start), with
    /// `pages` placed as chapters hold them, read from memory: nothing plays,
    /// and nothing is read from disk.
    @MainActor
    func makePagedReader(
        pages: [PageBreak],
        chapterZeroHeadings: [Heading] = [],
        settings: SettingsViewModel? = nil
    ) -> ReaderViewModel {
        let book = Book(
            title: "Paged Book",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-paged-book.txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings ?? ((try? makeIsolatedSettings("page-reader")) ?? SettingsViewModel(initializeServices: false))
        )
        // Pages are held by their chapter with a chapter index of 0, as the
        // parse leaves them.
        func held(by chapter: Int) -> [PageBreak] {
            pages.filter { $0.chapterIndex == chapter }.map {
                PageBreak(label: $0.label, characterOffset: $0.characterOffset)
            }
        }
        let chapters = [
            Chapter(
                title: "One",
                text: String(repeating: "word ", count: 40),
                headings: chapterZeroHeadings,
                pages: held(by: 0)
            ),
            Chapter(
                title: "Two",
                text: String(repeating: "word ", count: 20),
                pages: held(by: 1)
            ),
        ]
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: chapters)
        reader.isLoading = false
        return reader
    }

    /// Where `reader`'s cursor is, as "chapter:offset".
    @MainActor
    func pagedPlace(of reader: ReaderViewModel) -> String {
        "\(reader.currentChapterIndex):\(reader.currentCharacterOffset)"
    }
}
