import XCTest
@testable import TextMouth

/// Risk 2 of LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md, the first of Phase
/// 0's guards: reopening a book on a Mac that is behind must not put the
/// book's old place back, newly dated. Another Mac sharing the library in
/// the cloud writes its later place, bookmarks, and settings into the
/// book's record (bookInfo.json) while this Mac's row lags behind; these
/// tests stand for that Mac with a record written as it writes one, never
/// with a real drive.
///
/// - The rule (`Book.readingState(standingAgainst:)`): the record's state
///   stands only when its place was saved later, to the second.
/// - The record's rebuild from the row (`Book.bookInfo(replacing:...)`)
///   never writes a row's older place, bookmarks, or settings over it.
/// - A reader opening the book opens at the later place, with its
///   bookmarks and settings, and a place saved without moving keeps its
///   date (`ReaderViewModel.savePosition()`).
///
/// Beside each guard, the case of one Mac and one library: the row's state
/// is written and kept exactly as before.
final class StaleRowGuardTests: CloudMaintenanceTestCase {
    /// When this Mac last read the book: a whole second, as the files keep
    /// a place's date.
    private static let readHere = Date(timeIntervalSince1970: 1_790_000_000)
    /// When the other Mac read it, an hour later.
    private static let readThere = readHere.addingTimeInterval(3600)
    /// The text of every book here: long enough for every place the tests
    /// save to stand inside its first chapter.
    private static let text = "# Opening\n\nSome words, and then a good many more words, so a cursor has room to move."

    // MARK: - The Rule

    /// The record's later place stands, and with it, as one, its bookmarks
    /// and the book's settings and playback times; the later opening is
    /// kept.
    func testTheRecordsLaterPlaceStandsWithItsBookmarksAndSettings() throws {
        let row = try rowReadHere()
        let other = readOnTheOtherMac(row)

        let standing = row.readingState(standingAgainst: other.readingState)

        XCTAssertEqual(standing, other.readingState, "the other Mac's whole reading state should stand")
    }

    /// On one Mac the row is at least as new as its record: its own state
    /// stands, so a bookmark it deleted and a setting it changed are kept.
    func testTheRowsStateStandsWhenItsPlaceIsLater() throws {
        let stored = try rowReadHere()
        var row = stored
        row.readingPosition = Self.position(at: 30, savedAt: Self.readThere)
        row.bookmarks = []
        row.localVoiceID = "com.textmouth.test.voice"

        let standing = row.readingState(standingAgainst: stored.readingState)

        XCTAssertEqual(standing, row.readingState, "the row's later state should stand, its deletion and its voice too")
    }

    /// The two copies of one save tie, whatever fraction of a second the
    /// row's copy still holds, and the row's state stands.
    func testTwoCopiesOfOneSaveTieAndTheRowStands() throws {
        var row = try rowReadHere()
        row.readingPosition = Self.position(at: 12, savedAt: Self.readHere.addingTimeInterval(0.7))
        var stored = row
        stored.readingPosition = Self.position(at: 12, savedAt: Self.readHere)
        stored.bookmarks = [Bookmark(number: 9, chapterIndex: 0, characterOffset: 3, label: "Stored only")]

        let standing = row.readingState(standingAgainst: stored.readingState)

        XCTAssertEqual(standing, row.readingState, "a tie to the second should keep the row's state")
    }

    /// A place saved later stands even when it is earlier in the book: the
    /// listener went back to reread on the other Mac.
    func testALaterPlaceEarlierInTheBookStands() throws {
        var row = try rowReadHere()
        row.readingPosition = Self.position(at: 40, savedAt: Self.readHere)
        var other = row
        other.readingPosition = Self.position(at: 4, savedAt: Self.readThere)

        let standing = row.readingState(standingAgainst: other.readingState)

        XCTAssertEqual(standing.readingPosition?.characterOffset, 4, "the place saved later should stand, back in the book")
    }

    /// The later opening is kept when the record's state stands, and the
    /// row's own opening when its state does.
    func testTheLaterOpeningIsKept() throws {
        var row = try rowReadHere()
        var other = readOnTheOtherMac(row)
        // This Mac opened the book after the other Mac read it, without
        // moving its place.
        row.lastOpened = Self.readThere.addingTimeInterval(60)
        other.lastOpened = Self.readThere

        XCTAssertEqual(row.readingState(standingAgainst: other.readingState).lastOpened, row.lastOpened)
        XCTAssertEqual(row.readingState(standingAgainst: other.readingState).readingPosition, other.readingPosition)
        XCTAssertEqual(other.readingState(standingAgainst: row.readingState).lastOpened, other.lastOpened,
                       "a row whose state stands keeps its own opening, as before")
    }

