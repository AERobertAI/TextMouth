import XCTest
@testable import TextMouth

/// Compare Libraries' pure comparison (Phase 0 of the local-first design):
/// two copies of a small library that differ in each way the command lists,
/// compared as values, and the exact words of every row. No file is read:
/// `LibraryCopyReaderTests` reads fixture folders.
final class LibraryComparisonTests: XCTestCase {

    // MARK: - Identical Copies

    /// Two copies that agree in everything differ in nothing, whatever the
    /// order their books were written in.
    func testIdenticalCopiesDifferInNothing() {
        let moby = book("Moby-Dick", position: place(chapter: 2, offset: 410, at: 100))
        let emma = book("Emma", folder: "Novels")
        let folders = [folder("Novels")]
        let this = copy(Library(books: [moby, emma], folders: folders))
        let other = copy(Library(books: [emma, moby], folders: folders))

        let comparison = LibraryComparison.compare(this: this, other: other)

        XCTAssertEqual(comparison.differences, [])
        XCTAssertEqual(comparison.unread, [])
    }

    // MARK: - Books

    /// A book only one copy holds is listed with its copy, in title order,
    /// with its author when known.
    func testBooksInOneCopyOnlyAreListedWithTheirCopy() {
        let shared = book("Moby-Dick")
        let this = copy(Library(books: [shared, book("Zadie", author: "Zadie Smith"), book("Emma")]))
        let other = copy(Library(books: [shared, book("Persuasion", author: "Jane Austen")]))

        let sentences = sentences(of: LibraryComparison.compare(this: this, other: other))

        XCTAssertEqual(sentences, [
            "Book only in this copy: Emma.",
            "Book only in the other copy: Persuasion by Jane Austen.",
            "Book only in this copy: Zadie by Zadie Smith.",
        ])
    }

    /// A book filed in different folders is said to be, at the top of the
    /// library or in a named folder.
    func testABookFiledDifferentlyIsListed() {
        let id = UUID()
        let this = copy(Library(books: [book("Moby-Dick", id: id, folder: "Sea")], folders: [folder("Sea")]))
        let other = copy(Library(books: [book("Moby-Dick", id: id)]))

        let sentences = sentences(of: LibraryComparison.compare(this: this, other: other))

        XCTAssertEqual(sentences, [
            "Moby-Dick is filed in the folder “Sea” in this copy and at the top of the library in the other copy.",
            "Folder “Sea” is only in this copy.",
        ])
    }

    // MARK: - Places

    /// The newer of a book's places is named with its copy, as a sentence of
    /// its own, and the older follows.
    func testTheNewerPositionIsNamedWithItsCopy() {
        let id = UUID()
        let newer = book("Moby-Dick", id: id, position: place(chapter: 2, offset: 410, at: 2_000))
        let older = book("Moby-Dick", id: id, position: place(chapter: 1, offset: 200, at: 1_000))

        let thisNewer = LibraryComparison.compare(this: copy(Library(books: [newer])), other: copy(Library(books: [older])))
        let otherNewer = LibraryComparison.compare(this: copy(Library(books: [older])), other: copy(Library(books: [newer])))

        XCTAssertEqual(sentences(of: thisNewer), [
            "Position in Moby-Dick: newer in this copy, chapter 3, 41%. The other copy has chapter 2, 20%.",
        ])
        XCTAssertEqual(sentences(of: otherNewer), [
            "Position in Moby-Dick: newer in the other copy, chapter 3, 41%. This copy has chapter 2, 20%.",
        ])
        XCTAssertEqual(thisNewer.newerPositions(in: .thisCopy), 1)
        XCTAssertEqual(thisNewer.newerPositions(in: .otherCopy), 0)
    }

    /// A copy with no place at all is behind a copy that has one.
    func testAPositionInOneCopyOnlyIsTheNewer() {
        let id = UUID()
        let placed = book("Emma", id: id, position: place(chapter: 0, offset: 500, at: 1_000))
        let unplaced = book("Emma", id: id)

        let comparison = LibraryComparison.compare(this: copy(Library(books: [unplaced])), other: copy(Library(books: [placed])))

        XCTAssertEqual(sentences(of: comparison), [
            "Position in Emma: newer in the other copy, chapter 1, 50%. This copy has no place saved.",
        ])
    }

