import Combine
import XCTest
import os
@testable import TextMouth

/// A content analysis can run for minutes on a copy of its book taken when it
/// started. Its result must change only the fields an analysis owns, and
/// must land on the latest state of the book, never on that old copy
/// (TODO S05).
final class ContentAnalysisMergeTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Folders this test created in the test root's library, removed after
    /// it with every package inside.
    private var createdDirectories: [URL] = []

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdDirectories = []
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        // Restoring flushes pending saves, so none lands in a removed folder.
        sandbox?.restore()
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - The Fields an Analysis Owns

    /// Setting a book's analysis fields changes exactly the eight fields an
    /// analysis owns. Every other field (reading state, bookmarks, settings,
    /// metadata, and where the package is) keeps its value, so neither a
    /// package record nor a library row can lose user state to an analysis.
    func testSettingAnalysisFieldsChangesNothingElse() {
        let user = Self.bookWithEveryFieldSet(seed: 1)
        let analysis = Self.bookWithEveryFieldSet(seed: 2)
        XCTAssertEqual(
            Self.fieldsThatDiffer(user, analysis).count,
            user.reflectedFields.children.count,
            "the fixtures must differ in every field, or this test proves nothing about it"
        )

        var changed = user
        changed.contentAnalysisFields = analysis.contentAnalysisFields

        XCTAssertEqual(changed.contentAnalysisFields, analysis.contentAnalysisFields)
        XCTAssertEqual(Set(Self.fieldsThatDiffer(user, changed)), Self.analysisFieldNames)
    }

    /// Applying an analysis records the statistics and version of its index
    /// and the cache version the analysis vouches for. One that vouches for
    /// no cache keeps the book's cache version, as a bare summary does.
    func testApplyingAnAnalysisRecordsItsIndexAndTheCacheItVouchesFor() {
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "One", text: "one two three")],
            format: .txt
        )

        var vouched = Self.bookWithEveryFieldSet(seed: 3)
        vouched.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertEqual(vouched.contentAnalysisFields, Book.ContentAnalysisFields(
            totalWordCount: 3,
            totalCharacterCount: index.totalCharacterCount,
            audioDuration: index.totalAudioDuration,
            contentIndexVersion: index.version,
            cacheFormatVersion: "9.9.9",
            // An index with no fingerprint keeps the record of the edit (B12).
            editedText: vouched.editedText,
            // An analysis says nothing of the page reader (PG09).
            pageReaderVersion: vouched.pageReaderVersion
        ))
        XCTAssertNotNil(vouched.pageReaderVersion, "the fixture should record a page reader")
        XCTAssertNotNil(vouched.editedText, "the fixture should record an edit")

        var silent = Self.bookWithEveryFieldSet(seed: 3)
        silent.applyContentAnalysis(index, cacheFormatVersion: nil)
        XCTAssertEqual(silent.cacheFormatVersion, "cache-3")
        XCTAssertEqual(silent.totalWordCount, 3)

        var summarized = Self.bookWithEveryFieldSet(seed: 3)
        summarized.applyContentIndexSummary(index)
        XCTAssertEqual(summarized.contentAnalysisFields, silent.contentAnalysisFields)
    }

    /// The text cache fingerprints come from the analysis's index, which
    /// carries those of the files it was made from. An index without any
    /// leaves the book without any, even when the book had some: they
    /// described the files of another index.
    func testAnalysisFingerprintsTravelWithTheirIndex() {
        var index = BookContentIndex.build(
            fromChapters: [Chapter(title: "One", text: "one two three")],
            format: .txt
        )

        var unfingerprinted = Self.bookWithEveryFieldSet(seed: 4)
        unfingerprinted.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertNil(unfingerprinted.textCacheFingerprint)

        index.textCacheFingerprint = Self.fingerprint(seed: 5)
        var fingerprinted = Self.bookWithEveryFieldSet(seed: 4)
        fingerprinted.applyContentAnalysis(index, cacheFormatVersion: nil)
        XCTAssertEqual(fingerprinted.textCacheFingerprint, Self.fingerprint(seed: 5))
        XCTAssertEqual(fingerprinted.makeBookInfo().state.textCacheFingerprint, Self.fingerprint(seed: 5))
        // The fixture's edit (seed 4) is not the content.md of seed 5's
        // fingerprint, so the record of it goes with the old fingerprint (B12).
        XCTAssertNotNil(unfingerprinted.editedText)
        XCTAssertNil(fingerprinted.editedText)
    }

    /// A fingerprint that cannot be read, in a package record or in a
    /// library row, counts as none instead of failing the record or the
    /// whole library: every other field still loads. A valid one loads
    /// unchanged.
    func testUnreadableFingerprintsDecodeAsNone() throws {
        for value in [#""garbage""#, "17", #"{"source": 3}"#] {
            let state = try Self.decodeState(#""manualSortOrder": 4, "textCacheFingerprint": \#(value)"#)
            XCTAssertNil(state.textCacheFingerprint, value)
            XCTAssertEqual(state.manualSortOrder, 4, value)
        }

        let book = Self.bookWithEveryFieldSet(seed: 6)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
        XCTAssertEqual(try decoder.decode(Book.self, from: encoder.encode(book)).textCacheFingerprint, book.textCacheFingerprint)

        row["textCacheFingerprint"] = "garbage"
        let damaged = try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(damaged.textCacheFingerprint)
        XCTAssertEqual(damaged.title, book.title)
    }

    // MARK: - Merging Into the Latest State

    /// The acceptance scenario of TODO S05. An analysis starts on the book as
    /// it was. Meanwhile the user adds a bookmark, saves a reading position,
    /// edits the title, opens the book, and changes its settings through the
    /// library, and all of it reaches the disk. Released afterwards, the
    /// analysis lands on that newer state: reloaded, the package has every
    /// newer field, the analysis's own fields, and its index.
    @MainActor
    func testAnalysisReleasedAfterNewerWritesReachedTheDiskKeepsEveryNewerField() throws {
        let original = try makePackage(title: "Started Long Ago")
        let analysis = try analyze(original)
        let model = makeModel(with: [original])

        makeNewerWrites(to: original, through: model)
        // Each save is the whole row, so once the last one's snapshot is on
        // disk the record holds every change and nothing is left waiting.
        waitForRecord(of: original, "the newer writes never reached the disk") {
            $0.state.lastPlaybackStopped == Self.playbackStop
        }
        let flushed = try BookInfo.load(from: original.tmbDirectory)
        XCTAssertEqual(flushed.metadata.title, "Retitled Meanwhile", "the newer writes reached the disk first")

        let committed = try XCTUnwrap(try LibraryPersistenceService.saveContentAnalysis(
            for: analysis.book, index: analysis.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))

        let reloaded = try BookInfo.load(from: original.tmbDirectory)
        assertNewerWritesSurvived(in: reloaded)
        XCTAssertEqual(reloaded.contentIndex, analysis.index)
        XCTAssertEqual(reloaded.state.contentAnalysisFields, analysis.book.contentAnalysisFields)
        XCTAssertEqual(reloaded.state.revision, try XCTUnwrap(flushed.state.revision) + 1)
        XCTAssertEqual(committed.title, "Retitled Meanwhile", "the result describes what was written")
        XCTAssertEqual(committed.contentAnalysisFields, analysis.book.contentAnalysisFields)
    }

    /// The same writes still waiting in the debounce when the analysis is
    /// released are merged with it and written at once, not lost; the
    /// debounce then writes nothing more.
    @MainActor
    func testAnalysisMergesIntoNewerWritesStillWaiting() throws {
        let original = try makePackage(title: "Saved Moments Ago")
        let analysis = try analyze(original)
        let model = makeModel(with: [original])

        makeNewerWrites(to: original, through: model)
        try LibraryPersistenceService.saveContentAnalysis(
            for: analysis.book, index: analysis.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )

        let merged = try BookInfo.load(from: original.tmbDirectory)
        assertNewerWritesSurvived(in: merged)
        XCTAssertEqual(merged.contentIndex, analysis.index)
        XCTAssertEqual(merged.state.contentAnalysisFields, analysis.book.contentAnalysisFields)

        waitPastLibrarySaveDebounce()
        XCTAssertEqual(try revision(of: original), merged.state.revision, "the merged snapshot is not written again")
    }

    /// When the merged record cannot be written, the analysis fails with
    /// the error, and the newer state waiting to be saved is not lost with
    /// it: its own debounce, or the quit flush, still writes it.
    ///
    /// The merged write fails because the index holds a duration that is
    /// not a number, which JSON cannot hold. That fails this write alone,
    /// so the outcome is the same whenever the waiting save's debounce
    /// fires; a read-only package would also fail that save if a busy
    /// machine delayed the test past the debounce.
    func testFailedAnalysisWriteKeepsTheWaitingSnapshot() throws {
        let book = try makePackage(title: "Unwritable Result")
        var unwritable = try analyze(book)
        unwritable.index.totalAudioDuration = .nan
        var newer = book
        newer.manualSortOrder = 7
        LibraryPersistenceService.saveBookInfo(for: newer)

        XCTAssertThrowsError(try LibraryPersistenceService.saveContentAnalysis(
            for: unwritable.book, index: unwritable.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.manualSortOrder, 7)
        XCTAssertNil(record.contentIndex)
    }

    /// A book rebuilt from its record has every field it was saved with,
    /// placed where the caller found its package.
    func testBookRebuiltFromItsRecordHasEveryField() {
        let book = Self.bookWithEveryFieldSet(seed: 5)

        let rebuilt = Book(
            record: book.makeBookInfo(),
            filePath: book.filePath,
            folderPath: book.folderPath,
            tmbDirectoryName: book.tmbDirectoryName
        )

        XCTAssertEqual(rebuilt, book)
    }

    // MARK: - Dropping Stale Results

    /// An analysis of a source that has since been replaced (the library
    /// now records another hash) is dropped: the record is left exactly as
    /// it was, and one log line names the book and the change.
    func testAnalysisOfAReplacedSourceIsDroppedAndLogged() throws {
        let original = try makePackage(title: "Replaced Source")
        let stale = try analyze(original)
        let replaced = try replaceSource(of: original, with: "# Second Edition\n\nOne two three four five six.")
        let before = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: original.tmbDirectory))

        let committed = try LibraryPersistenceService.saveContentAnalysis(
            for: stale.book, index: stale.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )

        XCTAssertNil(committed)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: original.tmbDirectory)), before)
        let lines = droppedLines(for: original)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("\"Replaced Source\"") == true, "\(lines)")
        XCTAssertTrue(
            lines.first?.contains("MD5 \(original.md5Hash) is now \(replaced.md5Hash)") == true,
            "\(lines)"
        )
    }

    /// A book moved to another folder while it was analyzed lives in another
    /// package, so a result for the old one is dropped and its newer state,
    /// still waiting to be saved, is written as it is.
    @MainActor
    func testAnalysisOfABookMovedMeanwhileIsDropped() throws {
        let original = try makePackage(title: "Moved Meanwhile")
        let stale = try analyze(original)
        let model = makeModel(with: [original])
        let destination = "Analysis Merge Destination \(UUID().uuidString.prefix(8))"
        createdDirectories.append(TextMouthPaths.libraryDir.appendingPathComponent(destination, isDirectory: true))
        let move = outcome { await model.moveBooksReturningOutcome([original], toFolder: destination) }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        let moved = try XCTUnwrap(model.bookByID(original.id))
        XCTAssertEqual(moved.folderPath, destination)
        model.persistReadingPosition(bookID: original.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 5))

        XCTAssertNil(try LibraryPersistenceService.saveContentAnalysis(
            for: stale.book, index: stale.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: moved.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 5)
        XCTAssertNil(record.contentIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.tmbDirectory.path), "no package is recreated")
        XCTAssertTrue(droppedLines(for: original).first?.contains("its source file moved") == true)
    }

    /// A package whose record names another book, as a legacy package
    /// shared by two books can, never takes this book's result.
    func testAnalysisOfAPackageHoldingAnotherBooksRecordIsDropped() throws {
        let book = try makePackage(title: "Shares A Package")
        let analysis = try analyze(book)
        var other = Self.bookWithEveryFieldSet(seed: 6)
        other.folderPath = book.folderPath
        other.tmbDirectoryName = book.tmbDirectoryName
        try other.makeBookInfo().save(to: book.tmbDirectory)

        XCTAssertNil(try LibraryPersistenceService.saveContentAnalysis(
            for: analysis.book, index: analysis.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.metadata.bookID, other.id)
        XCTAssertNil(record.contentIndex)
        XCTAssertTrue(
            droppedLines(for: book).first?.contains("belongs to book \(other.id.uuidString.prefix(8))") == true
        )
    }

    /// Two analyses of one book, one of its first source and one of the
    /// source that replaced it, leave the second source's result whichever
    /// finishes last: the first is dropped as soon as the library records
    /// the replacement.
    func testAnalysesFinishingOutOfOrderLeaveTheLaterSourcesResult() throws {
        for laterFinishesFirst in [true, false] {
            let original = try makePackage(title: "Two Editions")
            let earlier = try analyze(original)
            let replaced = try replaceSource(of: original, with: "# Second Edition\n\nOne two three four five six.")
            let later = try analyze(replaced)
            XCTAssertNotEqual(earlier.index, later.index)

            for result in laterFinishesFirst ? [later, earlier] : [earlier, later] {
                try LibraryPersistenceService.saveContentAnalysis(
                    for: result.book, index: result.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
                )
            }

            let record = try BookInfo.load(from: original.tmbDirectory)
            let order = laterFinishesFirst ? "later first" : "later last"
            XCTAssertEqual(record.metadata.md5Hash, replaced.md5Hash, order)
            XCTAssertEqual(record.contentIndex, later.index, order)
            XCTAssertEqual(record.state.contentAnalysisFields, later.book.contentAnalysisFields, order)
            XCTAssertEqual(droppedLines(for: original).count, 1, order)
        }
    }

    // MARK: - The Library Row

    /// The library row equals its package after a cache batch merges an
    /// analysis, even in the hardest order: the batch commits the analysis,
    /// and before the row hears of it the user changes the book, so the
    /// row's own saves still carry the old analysis fields. The row then
    /// takes only the committed analysis fields and keeps the user's
    /// changes, and the package keeps the analysis and takes the changes.
    ///
    /// The batch starts on the main thread once its books are found off it
    /// (PERF13), so the test holds the main thread only once the batch is at
    /// work on the book, held before it commits anything; released, the
    /// batch commits while the main thread is held.
    @MainActor
    func testLibraryRowEqualsItsPackageAfterACacheBatch() async throws {
        let original = try makePackage(title: "Row After A Batch")
        let model = makeModel(with: [original])
        let finished = expectation(description: "The batch finished")
        let held = holdCacheGeneration(of: original)

        model.extractMissingContentCaches { finished.fulfill() }
        await fulfillment(of: [held.reached], timeout: 10)
        held.gate.signal()
        waitForCommittedAnalysis(of: original)
        makeNewerWrites(to: original, through: model)
        await fulfillment(of: [finished], timeout: 10)
        LibraryPersistenceService.flushPendingSave()

        try assertRowEqualsItsPackage(original, in: model)
    }

    /// The statistics pass hands its result to the row the same way.
    @MainActor
    func testLibraryRowEqualsItsPackageAfterTheStatisticsPass() async throws {
        let original = try makePackage(title: "Row After Statistics")
        let model = makeModel(with: [original])
        XCTAssertTrue(LibraryViewModel.needsContentAnalysis(original))
        let counted = expectation(description: "The row received its statistics")
        let subscription = model.$library
            .first { $0.books.first?.totalWordCount != nil }
            .sink { _ in counted.fulfill() }
        defer { subscription.cancel() }

        model.calculateMissingBookStats()
        waitForCommittedAnalysis(of: original)
        makeNewerWrites(to: original, through: model)
        await fulfillment(of: [counted], timeout: 10)
        LibraryPersistenceService.flushPendingSave()

        try assertRowEqualsItsPackage(original, in: model)
    }

    /// An analysis the reader hands to the library changes the row's
    /// analysis fields and nothing else, and the package records the index
    /// with those same fields.
    @MainActor
    func testReaderAnalysisChangesOnlyTheRowsAnalysisFields() throws {
        let original = try makePackage(title: "Opened In The Reader")
        let model = makeModel(with: [original])
        makeNewerWrites(to: original, through: model)
        let before = try XCTUnwrap(model.bookByID(original.id))
        let analysis = try analyze(original)

        model.updateContentIndex(
            bookID: original.id, index: analysis.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )
        LibraryPersistenceService.flushPendingSave()

        let row = try XCTUnwrap(model.bookByID(original.id))
        XCTAssertTrue(Set(Self.fieldsThatDiffer(before, row)).isSubset(of: Self.analysisFieldNames))
        XCTAssertEqual(row.contentAnalysisFields, analysis.book.contentAnalysisFields)
        XCTAssertEqual(try BookInfo.load(from: original.tmbDirectory).contentIndex, analysis.index)
        try assertRowEqualsItsPackage(original, in: model)
    }

    // MARK: - Invariants Kept

    /// A package retired by Remove from Library Only still takes nothing:
    /// neither an analysis released after the removal, nor a save that a
    /// reader left open queues alongside it. Nothing is logged as stale.
    func testRetiredPackageStillDropsEveryWrite() throws {
        let book = try makePackage(title: "Removed Mid-Analysis")
        let analysis = try analyze(book)
        _ = try LibraryPersistenceService.retirePackage(of: book)

        LibraryPersistenceService.saveBookInfo(for: book)
        XCTAssertNil(try LibraryPersistenceService.saveContentAnalysis(
            for: analysis.book, index: analysis.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))
        LibraryPersistenceService.flushPendingSave()
        waitPastLibrarySaveDebounce()

        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path))
        XCTAssertTrue(droppedLines(for: book).isEmpty)
    }

    /// While library.json writes are suspended because the index could not
    /// be read (TODO S01), an analysis and the newer state it merges with
    /// are still written to the package.
    func testAnalysisIsSavedWhileLibraryIndexWritesAreSuspended() throws {
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        _ = LibraryPersistenceService.load()
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended)
        let book = try makePackage(title: "Analyzed During Recovery")
        let analysis = try analyze(book)
        var newer = book
        newer.manualSortOrder = 3
        LibraryPersistenceService.saveBookInfo(for: newer)

        XCTAssertNotNil(try LibraryPersistenceService.saveContentAnalysis(
            for: analysis.book, index: analysis.index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.contentIndex, analysis.index)
        XCTAssertEqual(record.state.manualSortOrder, 3)
    }

    // MARK: - Saves Without an Index

    /// A library row hears of a committed analysis a moment after the
    /// package does, so a save of the row in between carries the counts and
    /// versions from before the analysis. That save still records the
    /// row's newer reading state, but keeps the stored index together with
    /// the analysis fields measured with it.
    func testSaveWithoutAnIndexKeepsTheStoredAnalysis() throws {
        let row = try makePackage(title: "Lagging Row")
        let index = Self.index(of: "one two three")
        try LibraryPersistenceService.saveContentAnalysis(for: row, index: index, cacheFormatVersion: "9.9.9")

        var lagging = row
        lagging.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 8)
        XCTAssertNil(lagging.totalWordCount, "the row has not heard of the analysis yet")
        LibraryPersistenceService.saveBookInfo(for: lagging)
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: row.tmbDirectory)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 8)
        XCTAssertEqual(record.contentIndex, index)
        XCTAssertEqual(record.state.totalWordCount, 3)
        XCTAssertEqual(record.state.contentIndexVersion, index.version)
        XCTAssertEqual(record.state.cacheFormatVersion, "9.9.9")
    }

    /// A save that carries an index records that index with the saved
    /// book's own analysis fields, which describe it.
    func testSaveWithAnIndexRecordsItsOwnAnalysis() throws {
        let book = try makePackage(title: "Indexed Save")
        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: Self.index(of: "one two three"), cacheFormatVersion: "9.9.9"
        )
        let newer = Self.index(of: "one two three four five")
        var analyzed = book
        analyzed.applyContentAnalysis(newer, cacheFormatVersion: "9.9.10")

        LibraryPersistenceService.saveBookInfo(for: analyzed, contentIndex: newer)
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.contentIndex, newer)
        XCTAssertEqual(record.state.totalWordCount, 5)
        XCTAssertEqual(record.state.cacheFormatVersion, "9.9.10")
    }

    /// Over a record with no index there is no analysis to keep, so a save
    /// without an index records the book's own counts and versions.
    func testSaveOverAnUnindexedRecordRecordsTheBooksOwnFields() throws {
        var book = try makePackage(title: "Never Indexed")
        book.totalWordCount = 12
        book.totalCharacterCount = 60
        book.cacheFormatVersion = "9.9.9"

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertNil(record.contentIndex)
        XCTAssertEqual(record.state.contentAnalysisFields, book.contentAnalysisFields)
    }

    // MARK: - Revisions

    /// Every write of a package record stores one more than the record it
    /// replaces, with an index or without one. A record without a revision,
    /// as earlier versions wrote, counts as 0.
    func testEveryRecordWriteStoresTheNextRevision() throws {
        let book = try makePackage(title: "Counted Writes", writingRecord: false)
        try book.makeBookInfo().save(to: book.tmbDirectory)
        XCTAssertNil(try revision(of: book), "a record from an earlier version has no revision")

        try book.saveBookInfoThrowing()
        XCTAssertEqual(try revision(of: book), 1)
        // One index, made once: an index made again a moment later can carry
        // the next second as its date, and then is not the one saved.
        let index = Self.index(of: "one two")
        try book.saveBookInfoThrowing(contentIndex: index)
        XCTAssertEqual(try revision(of: book), 2)
        try book.saveBookInfoThrowing()
        XCTAssertEqual(try revision(of: book), 3)
        XCTAssertEqual(
            try BookInfo.load(from: book.tmbDirectory).contentIndex,
            index,
            "a save without an index keeps the stored one"
        )
    }

    /// A write numbers from the higher of the stored revision and the
    /// floor, so a record that lost its revision (or was never written)
    /// still gets one above every revision written before it.
    func testRevisionFollowsTheHigherOfTheStoredRevisionAndTheFloor() {
        let book = Self.bookWithEveryFieldSet(seed: 4)
        var storedInfo = book.makeBookInfo()
        storedInfo.state.revision = 9
        let stored = StoredBookRecord(info: storedInfo, keepsContentIndex: false)

        XCTAssertEqual(book.bookInfo(replacing: nil, contentIndex: nil).state.revision, 1)
        XCTAssertEqual(book.bookInfo(replacing: nil, contentIndex: nil, revisionFloor: 7).state.revision, 8)
        XCTAssertEqual(book.bookInfo(replacing: stored, contentIndex: nil, revisionFloor: 7).state.revision, 10)
        XCTAssertEqual(book.bookInfo(replacing: stored, contentIndex: nil, revisionFloor: 12).state.revision, 13)
    }

    /// A revision no record can have (negative, fractional, too large, or
    /// text) is dropped instead of failing the record, whose other fields
    /// still load. A valid one loads unchanged.
    func testUnusableRevisionsDecodeAsNone() throws {
        for value in ["-3", "1.5", "1e30", #""many""#] {
            let state = try Self.decodeState(#""manualSortOrder": 4, "revision": \#(value)"#)
            XCTAssertNil(state.revision, value)
            XCTAssertEqual(state.manualSortOrder, 4, value)
        }
        XCTAssertEqual(try Self.decodeState(#""revision": 41"#).revision, 41)
    }

    /// The revision after the largest integer is that integer, so a
    /// hand-edited record cannot make the next write overflow.
    func testRevisionStopsAtTheLargestInteger() {
        XCTAssertEqual(BookState.revision(after: 0), 1)
        XCTAssertEqual(BookState.revision(after: 41), 42)
        XCTAssertEqual(BookState.revision(after: .max), .max)
    }

    /// Each write through the metadata queue (a debounced save, the quit
    /// flush, and an analysis result) raises the book's revision by one.
    @MainActor
    func testEveryMetadataQueueWriteRaisesTheRevision() throws {
        let book = try makePackage(title: "Queued Revisions")
        XCTAssertEqual(try revision(of: book), 1, "the import's own write")

        LibraryPersistenceService.saveBookInfo(for: book)
        waitForRecord(of: book, "the debounced save never reached the disk") { ($0.state.revision ?? 0) >= 2 }
        XCTAssertEqual(try revision(of: book), 2, "the debounced save")

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try revision(of: book), 3, "the quit flush")

        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: Self.index(of: "one two three"), cacheFormatVersion: nil
        )
        XCTAssertEqual(try revision(of: book), 4, "the analysis result")
    }

    /// The queue numbers its first write of a book from the revision on
    /// disk, as it does after a restart, when it remembers nothing.
    func testMetadataQueueContinuesFromTheRevisionOnDisk() throws {
        let book = try makePackage(title: "Restarted", writingRecord: false)
        var record = book.makeBookInfo()
        record.state.revision = 41
        try record.save(to: book.tmbDirectory)

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try revision(of: book), 42)
    }

    /// A record replaced without a revision (as an earlier version, or a
    /// rewrite of every package, leaves it) does not send the book's
    /// revisions back to 1: the queue continues above its own last write.
    func testMetadataQueueRevisionsNeverFallWhenARecordLosesItsOwn() throws {
        let book = try makePackage(title: "Lost Revision")
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        let written = try XCTUnwrap(try revision(of: book))
        try book.makeBookInfo().save(to: book.tmbDirectory)
        XCTAssertNil(try revision(of: book))

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try revision(of: book), written + 1)
    }

    // MARK: - Fixtures

    /// Creates a real package in a folder of its own, as an import leaves
    /// it: a Markdown source whose unique words give it a unique hash and,
    /// unless `writingRecord` is false, its bookInfo.json. The folder and
    /// everything in it are removed after the test.
    private func makePackage(title: String, writingRecord: Bool = true) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let folder = "Analysis Merge \(UUID().uuidString.prefix(8))"
        createdDirectories.append(TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true))
        let packageName = "AnalysisMerge-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("book.md")
        try "# Opening\n\nThe words of \(title), \(UUID().uuidString).".write(
            to: source, atomically: true, encoding: .utf8
        )
        let book = Book(
            title: title,
            author: "Merge Fixture",
            format: .markdown,
            filePath: source.path,
            md5Hash: try FileImportService.md5Hash(of: source),
            folderPath: folder,
            tmbDirectoryName: packageName,
            cacheFormatVersion: "3.0.3"
        )
        if writingRecord {
            try book.saveBookInfoThrowing()
        }
        return book
    }

    /// The revision of the bookInfo.json in `book`'s package.
    private func revision(of book: Book) throws -> Int? {
        try BookInfo.load(from: book.tmbDirectory).state.revision
    }

    /// Analyzes `book` exactly as a cache batch does: writes its text cache
    /// and returns the index with the book stamped with it, which is what
    /// the batch then commits.
    private func analyze(_ book: Book) throws -> (book: Book, index: BookContentIndex) {
        var analyzed = book
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &analyzed))
        return (analyzed, index)
    }

    /// Replaces `book`'s source file with `text` and records the new hash
    /// through the metadata queue, as the library does when a source
    /// changes (an EPUB metadata edit written back to the file, for one).
    /// Returns the book as the library now has it.
    private func replaceSource(of book: Book, with text: String) throws -> Book {
        try text.write(toFile: book.filePath, atomically: true, encoding: .utf8)
        var replaced = book
        replaced.md5Hash = try FileImportService.md5Hash(of: URL(fileURLWithPath: book.filePath))
        LibraryPersistenceService.saveBookInfo(for: replaced)
        LibraryPersistenceService.flushPendingSave()
        return replaced
    }

    /// A library model listing `books`, without the app's services.
    @MainActor
    private func makeModel(with books: [Book]) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books)
        return model
    }

    /// Changes `book` through the library as a reader would while its
    /// analysis runs: a bookmark, a reading position, a new title, opening
    /// it, its voice, speed, and pitch, a skipped heading, and its playback
    /// times. Each change is saved through the normal debounced path.
    @MainActor
    private func makeNewerWrites(to book: Book, through model: LibraryViewModel) {
        model.addBookmark(bookID: book.id, chapterIndex: 0, characterOffset: 9, label: "Added Meanwhile")
        model.persistReadingPosition(bookID: book.id, position: ReadingPosition(chapterIndex: 0, characterOffset: 9))
        model.updateBookMetadata(
            Book.MetadataEdit(opened: [.title: book.title], saved: [.title: "Retitled Meanwhile"]),
            of: book.id
        )
        model.markBookOpened(book.id)
        model.updateLocalVoiceAndSpeed(bookID: book.id, voiceID: "voice.meanwhile", wpm: 240, pitch: 1.2)
        model.updateSkippedHeadings(bookID: book.id, headings: [Self.skippedMeanwhile])
        // Keep this change last: waits for these writes look for its stop time.
        model.updatePlaybackTimestamps(bookID: book.id, started: Self.playbackStart, stopped: Self.playbackStop)
    }

    /// Asserts that `record` holds every change `makeNewerWrites` made.
    private func assertNewerWritesSurvived(
        in record: BookInfo,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(record.metadata.title, "Retitled Meanwhile", file: file, line: line)
        XCTAssertEqual(record.bookmarks.map(\.label), ["Added Meanwhile"], file: file, line: line)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 9, file: file, line: line)
        XCTAssertNotNil(record.metadata.lastOpened, file: file, line: line)
        XCTAssertFalse(record.state.isNew, file: file, line: line)
        XCTAssertEqual(record.state.localVoiceID, "voice.meanwhile", file: file, line: line)
        XCTAssertEqual(record.state.localWPM, 240, file: file, line: line)
        XCTAssertEqual(record.state.localPitch, 1.2, file: file, line: line)
        XCTAssertEqual(record.state.skippedHeadings, [Self.skippedMeanwhile], file: file, line: line)
        XCTAssertEqual(record.state.skippedHeadingIDs, [Self.skippedMeanwhile.id], file: file, line: line)
        XCTAssertEqual(record.state.lastPlaybackStarted, Self.playbackStart, file: file, line: line)
        XCTAssertEqual(record.state.lastPlaybackStopped, Self.playbackStop, file: file, line: line)
    }

    /// The heading `makeNewerWrites` skips, as a reader saves a skip (T06).
    private static let skippedMeanwhile = SkippedHeading(level: 2, label: "Meanwhile", chapterIndex: 0, characterOffset: 4)

    /// Whole-second times, which bookInfo.json's ISO 8601 dates keep exactly,
    /// for the playback `makeNewerWrites` records.
    private static let playbackStart = Date(timeIntervalSince1970: 1_790_000_000)
    private static let playbackStop = playbackStart.addingTimeInterval(60)

    /// Waits, spinning the main run loop, until the bookInfo.json in `book`'s
    /// package satisfies `condition`, and fails with `message` if it has not
    /// after ten seconds. A debounced save lands half a second after it is
    /// made, and later still on a busy machine, so a test that checks one
    /// waits for it instead of for a fixed time.
    @MainActor
    private func waitForRecord(
        of book: Book,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: (BookInfo) -> Bool
    ) {
        let landed = waitUntil(timeout: 10) { book.storedBookInfo().map(condition) ?? false }
        XCTAssertTrue(landed, message, file: file, line: line)
    }

    /// The debug log's CONTENT_ANALYSIS_DROPPED lines about `book`.
    private func droppedLines(for book: Book) -> [String] {
        debugLogLines(containing: "CONTENT_ANALYSIS_DROPPED: book \(book.id.uuidString.prefix(8))")
    }

    /// An index of one chapter holding `text`.
    private static func index(of text: String) -> BookContentIndex {
        BookContentIndex.build(fromChapters: [Chapter(title: "Chapter", text: text)], format: .markdown)
    }

    /// Decodes a saved book state made of `fields` added to a minimal one,
    /// as someone editing bookInfo.json by hand could leave it.
    private static func decodeState(_ fields: String) throws -> BookState {
        let json = #"{"isNew": false, "tmbDirectoryName": "saved.tmb", \#(fields)}"#
        return try JSONDecoder().decode(BookState.self, from: Data(json.utf8))
    }

    /// A book with every field set, each to a value derived from `seed`, so
    /// books made from two different seeds differ in every field.
    private static func bookWithEveryFieldSet(seed: Int) -> Book {
        let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + seed * 1_000))
        // A skipped heading in step with its ID, as a book keeps both (T06).
        let skipped = SkippedHeading(
            level: 1 + seed % 6, label: "Heading \(seed)", chapterIndex: seed, characterOffset: seed * 7,
            anchor: anchor(seed: seed, at: "heading")
        )
        // A skip that waits (T06's branch D): another level, label, and
        // place than the named one, so the two lists never hold alike.
        let waiting = SkippedHeading(
            level: 1 + (seed + 2) % 6, label: "Waiting \(seed)", chapterIndex: seed + 50, characterOffset: seed * 11,
            anchor: anchor(seed: seed, at: "waiting heading")
        )
        return Book(
            id: UUID(),
            title: "Title \(seed)",
            author: "Author \(seed)",
            format: seed.isMultiple(of: 2) ? .epub : .txt,
            filePath: "/library/book-\(seed).txt",
            md5Hash: "hash-\(seed)",
            folderPath: "Folder \(seed)",
            dateAdded: date,
            lastOpened: date.addingTimeInterval(1),
            readingPosition: ReadingPosition(chapterIndex: seed, characterOffset: seed * 10, anchor: anchor(seed: seed, at: "position")),
            bookmarks: [
                Bookmark(
                    number: seed, chapterIndex: seed, characterOffset: seed, label: "Mark \(seed)", dateCreated: date,
                    anchor: anchor(seed: seed, at: "bookmark")
                )
            ],
            totalWordCount: seed * 100,
            totalCharacterCount: seed * 500,
            tmbDirectoryName: "Package-\(seed).tmb",
            sourceFilePath: "/sources/book-\(seed).txt",
            lastPlaybackStarted: date.addingTimeInterval(2),
            lastPlaybackStopped: date.addingTimeInterval(3),
            localVoiceID: "voice.\(seed)",
            localWPM: Double(200 + seed),
            localPitch: 1 + Double(seed) / 10,
            skippedHeadingIDs: [skipped.id],
            skippedHeadings: [skipped],
            waitingSkippedHeadings: [waiting],
            localEndOfBookBehavior: "behavior-\(seed)",
            localSkipForwardUnit: "forward-\(seed)",
            localSkipBackwardUnit: "backward-\(seed)",
            manualSortOrder: seed,
            audioDuration: TimeInterval(seed * 60),
            audioAlbum: "Album \(seed)",
            audioGenre: "Genre \(seed)",
            audioYear: "\(2000 + seed)",
            epubPublisher: "Publisher \(seed)",
            epubPublicationDate: "Published \(seed)",
            epubISBN: "ISBN \(seed)",
            epubLanguage: "language-\(seed)",
            epubIdentifier: "identifier-\(seed)",
            epubVersion: "version-\(seed)",
            cacheFormatVersion: "cache-\(seed)",
            contentIndexVersion: "index-\(seed)",
            textCacheFingerprint: fingerprint(seed: seed),
            editedText: EditedText(cacheDigest: "cache-\(seed)", takenAt: date.addingTimeInterval(4)),
            pageReaderVersion: "pages-\(seed)",
            metadataReaderVersion: "reader-\(seed)",
            handEdits: Book.HandEdits(
                fields: [Book.MetadataField.allCases[seed % Book.MetadataField.allCases.count]],
                sinceImport: seed.isMultiple(of: 2)
            ),
            feedLink: FeedBookLink(feedID: UUID(), itemID: "item-\(seed)"),
            brailleTable: "table-\(seed).ctb",
            brailleTableVersion: "liblouis-\(seed)",
            brailleFileCode: "code-\(seed)",
            textEncoding: "encoding-\(seed)",
            // Two values only, so books of two seeds differ when one is odd and one even.
            textEncodingSource: seed.isMultiple(of: 2) ? .automatic : .chosen,
            // One case only (`.guessed`), so an even seed leaves it unset: books
            // of an odd and an even seed still differ in it.
            brailleTableOrigin: seed.isMultiple(of: 2) ? nil : .guessed
        )
    }

    /// A saved place's anchor (T06) whose every value derives from `seed`
    /// and names the place it is `at`, so anchors made from two different
    /// seeds differ throughout.
    private static func anchor(seed: Int, at place: String) -> TextAnchor {
        TextAnchor(
            before: "\(place) before \(seed)", after: "\(place) after \(seed)",
            fraction: Double(seed) / 10, measuredIn: "measure-\(seed)", version: seed
        )
    }

    /// A text cache fingerprint whose every value derives from `seed`, so
    /// fingerprints made from two different seeds differ throughout.
    private static func fingerprint(seed: Int) -> TextCacheFingerprint {
        TextCacheFingerprint(
            source: FileFingerprint(
                stamp: FileStamp(byteCount: Int64(seed) * 1_000, modificationTimeNanoseconds: Int64(seed) * 1_000_000_007),
                digest: "source-\(seed)"
            ),
            cache: FileFingerprint(
                stamp: FileStamp(byteCount: Int64(seed) * 2_000, modificationTimeNanoseconds: Int64(seed) * 2_000_000_011),
                digest: "cache-\(seed)"
            )
        )
    }

    /// The names of the `Book` properties an analysis owns.
    private static let analysisFieldNames: Set<String> = [
        "totalWordCount", "totalCharacterCount", "audioDuration", "contentIndexVersion", "cacheFormatVersion",
        "textCacheFingerprint", "editedText", "pageReaderVersion"
    ]

    /// Blocks the main thread, without running its queue, until `book`'s
    /// record holds a committed analysis, so the batch's update of the
    /// library row waits behind whatever the test does next. Fails after
    /// ten seconds.
    @MainActor
    private func waitForCommittedAnalysis(of book: Book, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while book.storedBookInfo()?.contentIndex == nil {
            guard Date() < deadline else {
                return XCTFail("the analysis was never committed", file: file, line: line)
            }
            usleep(10_000)
        }
    }

    /// Asserts that `book`'s row in `model` and its package record the same
    /// value for every field a record keeps, and that both hold the newer
    /// writes and a current analysis.
    @MainActor
    private func assertRowEqualsItsPackage(
        _ book: Book,
        in model: LibraryViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let row = try XCTUnwrap(model.bookByID(book.id), file: file, line: line)
        let record = try BookInfo.load(from: book.tmbDirectory)
        assertNewerWritesSurvived(in: record, file: file, line: line)
        XCTAssertNotNil(record.contentIndex, file: file, line: line)
        XCTAssertEqual(row.cacheFormatVersion, MarkdownCacheService.currentCacheVersion, file: file, line: line)
        XCTAssertNotNil(row.totalWordCount, file: file, line: line)
        XCTAssertEqual(
            try Self.recordedFields(of: row.makeBookInfo()),
            try Self.recordedFields(of: record),
            file: file,
            line: line
        )
    }

    /// Every field of `record` a library row also has, as JSON written the
    /// way bookInfo.json is: without the content index and the revision,
    /// which only a package keeps.
    private static func recordedFields(of record: BookInfo) throws -> NSDictionary {
        var comparable = record
        comparable.contentIndex = nil
        comparable.state.revision = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(comparable)) as? NSDictionary)
    }

    /// The names of `Book`'s stored properties whose values differ between
    /// `a` and `b`.
    private static func fieldsThatDiffer(_ a: Book, _ b: Book) -> [String] {
        zip(a.reflectedFields.children, b.reflectedFields.children).compactMap { left, right in
            String(reflecting: left.value) == String(reflecting: right.value) ? nil : left.label
        }
    }
}