    /// The skipped headings go with the later place as one, their IDs, which
    /// older builds read, and the headings with their places together, as the
    /// record kept them.
    func testTheSkippedHeadingsGoWithTheLaterPlaceAsAPair() throws {
        var row = try rowReadHere()
        var other = readOnTheOtherMac(row)
        other.setSkippedHeadings([SkippedHeading(level: 2, label: "Notes", chapterIndex: 0, characterOffset: 30)])

        XCTAssertTrue(row.takeStandingReadingState(of: other.makeBookInfo()))

        XCTAssertEqual(row.skippedHeadingIDs, other.skippedHeadingIDs)
        XCTAssertEqual(row.skippedHeadings, other.skippedHeadings)
        XCTAssertNotNil(row.skippedHeadings?.first, "the row took no skipped heading")
    }

    /// Another book's record, as an old shared package may hold, gives the
    /// row nothing.
    func testAnotherBooksRecordChangesNothing() throws {
        var row = try rowReadHere()
        let before = row
        var stranger = readOnTheOtherMac(row).makeBookInfo()
        stranger.metadata.bookID = UUID()

        XCTAssertFalse(row.takeStandingReadingState(of: stranger))
        XCTAssertEqual(row, before)
    }

    // MARK: - The Record's Rebuild From the Row

    /// A row that lags never writes its older place, bookmarks, or settings
    /// over the record another Mac wrote, while what it changed itself, its
    /// title here, is written.
    func testAStaleRowNeverWritesItsOlderStateOverTheRecord() throws {
        var row = try rowReadHere()
        let other = readOnTheOtherMac(row)
        try writeRecord(of: other)
        row.title = "Retitled Here"

        try row.saveBookInfoThrowing()

        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(Book.ReadingState(record: record), other.readingState, "the record should keep the other Mac's state")
        XCTAssertEqual(record.metadata.title, "Retitled Here", "the row's own change should be written")
    }

    /// One Mac: the record is written from the row, and a bookmark deleted
    /// and a voice chosen without moving the place are written as before.
    func testOnOneMacTheRowsChangesAreWritten() throws {
        var row = try rowReadHere()
        try row.saveBookInfoThrowing()
        row.bookmarks = []
        row.localVoiceID = "com.textmouth.test.voice"

        try row.saveBookInfoThrowing()

        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(Book.ReadingState(record: record), row.readingState, "the row's state should be written whole")
    }

    // MARK: - Opening the Book