    /// The same place saved at two times is no difference, but two places
    /// saved at the same time are, and say so.
    func testSamePlacesDifferInNothingAndSameTimesAreSaid() {
        let id = UUID()
        let first = book("Emma", id: id, position: place(chapter: 0, offset: 500, at: 1_000))
        let later = book("Emma", id: id, position: place(chapter: 0, offset: 500, at: 5_000))
        let elsewhere = book("Emma", id: id, position: place(chapter: 3, offset: 800, at: 1_000.4))

        XCTAssertEqual(LibraryComparison.compare(this: copy(Library(books: [first])), other: copy(Library(books: [later]))).differences, [])
        XCTAssertEqual(
            sentences(of: LibraryComparison.compare(this: copy(Library(books: [first])), other: copy(Library(books: [elsewhere])))),
            ["Position in Emma: differs, and both were saved at the same time. "
                + "This copy has chapter 1, 50%; the other copy has chapter 4, 80%."]
        )
    }

    /// A copy's place is the newer of its row's and its package record's,
    /// as the reader saves into both, so the record can hold the newer.
    func testARecordNewerThanItsRowIsTheCopysPosition() {
        let id = UUID()
        let row = book("Emma", id: id, position: place(chapter: 0, offset: 100, at: 1_000))
        let there = book("Emma", id: id, position: place(chapter: 1, offset: 600, at: 3_000))
        let record = LibraryRecordFacts(position: place(chapter: 4, offset: 900, at: 5_000), bookmarks: [], totalCharacterCount: nil)
        let this = copy(Library(books: [row]), records: [id: record])

        let comparison = LibraryComparison.compare(this: this, other: copy(Library(books: [there])))

        XCTAssertEqual(sentences(of: comparison), [
            "Position in Emma: newer in this copy, chapter 5, 90%. The other copy has chapter 2, 60%.",
        ])
    }

    /// A record that holds the book's length stands in for a row without
    /// one, so a percent is still said.
    func testARecordsLengthGivesTheRowsPercent() {
        let id = UUID()
        let row = book("Emma", id: id, position: place(chapter: 0, offset: 250, at: 2_000), total: nil)
        let record = LibraryRecordFacts(position: nil, bookmarks: [], totalCharacterCount: 1_000)

        let comparison = LibraryComparison.compare(
            this: copy(Library(books: [row]), records: [id: record]),
            other: copy(Library(books: [book("Emma", id: id)]))
        )

        XCTAssertEqual(sentences(of: comparison), [
            "Position in Emma: newer in this copy, chapter 1, 25%. The other copy has no place saved.",
        ])
    }

    // MARK: - Bookmarks

