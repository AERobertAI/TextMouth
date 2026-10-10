import XCTest
@testable import TextMouth

/// Every saved place of a text book takes the words around it as it is
/// saved (T06's branch B): the reading position at each save, a bookmark as
/// either add makes it, and a skipped heading as it is toggled, each in the
/// book's row and its record. The skipped headings themselves are what is
/// saved, and their IDs are written from them.
///
/// Each book is an EPUB imported as a user imports one, into a library
/// folder of the test's own, and opened in a real reader that loads it
/// through its own background loader; nothing is spoken.
@MainActor
final class TextAnchorCaptureTests: XCTestCase {

    // MARK: - Skipped Headings

    /// The library saves skipped headings as they are given, with their IDs
    /// written from them; a heading given without its text keeps the text
    /// the row already holds for the same heading, as a reader whose copy
    /// of the book predates a capture would give it, and the record takes
    /// the same.
    func testAHeadingSavedWithoutItsTextKeepsTheTextTheRowHolds() throws {
        let world = try makeIntegrationWorld("Anchor Capture Skip Save")
        let book = try world.importBook(from: writeOrchardEPUB())
        let pruning = SkippedHeading(level: 1, label: "Pruning in Frost", chapterIndex: 1, characterOffset: 0)
        let pressing = SkippedHeading(level: 1, label: "The Cider Press", chapterIndex: 2, characterOffset: 0)
        var anchoredPruning = pruning
        anchoredPruning.anchor = TextAnchor(before: "", after: "Pruning in Frost", fraction: 0.3, measuredIn: "3.0.7/1.0.0")
        world.library.updateSkippedHeadings(bookID: book.id, headings: [anchoredPruning])

        world.library.updateSkippedHeadings(bookID: book.id, headings: [pruning, pressing])

        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.skippedHeadings, [anchoredPruning, pressing])
        XCTAssertEqual(row.skippedHeadingIDs, [pruning.id, pressing.id])
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.skippedHeadings, [anchoredPruning, pressing])
        XCTAssertEqual(record.state.skippedHeadingIDs, [pruning.id, pressing.id])

        world.library.updateSkippedHeadings(bookID: book.id, headings: [])
        XCTAssertNil(world.library.bookByID(book.id)?.skippedHeadings)
        XCTAssertNil(world.library.bookByID(book.id)?.skippedHeadingIDs)
    }

    // MARK: - The Reading Position

    /// Each save of a text book's position takes the words around it from
    /// the text the reader shows: up to 64 UTF-16 units before and after
    /// it, its share of the book, and this build's measure, in the book's
    /// row and its record.
    func testEachSaveOfThePositionTakesTheWordsAroundIt() throws {
        let world = try makeIntegrationWorld("Anchor Capture Position")
        let book = try world.importBook(from: writeOrchardEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let content = try XCTUnwrap(reader.content)
        let place = TextPlace(chapter: 1, offset: 70)

        reader.currentChapterIndex = place.chapter
        reader.currentCharacterOffset = place.offset
        reader.savePosition()

        let saved = try XCTUnwrap(world.library.bookByID(book.id)?.readingPosition)
        let anchor = try XCTUnwrap(saved.anchor, "the position was saved without its words")
        let chapter = content.chapters[1].text as NSString
        XCTAssertEqual(anchor.before, chapter.substring(with: NSRange(location: 6, length: 64)))
        XCTAssertEqual(anchor.after, chapter.substring(with: NSRange(location: 70, length: 64)))
        XCTAssertEqual(anchor.measuredIn, TextAnchor.currentMeasure)
        XCTAssertEqual(anchor.fraction, Double(content.chapterStartOffset(1) + 70) / Double(content.totalCharacterCount), accuracy: 1e-12)
        XCTAssertTrue(anchor.stands(at: place, in: content.chapters.map(\.text)))
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.readingPosition?.anchor, anchor, "the record lacks the words")
    }

    /// The place the book opened at keeps the words it was saved with while
    /// the cursor stays there, even words its text no longer holds there, as
    /// after a change of the text no build could follow yet: the load's save
    /// and any save before the cursor moves keep them. Once the cursor moves,
    /// every save takes the words where it is, a return to the opened place
    /// included.
    func testTheOpenedPlaceKeepsItsWordsUntilTheCursorMoves() throws {
        let world = try makeIntegrationWorld("Anchor Capture Opened Place")
        let book = try world.importBook(from: writeOrchardEPUB())
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let earlier = TextAnchor(
            before: "words this text no longer holds ",
            after: "nor these either",
            fraction: 0.4,
            measuredIn: "3.0.4/1.0.0"
        )
        world.library.persistReadingPosition(
            bookID: book.id,
            position: ReadingPosition(
                chapterIndex: 1,
                characterOffset: 40,
                globalCharacterOffset: content.chapterStartOffset(1) + 40,
                anchor: earlier
            )
        )
        let reader = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(reader)
        func savedAnchor() -> TextAnchor? {
            world.library.bookByID(book.id)?.readingPosition?.anchor
        }
        XCTAssertEqual(savedAnchor(), earlier, "the load's save took other words")

        reader.savePosition()
        XCTAssertEqual(savedAnchor(), earlier, "a save without moving took other words")

        reader.currentCharacterOffset = 60
        reader.savePosition()
        XCTAssertEqual(savedAnchor(), content.anchor(at: TextPlace(chapter: 1, offset: 60), measuredIn: TextAnchor.currentMeasure))
        reader.currentCharacterOffset = 40
        reader.savePosition()
        XCTAssertEqual(
            savedAnchor(),
            content.anchor(at: TextPlace(chapter: 1, offset: 40), measuredIn: TextAnchor.currentMeasure),
            "a return to the opened place took its old words"
        )
    }

    /// An audiobook's places count time in its recording (P08), so neither
    /// its position nor a bookmark keeps words.
    func testAnAudiobooksPlacesKeepNoWords() throws {
        let world = try makeIntegrationWorld("Anchor Capture Audiobook")
        let book = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1, 1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)

        reader.currentCharacterOffset = 5
        reader.savePosition()
        let bookmark = try XCTUnwrap(reader.addBookmarkAtCurrentPosition(label: "Second bell"))

        let saved = try XCTUnwrap(world.library.bookByID(book.id)?.readingPosition)
        XCTAssertEqual(saved.characterOffset, 5)
        XCTAssertNil(saved.anchor)
        XCTAssertNil(bookmark.anchor)
        XCTAssertNil(world.library.bookmarksForBook(book.id).first?.anchor)
    }

    // MARK: - Bookmarks

    /// Both ways of adding a bookmark keep the words around the offset each
    /// saves: Add Bookmark at the cursor, and the bookmark toggle at the
    /// offset it saves, which at a chapter's very end is its last character.
    /// Each is in the book's row and its record.
    func testBothBookmarkAddsKeepTheWordsWhereTheySave() throws {
        let world = try makeIntegrationWorld("Anchor Capture Bookmarks")
        let book = try world.importBook(from: writeOrchardEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let content = try XCTUnwrap(reader.content)

        reader.currentChapterIndex = 2
        reader.currentCharacterOffset = 25
        let added = try XCTUnwrap(reader.addBookmarkAtCurrentPosition(label: "The oak screw"))
        XCTAssertEqual(added.anchor, content.anchor(at: TextPlace(chapter: 2, offset: 25), measuredIn: TextAnchor.currentMeasure))

        let end = content.chapters[0].text.utf16Length
        reader.currentChapterIndex = 0
        reader.currentCharacterOffset = end
        reader.toggleBookmarkAtCurrentPosition()
        let toggled = try XCTUnwrap(world.library.bookmarksForBook(book.id).first { $0.chapterIndex == 0 })
        XCTAssertEqual(toggled.characterOffset, end - 1, "the toggle saved another offset")
        XCTAssertEqual(toggled.anchor, content.anchor(at: TextPlace(chapter: 0, offset: end - 1), measuredIn: TextAnchor.currentMeasure))

        let row = world.library.bookmarksForBook(book.id)
        XCTAssertEqual(row.count, 2)
        XCTAssertTrue(row.allSatisfy { $0.anchor != nil }, "a bookmark lacks its words")
        XCTAssertEqual(reader.bookmarks, row, "the reader's bookmarks differ from the row's")
        LibraryPersistenceService.flushPendingSave()
        // The record keeps dates to the second, so the bookmarks are
        // compared by what identifies them and their words.
        let recorded = try BookInfo.load(from: book.tmbDirectory).bookmarks
        XCTAssertEqual(recorded.map(\.id), row.map(\.id))
        XCTAssertEqual(recorded.map(\.anchor), row.map(\.anchor), "the record's bookmarks lack their words")
    }

    /// A bookmark added where the book opened, before the cursor moves,
    /// keeps the words that place was saved with, as the position does, so
    /// both stay together however the text changed under them.
    func testABookmarkAddedWhereTheBookOpenedKeepsThatPlacesWords() throws {
        let world = try makeIntegrationWorld("Anchor Capture Bookmark Opened")
        let book = try world.importBook(from: writeOrchardEPUB())
        let earlier = TextAnchor(before: "an older reading's ", after: "words at this place", fraction: 0.5, measuredIn: "3.0.4/1.0.0")
        world.library.persistReadingPosition(
            bookID: book.id,
            position: ReadingPosition(chapterIndex: 2, characterOffset: 30, anchor: earlier)
        )
        let reader = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(reader)

        let bookmark = try XCTUnwrap(reader.addBookmarkAtCurrentPosition())

        XCTAssertEqual(bookmark.anchor, earlier)
        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition?.anchor, earlier)
    }

    /// A reader's live position reaches the library's rows only when its
    /// cursor moves: one at the cursor the row shows publishes nothing,
    /// though it carries words the row's position lacks, as every position
    /// a reader makes now does; one a unit further publishes, with them.
    func testALivePositionWithWordsAtAnUnmovedCursorPublishesNothing() {
        let saved = ReadingPosition(chapterIndex: 1, characterOffset: 40, globalCharacterOffset: 140)
        let book = Book(title: "Orchard Ledger", format: .epub, filePath: "/nowhere/orchard.epub", md5Hash: "orchard", readingPosition: saved)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let entry = model.livePositions.entry(for: book.id)
        var publishes = 0
        let watchers = [
            entry.objectWillChange.sink { publishes += 1 },
            model.livePositions.objectWillChange.sink { publishes += 1 },
        ]
        defer { watchers.forEach { $0.cancel() } }
        let words = TextAnchor(before: "stacked in cloths ", after: "between slatted boards", fraction: 0.45, measuredIn: TextAnchor.currentMeasure)

        model.updateLiveReadingPosition(
            bookID: book.id,
            position: ReadingPosition(chapterIndex: 1, characterOffset: 40, globalCharacterOffset: 140, anchor: words)
        )
        XCTAssertEqual(publishes, 0, "an unmoved cursor published")
        XCTAssertNil(entry.position)

        model.updateLiveReadingPosition(
            bookID: book.id,
            position: ReadingPosition(chapterIndex: 1, characterOffset: 41, globalCharacterOffset: 141, anchor: words)
        )
        XCTAssertEqual(publishes, 2, "a moved cursor did not publish its entry and the store")
        XCTAssertEqual(entry.position?.anchor, words)
    }

    /// A text's measure names the text cache version that wrote the
    /// content.md it was read from and this build's content index version;
    /// this build's own is the current measure.
    func testATextsMeasureNamesTheCacheThatWroteIt() {
        XCTAssertEqual(TextAnchor.measure(ofTextCachedBy: "3.0.4"), "3.0.4/\(BookContentIndex.currentVersion)")
        XCTAssertEqual(TextAnchor.measure(ofTextCachedBy: MarkdownCacheService.currentCacheVersion), TextAnchor.currentMeasure)
    }

    // MARK: - Where a Saved Place Opens (Question 7)

    /// A saved place opens where the loaded text holds it; one the text
    /// does not hold opens nearby: an offset past its chapter's end at that
    /// end (the book's end in the last chapter), one before its start at its
    /// start, a chapter before the first at the book's start, and a chapter
    /// past the last at the book's end when the place was at or past the
    /// book's end by its offset in the whole book, else at the last
    /// chapter's start. Pure: no window.
    func testASavedPlaceOpensWithinTheBook() {
        let content = DocumentContent(
            title: "Breakwater Survey",
            author: "Odalys Pretorius",
            chapters: [
                Chapter(title: "Piles", text: String(repeating: "pile ", count: 20)),
                Chapter(title: "Stones", text: String(repeating: "stone ", count: 30)),
            ]
        )
        let first = 100
        let total = 280
        XCTAssertEqual(content.totalCharacterCount, total)
        func opening(_ chapter: Int, _ offset: Int, global: Int? = nil) -> TextPlace {
            ReaderViewModel.openingPlace(of: TextPlace(chapter: chapter, offset: offset), savedGlobalOffset: global, in: content)
        }

        XCTAssertEqual(opening(0, 37), TextPlace(chapter: 0, offset: 37), "a place the text holds moved")
        XCTAssertEqual(opening(1, 180, global: total + 40), TextPlace(chapter: 1, offset: 180), "a held place moved by its global offset")
        XCTAssertEqual(opening(0, first + 9), TextPlace(chapter: 0, offset: first), "past a chapter's end")
        XCTAssertEqual(opening(1, 400, global: 500), TextPlace(chapter: 1, offset: 180), "past the book's end")
        XCTAssertEqual(opening(1, -3), TextPlace(chapter: 1, offset: 0), "before a chapter's start")
        XCTAssertEqual(opening(-1, 50), TextPlace(chapter: 0, offset: 0), "a chapter before the first")
        XCTAssertEqual(opening(4, 10, global: total), TextPlace(chapter: 1, offset: 180), "a finished book's lost chapter")
        XCTAssertEqual(opening(4, 10, global: total - 1), TextPlace(chapter: 1, offset: 0), "a lost chapter short of the end")
        XCTAssertEqual(opening(4, 10), TextPlace(chapter: 1, offset: 0), "a lost chapter with no global offset")
        let empty = DocumentContent(title: "Blank", author: "", chapters: [])
        XCTAssertEqual(
            ReaderViewModel.openingPlace(of: TextPlace(chapter: 2, offset: 9), savedGlobalOffset: 9, in: empty),
            TextPlace(chapter: 0, offset: 0)
        )
    }

    /// A finished one-chapter book whose text then loses its last
    /// character, as a new text extraction or an edit trimming its end
    /// leaves it, opens at its new end, finished, and is saved there, so
    /// its row and its record read Finished still (REV14; board #2028). It
    /// used to open at its start and be saved there.
    func testAFinishedBookWhoseTextLosesItsLastCharacterOpensFinished() throws {
        let world = try makeIntegrationWorld("Anchor Capture Shortened End")
        let book = try world.importBook(from: writeSource(named: "Pier Notices.txt", Self.pierNotices))
        XCTAssertNotNil(book.textCacheFingerprint, "the import recorded no fingerprints, so a changed file would go unnoticed")
        let first = world.openReader(for: book)
        waitForReaderToLoad(first)
        XCTAssertEqual(first.content?.chapters.count, 1, "the fixture is not one chapter")
        let length = try XCTUnwrap(first.content?.chapters.first?.text.utf16Length)
        first.restAtEnd()
        first.close()
        XCTAssertTrue(world.library.bookByID(book.id)?.restsAtEnd ?? false, "the book was not saved at its end")

        // The book's own file loses its last character, and the next open
        // reads the shorter text, rebuilding the cache it no longer matches.
        let trimmed = String(Self.pierNotices.dropLast())
        try Data(trimmed.utf8).write(to: book.bookFileURL)
        let reopened = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(reopened)

        let shortened = try XCTUnwrap(reopened.content?.chapters.first?.text.utf16Length)
        XCTAssertLessThan(shortened, length, "the text did not shorten")
        XCTAssertEqual(reopened.currentChapterIndex, 0)
        XCTAssertEqual(reopened.currentCharacterOffset, shortened, "the book did not open at its end")
        XCTAssertTrue(reopened.hasFinishedBook, "the book did not open finished")
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.readingPosition?.characterOffset, shortened)
        XCTAssertEqual(row.readingPosition?.globalCharacterOffset, shortened)
        XCTAssertTrue(row.restsAtEnd, "the row no longer reads Finished")
        LibraryPersistenceService.flushPendingSave()
        let recorded = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).state.readingPosition)
        XCTAssertEqual(recorded.characterOffset, shortened, "the record holds another place")
    }

    /// A place saved past a chapter's end opens at that end: past a middle
    /// chapter's end, at that end, not finished; past the last chapter's
    /// end, at the book's end, finished, as three of the user's books were
    /// saved (T06's design note found them at offsets 534 of 530, 445 of
    /// 194, and 2,786 of 2,782). Each is saved where it opened.
    func testAPlacePastItsChaptersEndOpensAtThatEnd() throws {
        let world = try makeIntegrationWorld("Anchor Capture Chapter End")
        let book = try world.importBook(from: writeOrchardEPUB())
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let lengths = content.chapters.map(\.text.utf16Length)
        XCTAssertEqual(lengths.count, 3, "the fixture is not three chapters")
        guard lengths.count == 3 else { return }

        world.library.persistReadingPosition(
            bookID: book.id,
            position: ReadingPosition(chapterIndex: 0, characterOffset: lengths[0] + 12, globalCharacterOffset: lengths[0] + 12)
        )
        let middle = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(middle)
        XCTAssertEqual(middle.currentChapterIndex, 0)
        XCTAssertEqual(middle.currentCharacterOffset, lengths[0], "a place past a middle chapter's end did not open at that end")
        XCTAssertFalse(middle.hasFinishedBook, "a place in the middle of the book opened finished")
        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition?.characterOffset, lengths[0])
        middle.close()

        let total = lengths.reduce(0, +)
        world.library.persistReadingPosition(
            bookID: book.id,
            position: ReadingPosition(chapterIndex: 2, characterOffset: lengths[2] + 4, globalCharacterOffset: total + 4)
        )
        let last = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(last)
        XCTAssertEqual(last.currentChapterIndex, 2)
        XCTAssertEqual(last.currentCharacterOffset, lengths[2], "a place past the last chapter's end did not open at the book's end")
        XCTAssertTrue(last.hasFinishedBook, "a place past the book's end did not open finished")
        XCTAssertTrue(world.library.bookByID(book.id)?.restsAtEnd ?? false, "the row does not read Finished")
    }

    // MARK: - Fixture

    /// A one-chapter text book about a pier's notices, ending in a full
    /// stop: two paragraphs and nothing a parser could take for a chapter.
    private static let pierNotices = """
        The harbour office pins the week's tide tables beside the gangway every Monday, \
        and the ferry crews copy the low waters into their logbooks before the first sailing.

        A notice about the dredger working the inner basin stays up until the channel buoys \
        are moved back to their summer marks.
        """

    /// Writes `text` to a file named `name` in a folder of this test's own,
    /// for an import to read.
    private func writeSource(named name: String, _ text: String) throws -> URL {
        let source = try makeSandboxDirectory("AnchorCaptureSources").appendingPathComponent(name)
        try Data(text.utf8).write(to: source)
        return source
    }

    /// The three chapters of the orchard book: each heading, and the
    /// paragraphs under it.
    private static let orchardChapters: [(heading: String, paragraphs: [String])] = [
        ("Grafting the Old Trees", [
            "A scion cut in late winter keeps its buds closed until the stock beneath it wakes, so the cuts are wrapped in waxed cloth and left alone for six weeks.",
            "Thessaly Amundsen kept a ledger of every graft she made along the north wall, and the ledger says that forty of the fifty-two took in a wet spring.",
        ]),
        ("Pruning in Frost", [
            "Branches pruned on a frozen morning split along the grain, which is why the crew waits for the sun to reach the lower terraces before the saws come out.",
            "A tree that loses more than a third of its wood in one season answers with a thicket of water shoots, each one thin, upright, and useless for fruit.",
        ]),
        ("The Cider Press", [
            "The press in the long barn takes two hundredweight of milled apples at a time, stacked in cloths between slatted boards and squeezed by a screw of oak.",
            "Juice from the first pressing goes into the cool cellar the same evening, and the pomace is carted to the pigs before it can sour in the yard.",
        ]),
    ]

    /// The orchard book as an EPUB in a folder of this test's own: three
    /// chapters, each listed in the table of contents under its heading.
    private func writeOrchardEPUB() throws -> URL {
        let epub = try makeSandboxDirectory("AnchorCaptureEPUB").appendingPathComponent("orchard.epub")
        let chapters = Self.orchardChapters
        try IntegrationEPUB.write(
            title: "Orchard Ledger",
            chapters: chapters.enumerated().map { number, chapter in
                IntegrationEPUBChapter(
                    fileName: "ch0\(number + 1).xhtml",
                    body: "<h1>\(chapter.heading)</h1>" + chapter.paragraphs.map { "<p>\($0)</p>" }.joined()
                )
            },
            contents: chapters.enumerated().map { number, chapter in
                IntegrationTOCEntry(label: chapter.heading, target: "ch0\(number + 1).xhtml")
            },
            to: epub
        )
        return epub
    }
}
