import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Page as a navigation unit (PG02): the Page skip unit and its place in the
/// unit cycle, the pickers that offer it (the playback bar's leave it out
/// for a book without pages), `nextPage()` and `previousPage()`, which the
/// Page unit moves with, called "Next Page" and "Previous Page" below, over a
/// book's pages, the pages a skipped section is passed over for, the words
/// VoiceOver hears, and Go to Page…'s action.
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

    // MARK: - The Playback Bar's Pickers

    /// A picker for one book offers every unit, in the one order, when the
    /// book has pages, and leaves Page out when it has none: there would be
    /// nothing to move by. A unit already in force stays in, Page included,
    /// so the picker still holds the value it shows.
    func testAPickerLeavesPageOutForABookWithoutPages() {
        let everyUnit = SkipUnit.allCases
        let withoutPage = everyUnit.filter { $0 != .page }

        for selected in everyUnit {
            XCTAssertEqual(
                ReaderViewModel.navigationUnitChoices(bookHasPages: true, keeping: selected),
                everyUnit,
                "with pages, \(selected.rawValue) selected"
            )
            XCTAssertEqual(
                ReaderViewModel.navigationUnitChoices(bookHasPages: false, keeping: selected),
                selected == .page ? everyUnit : withoutPage,
                "without pages, \(selected.rawValue) selected"
            )
        }
        XCTAssertFalse(withoutPage.isEmpty)
        XCTAssertEqual(withoutPage.first, .seconds10)
        XCTAssertEqual(withoutPage.last, .bookmark)
    }

    /// The reader asks for its own book's pages: a book with pages offers
    /// Page, one without does not, and an audiobook, which has none, does
    /// not either; each keeps the unit in force.
    func testTheReaderOffersPageOnlyForABookWithPages() throws {
        let paged = makePagedReader(pages: Self.fivePages)
        defer { paged.close() }
        XCTAssertTrue(paged.navigationUnitChoices(keeping: .seconds15).contains(.page))

        let plain = makePagedReader(pages: [])
        defer { plain.close() }
        XCTAssertFalse(plain.navigationUnitChoices(keeping: .seconds15).contains(.page))
        XCTAssertTrue(plain.navigationUnitChoices(keeping: .page).contains(.page), "the unit in force stays")

        let audiobook = RecordingTimeFixtures.makeReader(format: .audio)
        defer { audiobook.close() }
        audiobook.content = try RecordingTimeFixtures.audioContent(.oneFile)
        XCTAssertFalse(audiobook.hasPages)
        XCTAssertEqual(
            audiobook.navigationUnitChoices(keeping: .heading),
            SkipUnit.allCases.filter { $0 != .page }
        )
    }

    /// The shared picker the playback bar draws lists Page for a book with
    /// pages and not for one without, and shows a Page already in force.
    /// Skipped where no pop-up is drawn offscreen.
    func testTheSharedPickerOffersPageOnlyForABookWithPages() throws {
        let everyUnit = SkipUnit.allCases.map(\.rawValue)
        let withoutPage = SkipUnit.allCases.filter { $0 != .page }.map(\.rawValue)
        // (pages, the unit in force, the titles the pop-up lists, the title it shows)
        let cases: [(pages: [PageBreak], unit: SkipUnit, titles: [String], shown: String)] = [
            (Self.fivePages, .seconds30, everyUnit, "30 seconds"),
            ([], .seconds30, withoutPage, "30 seconds"),
            ([], .page, everyUnit, "Page"),
        ]
        for (pages, unit, titles, shown) in cases {
            let settings = try makeIsolatedSettings("page-picker")
            settings.playbackNavigationUnitControlMode = .shared
            settings.skipForwardUnit = unit
            settings.skipBackwardUnit = unit
            let reader = makePagedReader(pages: pages, settings: settings)
            defer { reader.close() }
            let size = NSSize(width: 700, height: 80)

            try withHostedView(
                PlaybackControlsView(viewModel: reader).frame(width: size.width, height: size.height),
                size: size,
                until: { !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty }
            ) { hosting in
                let popUp = try XCTUnwrap(
                    descendants(of: hosting, as: NSPopUpButton.self).first { $0.itemTitles.contains("15 seconds") },
                    "no navigation unit pop-up was drawn"
                )
                XCTAssertEqual(popUp.itemTitles, titles, "\(pages.count) pages, \(unit.rawValue) in force")
                XCTAssertEqual(popUp.titleOfSelectedItem, shown)
            }
        }
    }

    /// Only Settings' own pickers list every unit by name: they choose the
    /// units of all books at once, so Page stays among them. The playback
    /// bar's pickers take theirs from the reader, which leaves Page out for
    /// a book without pages, and a list of every unit written into the bar
    /// again would offer it there.
    func testOnlySettingsPickersListEveryUnit() throws {
        let sources = try AppSourceFile.all()
        let listing = sources.filter { $0.text.contains("ForEach(SkipUnit.allCases") }.map(\.path)
        XCTAssertEqual(listing, ["Views/Settings/SettingsView.swift"])
        let settings = try XCTUnwrap(sources.first { $0.path == "Views/Settings/SettingsView.swift" })
        XCTAssertEqual(
            settings.text.components(separatedBy: "ForEach(SkipUnit.allCases").count - 1,
            4,
            "Skip Forward, Skip Backward, and the two Shift+Skip pickers"
        )
        let bar = try XCTUnwrap(sources.first { $0.path == "Views/Reader/PlaybackControlsView.swift" })
        XCTAssertEqual(
            bar.text.components(separatedBy: "navigationUnitChoices(keeping:").count - 1,
            3,
            "the shared picker, and the forward and backward pickers"
        )
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

    /// Next Page never says a page twice. A page after chapter One's last
    /// word (offset 200 of 200) is reached at chapter Two's first word, and
    /// one after the book's last word, which has no words, is passed over:
    /// each press moves on and says the page the row shows, until the last
    /// page there is to reach. Previous Page goes back the same way. Before,
    /// a page at a chapter's very end was clamped onto the page before it,
    /// and every press said it again.
    func testNextPageNeverSaysAPageTwice() {
        let pages = [
            PageBreak(label: "1", chapterIndex: 0, characterOffset: 0),
            PageBreak(label: "2", chapterIndex: 0, characterOffset: 100),
            PageBreak(label: "3", chapterIndex: 0, characterOffset: 200),
            PageBreak(label: "4", chapterIndex: 1, characterOffset: 50),
            PageBreak(label: "5", chapterIndex: 1, characterOffset: 100),
        ]
        let reader = makePagedReader(pages: pages)
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0

        // Each press's announcement and place, until a press says nothing.
        func presses(_ command: () -> Void) -> [String] {
            var said: [String] = []
            for _ in 0..<pages.count + 1 {
                reader.lastAnnouncement = nil
                command()
                guard let announcement = reader.lastAnnouncement else { break }
                said.append("\(announcement) at \(pagedPlace(of: reader))")
                XCTAssertEqual(announcement, "Page \(reader.currentPagePosition.page?.label ?? "none")", "the row says otherwise")
            }
            return said
        }

        XCTAssertEqual(presses { reader.nextPage() }, ["Page 2 at 0:100", "Page 3 at 1:0", "Page 4 at 1:50"])
        XCTAssertEqual(presses { reader.previousPage() }, ["Page 3 at 1:0", "Page 2 at 0:100", "Page 1 at 0:0"])
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

    /// In a book of one page every page command says so and moves nothing,
    /// as in a book without pages, since there is no other page to go to
    /// (the user's request, November 4, 2026), and the pickers leave Page
    /// out unless it is the unit in force.
    func testABookOfOnePageSaysSoAndMovesNothing() {
        let reader = makePagedReader(pages: [PageBreak(label: "1", chapterIndex: 0, characterOffset: 0)])
        defer { reader.close() }
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 50

        reader.performSkip(unit: .page, forward: true)
        XCTAssertEqual(reader.lastAnnouncement, "This book has only one page.")
        XCTAssertEqual(pagedPlace(of: reader), "0:50")

        reader.lastAnnouncement = nil
        reader.previousPage()
        XCTAssertEqual(reader.lastAnnouncement, ReaderPageWording.onlyOnePage)
        XCTAssertEqual(pagedPlace(of: reader), "0:50", "Previous Page moved to the page's start")

        reader.lastAnnouncement = nil
        reader.requestGoToPage()
        XCTAssertEqual(reader.lastAnnouncement, "This book has only one page.")
        XCTAssertEqual(reader.goToPageRequests, 0, "Go to Page… opened its panel")

        XCTAssertTrue(reader.hasPages)
        XCTAssertFalse(reader.hasSeveralPages)
        XCTAssertFalse(reader.navigationUnitChoices(keeping: .seconds15).contains(.page))
        XCTAssertTrue(reader.navigationUnitChoices(keeping: .page).contains(.page), "the unit in force stays")
    }

    /// While the book loads every page command does nothing and says
    /// nothing, as Next Heading does: the reader has no book to ask yet, and
    /// "This book has no pages." for the moments a book with pages takes to
    /// load would tell the listener otherwise. Once it has loaded, the same
    /// commands move.
    func testWhileTheBookLoadsThePageCommandsAreSilent() {
        let reader = makePagedReader(pages: Self.fivePages)
        defer { reader.close() }
        let loaded = reader.content
        reader.content = nil
        reader.isLoading = true
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = 0
        reader.lastAnnouncement = nil

        reader.nextPage()
        reader.previousPage()
        reader.performSkip(unit: .page, forward: true)
        reader.performSkip(unit: .page, forward: false)
        reader.requestGoToPage()

        XCTAssertNil(reader.lastAnnouncement, "a page command spoke while the book loaded")
        XCTAssertEqual(reader.goToPageRequests, 0)
        XCTAssertEqual(pagedPlace(of: reader), "0:0")

        reader.content = loaded
        reader.isLoading = false
        reader.nextPage()
        XCTAssertEqual(pagedPlace(of: reader), "0:100")
        reader.requestGoToPage()
        XCTAssertEqual(reader.goToPageRequests, 1)
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

    /// The one page action: its title, group, notification, key, and the
    /// scope it works in. Moving from page to page is the Page unit's: the
    /// separate Next Page and Previous Page commands were removed at the
    /// user's request (November 5, 2026), and their names are no action's.
    func testThePageAction() {
        let action = ShortcutAction.goToPage
        XCTAssertEqual(action.title, "Go to Page…")
        XCTAssertEqual(action.category, "Navigation")
        XCTAssertEqual(action.notificationName, .goToPage)
        XCTAssertEqual(
            ShortcutAction.defaultBindings[action],
            [KeyBinding(key: "g", command: true, option: true)]
        )
        XCTAssertEqual(action.defaultScope, .app)
        XCTAssertNil(ShortcutAction.named("Next Page"))
        XCTAssertNil(ShortcutAction.named("Previous Page"))
    }

    /// A key the user gave one of the removed commands is left out of the
    /// record of their edits, with a line saying why, and every other edit
    /// in the record is kept.
    func testAKeyGivenToARemovedPageCommandIsLeftOut() throws {
        let record = #"""
            {"Next Page": ["control+n"], "Go to Page…": ["control+g"]}
            """#
        let reading = ShortcutEdits.reading(try XCTUnwrap(record.data(using: .utf8)))
        XCTAssertEqual(reading.skipped.map(\.name), ["Next Page"])
        XCTAssertEqual(
            reading.edits.keys(of: .goToPage),
            [KeyBinding(key: "g", control: true)]
        )
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
    /// and nothing is read from disk. `chapterZeroText` gives chapter One
    /// words of its own, and `substitutions` gives the reader text
    /// substitution rules of its own; without them it uses the app's.
    @MainActor
    func makePagedReader(
        pages: [PageBreak],
        chapterZeroHeadings: [Heading] = [],
        settings: SettingsViewModel? = nil,
        chapterZeroText: String = String(repeating: "word ", count: 40),
        substitutions: [SubstitutionRule]? = nil
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
            settingsViewModel: settings ?? ((try? makeIsolatedSettings("page-reader")) ?? SettingsViewModel(initializeServices: false)),
            // A service of the test's own, which reads and writes no rule
            // file; nil keeps the app's.
            substitutionService: substitutions.map { TextSubstitutionService(rules: $0) }
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
                text: chapterZeroText,
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
