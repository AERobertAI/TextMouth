import XCTest
@testable import TextMouth

/// The snapshots a rebuild of a book's text keeps of its old text and
/// places (T06's branch D, `PlaceSnapshot`): keeping one and listing what a
/// stop left, the unfinished copies that are removed, and moving the places
/// from the snapshot's text to a new one. The store tests use a folder of
/// their own, never `MachineLocalPaths`.
final class PlaceSnapshotTests: XCTestCase {

    // MARK: - Fixtures

    /// A new, empty folder in the system's temporary directory, removed
    /// when the test ends.
    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaceSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The content.md of a book whose chapters read `texts`: a chapter
    /// marker line and the chapter's text, for each chapter.
    private func markdown(of texts: [String]) -> String {
        texts.enumerated().map { index, text in
            "\(MarkdownCacheService.chapterMarker(title: "Chapter \(index + 1)"))\n\(text)"
        }.joined(separator: "\n\n")
    }

    /// The text of a content.md as the reader reads it.
    private func parse(_ markdown: String, title: String) -> DocumentContent {
        MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: title, bookAuthor: "A. Volunteer")
    }

    /// A title no other test's book has, so a search of the debug log finds
    /// only this test's lines.
    private func uniqueTitle() -> String {
        "Mill Book \(UUID().uuidString)"
    }

    /// How many lines of the debug log hold `text`, read after every queued
    /// log write (`debugLogLines(containing:)`).
    private func logLineCount(_ text: String) -> Int {
        debugLogLines(containing: text).count
    }

    /// Writes `text` as a file named `name` in a new folder, and returns the file.
    private func writeFile(_ text: String, named name: String = "content.md") throws -> URL {
        let url = try makeTemporaryFolder().appendingPathComponent(name, isDirectory: false)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A record of a book with a place of every kind: a position, a
    /// bookmark, a skipped heading, and a waiting skip, whose words are those
    /// of the mill book's chapters.
    private func fullRecord(title: String, takenAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> PlaceSnapshot.Record {
        let book = MillBook.chapters
        let reading = try Phrase.place(of: "spirit level", inChapter: 0, of: book)
        let marked = try Phrase.place(of: "French burrs", inChapter: 2, of: book)
        var position = ReadingPosition(
            chapterIndex: 0,
            characterOffset: reading.offset,
            globalCharacterOffset: BookWords(texts: book).globalOffset(of: reading),
            anchor: try SavedPlace.anchor(at: reading, in: book)
        )
        // A fixed time, so that the record compares equal after a round trip.
        position.lastUpdated = Date(timeIntervalSince1970: 1_699_999_000)
        let waiting = SkippedHeading(level: 2, label: "Notes", chapterIndex: 1, characterOffset: 40)
        return PlaceSnapshot.Record(
            bookID: UUID(),
            title: title,
            author: "A. Volunteer",
            places: PlaceRelocator.Places(
                position: position,
                bookmarks: [Bookmark(number: 1, chapterIndex: 2, characterOffset: marked.offset, label: "the burrs",
                                     anchor: try SavedPlace.anchor(at: marked, in: book))],
                skippedHeadings: [try SavedPlace.skip(of: try MillBook.heading(ofChapter: 3, in: book), in: book)],
                waitingSkippedHeadings: [waiting]
            ),
            takenAt: takenAt
        )
    }

    /// A book kept aside, ready to have its places moved.
    private struct KeptBook {
        /// The snapshots folder the snapshot is in.
        let folder: URL
        /// The snapshot.
        let snapshot: PlaceSnapshot
        /// The content.md's text, as `markdown(of:)` wrote it.
        let markdown: String
        /// The old text as the reader reads it.
        let old: DocumentContent
        /// The book's title.
        let title: String
    }

    /// Keeps aside the mill book's content.md with a record whose only
    /// place is a bookmark at "French burrs" in chapter III, its words taken
    /// from the old text as the reader reads it and measured as this build
    /// measures a text, as a saved place's are.
    private func keepMillBook() throws -> KeptBook {
        let title = uniqueTitle()
        let markdown = markdown(of: MillBook.chapters)
        let old = parse(markdown, title: title)
        let chapterText = try XCTUnwrap(old.chapters.dropFirst(2).first?.text, "the old text lacks chapter III")
        let marked = TextPlace(chapter: 2, offset: try Phrase.offset(of: "French burrs", in: chapterText))
        let anchor = try XCTUnwrap(old.anchor(at: marked, measuredIn: TextAnchor.currentMeasure))
        let record = PlaceSnapshot.Record(
            bookID: UUID(),
            title: title,
            author: "A. Volunteer",
            places: PlaceRelocator.Places(bookmarks: [Bookmark(number: 1, chapterIndex: 2, characterOffset: marked.offset, label: "the burrs", anchor: anchor)]),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let folder = try makeTemporaryFolder()
        let snapshot = try PlaceSnapshot.keep(textAt: try writeFile(markdown), record: record, in: folder)
        return KeptBook(folder: folder, snapshot: snapshot, markdown: markdown, old: old, title: title)
    }

    // MARK: - Keeping and Listing

    /// A snapshot is a folder of its own holding the file's exact bytes as
    /// content.md and the record as places.json; it is listed with a record
    /// equal to the one kept, and gone from the list once discarded.
    func testKeepingAndListingASnapshot() throws {
        let folder = try makeTemporaryFolder()
        // Bytes a text round trip would change: a byte-order mark and a CR LF.
        let source = try writeFile("\u{FEFF}<!-- chapter: One -->\r\nWords.\r\n")
        let record = try fullRecord(title: "The Mill")

        let snapshot = try PlaceSnapshot.keep(textAt: source, record: record, in: folder)

        XCTAssertEqual(snapshot.record, record)
        XCTAssertEqual(snapshot.folder.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(snapshot.folder.lastPathComponent.hasPrefix("\(record.bookID.uuidString) "))
        XCTAssertEqual(try Data(contentsOf: snapshot.folder.appendingPathComponent("content.md")), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.folder.appendingPathComponent("places.json").path))

        // In use by this run (a rebuild between its copy and its commit),
        // it is no leftover; a quit makes it one.
        XCTAssertEqual(PlaceSnapshot.leftovers(in: folder), [])
        PlaceSnapshot.forgetCopiesInUse()
        let listed = PlaceSnapshot.leftovers(in: folder)
        XCTAssertEqual(listed.map(\.record), [record], "the listed record is the kept one, places and all")
        XCTAssertEqual(listed.map(\.folder.lastPathComponent), [snapshot.folder.lastPathComponent])

        snapshot.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.folder.path))
        XCTAssertEqual(PlaceSnapshot.leftovers(in: folder), [])
        // Discarding a folder that is gone is no error.
        snapshot.discard()
    }

    /// Keeping a file that is not there throws and leaves no folder behind.
    func testAFailedKeepLeavesNoFolder() throws {
        let folder = try makeTemporaryFolder()
        let missing = folder.appendingPathComponent("nothing.md")
        XCTAssertThrowsError(try PlaceSnapshot.keep(textAt: missing, record: try fullRecord(title: "The Mill"), in: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// A folder with only content.md (a copy stopped before its record), and
    /// one whose record cannot be read, are removed by the listing, which
    /// shows only the finished snapshot; a stray file is left alone.
    func testUnfinishedCopiesAreRemoved() throws {
        let folder = try makeTemporaryFolder()
        let fileManager = FileManager.default
        let finished = try PlaceSnapshot.keep(textAt: try writeFile("Words."), record: try fullRecord(title: "The Mill"), in: folder)

        let onlyText = folder.appendingPathComponent("only text", isDirectory: true)
        try fileManager.createDirectory(at: onlyText, withIntermediateDirectories: true)
        try Data("Words.".utf8).write(to: onlyText.appendingPathComponent("content.md"))

        let unreadable = folder.appendingPathComponent("unreadable", isDirectory: true)
        try fileManager.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("Words.".utf8).write(to: unreadable.appendingPathComponent("content.md"))
        try Data("not json".utf8).write(to: unreadable.appendingPathComponent("places.json"))

        let noText = folder.appendingPathComponent("no text", isDirectory: true)
        try fileManager.createDirectory(at: noText, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: noText.appendingPathComponent("places.json"))

        let stray = folder.appendingPathComponent("stray.txt")
        try Data("left alone".utf8).write(to: stray)

        // The finished copy as a quit leaves it.
        PlaceSnapshot.forgetCopiesInUse()
        XCTAssertEqual(PlaceSnapshot.leftovers(in: folder), [finished])
        XCTAssertFalse(fileManager.fileExists(atPath: onlyText.path))
        XCTAssertFalse(fileManager.fileExists(atPath: unreadable.path))
        XCTAssertFalse(fileManager.fileExists(atPath: noText.path))
        XCTAssertTrue(fileManager.fileExists(atPath: finished.folder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stray.path))
    }

    /// A folder that is not there holds no snapshots.
    func testAMissingFolderHoldsNoSnapshots() throws {
        let folder = try makeTemporaryFolder().appendingPathComponent("never made", isDirectory: true)
        XCTAssertEqual(PlaceSnapshot.leftovers(in: folder), [])
    }

    /// Two rebuilds of one book keep two snapshots in distinct folders, both
    /// listed, the older first however they are named.
    func testTwoSnapshotsOfOneBookAreListedOldestFirst() throws {
        let folder = try makeTemporaryFolder()
        let source = try writeFile("Words.")
        let first = try fullRecord(title: "The Mill", takenAt: Date(timeIntervalSince1970: 1_700_000_000))
        var second = first
        second.takenAt = first.takenAt.addingTimeInterval(1)

        // The newer is kept first, so the order listed is the dates', not the keeping's.
        let newer = try PlaceSnapshot.keep(textAt: source, record: second, in: folder)
        let older = try PlaceSnapshot.keep(textAt: source, record: first, in: folder)

        XCTAssertNotEqual(older.folder, newer.folder)
        PlaceSnapshot.forgetCopiesInUse()
        XCTAssertEqual(PlaceSnapshot.leftovers(in: folder), [older, newer])
    }

    /// A copy this run is still using is neither listed nor swept, though it
    /// looks unfinished (its record not yet written, or gone): a recovery
    /// running while a rebuild works never takes or removes the rebuild's
    /// copy. Once discarded it is no longer in use; once a quit forgets it,
    /// an unfinished one is swept like any other.
    func testACopyInUseIsNeitherListedNorSwept() throws {
        let folder = try makeTemporaryFolder()
        let source = try writeFile("Words.")
        let half = try PlaceSnapshot.keep(textAt: source, record: try fullRecord(title: "The Mill"), in: folder)
        try FileManager.default.removeItem(at: half.folder.appendingPathComponent("places.json"))
        let whole = try PlaceSnapshot.keep(textAt: source, record: try fullRecord(title: "The Mill"), in: folder)

        XCTAssertEqual(PlaceSnapshot.leftovers(in: folder), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: half.folder.path), "a copy in use is never swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: whole.folder.path))

        whole.discard()
        PlaceSnapshot.forgetCopiesInUse()
        XCTAssertEqual(PlaceSnapshot.leftovers(in: folder), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: half.folder.path), "once forgotten, an unfinished copy is swept")
    }

    /// The snapshots' default folder is this Mac's own, inside the machine
    /// folder, and is named for what it holds.
    func testTheDefaultFolderIsInThisMacsFolder() {
        let folder = MachineLocalPaths.placeSnapshots
        XCTAssertEqual(folder.lastPathComponent, "Place Snapshots")
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, MachineLocalPaths.root.standardizedFileURL)
    }

    // MARK: - Reading the Old Text

    /// The snapshot's text is read as a content.md is: the same chapters as
    /// parsing the file's text with the book's title and author.
    func testTheOldTextIsReadAsTheReaderReadsIt() throws {
        let kept = try keepMillBook()
        let read = try kept.snapshot.oldText()
        XCTAssertEqual(read.chapters.map(\.text), kept.old.chapters.map(\.text))
        XCTAssertEqual(read.chapters.map(\.title), kept.old.chapters.map(\.title))
        XCTAssertEqual(read.author, "A. Volunteer")
        XCTAssertEqual(read.chapters.count, MillBook.chapters.count)
    }

    // MARK: - Moving the Places

    /// With a sentence put in before the bookmark, the moved bookmark is at
    /// the same words in the new text; the original places are the record's,
    /// the snapshot stays until it is discarded, and the log holds one line
    /// of counts.
    func testMovingPlacesToTextWithASentencePutIn() throws {
        let kept = try keepMillBook()
        let newMarkdown = kept.markdown.replacingOccurrences(
            of: "The parish records listed",
            with: "Volunteers argued about it for years. The parish records listed"
        )
        XCTAssertNotEqual(newMarkdown, kept.markdown, "the test's edit did not apply")
        let new = parse(newMarkdown, title: kept.title)

        let moved = try XCTUnwrap(kept.snapshot.movePlaces(to: new, at: SavedPlace.moveDate))

        XCTAssertEqual(moved.bookID, kept.snapshot.record.bookID)
        XCTAssertEqual(moved.original, kept.snapshot.record.places)
        XCTAssertEqual(moved.snapshot, kept.snapshot)
        let newChapter = try XCTUnwrap(new.chapters.dropFirst(2).first?.text)
        let bookmark = try XCTUnwrap(moved.moved.bookmarks.first)
        XCTAssertEqual(bookmark.chapterIndex, 2)
        XCTAssertEqual(bookmark.characterOffset, try Phrase.offset(of: "French burrs", in: newChapter))
        XCTAssertNotEqual(bookmark.characterOffset, kept.snapshot.record.places.bookmarks.first?.characterOffset)

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.snapshot.folder.path), "the copy stays until the record holds the places")
        XCTAssertEqual(logLineCount("PLACES_RELOCATED: \(kept.title):"), 1)

        moved.discardSnapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.snapshot.folder.path))
    }

    /// A new text equal to the old, with places that have their words, needs
    /// nothing written: no result, the snapshot's folder gone, and no line
    /// of counts, since nothing moved.
    func testNothingToWriteWhenTheTextIsUnchanged() throws {
        let kept = try keepMillBook()
        let new = parse(kept.markdown, title: kept.title)

        XCTAssertNil(kept.snapshot.movePlaces(to: new, at: SavedPlace.moveDate))

        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.snapshot.folder.path))
        XCTAssertEqual(logLineCount("PLACES_RELOCATED: \(kept.title):"), 0)
        XCTAssertEqual(logLineCount("PLACES_NOT_MOVED: \(kept.title):"), 0)
    }

    /// A copy whose text is gone is no use: the move returns nothing,
    /// removes the folder, and logs one line saying the places were not moved.
    func testACopyThatCannotBeReadMovesNothing() throws {
        let kept = try keepMillBook()
        try FileManager.default.removeItem(at: kept.snapshot.folder.appendingPathComponent("content.md"))
        // Text that moves the bookmark, so that the old text is needed.
        let new = parse(
            kept.markdown.replacingOccurrences(of: "The parish records listed", with: "Volunteers argued about it for years. The parish records listed"),
            title: kept.title
        )

        XCTAssertNil(kept.snapshot.movePlaces(to: new, at: SavedPlace.moveDate))

        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.snapshot.folder.path))
        XCTAssertEqual(logLineCount("PLACES_NOT_MOVED: \(kept.title):"), 1)
        XCTAssertEqual(logLineCount("PLACES_RELOCATED: \(kept.title):"), 0)
    }
}
