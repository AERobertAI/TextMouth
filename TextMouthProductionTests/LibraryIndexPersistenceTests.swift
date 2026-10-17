import XCTest
import AppKit
@testable import TextMouth

/// An index that exists but cannot be used must be reported, preserved, and
/// protected, never replaced by an empty library that the startup repair then
/// saves over the user's folders, order, and reading state (TODO S01). Tests
/// stage fixtures in the isolated test root and restore it afterwards.
final class LibraryIndexPersistenceTests: XCTestCase {
    private var sandbox: LibraryIndexSandbox!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - Unreadable Current Index

    func testTruncatedIndexIsPreservedAndNeverWritten() throws {
        try assertUnreadableIndexIsPreserved(.truncated, at: sandbox.indexURL)
    }

    func testIndexWithUnknownFormatIsPreservedAndNeverWritten() throws {
        try assertUnreadableIndexIsPreserved(.unknownFormat, at: sandbox.indexURL)
    }

    func testIndexWithoutReadPermissionIsPreservedAndNeverWritten() throws {
        try assertUnreadableIndexIsPreserved(.unreadable, at: sandbox.indexURL)
    }

    // MARK: - Unreadable Legacy Index

    func testTruncatedLegacyIndexIsPreservedAndNeverDeleted() throws {
        try assertUnreadableIndexIsPreserved(.truncated, at: sandbox.legacyURL)
    }

    func testLegacyIndexWithUnknownFormatIsPreservedAndNeverDeleted() throws {
        try assertUnreadableIndexIsPreserved(.unknownFormat, at: sandbox.legacyURL)
    }

    func testLegacyIndexWithoutReadPermissionIsPreservedAndNeverDeleted() throws {
        try assertUnreadableIndexIsPreserved(.unreadable, at: sandbox.legacyURL)
    }

    // MARK: - Readable and Missing Indexes

