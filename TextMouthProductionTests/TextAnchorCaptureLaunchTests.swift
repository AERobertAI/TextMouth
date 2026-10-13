import XCTest
@testable import TextMouth

/// The launch pass that gives the places saved before anchors their words
/// from each book's text as it reads now (T06's branch B; the user's answer
/// to question 6), before the text cache batch can rebuild any text
/// (question 9): which books it reads, which wait for a later launch, what
/// each place takes, and that the words survive the paths that carry
/// places, the checkpoint journal's adoption and a feed item's index among
/// them, and the record a build before anchors wrote.
///
/// Built on the feed and cloud maintenance fixtures: each test's packages
/// are in a library folder and a feed of its own, removed afterwards, with
/// the library index put back as it was. A hosted test cannot make a real
/// dataless file, so the cloud is scripted (`FakeCloudFiles`).
final class TextAnchorCaptureLaunchTests: FeedItemIndexTestCase {

    // MARK: - Which Books the Pass Reads

    /// A library shaped like the user's: a text book whose position,
    /// bookmarks, and skipped headings were saved before anchors takes their
    /// words, each at its place in its text as it reads now, in its row and
    /// its record; a bookmark in a chapter the book lacks and a skipped
    /// heading whose ID names no heading now take none. A book whose places
    /// have words already, one with no place, and an audiobook are not read.
    /// One log line counts it all.
    @MainActor
    func testTheLaunchPassGivesPlacesSavedBeforeAnchorsTheirWords() throws {
        var ledger = try makeTextBook(title: "North Wall")
        let content = try MarkdownCacheService.loadFromCache(for: ledger)
        let notes = try XCTUnwrap(content.allHeadings.first { $0.text == "Pruning Notes" }, "the fixture lacks the heading")
        let gone = "0-999-2-Gone Heading"
        ledger.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 40)
        ledger.bookmarks = [
            Bookmark(number: 1, chapterIndex: 0, characterOffset: 75, label: "Wet spring"),
            Bookmark(number: 2, chapterIndex: 3, characterOffset: 9),
        ]
        ledger.skippedHeadingIDs = [notes.id, gone]
        var anchored = try makeTextBook(title: "Already Anchored")
        let earlier = TextAnchor(before: "an earlier ", after: "capture", fraction: 0.1, measuredIn: TextAnchor.currentMeasure)
        anchored.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 12, anchor: earlier)
        let placeless = try makeTextBook(title: "Never Opened")
        let audiobook = Book(
            title: "Tide Clock Recordings", format: .audio, filePath: folderURL.appendingPathComponent("tide.m4b").path,
            md5Hash: UUID().uuidString, folderPath: folderPath,
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 30), tmbDirectoryName: "Tide.tmb"
        )
        // A read of either book's text would be refused, and noted.
        cloud.refuseReads(of: MarkdownCacheService.cacheURL(for: anchored), MarkdownCacheService.cacheURL(for: placeless))
        let model = makeModel(with: [ledger, anchored, placeless, audiobook])
        let expected = LibraryViewModel.TextAnchorBackfillOutcome(books: 1, positions: 1, bookmarks: 1, skippedHeadings: 1, unplaced: 2)
        XCTAssertEqual(
            expected.logLine,
            "TEXT_ANCHORS_BACKFILLED: 1 book's places took their words: 1 position, 1 bookmark, 1 skipped heading; "
                + "0 books wait for a later launch; 2 places have no words to take"
        )
        let linesBefore = logLineCount(expected.logLine)

        let outcome = try backfill(model, access: cloud.access)

        XCTAssertEqual(outcome, expected)
        XCTAssertEqual(cloud.refusedReads, [], "a book with no place lacking words was read")
        XCTAssertEqual(logLineCount(expected.logLine), linesBefore + 1, "the pass's one line was not logged")
        func words(_ offset: Int) -> TextAnchor? {
            content.anchor(at: TextPlace(chapter: 0, offset: offset), measuredIn: TextAnchor.currentMeasure)
        }
        let row = try XCTUnwrap(model.bookByID(ledger.id))
        XCTAssertEqual(row.readingPosition?.anchor, words(40))
        XCTAssertEqual(row.readingPosition?.lastUpdated, ledger.readingPosition?.lastUpdated, "the place was dated anew")
        XCTAssertEqual(row.bookmarks.map(\.anchor), [words(75), nil])
        let waiting = try XCTUnwrap(SkippedHeading(id: gone))
        XCTAssertEqual(row.skippedHeadings, [SkippedHeading(notes, anchor: words(notes.characterOffset)), waiting])
        XCTAssertEqual(row.skippedHeadingIDs, [notes.id, gone])
        XCTAssertEqual(model.bookByID(anchored.id)?.readingPosition?.anchor, earlier)
        XCTAssertNil(model.bookByID(placeless.id)?.readingPosition)
        XCTAssertNil(model.bookByID(audiobook.id)?.readingPosition?.anchor)
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: ledger.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.anchor, words(40))
        XCTAssertEqual(record.bookmarks.map(\.anchor), [words(75), nil])
        XCTAssertEqual(record.state.skippedHeadings, row.skippedHeadings)
        XCTAssertEqual(record.state.skippedHeadingIDs, [notes.id, gone])

        // The next launch finds the same two places without words, and
        // reads the book again for them, giving nothing new.
        let again = try backfill(model, access: cloud.access)
        XCTAssertEqual(again, LibraryViewModel.TextAnchorBackfillOutcome(unplaced: 2))
    }

    /// A library whose places all have words, or that has none, is not
    /// read: the pass ends at once, giving nothing and logging nothing.
    @MainActor
    func testALibraryWithoutPlacesLackingWordsIsNotRead() throws {
        let placeless = try makeTextBook(title: "Never Opened")
        cloud.refuseReads(of: MarkdownCacheService.cacheURL(for: placeless))
        let model = makeModel(with: [placeless])
        let empty = LibraryViewModel.TextAnchorBackfillOutcome()
        let linesBefore = logLineCount(empty.logLine)

        let outcome = try backfill(model, access: cloud.access)

        XCTAssertEqual(outcome, empty)
        XCTAssertEqual(cloud.refusedReads, [])
        XCTAssertEqual(logLineCount(empty.logLine), linesBefore, "a pass with nothing to do logged a line")
    }

    /// A book whose text is only in the cloud, one whose text an Edit Text
    /// session holds, and one a reader has open wait for a later launch,
    /// keeping their places as they are; that launch, with each here and
    /// free, gives their places their words.
    @MainActor
    func testABookInTheCloudHeldByAnEditOrOpenWaitsForALaterLaunch() throws {
        let inCloud = try makeTextBookWithAPosition(title: "In the Cloud")
        let edited = try makeTextBookWithAPosition(title: "Being Edited")
        let open = try makeTextBookWithAPosition(title: "Open Now")
        cloud.markDataless(MarkdownCacheService.cacheURL(for: inCloud))
        holdInAnEditSession(edited)
        let model = makeModel(with: [inCloud, edited, open])
        model.openBookIDs.insert(open.id)

        let first = try backfill(model, access: cloud.access)

        XCTAssertEqual(first, LibraryViewModel.TextAnchorBackfillOutcome(waiting: 3))
        for book in [inCloud, edited, open] {
            XCTAssertEqual(model.bookByID(book.id)?.readingPosition, book.readingPosition, "\(book.title) changed")
        }

        BookTextEditSessions.shared.end(edited.id)
        model.openBookIDs.remove(open.id)
        let second = try backfill(model, access: .live)

        XCTAssertEqual(second, LibraryViewModel.TextAnchorBackfillOutcome(books: 3, positions: 3))
        for book in [inCloud, edited, open] {
            XCTAssertNotNil(model.bookByID(book.id)?.readingPosition?.anchor, "\(book.title) has no words")
        }
    }

    // MARK: - Before the Text Cache Batch

    /// A place saved in a text an older extraction wrote takes the words of
    /// that text, recording that it was measured in it ("3.0.3/1.0.0"),
    /// before the launch's cache batch rebuilds the text with this build's
    /// extraction: the launch's passes give places their words before any
    /// text is rebuilt (T06, question 9).
    @MainActor
    func testPlacesTakeTheirWordsBeforeTheCacheBatchRebuildsTheirText() throws {
        var book = try makePackagedBook(title: "Rebuilt Later", text: Self.ledger, cacheFormatVersion: "3.0.3")
        let older = "# Ledger of the North Wall\n\nAn older extraction read this ledger otherwise, in words this build no longer writes at all."
        try Data(older.utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        let oldText = try MarkdownCacheService.loadFromCache(for: book)
        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 40)
        let model = makeModel(with: [book])
        let finished = expectation(description: "The launch's passes ended")

        model.updateContentCachesAndStatistics(access: .live) { finished.fulfill() }
        wait(for: [finished], timeout: 30)

        let row = try XCTUnwrap(model.bookByID(book.id))
        let measure = TextAnchor.measure(ofTextCachedBy: "3.0.3")
        XCTAssertEqual(measure, "3.0.3/\(BookContentIndex.currentVersion)")
        XCTAssertEqual(row.readingPosition?.anchor, oldText.anchor(at: TextPlace(chapter: 0, offset: 40), measuredIn: measure))
        XCTAssertEqual(row.cacheFormatVersion, MarkdownCacheService.currentCacheVersion, "the cache was not rebuilt")
        let rebuilt = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertNotEqual(rebuilt.chapters.first?.text, oldText.chapters.first?.text, "the text was not rebuilt")
    }

    // MARK: - Paths That Carry Places

    /// A checkpoint with its words that reached the book's record but not
    /// library.json before a crash is taken from the record at the next
    /// launch with its words (`adoptNewerRecordedPositions`).
    @MainActor
    func testTheCheckpointJournalsAdoptionKeepsTheWords() throws {
        let book = try makeTextBook(title: "Checkpointed")
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let model = makeModel(with: [book])
        model.save()
        LibraryPersistenceService.flushPendingSave()
        let words = try XCTUnwrap(content.anchor(at: TextPlace(chapter: 0, offset: 64), measuredIn: TextAnchor.currentMeasure))
        model.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 64, anchor: words))
        waitPastLibrarySaveDebounce()
        LibraryPersistenceService._discardPendingIndexSaveForTesting()
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.readingPosition?.anchor, words, "the record lacks the words")

        let relaunched = LibraryViewModel(initializeServices: false)
        relaunched.loadLibraryIndex()

        XCTAssertEqual(relaunched.bookByID(book.id)?.readingPosition?.characterOffset, 64)
        XCTAssertEqual(relaunched.bookByID(book.id)?.readingPosition?.anchor, words)
    }

    /// A feed item's places take their words like a book's, and its feed's
    /// own index keeps them, never library.json (FR11).
    @MainActor
    func testAFeedItemsIndexKeepsItsPlacesWords() throws {
        let downloaded = try makeFeedItem(title: "Orchard Report", position: Self.position(5, at: 60))
        let item = try commitCache(of: downloaded)
        XCTAssertNotNil(item.feedLink, "the item is not a feed item")
        let model = makeModel(with: [item])

        let outcome = try backfill(model, access: .live)

        XCTAssertEqual(outcome.positions, 1)
        let words = try XCTUnwrap(model.bookByID(item.id)?.readingPosition?.anchor)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try indexedRows().first { $0.id == item.id }?.readingPosition?.anchor, words)
        try assertLibraryJSONHoldsNoFeedItem([item])
    }

    /// A record a build before anchors wrote (no "anchor" and no
    /// "skippedHeadings" anywhere, skips by their IDs alone) loads as it
    /// was, and its places take their words; the record then holds the
    /// skipped headings with their words, and their IDs still, for older
    /// builds.
    @MainActor
    func testARecordWrittenBeforeAnchorsLoadsAndItsPlacesTakeTheirWords() throws {
        var book = try makeTextBook(title: "Older Record")
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let notes = try XCTUnwrap(content.allHeadings.first { $0.text == "Pruning Notes" })
        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 40)
        book.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 75, label: "Kept")]
        book.skippedHeadingIDs = [notes.id]
        try book.saveBookInfoThrowing()
        try rewriteRecordWithoutAnchors(of: book)

        let stored = try StoredBookRecord.read(from: book.tmbDirectory).info
        let loaded = Book(record: stored, filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)
        XCTAssertNil(loaded.readingPosition?.anchor)
        XCTAssertEqual(loaded.readingPosition?.characterOffset, 40)
        XCTAssertNil(loaded.bookmarks.first?.anchor)
        XCTAssertEqual(loaded.skippedHeadings, [SkippedHeading(notes)])
        XCTAssertEqual(loaded.skippedHeadingIDs, [notes.id])
        let model = makeModel(with: [loaded])

        let outcome = try backfill(model, access: .live)

        XCTAssertEqual(outcome, LibraryViewModel.TextAnchorBackfillOutcome(books: 1, positions: 1, bookmarks: 1, skippedHeadings: 1))
        LibraryPersistenceService.flushPendingSave()
        func words(_ offset: Int) -> TextAnchor? {
            content.anchor(at: TextPlace(chapter: 0, offset: offset), measuredIn: TextAnchor.currentMeasure)
        }
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.anchor, words(40))
        XCTAssertEqual(record.bookmarks.first?.anchor, words(75))
        XCTAssertEqual(record.state.skippedHeadings, [SkippedHeading(notes, anchor: words(notes.characterOffset))])
        XCTAssertEqual(record.state.skippedHeadingIDs, [notes.id])
        let json = String(decoding: try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"skippedHeadingIDs\""), "the IDs older builds read are gone")
    }

    // MARK: - Fixtures

    /// The Markdown every fixture book holds: one chapter, under two
    /// headings, the second of level 2.
    private static let ledger = """
        # Ledger of the North Wall

        The grafts along the north wall took in a wet spring, forty of fifty-two, \
        and the ledger says so in a careful hand.

        ## Pruning Notes

        A tree that loses a third of its wood in one season answers with water shoots, \
        thin and upright and useless for fruit.
        """

    /// A Markdown book titled `title` holding `ledger`, in a package of its
    /// own in this test's folder, its text cache written and committed as
    /// the cache batch writes it: current, fingerprinted, and analyzed.
    private func makeTextBook(title: String) throws -> Book {
        try commitCache(of: makePackagedBook(title: title, text: Self.ledger))
    }

    /// A fixture book titled `title` saved 40 units into its text, before
    /// anchors: its position has no words.
    private func makeTextBookWithAPosition(title: String) throws -> Book {
        var book = try makeTextBook(title: title)
        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 40)
        return book
    }

    /// Rewrites `book`'s bookInfo.json as a build before anchors wrote it:
    /// without any "anchor", and without "skippedHeadings", keeping the
    /// heading IDs and every other field as written.
    private func rewriteRecordWithoutAnchors(of book: Book) throws {
        let url = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        state.removeValue(forKey: "skippedHeadings")
        if var position = state["readingPosition"] as? [String: Any] {
            position.removeValue(forKey: "anchor")
            state["readingPosition"] = position
        }
        object["state"] = state
        if let bookmarks = object["bookmarks"] as? [[String: Any]] {
            object["bookmarks"] = bookmarks.map { bookmark in
                var bare = bookmark
                bare.removeValue(forKey: "anchor")
                return bare
            }
        }
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let written = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(written.contains("\"anchor\""))
        XCTAssertFalse(written.contains("\"skippedHeadings\""))
    }

    /// Runs the launch pass over `model`'s library through `access`, waits
    /// for it, and returns what it did.
    @MainActor
    private func backfill(
        _ model: LibraryViewModel,
        access: MaintenanceFileAccess
    ) throws -> LibraryViewModel.TextAnchorBackfillOutcome {
        var outcome: LibraryViewModel.TextAnchorBackfillOutcome?
        model.captureMissingTextAnchors(access: access) { outcome = $0 }
        XCTAssertTrue(eventually(within: 10) { outcome != nil }, "the pass never ended")
        return try XCTUnwrap(outcome)
    }
}
