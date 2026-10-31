import XCTest
@testable import TextMouth

/// Rebuild Library Index never destroys the only copy of an index (TODO S01,
/// audit U03). Before a rebuilt library.json replaces an unreadable one, the
/// file there is preserved beside it, and when no copy can be made, nothing
/// is replaced (`LibraryPersistenceService.replaceUnreadableIndex(with:)`).
///
/// `LibraryIndexRecoveryTests` and `LibraryIndexQuarantineTests` cover the
/// rebuilds that can preserve the index. These drive the ones that cannot,
/// in a data directory whose folder takes no new item, so neither a copy of
/// the index's bytes nor a hard link to it can be made beside it, and the
/// rebuild after the index vanished, which has nothing left to preserve.
///
/// Fixtures are staged in the isolated test root (`LibraryIndexSandbox`),
/// which the hosted app shares. When a test ends, the folder's permission is
/// put back first (teardown blocks run before `tearDownWithError`), then
/// the index.
final class LibraryIndexRebuildFailureTests: XCTestCase {
    /// Both library index locations as the test found them, put back when
    /// it ends. Optional: tear-down also runs when capturing failed.
    private var sandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        sandbox?.restore()
    }

    // MARK: - No Copy Can Be Made

    /// An index cut short, whose bytes can be read, cannot be copied into a
    /// folder that takes no new file: the rebuild is refused, naming the
    /// index, and the index is left exactly as it was.
    func testARebuildThatCannotCopyTheIndexReplacesNothing() throws {
        try assertRebuildReplacesNothing(damagedBy: .truncated)
    }

    /// An index without read permission, which is preserved by a hard link,
    /// can be neither linked nor copied into a folder that takes no new
    /// item: the rebuild is refused the same way, and replaces nothing.
    func testARebuildThatCannotLinkTheIndexReplacesNothing() throws {
        try assertRebuildReplacesNothing(damagedBy: .unreadable)
    }

    /// Rebuild Library Index, chosen in the recovery sheet when no copy of
    /// the index can be made, says why it rebuilt nothing, in the sentence
    /// VoiceOver announces and the sheet shows as the last attempt. The
    /// library stays in recovery, with its options open, and the index
    /// stays protected and unchanged.
    @MainActor
    func testRebuildLibraryIndexSaysWhyItReplacedNothingAndStaysInRecovery() throws {
        let sandbox = try XCTUnwrap(self.sandbox)
        let damagedBytes = try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        try makeIndexFolderUnwritable()
        model.loadLibraryIndex()
        let recovery = try XCTUnwrap(model.indexRecovery, "the damaged index did not start recovery")
        XCTAssertNil(recovery.failure.quarantineURL, "a copy was made in a folder that takes no new item")

        let outcome = model.rebuildLibraryIndex()

        XCTAssertEqual(
            outcome.message,
            "The library index was not rebuilt. TextMouth could not save a copy of \(sandbox.indexURL.path), "
                + "so it left that file unchanged. Make sure its folder can be written to, then try again."
        )
        guard case .rebuildFailed = outcome else {
            return XCTFail("Expected the rebuild to fail, got \(outcome)")
        }
        XCTAssertNotNil(model.indexRecovery, "recovery ended")
        XCTAssertEqual(model.indexRecovery?.lastAttempt, outcome, "the sheet does not show the last attempt")
        XCTAssertTrue(model.showIndexRecoveryOptions, "the recovery options closed")
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended, "index writes resumed")
        XCTAssertEqual(try Data(contentsOf: sandbox.indexURL), damagedBytes, "the index's bytes changed")
    }

    // MARK: - Nothing to Preserve

    /// When the unreadable index is gone by the time the rebuild runs, there
    /// is nothing left to preserve, and nothing is: the rebuild reports no
    /// copy, makes none, writes the rebuilt index, and resumes index writes.
    /// The copy made when the index failed to load stays as it was.
    func testARebuildAfterTheIndexVanishedPreservesNothingAndWritesTheIndex() throws {
        let sandbox = try XCTUnwrap(self.sandbox)
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        guard case .unreadable(let failure) = LibraryPersistenceService.load() else {
            return XCTFail("The damaged index loaded, or was missing")
        }
        XCTAssertNotNil(failure.quarantineURL, "the failed load made no copy")
        let copiesAfterLoad = LibraryIndexQuarantine.existingCopies(of: sandbox.indexURL)
        try FileManager.default.removeItem(at: sandbox.indexURL)
        let rebuilt = LibraryIndexSandbox.sampleLibrary()

        let preservedCopy = try LibraryPersistenceService.replaceUnreadableIndex(with: rebuilt)

        XCTAssertNil(preservedCopy, "a copy was reported of an index that was not there")
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: sandbox.indexURL), copiesAfterLoad, "the rebuild made a copy")
        XCTAssertEqual(
            try Data(contentsOf: sandbox.indexURL),
            try LibraryIndexSandbox.encoded(rebuilt),
            "the rebuilt index was not written as the library it was given"
        )
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended, "index writes stayed suspended")
    }

    // MARK: - Fixtures

    /// Stages library.json damaged by `damage`, takes away its folder's
    /// write permission, and loads it: the load can make no copy, so index
    /// writes are suspended with none. Then a rebuild must throw
    /// `couldNotPreserve`, naming the index, leave the file as it was (the
    /// same file, holding the same bytes), and keep index writes suspended.
    private func assertRebuildReplacesNothing(
        damagedBy damage: LibraryIndexDamage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sandbox = try XCTUnwrap(self.sandbox)
        let indexURL = sandbox.indexURL
        let damagedBytes = try sandbox.stage(damage, at: indexURL)
        let inode = try LibraryIndexSandbox.inode(of: indexURL)
        try makeIndexFolderUnwritable()
        guard case .unreadable(let failure) = LibraryPersistenceService.load() else {
            return XCTFail("The damaged index loaded, or was missing", file: file, line: line)
        }
        XCTAssertNil(failure.quarantineURL, "a copy was made in a folder that takes no new item", file: file, line: line)
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended, file: file, line: line)

        XCTAssertThrowsError(
            try LibraryPersistenceService.replaceUnreadableIndex(with: LibraryIndexSandbox.sampleLibrary()),
            file: file,
            line: line
        ) { error in
            guard case LibraryIndexRecoveryError.couldNotPreserve(let refused) = error else {
                return XCTFail("Expected the could-not-preserve refusal, received \(error)", file: file, line: line)
            }
            XCTAssertEqual(refused.path, indexURL.path, "the refusal names another file", file: file, line: line)
        }

        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended, "index writes resumed", file: file, line: line)
        XCTAssertEqual(try LibraryIndexSandbox.inode(of: indexURL), inode, "the index was replaced", file: file, line: line)
        // An index staged without read permission is read once it has it back.
        LibraryIndexSandbox.makeReadable(indexURL)
        XCTAssertEqual(try Data(contentsOf: indexURL), damagedBytes, "the index's bytes changed", file: file, line: line)
    }

    /// Takes away the write permission of the folder library.json is in,
    /// the test root, so no item can be added to it: neither a copy of the
    /// index's bytes nor a hard link to it. The folder's own permission is
    /// put back when the test ends, however it ends, before the sandbox
    /// restores the index. The superuser writes where permissions forbid,
    /// so a test host running as the superuser skips the test.
    private func makeIndexFolderUnwritable() throws {
        try XCTSkipIf(getuid() == 0, "the superuser writes where permissions forbid")
        let folder = try XCTUnwrap(sandbox).indexURL.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber, "the folder's permission").uint16Value
        addTeardownBlock { _ = chmod(folder.path, mode_t(mode)) }
        XCTAssertEqual(chmod(folder.path, 0o555), 0, "the folder's permission could not be changed")
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: folder.path), "the folder must really take no new item")
    }
}