    /// Regression: a valid index loads without a copy or a suspension, and
    /// saving what loaded writes back the same index, folders, sort settings,
    /// manual order, and reading state included.
    func testValidIndexRoundTripsUnchanged() throws {
        let original = LibraryIndexSandbox.sampleLibrary()
        let bytes = try sandbox.stageValid(original, at: sandbox.indexURL)

        let loaded = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: sandbox.indexURL), [])
        XCTAssertEqual(loaded.books.map(\.manualSortOrder), original.books.map(\.manualSortOrder))

        LibraryPersistenceService.save(loaded)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(
            try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: sandbox.indexURL)),
            try LibraryIndexSandbox.canonicalJSON(bytes)
        )
    }

    /// An index an older version wrote pretty-printed loads as before, and
    /// is written back compact (PERF15): the same index in fewer bytes, on
    /// one line, which any JSON reader, older versions included, reads the
    /// same.
    func testPrettyPrintedIndexIsWrittenBackCompact() throws {
        let original = LibraryIndexSandbox.sampleLibrary()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let pretty = try encoder.encode(original)
        try pretty.write(to: sandbox.indexURL, options: .atomic)

        let loaded = try XCTUnwrap(LibraryPersistenceService.load().library)
        LibraryPersistenceService.save(loaded)
        LibraryPersistenceService.flushPendingSave()

        let written = try Data(contentsOf: sandbox.indexURL)
        XCTAssertFalse(written.contains(UInt8(ascii: "\n")), "library.json is still pretty-printed")
        XCTAssertLessThan(written.count, pretty.count)
        XCTAssertEqual(try LibraryIndexSandbox.canonicalJSON(written), try LibraryIndexSandbox.canonicalJSON(pretty))
    }

    /// No index at either location is a fresh install, not a failure.
    func testMissingIndexIsAFreshInstall() throws {
        try? FileManager.default.removeItem(at: sandbox.indexURL)
        try? FileManager.default.removeItem(at: sandbox.legacyURL)

        guard case .missing = LibraryPersistenceService.load() else {
            return XCTFail("A missing index must load as .missing")
        }
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: sandbox.indexURL), [])
    }

    /// Relaunching or retrying against the same damaged file keeps one copy.
    func testRepeatedLoadsOfOneDamagedFileKeepOneCopy() throws {
        try sandbox.stage(.truncated, at: sandbox.indexURL)

        let first = try XCTUnwrap(unreadableFailure(from: LibraryPersistenceService.load()))
        let second = try XCTUnwrap(unreadableFailure(from: LibraryPersistenceService.load()))

        XCTAssertNotNil(first.quarantineURL)
        XCTAssertEqual(second.quarantineURL, first.quarantineURL)
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: sandbox.indexURL).count, 1)
    }

    // MARK: - Legacy Migration

    /// A readable legacy index is migrated: the current index is written at
    /// once, not by a debounced save a crash could lose, and only then is the
    /// legacy file retired.
    func testReadableLegacyIndexIsWrittenBeforeTheLegacyFileIsRetired() throws {
        let legacy = LibraryIndexSandbox.sampleLibrary()
        try sandbox.stageValid(legacy, at: sandbox.legacyURL)

        let loaded = try XCTUnwrap(LibraryPersistenceService.load().library)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.indexURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.legacyURL.path))
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(Set(written.books.map(\.id)), Set(loaded.books.map(\.id)))
        XCTAssertTrue(Set(written.books.map(\.id)).isSuperset(of: legacy.books.map(\.id)))
        XCTAssertEqual(written.folders.map(\.fullPath), legacy.folders.map(\.fullPath))
    }

    /// A legacy index that becomes readable while writes are suspended (Try
    /// Again after a legacy failure) loads, but nothing is written and the
    /// legacy file stays until the library model saves after resuming.
    func testLegacyIndexLoadedWhileSuspendedIsNotRetired() throws {
        try sandbox.stage(.truncated, at: sandbox.legacyURL)
        _ = LibraryPersistenceService.load()
        let legacy = LibraryIndexSandbox.sampleLibrary()
        let legacyBytes = try sandbox.stageValid(legacy, at: sandbox.legacyURL)

        let loaded = try XCTUnwrap(LibraryPersistenceService.load().library)

        XCTAssertTrue(Set(loaded.books.map(\.id)).isSuperset(of: legacy.books.map(\.id)))
        XCTAssertEqual(try Data(contentsOf: sandbox.legacyURL), legacyBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.indexURL.path))
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended)
    }

    // MARK: - Leaving Suspension

    /// Quitting from recovery runs the ordinary termination flush, which must
    /// leave the unreadable index exactly as it was.
    @MainActor
    func testTerminationDoesNotWriteWhileSuspended() throws {
        let bytes = try sandbox.stage(.truncated, at: sandbox.indexURL)
        let inode = try LibraryIndexSandbox.inode(of: sandbox.indexURL)
        _ = LibraryPersistenceService.load()
        LibraryPersistenceService.save(LibraryIndexSandbox.sampleLibrary())

        AppDelegate().applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(try LibraryIndexSandbox.inode(of: sandbox.indexURL), inode)
        XCTAssertEqual(try Data(contentsOf: sandbox.indexURL), bytes)
    }

    /// Resuming re-enables writes, and nothing saved during the suspension is
    /// replayed afterwards: only saves made after resuming reach the disk.
    func testResumeEnablesWritesWithoutReplayingSuspendedSaves() throws {
        let damagedBytes = try sandbox.stage(.truncated, at: sandbox.indexURL)
        _ = LibraryPersistenceService.load()
        LibraryPersistenceService.save(LibraryIndexSandbox.sampleLibrary())

        LibraryPersistenceService.resumeIndexWrites()
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(
            try Data(contentsOf: sandbox.indexURL),
            damagedBytes,
            "the snapshot saved while suspended must not be written on resume"
        )

        let resumedSnapshot = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(resumedSnapshot)
        LibraryPersistenceService.flushPendingSave()
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.folders.map(\.fullPath), resumedSnapshot.folders.map(\.fullPath))
    }

    /// Rebuild Library Index writes the replacement, keeps the copy of what it
    /// replaced, and resumes ordinary saves.
    func testReplacingTheUnreadableIndexKeepsItsCopyAndResumesWrites() throws {
        let damagedBytes = try sandbox.stage(.unknownFormat, at: sandbox.indexURL)
        let failure = try XCTUnwrap(unreadableFailure(from: LibraryPersistenceService.load()))
        let replacement = LibraryIndexSandbox.sampleLibrary()

        let keptCopy = try LibraryPersistenceService.replaceUnreadableIndex(with: replacement)

        XCTAssertEqual(keptCopy, failure.quarantineURL, "the copy made at load time is reused")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(keptCopy)), damagedBytes)
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
        let rebuilt = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(rebuilt.books.map(\.id), replacement.books.map(\.id))
    }

    /// Replacing after a legacy failure writes the current index and leaves
    /// the legacy file, the unreadable evidence, where it is.
    func testReplacingAfterALegacyFailureLeavesTheLegacyFile() throws {
        let legacyBytes = try sandbox.stage(.truncated, at: sandbox.legacyURL)
        _ = LibraryPersistenceService.load()
        let replacement = LibraryIndexSandbox.sampleLibrary()

        let keptCopy = try LibraryPersistenceService.replaceUnreadableIndex(with: replacement)

        XCTAssertNil(keptCopy, "there was no current index to replace")
        XCTAssertEqual(try Data(contentsOf: sandbox.legacyURL), legacyBytes)
        let rebuilt = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(rebuilt.books.map(\.id), replacement.books.map(\.id))
    }

    // MARK: - Plain-Language Reasons

    /// Each failure is explained in words a listener can act on.
    func testFailureReasonsAreWrittenInPlainLanguage() throws {
        let reasons: [LibraryIndexDamage: String] = [
            .truncated: "damaged or incomplete",
            .unknownFormat: "books, item 1, format",
            .unreadable: "permission"
        ]
        for (damage, expectedPhrase) in reasons {
            try sandbox.stage(damage, at: sandbox.indexURL)
            let failure = try XCTUnwrap(unreadableFailure(from: LibraryPersistenceService.load()))
            XCTAssertTrue(failure.reason.contains(expectedPhrase), "\(damage): \(failure.reason)")
            LibraryIndexSandbox.makeReadable(sandbox.indexURL)
        }
        XCTAssertEqual(
            LibraryIndexReadFailure.plainLanguageReason(for: CocoaError(.fileReadCorruptFile), byteCount: 0),
            "The file is empty."
        )
    }

    // MARK: - Writing Only What Changed (SavedFile.OnDiskMemory)

    /// The memory of what a file holds: unchanged bytes of a file that is
    /// there are skipped; changed bytes, a file that is gone, a key it has
    /// not seen, and a new data directory are not.
    func testOnDiskMemorySkipsOnlyUnchangedBytesOfAFileThatIsThere() throws {
        let folder = try makeSandboxDirectory("on-disk-memory")
        let file = folder.appendingPathComponent("remembered.json")
        let bytes = Data("first".utf8)
        try bytes.write(to: file)
        var memory = SavedFile.OnDiskMemory<String>()
        memory.startOver(unlessIn: folder)
        XCTAssertFalse(memory.holds(bytes, for: "a", at: file), "nothing is remembered yet")

        memory.remember(bytes, for: "a")
        XCTAssertTrue(memory.holds(bytes, for: "a", at: file))
        XCTAssertFalse(memory.holds(Data("second".utf8), for: "a", at: file), "changed bytes are written")
        XCTAssertFalse(memory.holds(bytes, for: "b", at: file), "another key is another file")

        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(memory.holds(bytes, for: "a", at: file), "a file that is gone is written again")
        try bytes.write(to: file)
        XCTAssertTrue(memory.holds(bytes, for: "a", at: file))

        memory.startOver(unlessIn: folder)
        XCTAssertTrue(memory.holds(bytes, for: "a", at: file), "the same directory keeps the memory")
        memory.forget("a")
        XCTAssertFalse(memory.holds(bytes, for: "a", at: file), "a forgotten file is written")

        memory.remember(bytes, for: "a")
        memory.startOver(unlessIn: folder.appendingPathComponent("elsewhere", isDirectory: true))
        XCTAssertFalse(memory.holds(bytes, for: "a", at: file), "a new directory starts the memory over")
    }

    /// A save of a library whose bytes library.json already holds writes
    /// nothing: the file's modification date, set to the past by the test so
    /// that a rewrite could not hide, is as the test left it.
    func testASaveOfAnUnchangedLibraryWritesNothing() throws {
        let library = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        let past = try backdateIndex()

        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try modificationDate(of: sandbox.indexURL), past, "library.json was written again")
        XCTAssertEqual(
            try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: sandbox.indexURL)),
            try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(library))
        )
    }

    /// A save of a changed library writes it, and a reload sees the change.
    func testASaveOfAChangedLibraryIsWritten() throws {
        var library = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        let past = try backdateIndex()
        let before = try Data(contentsOf: sandbox.indexURL)

        let added = "Added Shelf \(UUID().uuidString.prefix(8))"
        library.folders.append(BookFolder(name: added))
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNotEqual(try modificationDate(of: sandbox.indexURL), past, "the changed library was not written")
        XCTAssertNotEqual(try Data(contentsOf: sandbox.indexURL), before)
        let reloaded = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertTrue(reloaded.folders.contains { $0.name == added })
    }

    /// A library.json that is gone since the last save is written again by
    /// the next save of the same library, as after a deletion outside the app.
    func testADeletedIndexIsWrittenAgainByASaveOfAnUnchangedLibrary() throws {
        let library = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        try FileManager.default.removeItem(at: sandbox.indexURL)

        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(
            try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: sandbox.indexURL)),
            try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(library))
        )
    }

    /// A new data directory starts the memory over: bytes remembered of the
    /// old directory's library.json say nothing about the new one's, so a
    /// file standing there is replaced, however alike the libraries are.
    @MainActor
    func testANewDataDirectoryStartsTheMemoryOver() throws {
        let library = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        let newRoot = try makeCurrentDataDirectory("IndexMemoryRoot")
        let newIndex = newRoot.appendingPathComponent("library.json")
        let stale = Data("not the library".utf8)
        try stale.write(to: newIndex)

        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNotEqual(try Data(contentsOf: newIndex), stale, "the new directory's file was left as it was")
        XCTAssertEqual(
            try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: newIndex)),
            try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(library))
        )
    }

    /// A write that failed is not remembered: the retry of the same library
    /// writes it, over a file that stands there since, and settles the failure.
    @MainActor
    func testAFailedWriteIsNotRememberedSoTheRetryWritesIt() throws {
        let center = cleanSharedFailureCenter()
        let library = LibraryIndexSandbox.sampleLibrary()
        let obstruction = try WriteObstruction.place(at: sandbox.indexURL)
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertTrue(center.hasUnsavedChanges, "the write did not fail")

        // Something else stands where library.json goes now, so only a
        // write replaces it.
        obstruction.clear()
        let stale = Data("not the library".utf8)
        try stale.write(to: sandbox.indexURL)
        _ = recordingAnnouncements { center.retry(.libraryIndex) }

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertNotEqual(try Data(contentsOf: sandbox.indexURL), stale, "the retry did not write")
        XCTAssertEqual(
            try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: sandbox.indexURL)),
            try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(library))
        )
    }

    // MARK: - A Write That Throws Forgets What Was Remembered (REV18c, finding 10)

    /// A throwing error for the write closures below.
    private struct WriteRefused: Error, Equatable {}

    /// A write that succeeds remembers the bytes it wrote, for its key only.
    func testAMemoryRemembersWhatASuccessfulWriteWrote() throws {
        let file = try scratchFile()
        let bytes = Data("written".utf8)
        var memory = SavedFile.OnDiskMemory<String>()

        memory.write(bytes, for: "a") {}

        XCTAssertTrue(memory.holds(bytes, for: "a", at: file))
        XCTAssertFalse(memory.holds(bytes, for: "b", at: file), "another key's file was taken for written")
    }

    /// A write that throws rethrows its own error and leaves the memory
    /// holding neither the older bytes nor the new, while another key's file
    /// is still remembered.
    func testAMemoryForgetsTheOlderBytesWhenAWriteThrows() throws {
        let file = try scratchFile()
        let older = Data("older".utf8)
        let newer = Data("newer".utf8)
        var memory = SavedFile.OnDiskMemory<String>()
        memory.remember(older, for: "a")
        memory.remember(older, for: "b")

        XCTAssertThrowsError(try memory.write(newer, for: "a") { throw WriteRefused() }) { error in
            XCTAssertEqual(error as? WriteRefused, WriteRefused(), "the write's own error was not rethrown")
        }

        XCTAssertFalse(memory.holds(older, for: "a", at: file), "the older bytes are still remembered")
        XCTAssertFalse(memory.holds(newer, for: "a", at: file), "the failed bytes were remembered")
        XCTAssertTrue(memory.holds(older, for: "b", at: file), "another key's failure forgot this key's bytes")
    }

    /// The case the finding names: a write of library B throws (its rename may
    /// still have landed, as on a network volume), so the file's state is
    /// unknown. Saving library A again, as an undo does, must write A and not
    /// skip it as unchanged because A was the last thing remembered.
    @MainActor
    func testASaveAfterAThrowingWriteIsNotSkippedAsUnchanged() throws {
        let center = cleanSharedFailureCenter()
        let libraryA = LibraryIndexSandbox.sampleLibrary()
        let libraryB = Library(folders: [BookFolder(name: "Newer \(UUID().uuidString)")])
        LibraryPersistenceService.save(libraryA)
        LibraryPersistenceService.flushPendingSave()

        // B's write throws.
        let obstruction = try WriteObstruction.place(at: sandbox.indexURL)
        LibraryPersistenceService.save(libraryB)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(center.outstandingFailures().map(\.subject), [.libraryIndex], "the failed write is not listed")

        // The file holds B all the same, as a rename that landed though it
        // reported failure would leave it.
        obstruction.clear()
        try sandbox.stageValid(libraryB, at: sandbox.indexURL)
        LibraryPersistenceService.save(libraryA)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(
            try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: sandbox.indexURL)),
            try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(libraryA)),
            "the undo was skipped and library.json still holds B"
        )
        XCTAssertTrue(center.outstandingFailures().isEmpty, "the write that settled the failure left it listed")
    }

    /// A save skipped because its bytes are the file's still clears the
    /// checkpoint journal when nothing failed before.
    func testASkippedSaveStillClearsTheCheckpointJournal() throws {
        let library = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        try Data("{\"books\":[]}".utf8).write(to: sandbox.checkpointJournalURL)
        let past = try backdateIndex()

        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try modificationDate(of: sandbox.indexURL), past, "library.json was written again")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandbox.checkpointJournalURL.path),
            "the skipped save left the journal"
        )
    }

    /// After a failure that forgot the memory, a save whose bytes equal the
    /// file's writes them instead of skipping, and then clears the journal.
    @MainActor
    func testASaveAfterAThrowingWriteWritesAndThenClearsTheCheckpointJournal() throws {
        _ = cleanSharedFailureCenter()
        let library = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        let obstruction = try WriteObstruction.place(at: sandbox.indexURL)
        LibraryPersistenceService.save(Library(folders: [BookFolder(name: "Never Written \(UUID().uuidString)")]))
        LibraryPersistenceService.flushPendingSave()

        // The file holds this library's bytes again, and a journal waits.
        obstruction.clear()
        try sandbox.stageValid(library, at: sandbox.indexURL)
        try Data("{\"books\":[]}".utf8).write(to: sandbox.checkpointJournalURL)
        let past = try backdateIndex()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNotEqual(try modificationDate(of: sandbox.indexURL), past, "the save after the failure wrote nothing")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandbox.checkpointJournalURL.path),
            "the write left the journal"
        )
    }

    /// A file in this test's scratch folder, which a memory's `holds` finds
    /// there.
    private func scratchFile() throws -> URL {
        let file = try makeSandboxDirectory("OnDiskMemory").appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        return file
    }

    /// The first save after a load of a valid index writes nothing when it
    /// changes nothing, the bytes read being noted as the feed indexes' are.
    func testTheFirstSaveAfterLoadingAValidIndexWritesNothing() throws {
        try sandbox.stageValid(LibraryIndexSandbox.sampleLibrary(), at: sandbox.indexURL)
        let past = try backdateIndex()

        let loaded = try XCTUnwrap(LibraryPersistenceService.load().library)
        LibraryPersistenceService.save(loaded)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try modificationDate(of: sandbox.indexURL), past, "library.json was written again")
    }

    /// An index an older version wrote pretty-printed differs from what is
    /// saved, so the first save writes it back, compact.
    func testAPrettyPrintedIndexIsRewrittenByTheFirstSave() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(LibraryIndexSandbox.sampleLibrary()).write(to: sandbox.indexURL, options: .atomic)
        let past = try backdateIndex()

        let loaded = try XCTUnwrap(LibraryPersistenceService.load().library)
        LibraryPersistenceService.save(loaded)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNotEqual(try modificationDate(of: sandbox.indexURL), past, "the pretty index was not rewritten")
        XCTAssertFalse(try Data(contentsOf: sandbox.indexURL).contains(UInt8(ascii: "\n")))
    }

    /// An index that could not be read is not remembered, so the rebuild
    /// that replaces it writes even the bytes this process wrote before.
    func testAnUnreadableIndexIsReplacedByTheRebuildWhateverWasWrittenBefore() throws {
        let library = LibraryIndexSandbox.sampleLibrary()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        try sandbox.stage(.truncated, of: library, at: sandbox.indexURL)
        XCTAssertNotNil(unreadableFailure(from: LibraryPersistenceService.load()))

        try LibraryPersistenceService.replaceUnreadableIndex(with: library)

        XCTAssertEqual(
            try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: sandbox.indexURL)),
            try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(library))
        )
    }

    /// Equal libraries encode to equal bytes, however their dictionaries
    /// were built, and a library decoded from its bytes encodes to them
    /// again: the skip works only when they do.
    func testEqualLibrariesEncodeToEqualBytes() throws {
        let names = (0..<40).map { "Shelf \($0)" }
        let settings = FolderSortSetting(sortField: .manual, sortAscending: true)
        var forward = Library()
        var backward = Library()
        for name in names { forward.folderSortSettings[name] = settings }
        for name in names.reversed() { backward.folderSortSettings[name] = settings }

        let bytes = try LibraryPersistenceService.encodedIndex(forward)

        XCTAssertEqual(try LibraryPersistenceService.encodedIndex(backward), bytes)
        XCTAssertEqual(try LibraryPersistenceService.encodedIndex(forward), bytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Library.self, from: bytes)
        XCTAssertEqual(try LibraryPersistenceService.encodedIndex(decoded), bytes)
    }

    // MARK: - Helpers

    /// Stages `damage` at `location`, loads, and checks the whole contract:
    /// the result is unreadable and names that file, a verbatim copy sits
    /// beside it, writes are suspended, and neither that file nor the current
    /// index location is written, even by a debounced save plus a flush.
    private func assertUnreadableIndexIsPreserved(
        _ damage: LibraryIndexDamage,
        at location: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bytes = try sandbox.stage(damage, at: location)
        let inode = try LibraryIndexSandbox.inode(of: location)
        let isLegacy = location != sandbox.indexURL

        let failure = try XCTUnwrap(
            unreadableFailure(from: LibraryPersistenceService.load()),
            "\(damage) must load as unreadable", file: file, line: line
        )

        XCTAssertEqual(failure.indexURL.standardizedFileURL, location.standardizedFileURL, file: file, line: line)
        let copy = try XCTUnwrap(failure.quarantineURL, "no copy was preserved", file: file, line: line)
        XCTAssertEqual(
            copy.deletingLastPathComponent().standardizedFileURL,
            location.deletingLastPathComponent().standardizedFileURL,
            "the copy must sit beside the file it preserves", file: file, line: line
        )
        XCTAssertTrue(
            copy.lastPathComponent.hasPrefix("library.json" + LibraryIndexQuarantine.nameMarker),
            file: file, line: line
        )
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended, file: file, line: line)

        // Try every write path: a debounced save allowed to fire, then a flush.
        LibraryPersistenceService.save(LibraryIndexSandbox.sampleLibrary())
        waitPastLibrarySaveDebounce()
        LibraryPersistenceService.save(Library())
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try LibraryIndexSandbox.inode(of: location), inode, "the file was replaced", file: file, line: line)
        if isLegacy {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sandbox.indexURL.path),
                "no current index may be written while the legacy one is unreadable", file: file, line: line
            )
        }
        LibraryIndexSandbox.makeReadable(location)
        XCTAssertEqual(try Data(contentsOf: location), bytes, "the file changed", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: copy), bytes, "the copy is not verbatim", file: file, line: line)
    }

    /// Sets library.json's modification date far in the past and returns it,
    /// so a later write of the file shows as a newer date however quickly it
    /// follows. Clock resolution can never hide a rewrite.
    private func backdateIndex() throws -> Date {
        // Whole seconds, as every file system keeps them.
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: sandbox.indexURL.path)
        return past
    }

    /// When the file at `url` was last modified.
    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    /// The failure carried by an unreadable result, or nil for any other.
    private func unreadableFailure(from result: LibraryLoadResult) -> LibraryIndexReadFailure? {
        if case .unreadable(let failure) = result {
            return failure
        }
        return nil
    }
}