    /// A bookmark only one copy holds is listed, and one both hold under
    /// another note is said to differ.
    func testBookmarksInOneCopyOnlyAndChangedBookmarksAreListed() {
        let id = UUID()
        let shared = bookmark(1, chapter: 0, note: "")
        let changedHere = bookmark(2, chapter: 1, note: "Check this", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let changedThere = bookmark(2, chapter: 1, note: "", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let hereOnly = bookmark(3, chapter: 2, note: "A quote")
        let thereOnly = bookmark(4, chapter: 4, note: "")
        let this = copy(Library(books: [book("Moby-Dick", id: id, bookmarks: [shared, changedHere, hereOnly])]))
        let other = copy(Library(books: [book("Moby-Dick", id: id, bookmarks: [shared, changedThere, thereOnly])]))

        let sentences = sentences(of: LibraryComparison.compare(this: this, other: other))

        XCTAssertEqual(sentences, [
            "Bookmark 2 in Moby-Dick: differs. This copy has chapter 2, with the note “Check this”; "
                + "the other copy has chapter 2, with no note.",
            "Bookmark 3 in Moby-Dick: only in this copy, chapter 3, with the note “A quote”.",
            "Bookmark 4 in Moby-Dick: only in the other copy, chapter 5, with no note.",
        ])
    }

    /// A bookmark in a copy's record counts in that copy, though its row
    /// lacks it.
    func testABookmarkInARecordCountsInItsCopy() {
        let id = UUID()
        let mark = bookmark(1, chapter: 0, note: "Kept")
        let record = LibraryRecordFacts(position: nil, bookmarks: [mark], totalCharacterCount: nil)

        let comparison = LibraryComparison.compare(
            this: copy(Library(books: [book("Emma", id: id)]), records: [id: record]),
            other: copy(Library(books: [book("Emma", id: id, bookmarks: [mark])]))
        )

        XCTAssertEqual(comparison.differences, [])
    }

    // MARK: - The Reading List

    /// The reading list's books only one copy holds, their order, and the
    /// options that differ are each a sentence.
    func testReadingListDifferencesAreListed() {
        let moby = book("Moby-Dick")
        let emma = book("Emma")
        let dune = book("Dune")
        let this = copy(Library(
            books: [moby, emma, dune],
            readingList: ReadingList(bookIDs: [moby.id, emma.id, dune.id], continuation: .playBookBelow, skipsFinished: true)
        ))
        let other = copy(Library(
            books: [moby, emma, dune],
            readingList: ReadingList(bookIDs: [emma.id, moby.id], continuation: .stop, skipsFinished: false, removesFinished: true)
        ))

        let sentences = sentences(of: LibraryComparison.compare(this: this, other: other))

        XCTAssertEqual(sentences, [
            "Reading list: Dune is only on this copy's list, at place 3.",
            "Reading list: the order differs. This copy has Moby-Dick and Emma; the other copy has Emma and Moby-Dick.",
            "Reading list: “When a book ends” is Play the book below in this copy and Stop in the other copy.",
            "Reading list: “Skip finished books” is on in this copy and off in the other copy.",
            "Reading list: “Remove books when finished” is off in this copy and on in the other copy.",
        ])
    }

    /// A list that names a book neither library holds still reads as a
    /// sentence.
    func testAReadingListBookNeitherLibraryHoldsIsNamedPlainly() {
        let ghost = UUID()
        let other = copy(Library(readingList: ReadingList(bookIDs: [ghost])))

        let sentences = sentences(of: LibraryComparison.compare(this: copy(Library()), other: other))

        XCTAssertEqual(sentences, ["Reading list: a book that is not in the library is only on the other copy's list, at place 1."])
    }

    // MARK: - Folders

    /// Folders are matched by identifier: one only a copy holds is listed,
    /// and one renamed in a copy is said to be, while the same name made in
    /// both on its own is no difference.
    func testFoldersOnlyInOneCopyAndRenamedFoldersAreListed() {
        let shared = folder("Novels")
        let renamedHere = folder("Sea")
        var renamedThere = renamedHere
        renamedThere.name = "Ocean"
        let this = copy(Library(folders: [shared, renamedHere, folder("Mine"), folder("Twice")]))
        let other = copy(Library(folders: [shared, renamedThere, folder("Theirs"), folder("Twice")]))

        let sentences = sentences(of: LibraryComparison.compare(this: this, other: other))

        XCTAssertEqual(sentences, [
            "Folder “Mine” is only in this copy.",
            "Folder “Sea” in this copy is “Ocean” in the other copy.",
            "Folder “Theirs” is only in the other copy.",
        ])
    }

    // MARK: - Unread Files

    /// A file that was not read is listed as unread, with the reason, and is
    /// never reported as a missing book or a missing record.
    func testUnreadFilesAreListedAsUnreadNeverAsMissing() {
        let id = UUID()
        let unread = [
            LibraryUnreadFile(subject: .record(bookID: id, title: "Moby-Dick"), side: .otherCopy, reason: .notArrived(seconds: 30)),
            LibraryUnreadFile(subject: .record(bookID: id, title: "Moby-Dick"), side: .thisCopy, reason: .cannotBeRead("its contents are damaged")),
        ]
        let this = copy(Library(books: [book("Moby-Dick", id: id)]), unread: [unread[1]])
        let other = copy(Library(books: [book("Moby-Dick", id: id)]), unread: [unread[0]])

        let comparison = LibraryComparison.compare(this: this, other: other)

        XCTAssertEqual(comparison.differences, [])
        XCTAssertEqual(comparison.unread.count, 2)
        XCTAssertEqual(
            LibraryComparisonWording.sentence(for: unread[0]),
            "Unread: the record of Moby-Dick in the other copy hasn't arrived from the cloud after 30 seconds, "
                + "so its place and bookmarks there were taken from the library index alone."
        )
        XCTAssertEqual(
            LibraryComparisonWording.sentence(for: unread[1]),
            "Unread: the record of Moby-Dick in this copy couldn't be read (its contents are damaged), "
                + "so its place and bookmarks there were taken from the library index alone."
        )
    }

    // MARK: - What the Sheet Says

    /// The sheet says the count first, then each difference as a sentence,
    /// then the unread files, the first twenty by name and the rest counted.
    func testTheSheetSaysTheCountThenTheRowsThenTheUnreadFiles() {
        let unread = (1...23).map {
            LibraryUnreadFile(subject: .record(bookID: UUID(), title: "Book \($0)"), side: .otherCopy, reason: .notArrived(seconds: 30))
        }
        let comparison = LibraryComparison.compare(
            this: copy(Library(books: [book("Emma")])),
            other: copy(Library(), unread: unread)
        )

        let shown = LibraryComparisonModel.present(.compared(comparison), folder: "/Drive/Copy")

        XCTAssertEqual(
            shown.heading,
            "1 difference between this library and the copy in /Drive/Copy. "
                + "23 files couldn't be read, so the comparison may be missing differences. "
                + "They are listed after the differences."
        )
        // The differences and the files not read are lists of their own.
        XCTAssertEqual(shown.rows, ["Book only in this copy: Emma."])
        XCTAssertEqual(shown.unread.count, 20 + 1)
        XCTAssertTrue(shown.unread[0].hasPrefix("Unread: the record of Book 1 in the other copy"))
        XCTAssertEqual(shown.unread[20], "And 3 more files couldn't be read.")
    }

    /// The sheet says plainly when the folder holds another library, when
    /// nothing could be compared, and when it was stopped.
    func testTheSheetSaysWhyNothingWasCompared() {
        XCTAssertEqual(
            LibraryComparisonModel.present(.differentLibraries, folder: "/Other").heading,
            "The folder /Other holds a different library, so nothing was compared."
        )
        let marker = LibraryUnreadFile(subject: .identityMarker, side: .otherCopy, reason: .cannotBeRead("no file is there"))
        let shown = LibraryComparisonModel.present(.notComparable([marker]), folder: "/Other")
        XCTAssertEqual(
            shown.heading,
            "Nothing could be compared with the copy in /Other, because a file the comparison needs couldn't be read. "
                + "The files that couldn't be read are listed."
        )
        XCTAssertEqual(shown.rows, [])
        XCTAssertEqual(shown.unread, [
            "Unread: the identity marker of the library in the other copy couldn't be read (no file is there), "
                + "so TextMouth can't tell whether the two copies are one library, and compared nothing.",
        ])
        let stopped = LibraryComparisonModel.present(.cancelled, folder: "/Other")
        XCTAssertEqual(stopped.heading, "Comparing stopped. Nothing was changed.")
        XCTAssertEqual(stopped.rows, [])
    }

    /// A file whose comparison ran out of time is said to be unread for that
    /// reason, in the sheet and in Use This Library's words.
    func testRunningOutOfTimeIsSaidInEachPlace() {
        let file = LibraryUnreadFile(subject: .libraryIndex, side: .otherCopy, reason: .timeRanOut(seconds: 60))

        XCTAssertEqual(
            LibraryComparisonWording.sentence(for: file),
            "Unread: the library index in the other copy wasn't read, because TextMouth stopped waiting after 60 seconds "
                + "in all, so nothing in the other copy was compared."
        )
        XCTAssertEqual(
            LibraryComparisonWording.shortReason(for: file),
            "the library index of the copy in this folder wasn't read within 60 seconds"
        )
    }

    /// A long comparison says now and then that it is still going.
    func testTheProgressSentenceSaysHowLongAndHowToStop() {
        XCTAssertEqual(
            LibraryComparisonWording.progressSentence(seconds: 30),
            "Still comparing: 30 seconds so far. Press Escape to stop."
        )
        XCTAssertEqual(LibraryComparisonWording.buttonTitle, "Compare Libraries…", "one ellipsis character")
    }

    /// The upload-failed refusal ends the drive's words with a period when
    /// they have none, so the next sentence doesn't run on.
    func testTheUploadFailedRefusalIsPunctuated() {
        let bare = BookCloudError.cloudCopyNotProven(.uploadFailed("The disk is full")).explanation(in: .googleDrive)
        XCTAssertEqual(
            bare,
            "Google Drive couldn't upload this book: The disk is full. Its download can't be removed until it has uploaded."
        )
    }

    // MARK: - The Count and Use This Library's Words

    /// The count that heads the list, with and without differences and
    /// files not read.
    func testTheCountIsTheFirstSentence() {
        XCTAssertEqual(
            LibraryComparisonWording.countSentence(differences: 0, unread: 0, folder: "/Drive/TextMouthLibrary"),
            "No differences between this library and the copy in /Drive/TextMouthLibrary."
        )
        XCTAssertEqual(
            LibraryComparisonWording.countSentence(differences: 1, unread: 0, folder: "/Drive/TextMouthLibrary"),
            "1 difference between this library and the copy in /Drive/TextMouthLibrary."
        )
        XCTAssertEqual(
            LibraryComparisonWording.countSentence(differences: 7, unread: 2, folder: "/Drive/TextMouthLibrary"),
            "7 differences between this library and the copy in /Drive/TextMouthLibrary. "
                + "2 files couldn't be read, so the comparison may be missing differences. "
                + "They are listed after the differences."
        )
    }

    /// Use This Library says which copy is newer, in the words that replace
    /// "may not have its latest changes".
    func testUseThisLibrarySaysWhichCopyIsNewer() {
        let id = UUID()
        let newer = book("Moby-Dick", id: id, position: place(chapter: 2, offset: 410, at: 2_000))
        let older = book("Moby-Dick", id: id, position: place(chapter: 1, offset: 200, at: 1_000))
        let extra = book("Emma")

        let folderNewer = LibraryComparison.compare(this: copy(Library(books: [older])), other: copy(Library(books: [newer, extra])))
        let inUseNewer = LibraryComparison.compare(this: copy(Library(books: [newer])), other: copy(Library(books: [older])))
        let mixed = LibraryComparison.compare(this: copy(Library(books: [newer])), other: copy(Library(books: [older, extra])))
        let same = LibraryComparison.compare(this: copy(Library(books: [newer])), other: copy(Library(books: [newer])))

        XCTAssertEqual(
            LibraryComparisonWording.newerCopySentence(folderNewer, reason: nil),
            "This folder holds another copy of the library TextMouth is using. The copy in this folder is the newer. "
                + "It has newer places in 1 book and 1 book the other lacks. "
                + "Compare Libraries in Storage settings lists every difference."
        )
        XCTAssertEqual(
            LibraryComparisonWording.newerCopySentence(inUseNewer, reason: nil),
            "This folder holds another copy of the library TextMouth is using. The library in use is the newer. "
                + "It has newer places in 1 book. Compare Libraries in Storage settings lists every difference."
        )
        XCTAssertEqual(
            LibraryComparisonWording.newerCopySentence(mixed, reason: nil),
            "This folder holds another copy of the library TextMouth is using. Neither is newer: each has changes "
                + "the other lacks. The library in use has newer places in 1 book. The copy in this folder has 1 book "
                + "the other lacks. Compare Libraries in Storage settings lists every difference."
        )
        XCTAssertEqual(
            LibraryComparisonWording.newerCopySentence(same, reason: nil),
            "This folder holds another copy of the library TextMouth is using. It has the same books, places, "
                + "bookmarks, reading list, and folders."
        )
        XCTAssertEqual(
            LibraryComparisonWording.newerCopySentence(nil, reason: "its index hasn't arrived from Google Drive"),
            "This folder holds another copy of the library TextMouth is using. TextMouth couldn't tell which copy is "
                + "newer (its index hasn't arrived from Google Drive). "
                + "Compare Libraries in Storage settings lists every difference."
        )
        XCTAssertFalse(LibraryComparisonWording.newerCopySentence(same, reason: nil).contains("may not have its latest changes"))
    }

    // MARK: - Fixtures

    /// The sentences of every difference of `comparison`, in order.
    private func sentences(of comparison: LibraryComparison) -> [String] {
        comparison.differences.map { LibraryComparisonWording.sentence(for: $0) }
    }

    /// A copy of a library with the records and unread files given.
    private func copy(
        _ library: Library,
        records: [UUID: LibraryRecordFacts] = [:],
        unread: [LibraryUnreadFile] = []
    ) -> LibraryCopy {
        LibraryCopy(library: library, records: records, unread: unread)
    }

    /// A book, 1,000 characters long unless `total` says otherwise.
    private func book(
        _ title: String,
        id: UUID = UUID(),
        author: String = Book.unknownAuthor,
        folder: String = "",
        position: ReadingPosition? = nil,
        bookmarks: [Bookmark] = [],
        total: Int? = 1_000
    ) -> Book {
        Book(
            id: id,
            title: title,
            author: author,
            format: .txt,
            filePath: "/\(title).txt",
            md5Hash: title,
            folderPath: folder,
            readingPosition: position,
            bookmarks: bookmarks,
            totalCharacterCount: total,
            tmbDirectoryName: "\(title).tmb"
        )
    }

    /// A place in `chapter` (from 0) at `offset`, saved `seconds` after the
    /// start of the epoch.
    private func place(chapter: Int, offset: Int, at seconds: TimeInterval) -> ReadingPosition {
        var position = ReadingPosition(chapterIndex: chapter, characterOffset: offset, globalCharacterOffset: offset)
        position.lastUpdated = Date(timeIntervalSince1970: seconds)
        return position
    }

    /// A bookmark numbered `number` in `chapter` (from 0).
    private func bookmark(_ number: Int, chapter: Int, note: String, id: UUID = UUID()) -> Bookmark {
        Bookmark(id: id, number: number, chapterIndex: chapter, characterOffset: 10, label: note)
    }

    /// A folder of the top level.
    private func folder(_ name: String) -> BookFolder {
        BookFolder(name: name)
    }
}