    /// A reader opening a book whose record holds the later place opens
    /// there, with the other Mac's bookmarks and settings; the row takes
    /// them, the place keeping the other Mac's date, and the record keeps
    /// them through the reader's saves.
    @MainActor
    func testOpeningABookWhoseRecordIsAheadOpensWhereItWasReadLast() throws {
        let row = try rowReadHere()
        let other = readOnTheOtherMac(row)
        try writeRecord(of: other)
        let model = makeModel(with: [row])

        let reader = try openReader(of: row, in: model)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(reader.currentCharacterOffset, 20, "the reader should open at the other Mac's place")
        XCTAssertEqual(reader.bookmarks.map(\.label), other.bookmarks.map(\.label))
        XCTAssertEqual(reader.book.localVoiceID, other.localVoiceID)
        let saved = try XCTUnwrap(model.bookByID(row.id))
        XCTAssertEqual(saved.readingPosition?.characterOffset, 20)
        XCTAssertEqual(saved.readingPosition?.lastUpdated, Self.readThere, "the place should keep the other Mac's date")
        XCTAssertEqual(saved.bookmarks.map(\.label), other.bookmarks.map(\.label))
        XCTAssertEqual(saved.localEndOfBookBehavior, other.localEndOfBookBehavior)
        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 20)
        XCTAssertEqual(record.state.readingPosition?.lastUpdated, Self.readThere)
        XCTAssertEqual(record.bookmarks.map(\.label), other.bookmarks.map(\.label))
    }

    /// One Mac: a book opens at its row's place, which keeps its date
    /// through the load's save, while the book is dated as opened now.
    @MainActor
    func testOpeningABookKeepsItsPlacesDate() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])

        let reader = try openReader(of: row, in: model)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(reader.currentCharacterOffset, 5)
        let saved = try XCTUnwrap(model.bookByID(row.id))
        XCTAssertEqual(saved.readingPosition?.lastUpdated, Self.readHere, "opening should not date the place anew")
        // The load gives a bookmark saved without words its words, as ever;
        // the bookmark itself is the same.
        XCTAssertEqual(saved.bookmarks.map(\.id), row.bookmarks.map(\.id))
        XCTAssertEqual(saved.bookmarks.map(\.characterOffset), row.bookmarks.map(\.characterOffset))
        XCTAssertGreaterThan(try XCTUnwrap(saved.lastOpened), Self.readThere, "opening should date the opening")
        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.lastUpdated, Self.readHere)
    }

    /// Closing the reader without moving keeps the place's date.
    @MainActor
    func testClosingWithoutMovingKeepsThePlacesDate() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])
        let reader = try openReader(of: row, in: model)

        reader.close()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(model.bookByID(row.id)?.readingPosition?.lastUpdated, Self.readHere)
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).state.readingPosition?.lastUpdated, Self.readHere)
    }

    /// A cursor set to where it already rests, as a load or a command can
    /// set it, publishes a live place without moving: a close afterwards
    /// keeps the place's date.
    @MainActor
    func testACursorSetWhereItRestsIsNoMove() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])
        let reader = try openReader(of: row, in: model)

        let resting = reader.currentCharacterOffset
        reader.currentCharacterOffset = resting
        // The live publish it asks for runs on the main queue's next turns.
        _ = waitUntil(timeout: 0.5) { false }
        reader.close()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(model.bookByID(row.id)?.readingPosition?.lastUpdated, Self.readHere, "a cursor at rest was taken for a move")
    }

    /// A place the listener moved to is dated when it is saved, and wins
    /// over a record the other Mac wrote before.
    @MainActor
    func testAPlaceTheListenerMovedToIsDatedNow() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])
        let reader = try openReader(of: row, in: model)
        let before = Date()

        reader.navigateTo(chapterIndex: 0, characterOffset: 30)
        reader.savePosition()
        LibraryPersistenceService.flushPendingSave()

        let saved = try XCTUnwrap(model.bookByID(row.id)?.readingPosition)
        XCTAssertEqual(saved.characterOffset, 30)
        XCTAssertGreaterThanOrEqual(saved.lastUpdated, before.addingTimeInterval(-1), "a moved place should be dated now")
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).state.readingPosition?.characterOffset, 30)
    }

    /// A later load of the same reader, as after an edit of the text, is no
    /// opening: the reader keeps its cursor, and its place keeps the date of
    /// the reader's own last save, though its copy of the book still holds
    /// the place it opened with.
    @MainActor
    func testAReloadKeepsTheDateOfTheReadersLastSave() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])
        let reader = try openReader(of: row, in: model)
        reader.navigateTo(chapterIndex: 0, characterOffset: 30)
        reader.savePosition()
        let savedAt = try XCTUnwrap(model.bookByID(row.id)?.readingPosition?.lastUpdated)

        reader.loadContent()
        XCTAssertTrue(waitUntil(timeout: 20) { !reader.isLoading }, "the book should load again within 20 seconds")
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(reader.currentCharacterOffset, 30, "the reload moved the cursor")
        let saved = try XCTUnwrap(model.bookByID(row.id)?.readingPosition)
        XCTAssertEqual(saved.characterOffset, 30)
        XCTAssertEqual(saved.lastUpdated, savedAt, "the reload dated the place as the opening's")

        // The cursor moves on, as playback moves it, before its next
        // checkpoint; the record holds the last save, later than the place
        // the reader's copy opened with. A reload is no opening, so the
        // cursor stays where it is rather than go back to that save.
        reader.currentCharacterOffset = 40
        reader.loadContent()
        XCTAssertTrue(waitUntil(timeout: 20) { !reader.isLoading }, "the book should load again within 20 seconds")

        XCTAssertEqual(reader.currentCharacterOffset, 40, "the reload took the cursor back to the last save")
    }

    // MARK: - Two Readers and a Clock Set Back

    /// Two readers of one book: the one that moved saved a place; the other,
    /// never moved, closes. Its close writes nothing, so the row and the
    /// record keep the later place, and a bookmark made afterwards in the
    /// first reader survives a flush and a reopening.
    @MainActor
    func testAnUnmovedReaderClosingKeepsAnotherReadersLaterPlace() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])
        let first = try openReader(of: row, in: model)
        let second = try openReader(of: row, in: model)

        first.navigateTo(chapterIndex: 0, characterOffset: 30)
        first.savePosition()
        second.close()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(model.bookByID(row.id)?.readingPosition?.characterOffset, 30, "the unmoved reader's close put its opening place back")
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).state.readingPosition?.characterOffset, 30)

        // A bookmark made afterwards reaches the record, and a reader
        // opening the book again finds it.
        let made = try XCTUnwrap(first.addBookmarkAtCurrentPosition(label: "After the close"))
        LibraryPersistenceService.flushPendingSave()
        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertTrue(record.bookmarks.contains { $0.id == made.id }, "the bookmark did not reach the record")
        let reopened = try openReader(of: try XCTUnwrap(model.bookByID(row.id)), in: model)
        XCTAssertEqual(reopened.currentCharacterOffset, 30)
        XCTAssertTrue(reopened.bookmarks.contains { $0.id == made.id }, "the bookmark was lost at the reopening")
    }

    /// A reader that moved still saves its place when it closes.
    @MainActor
    func testAMovedReaderClosingSavesItsPlace() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])
        let reader = try openReader(of: row, in: model)

        reader.navigateTo(chapterIndex: 0, characterOffset: 40)
        reader.close()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(model.bookByID(row.id)?.readingPosition?.characterOffset, 40)
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).state.readingPosition?.characterOffset, 40)
    }

    /// The clock set back an hour: a move still wins over the place saved
    /// before it, in the row and the record, and the next opening keeps it.
    @MainActor
    func testAMoveWithTheClockSetBackStillWinsOverTheLastSave() throws {
        let row = try rowReadHere()
        try row.saveBookInfoThrowing()
        let model = makeModel(with: [row])
        let reader = try openReader(of: row, in: model)
        reader.positionClock = { Self.readHere.addingTimeInterval(-3600) }

        reader.navigateTo(chapterIndex: 0, characterOffset: 30)
        reader.savePosition()
        let firstMove = try XCTUnwrap(model.bookByID(row.id)?.readingPosition?.lastUpdated)
        XCTAssertGreaterThanOrEqual(firstMove, Self.readHere.addingTimeInterval(1), "the move was dated before the save it moves on from")
        // A second move, the clock still back, is later again.
        reader.navigateTo(chapterIndex: 0, characterOffset: 35)
        reader.savePosition()
        LibraryPersistenceService.flushPendingSave()

        let saved = try XCTUnwrap(model.bookByID(row.id)?.readingPosition)
        XCTAssertGreaterThanOrEqual(saved.lastUpdated, firstMove.addingTimeInterval(1))
        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 35)
        let reopened = try openReader(of: try XCTUnwrap(model.bookByID(row.id)), in: model)
        XCTAssertEqual(reopened.currentCharacterOffset, 35, "the next opening took the older place back")
    }

    // MARK: - Fixtures

    /// A packaged book as this Mac last read it: at offset 5, an hour
    /// before the other Mac read it, with one bookmark and none of its own
    /// settings.
    private func rowReadHere() throws -> Book {
        var book = try makePackagedBook(title: "Stale Row", text: Self.text)
        book.readingPosition = Self.position(at: 5, savedAt: Self.readHere)
        book.lastOpened = Self.readHere
        book.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 8, label: "Both Macs", dateCreated: Self.readHere)]
        return book
    }

    /// `book` as the other Mac left it, an hour later: further on, with a
    /// second bookmark, a voice, a speed, an end of its own, and the times
    /// it played.
    private func readOnTheOtherMac(_ book: Book) -> Book {
        var other = book
        other.readingPosition = Self.position(at: 20, savedAt: Self.readThere)
        other.lastOpened = Self.readThere
        other.lastPlaybackStarted = Self.readThere.addingTimeInterval(-600)
        other.lastPlaybackStopped = Self.readThere
        other.bookmarks.append(Bookmark(number: 2, chapterIndex: 0, characterOffset: 18, label: "Other Mac", dateCreated: Self.readThere))
        other.localVoiceID = "com.textmouth.test.other-voice"
        other.localWPM = 240
        other.localEndOfBookBehavior = "stop"
        other.localSkipForwardUnit = SkipUnit.paragraph.rawValue
        return other
    }

    /// Writes `book`'s record into its package as another Mac writes one:
    /// from its own row, over whatever is there.
    private func writeRecord(of book: Book) throws {
        var info = book.makeBookInfo()
        info.state.revision = 7
        try info.saveRecord(to: book.tmbDirectory)
    }

    /// A place in the first chapter at `offset`, saved at `date`.
    private static func position(at offset: Int, savedAt date: Date) -> ReadingPosition {
        var position = ReadingPosition(chapterIndex: 0, characterOffset: offset)
        position.lastUpdated = date
        return position
    }

    /// A reader of `book`, opened in `model` with settings of its own, once
    /// its text has loaded; closed when the test ends.
    @MainActor
    private func openReader(of book: Book, in model: LibraryViewModel) throws -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
        addTeardownBlock { @MainActor in reader.close() }
        XCTAssertTrue(waitUntil(timeout: 20) { !reader.isLoading }, "the book should load within 20 seconds")
        XCTAssertNotNil(reader.content, "the book's text should have loaded")
        return reader
    }
}
