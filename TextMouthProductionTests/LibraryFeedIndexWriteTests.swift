import XCTest
@testable import TextMouth

/// How each feed's own index (FR11) is written: only when its bytes changed,
/// unless its file is gone, when the same bytes are written again (REV10,
/// item 9); by one helper for a save and a data-directory move's staging;
/// and never over an index a newer TextMouth wrote in a later layout, which
/// is read as its version says (item 11).
final class LibraryFeedIndexWriteTests: FeedItemIndexTestCase {

    // MARK: - One Writer for Every Index

    /// The data-directory move's staging writes a feed's index as a save
    /// writes it, through the same helper: placed in the data directory and
    /// written in another folder, its bytes are the save's.
    func testTheStagingWritesWhatASaveWrites() throws {
        let item = try makeFeedItem(title: "Staged")
        let library = Library(books: [item])
        saveNow(library)
        let saved = try XCTUnwrap(contents(of: feedIndexURL))
        let staging = try makeSandboxDirectory("LibraryFeedStagedIndex")

        let index = try XCTUnwrap(try FeedIndexFiles.encodedIndexes(of: library, placedIn: TextMouthPaths.root).first { $0.feedID == feedID })
        try FeedIndexFiles.write(index, in: staging)

        XCTAssertEqual(index.rowCount, 1)
        XCTAssertEqual(try Data(contentsOf: FeedPaths.indexFile(of: feedID, in: staging)), saved)
    }

    // MARK: - The Layout's Version

    /// An index a newer TextMouth wrote, of a later layout, is left as it
    /// is: not read as this layout, not preserved as damage, its rows read
    /// from its packages, and written over by no save.
    func testAnIndexOfANewerLayoutIsLeftAsItIs() throws {
        let item = try makeFeedItem(title: "From A Newer TextMouth")
        let current = String(decoding: try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [item])), as: UTF8.self)
        XCTAssertTrue(current.contains("\"formatVersion\":1"), current)
        let newer = Data(current.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2").utf8)
        try newer.write(to: feedIndexURL)

        let read = FeedIndexFiles.read(feedID: feedID, in: TextMouthPaths.root)

        XCTAssertTrue(read.isLeftAlone)
        XCTAssertNil(read.indexBytes)
        XCTAssertEqual(read.rows.map(\.id), [item.id])
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: feedIndexURL), [], "the newer index was preserved as damage")
        XCTAssertThrowsError(try FeedIndexFiles.decoded(newer)) { error in
            XCTAssertEqual(error as? FeedIndexNewerLayout, FeedIndexNewerLayout(formatVersion: 2))
        }
        let shelf = LibraryPersistenceService.loadFeedShelf()
        XCTAssertTrue(shelf.indexesLeftAlone.contains(feedID))
        saveNow(Library(feedShelf: shelf))
        XCTAssertEqual(contents(of: feedIndexURL), newer, "a save wrote over the newer index")
    }

    /// An index naming no layout version is of the first layout, and reads.
    func testAnIndexNamingNoVersionIsOfTheFirstLayout() throws {
        let item = try makeFeedItem(title: "Unversioned")
        let written = try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [item]))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        object.removeValue(forKey: "formatVersion")

        let index = try FeedIndexFiles.decoded(try JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(index.books.map(\.id), [item.id])
    }

    // MARK: - Writing Again

    /// A feed's index deleted since this process wrote it is written again
    /// by the next save, though its rows did not change; while it is there,
    /// the same rows write nothing.
    func testAnIndexWhoseFileIsGoneIsWrittenAgain() throws {
        let item = try makeFeedItem(title: "Written Again")
        let library = Library(books: [item])
        saveNow(library)
        let written = try XCTUnwrap(contents(of: feedIndexURL))
        try FileManager.default.removeItem(at: feedIndexURL)

        saveNow(library)

        XCTAssertEqual(contents(of: feedIndexURL), written, "the index deleted since the last write was not written again")
        // Each write replaces the file atomically, with a new file, so the
        // same file number means no write.
        let before = try fileNumber(of: feedIndexURL)
        saveNow(library)
        XCTAssertEqual(try fileNumber(of: feedIndexURL), before, "an unchanged index on disk was written again")
    }

    // MARK: - A Write That Throws Forgets What Was Remembered

    /// A feed's index write throws (its rename may still have landed, as on a
    /// network volume), so the file's state is unknown. Saving the earlier
    /// rows again, as an undo does, must write them and not skip them as
    /// unchanged because they were the last bytes remembered (REV18c, 10).
    @MainActor
    func testASaveAfterAThrowingIndexWriteIsNotSkippedAsUnchanged() throws {
        let center = cleanSharedFailureCenter()
        var item = try makeFeedItem(title: "Undone")
        let libraryA = Library(books: [item])
        saveNow(libraryA)
        let bytesOfA = try XCTUnwrap(contents(of: feedIndexURL))
        item.readingPosition = Self.position(40, at: 5)
        let libraryB = Library(books: [item])

        // The index write of B throws.
        let obstruction = try WriteObstruction.place(at: feedIndexURL)
        saveNow(libraryB)
        XCTAssertTrue(center.hasUnsavedChanges, "the write did not fail")

        // The file holds B all the same, as a rename that landed though it
        // reported failure would leave it.
        obstruction.clear()
        let indexOfB = try XCTUnwrap(
            try FeedIndexFiles.encodedIndexes(of: libraryB, placedIn: TextMouthPaths.root).first { $0.feedID == feedID }
        )
        try indexOfB.data.write(to: feedIndexURL)
        XCTAssertNotEqual(indexOfB.data, bytesOfA, "the two libraries index to the same bytes")
        saveNow(libraryA)

        XCTAssertEqual(contents(of: feedIndexURL), bytesOfA, "the undo was skipped and the index still holds B")
        XCTAssertFalse(center.hasUnsavedChanges, "the write that settled the failure left it listed")
    }

    /// A save that writes no library.json still settles an earlier failed
    /// write, here of a feed's index, which forgot only that index's bytes:
    /// the retry writes the index, finds library.json unchanged, and leaves
    /// it alone, and the failure is no longer listed.
    @MainActor
    func testASkippedLibraryWriteStillSettlesAFailedFeedIndexWrite() throws {
        let center = cleanSharedFailureCenter()
        var item = try makeFeedItem(title: "Settled")
        saveNow(Library(books: [item]))
        item.readingPosition = Self.position(40, at: 5)
        let library = Library(books: [item])

        // The feed's index cannot be written, so the center lists the failure.
        let obstruction = try WriteObstruction.place(at: feedIndexURL)
        saveNow(library)
        XCTAssertEqual(center.outstandingFailures().map(\.subject), [.libraryIndex])

        // The retry writes the index; library.json is unchanged, so it is not
        // written again.
        obstruction.clear()
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: TextMouthPaths.libraryIndexFile.path)
        saveNow(library)

        let rows = try indexedRows()
        XCTAssertEqual(rows.first?.readingPosition?.characterOffset, 40, "the index was not written")
        let attributes = try FileManager.default.attributesOfItem(atPath: TextMouthPaths.libraryIndexFile.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, past, "library.json was written again")
        XCTAssertTrue(center.outstandingFailures().isEmpty, "the retry left the failure listed")
    }

    /// The file system's number of the file at `url`.
    private func fileNumber(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    }
}
