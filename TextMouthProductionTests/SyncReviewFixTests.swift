import XCTest
@testable import TextMouth

/// The early review's fixes to the changes and the applier (FR43): a place given new
/// words is no change, a revived book is recorded as present, two devices' new books,
/// folds that last, damaged folder names, tied order keys, and the speed of both.
final class SyncReviewFixTests: XCTestCase {
    private typealias Fixtures = SyncTestFixtures

    private func apply(_ entries: [SyncEntry], to library: Library) -> SyncApplication {
        SyncMerge.apply(Fixtures.registers(entries), to: library, voices: nil)
    }

    // MARK: - Item 2: places rewritten without moving

    /// A place that differs from the baseline only in its words, heading index, or global offset is no change.
    func testPlaceGivenAnchorWithoutMovingIsNotAChange() {
        var book = Fixtures.book()
        var place = ReadingPosition(chapterIndex: 2, characterOffset: 10)
        place.lastUpdated = Date(timeIntervalSince1970: 500)
        book.readingPosition = place
        let baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        var rewritten = place
        rewritten.anchor = TextAnchor(before: "words before", after: "words after", fraction: 0.5)
        rewritten.headingIndex = 3
        rewritten.globalCharacterOffset = 99
        book.readingPosition = rewritten
        let now = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: now, atLaunch: false).isEmpty)
    }

    /// A place that moved, or was saved again at a later date, is a change.
    func testMovedPlaceIsAChange() {
        var book = Fixtures.book()
        var place = ReadingPosition(chapterIndex: 2, characterOffset: 10)
        place.lastUpdated = Date(timeIntervalSince1970: 500)
        book.readingPosition = place
        let baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        place.characterOffset = 11
        book.readingPosition = place
        let now = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertEqual(Array(SyncMerge.changes(from: baseline, to: now, atLaunch: false).keys), [.book(book.id, .position)])
    }

    /// A bookmark or a skipped heading given new words is no change.
    func testBookmarkAndSkipGivenAnchorsAreNotChanges() {
        var book = Fixtures.book()
        var bookmark = Bookmark(number: 1, chapterIndex: 1, characterOffset: 4, label: "x")
        book.bookmarks = [bookmark]
        book.setSkippedHeadings([SkippedHeading(level: 1, label: "H", chapterIndex: 0, characterOffset: 0)])
        let baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        bookmark.anchor = TextAnchor(before: "a", after: "b", fraction: 0.5)
        book.bookmarks = [bookmark]
        book.setSkippedHeadings([SkippedHeading(level: 1, label: "H", chapterIndex: 0, characterOffset: 0, anchor: TextAnchor(before: "c", after: "d", fraction: 0.5))])
        let now = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: now, atLaunch: false).isEmpty)
    }

    /// The applier keeps this device's place when the winner differs only in its words, and takes a place that moved.
    func testApplierKeepsAPlaceThatDiffersOnlyInItsWords() {
        var book = Fixtures.book()
        var place = ReadingPosition(chapterIndex: 2, characterOffset: 10)
        place.lastUpdated = Date(timeIntervalSince1970: 500)
        place.anchor = TextAnchor(before: "mine", after: "mine", fraction: 0.5)
        book.readingPosition = place
        var theirs = place
        theirs.anchor = nil
        let same = apply([Fixtures.entry(.book(book.id, .position), SyncValueCoding.json(theirs), wall: 5)], to: Fixtures.library(books: [book]))
        XCTAssertEqual(same.library.books.first?.readingPosition?.anchor?.before, "mine")
        theirs.characterOffset = 77
        let moved = apply([Fixtures.entry(.book(book.id, .position), SyncValueCoding.json(theirs), wall: 5)], to: Fixtures.library(books: [book]))
        XCTAssertEqual(moved.library.books.first?.readingPosition?.characterOffset, 77)
    }

    // MARK: - Item 1: revival

    /// A book brought back on the device that removed it is recorded as present, and its removal is not applied.
    func testRevivedBookIsRecordedAsPresent() {
        let book = Fixtures.book()
        var baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        let registers = Fixtures.registers([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.book(book.id, .position), SyncValueCoding.json(ReadingPosition(chapterIndex: 4)), wall: 9, device: "b"),
        ])
        let application = SyncMerge.apply(registers, to: Fixtures.library(books: [book]), voices: nil)
        baseline.absorbApplied(application.appliedKeys, from: registers)
        XCTAssertNotNil(baseline.values[.book(book.id, .presence)], "the baseline still holds the book")
        XCTAssertEqual(application.entriesToRecord[.book(book.id, .presence)], .bool(true))
    }

    // MARK: - Item 5: two different libraries

    /// Two devices' libraries, each recorded and merged, give each the other's books and places and the same registers.
    func testTwoDifferentLibrariesMerge() throws {
        let shared = Fixtures.book(), onlyMac = Fixtures.book(title: "Mac"), onlyPhone = Fixtures.book(title: "Phone")
        var macLibrary = Fixtures.library(books: [shared, onlyMac])
        var phoneLibrary = Fixtures.library(books: [shared, onlyPhone])
        phoneLibrary.books[0].readingPosition = ReadingPosition(chapterIndex: 5)
        macLibrary.books[0].readingPosition = ReadingPosition(chapterIndex: 1)

        func record(_ library: Library, device: String, wall: Int64) -> [SyncEntry] {
            let now = SyncProjection.of(library, contents: Dictionary(uniqueKeysWithValues: library.books.map { ($0.id, Fixtures.content(of: $0)) }))
            return SyncMerge.changes(from: SyncProjection(), to: now, atLaunch: false).map {
                Fixtures.entry($0.key, $0.value, wall: wall, device: device)
            }
        }
        let macEntries = record(macLibrary, device: "mac", wall: 10)
        let phoneEntries = record(phoneLibrary, device: "phone", wall: 20)
        let macRegisters = Fixtures.registers(macEntries + phoneEntries)
        let phoneRegisters = Fixtures.registers(phoneEntries + macEntries.reversed())
        XCTAssertEqual(macRegisters, phoneRegisters)

        let onMac = SyncMerge.apply(macRegisters, to: macLibrary, voices: nil)
        XCTAssertEqual(onMac.booksToAdd.map(\.book.id), [onlyPhone.id])
        XCTAssertEqual(onMac.library.books.first { $0.id == shared.id }?.readingPosition?.chapterIndex, 5, "the later place wins")
        let onPhone = SyncMerge.apply(phoneRegisters, to: phoneLibrary, voices: nil)
        XCTAssertEqual(onPhone.booksToAdd.map(\.book.id), [onlyMac.id])
        XCTAssertEqual(onPhone.library.books.first { $0.id == shared.id }?.readingPosition?.chapterIndex, 5)
    }

    /// Applying to a library whose folders already exist changes only what the winners change.
    func testApplyToExistingFolders() {
        let fiction = BookFolder(name: "Fiction"), poetry = BookFolder(name: "Poetry", parentPath: "Fiction")
        let book = Fixtures.book(folderPath: "Fiction/Poetry")
        let library = Fixtures.library(books: [book], folders: [fiction, poetry])
        let untouched = apply([Fixtures.entry(.folder(fiction.id, .name), .string("Fiction"), wall: 5)], to: library)
        XCTAssertEqual(untouched.library, library)
        XCTAssertFalse(untouched.movesPackages)
        let moved = apply([Fixtures.entry(.folder(poetry.id, .parent), .null, wall: 5)], to: library)
        XCTAssertEqual(Set(moved.library.folders.map(\.fullPath)), ["Fiction", "Poetry"])
        XCTAssertEqual(moved.library.books.first?.folderPath, "Poetry")
        XCTAssertTrue(moved.movesPackages)
    }

    // MARK: - Item 9: new books from two devices

    /// Two devices' copies of one imported book are offered once, the older.
    func testTwoCopiesOfOneNewBookAreOfferedOnce() {
        var older = Fixtures.book(md5: "same"), newer = Fixtures.book(md5: "same")
        older.dateAdded = Date(timeIntervalSince1970: 10)
        newer.dateAdded = Date(timeIntervalSince1970: 20)
        let application = apply(Fixtures.presence(of: newer, wall: 5) + Fixtures.presence(of: older, wall: 5), to: Fixtures.library())
        XCTAssertEqual(application.booksToAdd.map(\.book.id), [older.id])
    }

    /// A dropped copy of a book is not a book of this library: none of its keys is applied, so a baseline
    /// that absorbs the applied keys never holds it, and no removal of it is ever recorded.
    func testDroppedDuplicateKeysAreNotApplied() {
        var older = Fixtures.book(md5: "same"), newer = Fixtures.book(md5: "same")
        older.dateAdded = Date(timeIntervalSince1970: 10)
        newer.dateAdded = Date(timeIntervalSince1970: 20)
        let registers = Fixtures.registers(
            Fixtures.presence(of: newer, wall: 5) + Fixtures.presence(of: older, wall: 5)
            + [Fixtures.entry(.bookmark(book: newer.id, id: UUID()), SyncValueCoding.json(SyncBookmarkValue(Bookmark(number: 1, chapterIndex: 0, characterOffset: 0))), wall: 6)]
        )
        let application = SyncMerge.apply(registers, to: Fixtures.library(), voices: nil)
        XCTAssertTrue(application.appliedKeys.allSatisfy { $0.bookID != newer.id }, "nothing of the dropped copy is applied")
        XCTAssertTrue(application.appliedKeys.contains(.book(older.id, .presence)))
        var baseline = SyncProjection()
        baseline.absorbApplied(application.appliedKeys, from: registers)
        XCTAssertNil(baseline.values[.book(newer.id, .presence)])
        let now = SyncProjection.of(application.library, contents: [:])
        XCTAssertNil(SyncMerge.changes(from: baseline, to: now, atLaunch: false)[.book(newer.id, .presence)])
    }

    /// Stopping keeping a removed book does not bring it back; keeping it later does.
    func testKeepFalseDoesNotReviveARemovedBook() {
        let book = Fixtures.book()
        let stopped = apply([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.book(book.id, .keep), .bool(false), wall: 9),
        ], to: Fixtures.library(books: [book]))
        XCTAssertEqual(stopped.booksToRemove, [book.id])
        let kept = apply([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.book(book.id, .keep), .bool(true), wall: 9),
        ], to: Fixtures.library(books: [book]))
        XCTAssertTrue(kept.booksToRemove.isEmpty)
    }

    /// A later content entry brings a removed book back, and a new book that comes back is recorded as present.
    func testLaterContentRevivesAndANewRevivedBookIsRecorded() {
        let book = Fixtures.book()
        let revived = apply([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.book(book.id, .content), SyncValueCoding.json(Fixtures.content(of: book)), wall: 9),
        ], to: Fixtures.library(books: [book]))
        XCTAssertTrue(revived.booksToRemove.isEmpty)
        let elsewhere = apply([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.book(book.id, .content), SyncValueCoding.json(Fixtures.content(of: book)), wall: 9),
        ], to: Fixtures.library())
        XCTAssertEqual(elsewhere.booksToAdd.map(\.book.id), [book.id])
        XCTAssertEqual(elsewhere.entriesToRecord[.book(book.id, .presence)], .bool(true))
        XCTAssertFalse(elsewhere.appliedKeys.contains(.book(book.id, .presence)))
    }

    /// A place dated in the future is stamped at now, so the clock does not refuse its stamp.
    func testJoiningStampOfAFutureDateIsCappedAtNow() {
        var place = ReadingPosition(chapterIndex: 1)
        let now = Date(timeIntervalSince1970: 1_000_000)
        place.lastUpdated = now.addingTimeInterval(10 * 365 * 24 * 3600)
        let key = SyncKey.book(UUID(), .position)
        let stamp = SyncMerge.joiningStamp(for: key, value: SyncValueCoding.json(place), device: "d", now: now)
        XCTAssertEqual(stamp.wall, SyncClock.milliseconds(of: now))
        var clock = SyncClock(device: "e")
        XCTAssertTrue(clock.observe(stamp, at: now))
    }

    // MARK: - Item 10: folders

    /// A fold lasts: a book recorded into the folded folder later lands in the survivor, and so does a folder.
    func testFoldLastsForBooksRecordedLater() {
        let older = UUID(), folded = UUID(), child = UUID()
        let book = Fixtures.book()
        let application = apply([
            Fixtures.entry(.folder(older, .presence), .bool(true), wall: 1), Fixtures.entry(.folder(older, .name), .string("Fiction"), wall: 1),
            Fixtures.entry(.folder(folded, .presence), SyncValueCoding.id(older), wall: 9),
            Fixtures.entry(.folder(folded, .name), .string("Fiction"), wall: 2),
            Fixtures.entry(.folder(child, .presence), .bool(true), wall: 3), Fixtures.entry(.folder(child, .name), .string("Sub"), wall: 3),
            Fixtures.entry(.folder(child, .parent), SyncValueCoding.id(folded), wall: 3),
            Fixtures.entry(.book(book.id, .folder), SyncValueCoding.id(folded), wall: 10),
        ], to: Fixtures.library(books: [book]))
        XCTAssertEqual(Set(application.library.folders.map(\.fullPath)), ["Fiction", "Fiction/Sub"])
        XCTAssertEqual(application.library.books.first?.folderPath, "Fiction")
        XCTAssertTrue(application.entriesToRecord.isEmpty, "nothing new to record, since the mark already says it")
    }

    /// A folder name from a damaged file passes through the rules for names.
    func testDamagedFolderNamesAreNormalized() {
        let slash = UUID(), dots = UUID()
        let application = apply([
            Fixtures.entry(.folder(slash, .presence), .bool(true), wall: 1), Fixtures.entry(.folder(slash, .name), .string("a/b"), wall: 1),
            Fixtures.entry(.folder(dots, .presence), .bool(true), wall: 1), Fixtures.entry(.folder(dots, .name), .string(".."), wall: 1),
        ], to: Fixtures.library())
        XCTAssertEqual(application.library.folders.map(\.fullPath), ["a-b"], "a folder named .. is not made")
    }

    // MARK: - Item 4: tied order keys

    /// Two books with one key: a book moved between them still lands between them, and the tie is broken.
    func testMovedBookBetweenTiedKeysStaysBetween() {
        let p = SyncTestFixtures.id(1), q = SyncTestFixtures.id(2), x = SyncTestFixtures.id(3)
        let existing = [p: "M", q: "M", x: "V"]
        let made = SyncOrderKey.assign(order: [p, x, q], existing: existing)
        var keys = existing
        keys.merge(made) { _, new in new }
        let sorted = [p, x, q].map { SyncOrderKey.SortKey(key: keys[$0] ?? "", id: $0.uuidString) }
        XCTAssertTrue(zip(sorted, sorted.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue(Set(keys.values).count == 3, "no two books share a key after")
    }

    /// A book inserted between two tied books gets a key between them, and the tie is broken.
    func testInsertionBetweenTiedKeys() {
        let p = SyncTestFixtures.id(1), q = SyncTestFixtures.id(2), added = SyncTestFixtures.id(3)
        let made = SyncOrderKey.assign(order: [p, added, q], existing: [p: "M", q: "M"])
        var keys: [UUID: String] = [p: "M", q: "M"]
        keys.merge(made) { _, new in new }
        let sorted = [p, added, q].map { keys[$0] ?? "" }
        XCTAssertTrue(zip(sorted, sorted.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: - Item 11: speed (logged, not asserted)

    /// Times the projection, the changes, and the apply on 750 books with 5,000 bookmarks, and prints them.
    func testTimingsOnALargeLibrary() {
        var books: [Book] = []
        for number in 0..<750 {
            var book = Fixtures.book(id: SyncTestFixtures.id(number + 1), title: "Book \(number)")
            book.readingPosition = ReadingPosition(chapterIndex: number % 30, characterOffset: number)
            book.bookmarks = (0..<7).map { Bookmark(number: $0 + 1, chapterIndex: $0, characterOffset: $0 * 10, label: "b\($0)") }
            books.append(book)
        }
        var library = Fixtures.library(books: books)
        library.readingList = ReadingList(bookIDs: books.prefix(200).map(\.id))
        let started = Date()
        let projection = SyncProjection.of(library, contents: [:])
        let projected = Date()
        let changes = SyncMerge.changes(from: SyncProjection(), to: projection, atLaunch: false)
        let changed = Date()
        let entries = changes.map { Fixtures.entry($0.key, $0.value, wall: 5) }
        let registers = Fixtures.registers(entries)
        let merged = Date()
        let application = SyncMerge.apply(registers, to: library, voices: nil)
        let applied = Date()
        print("SYNC_TIMING 750 books, \(books.count * 7) bookmarks: project \(projected.timeIntervalSince(started))s, changes \(changed.timeIntervalSince(projected))s, merge \(merged.timeIntervalSince(changed))s, apply \(applied.timeIntervalSince(merged))s")
        XCTAssertEqual(application.library.books.count, 750)
    }
}
