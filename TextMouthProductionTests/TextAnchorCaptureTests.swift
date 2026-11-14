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

    /// Skipping a heading saves the heading itself, with the words at its
    /// start as the text reads now, in the reader's copy, the book's row,
    /// and its record, with its ID written from it, which the reader's
    /// filter matches; skipping it again includes it, and saves no skip.
    func testASkippedHeadingKeepsTheWordsAtItsStart() throws {
        let world = try makeIntegrationWorld("Anchor Capture Skipped Heading")
        let book = try world.importBook(from: writeOrchardEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let content = try XCTUnwrap(reader.content)
        let heading = try XCTUnwrap(reader.headings.first { $0.text == "Pruning in Frost" }, "the fixture lacks the heading")

        reader.toggleHeadingSkip(heading)

        let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
        let expected = SkippedHeading(heading, anchor: content.anchor(at: start, measuredIn: TextAnchor.currentMeasure))
        XCTAssertNotNil(expected.anchor)
        XCTAssertEqual(reader.book.skippedHeadings, [expected])
        XCTAssertTrue(reader.isHeadingSkipped(heading))
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.skippedHeadings, [expected])
        XCTAssertEqual(row.skippedHeadingIDs, [heading.id])
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.skippedHeadings, [expected])
        XCTAssertEqual(record.state.skippedHeadingIDs, [heading.id])

        reader.toggleHeadingSkip(heading)

        XCTAssertFalse(reader.isHeadingSkipped(heading))
        XCTAssertNil(reader.book.skippedHeadings)
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
        let chapter = try XCTUnwrap(content.chapters[safe: 1], "the book has no second chapter").text as NSString
        XCTAssertEqual(anchor.before, chapter.substring(with: NSRange(location: 6, length: 64)))
        XCTAssertEqual(anchor.after, chapter.substring(with: NSRange(location: 70, length: 64)))
        XCTAssertEqual(anchor.measuredIn, TextAnchor.currentMeasure)
        XCTAssertEqual(anchor.fraction, Double(content.chapterStartOffset(1) + 70) / Double(content.totalCharacterCount), accuracy: 1e-12)
        XCTAssertTrue(anchor.stands(at: place, in: content.chapters.map(\.text)))
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.readingPosition?.anchor, anchor, "the record lacks the words")
    }

    /// A live position, which only moves the rows' time estimates, is
    /// published without the words around it (the audit's C17): nothing
    /// reads them, and taking them cuts two strings out of the chapter each
    /// second. The save that follows still takes them.
    func testALivePositionIsPublishedWithoutItsWords() throws {
        let world = try makeIntegrationWorld("Anchor Capture Live")
        let book = try world.importBook(from: writeOrchardEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let entry = world.library.livePositions.entry(for: book.id)

        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 70
        XCTAssertTrue(waitUntil(timeout: 5) { entry.position != nil }, "no live position was published")

        let live = try XCTUnwrap(entry.position)
        XCTAssertEqual(live.chapterIndex, 1)
        XCTAssertEqual(live.characterOffset, 70)
        XCTAssertNil(live.anchor, "the live position took the words around it")
        reader.savePosition()
        XCTAssertNotNil(world.library.bookByID(book.id)?.readingPosition?.anchor, "the save lacks the words")
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

        let end = try XCTUnwrap(content.chapters[safe: 0], "the book has no first chapter").text.utf16Length
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

    // MARK: - Places Saved Before Anchors, as the Book Loads (Question 6)

    /// A book whose places were saved before anchors gives them their words
    /// as it loads, from its text as it reads now: a bookmark at its place,
    /// one past its chapter's end at that end, a skipped heading its ID
    /// names at the heading's start, and the position through the load's
    /// own save. A bookmark in a chapter the book lacks, and a skipped
    /// heading whose ID names no heading now, keep none, and that skip waits
    /// (T06's branch E), skipping nothing; a bookmark that had words keeps
    /// them, and the other IDs stay as they were. The row, the record, and
    /// the reader's own copies take them.
    func testPlacesSavedBeforeAnchorsTakeTheirWordsAsTheBookLoads() throws {
        let world = try makeIntegrationWorld("Anchor Capture At Load")
        let book = try world.importBook(from: writeOrchardEPUB())
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let pressing = try XCTUnwrap(content.allHeadings.first { $0.text == "The Cider Press" }, "the fixture lacks the heading")
        let firstLength = try XCTUnwrap(content.chapters[safe: 0], "the book has no first chapter").text.utf16Length
        let earlier = TextAnchor(before: "an earlier ", after: "capture", fraction: 0.7, measuredIn: "3.0.4/1.0.0")
        let inPlace = Bookmark(number: 1, chapterIndex: 1, characterOffset: 33, label: "Frost")
        let pastItsEnd = Bookmark(number: 2, chapterIndex: 0, characterOffset: firstLength + 6)
        let lostChapter = Bookmark(number: 3, chapterIndex: 7, characterOffset: 4)
        let anchored = Bookmark(number: 4, chapterIndex: 2, characterOffset: 12, anchor: earlier)
        let gone = "1-999-1-Gone Heading"
        // The places as a build before anchors saved them: skips by ID alone.
        world.library.updateBook(id: book.id) { row in
            row.readingPosition = ReadingPosition(chapterIndex: 2, characterOffset: 50)
            row.bookmarks = [inPlace, pastItsEnd, lostChapter, anchored]
            row.skippedHeadingIDs = [pressing.id, gone]
        }

        let reader = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        waitForReaderToLoad(reader)

        func words(_ chapter: Int, _ offset: Int) -> TextAnchor? {
            content.anchor(at: TextPlace(chapter: chapter, offset: offset), measuredIn: TextAnchor.currentMeasure)
        }
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.bookmarks.map(\.anchor), [words(1, 33), words(0, firstLength + 6), nil, earlier])
        XCTAssertEqual(row.bookmarks.map(\.characterOffset), [33, firstLength + 6, 4, 12], "a bookmark moved")
        // T06's branch E: the skip whose ID names no heading and holds no
        // words waits (the addendum's rule) instead of staying skipped.
        let waiting = try XCTUnwrap(SkippedHeading(id: gone))
        let expectedSkips = [
            SkippedHeading(pressing, anchor: words(pressing.chapterIndex, pressing.characterOffset)),
        ]
        XCTAssertEqual(row.skippedHeadings, expectedSkips)
        XCTAssertEqual(row.waitingSkippedHeadings, [waiting])
        XCTAssertEqual(row.skippedHeadingIDs, [pressing.id])
        XCTAssertEqual(row.readingPosition?.anchor, words(2, 50))
        XCTAssertEqual(reader.bookmarks, row.bookmarks, "the reader's bookmarks lack their words")
        XCTAssertEqual(reader.book.skippedHeadings, expectedSkips, "the reader's skipped headings lack their words")
        XCTAssertEqual(reader.book.waitingSkippedHeadings, [waiting], "the reader's waiting skip changed")
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.bookmarks.map(\.anchor), row.bookmarks.map(\.anchor))
        XCTAssertEqual(record.state.skippedHeadings, expectedSkips)
        XCTAssertEqual(record.state.waitingSkippedHeadings, [waiting])
        XCTAssertEqual(record.state.readingPosition?.anchor, words(2, 50))
    }

    /// Words captured for a place go only to a place still saved where they
    /// were captured and still without words: a position and a bookmark the
    /// listener moved meanwhile, places given words meanwhile, and a heading
    /// no longer skipped keep what they have. A place given words keeps its
    /// date, and the skipped headings their IDs. An audiobook's places need
    /// no words. Pure: no window.
    func testCapturedWordsGoOnlyToPlacesStillSavedWhereTheyWere() {
        let words = TextAnchor(before: "the pomace is ", after: "carted to the pigs", fraction: 0.9, measuredIn: TextAnchor.currentMeasure)
        let other = TextAnchor(before: "juice from ", after: "the first pressing", fraction: 0.8)
        let pressing = SkippedHeading(level: 1, label: "The Cider Press", chapterIndex: 2, characterOffset: 0)
        let bookmark = Bookmark(number: 1, chapterIndex: 2, characterOffset: 40)
        let place = TextPlace(chapter: 2, offset: 40)
        var captured = CapturedPlaceAnchors()
        captured.position = CapturedPlaceAnchors.Placed(place: place, anchor: words)
        captured.bookmarks[bookmark.id] = CapturedPlaceAnchors.Placed(place: place, anchor: words)
        captured.skippedHeadings[pressing.id] = words
        func orchard(position: ReadingPosition?, bookmarks: [Bookmark], skippedIDs: [String]?, skipped: [SkippedHeading]? = nil) -> Book {
            Book(
                title: "Orchard Ledger", format: .epub, filePath: "/nowhere/orchard.epub", md5Hash: "orchard",
                readingPosition: position, bookmarks: bookmarks, skippedHeadingIDs: skippedIDs, skippedHeadings: skipped
            )
        }

        var still = orchard(position: ReadingPosition(chapterIndex: 2, characterOffset: 40), bookmarks: [bookmark], skippedIDs: [pressing.id])
        let dated = still.readingPosition?.lastUpdated
        XCTAssertEqual(still.placesWithoutAnchors, 3)
        XCTAssertEqual(still.adoptCapturedAnchors(captured), captured)
        XCTAssertEqual(still.readingPosition?.anchor, words)
        XCTAssertEqual(still.readingPosition?.lastUpdated, dated, "the place was dated anew")
        XCTAssertEqual(still.bookmarks.first?.anchor, words)
        XCTAssertEqual(still.skippedHeadings?.first?.anchor, words)
        XCTAssertEqual(still.skippedHeadingIDs, [pressing.id])
        XCTAssertEqual(still.placesWithoutAnchors, 0)

        let movedBookmark = Bookmark(id: bookmark.id, number: 1, chapterIndex: 2, characterOffset: 41)
        var moved = orchard(position: ReadingPosition(chapterIndex: 2, characterOffset: 41), bookmarks: [movedBookmark], skippedIDs: nil)
        XCTAssertTrue(moved.adoptCapturedAnchors(captured).isEmpty)
        XCTAssertNil(moved.readingPosition?.anchor)
        XCTAssertNil(moved.bookmarks.first?.anchor)
        XCTAssertNil(moved.skippedHeadings)

        var givenBookmark = bookmark
        givenBookmark.anchor = other
        var givenSkip = pressing
        givenSkip.anchor = other
        var given = orchard(
            position: ReadingPosition(chapterIndex: 2, characterOffset: 40, anchor: other),
            bookmarks: [givenBookmark],
            skippedIDs: [pressing.id],
            skipped: [givenSkip]
        )
        XCTAssertTrue(given.adoptCapturedAnchors(captured).isEmpty)
        XCTAssertEqual(given.readingPosition?.anchor, other)
        XCTAssertEqual(given.bookmarks.first?.anchor, other)
        XCTAssertEqual(given.skippedHeadings?.first?.anchor, other)

        let audiobook = Book(
            title: "Tide Clock Recordings", format: .audio, filePath: "/nowhere/tide.m4b", md5Hash: "tide",
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 9), bookmarks: [bookmark]
        )
        XCTAssertEqual(audiobook.placesWithoutAnchors, 0)
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
