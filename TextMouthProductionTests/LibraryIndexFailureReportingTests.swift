import XCTest
@testable import TextMouth

/// A library index write that fails is reported to the failure center with
/// its path and a retry of the same snapshot, never only to the console, and
/// the next index write that succeeds settles it (TODO S09). A folder put
/// where library.json goes makes every write of it fail; the sandbox puts
/// the index back afterwards.
final class LibraryIndexFailureReportingTests: XCTestCase {
    private var sandbox: LibraryIndexSandbox!
    /// The folder standing in place of library.json, while a test has one.
    private var obstruction: WriteObstruction?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // The index must be writable again before the sandbox restores it.
        obstruction?.clear()
        sandbox?.restore()
    }

    /// A debounced save that cannot be written is reported with the index's
    /// path and a retry; the next save that reaches the disk settles it.
    @MainActor
    func testAFailedSaveIsReportedUntilTheNextSaveSucceeds() throws {
        let center = cleanSharedFailureCenter()
        let library = LibraryIndexSandbox.sampleLibrary()
        obstruction = try WriteObstruction.place(at: sandbox.indexURL)

        LibraryPersistenceService.save(library)

        XCTAssertTrue(waitUntil(timeout: 5) { center.hasUnsavedChanges }, "the debounced write was not reported")
        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(center.outstandingFailures().count, 1)
        XCTAssertEqual(failure.subject, .libraryIndex)
        XCTAssertEqual(
            URL(fileURLWithPath: failure.path).standardizedFileURL,
            sandbox.indexURL.standardizedFileURL
        )
        XCTAssertNotNil(failure.retry)

        obstruction?.clear()
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(try writtenIndex(), try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(library)))
    }

    /// The termination flush writes at once and reports a failure before it
    /// returns, so quitting can ask the center straight away.
    @MainActor
    func testAFailedFlushIsReportedBeforeItReturns() throws {
        let center = cleanSharedFailureCenter()
        obstruction = try WriteObstruction.place(at: sandbox.indexURL)

        LibraryPersistenceService.save(LibraryIndexSandbox.sampleLibrary())
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(center.outstandingFailures().map(\.subject), [.libraryIndex])
        XCTAssertTrue(center.hasUnsavedChanges)
    }

    /// Retry writes the very snapshot that failed and settles the failure.
    @MainActor
    func testRetryWritesTheSameLibraryAndSettlesTheFailure() throws {
        let center = cleanSharedFailureCenter()
        let library = LibraryIndexSandbox.sampleLibrary()
        obstruction = try WriteObstruction.place(at: sandbox.indexURL)
        LibraryPersistenceService.save(library)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertTrue(center.hasUnsavedChanges)

        obstruction?.clear()
        try? FileManager.default.removeItem(at: sandbox.indexURL)
        let recorder = recordingAnnouncements { center.retry(.libraryIndex) }

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(try writtenIndex(), try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(library)))
        XCTAssertEqual(recorder.announcements.map(\.message), ["Library changes saved."])
    }

    /// A retry overtaken by a newer index write that succeeded writes
    /// nothing, so the older snapshot never replaces the newer one.
    @MainActor
    func testARetryOvertakenByANewerWriteWritesNothing() throws {
        let center = cleanSharedFailureCenter()
        let older = LibraryIndexSandbox.sampleLibrary()
        let newer = LibraryIndexSandbox.sampleLibrary()
        obstruction = try WriteObstruction.place(at: sandbox.indexURL)
        LibraryPersistenceService.save(older)
        LibraryPersistenceService.flushPendingSave()
        let overtaken = try XCTUnwrap(center.outstandingFailures().first)

        obstruction?.clear()
        LibraryPersistenceService.save(newer)
        LibraryPersistenceService.flushPendingSave()
        overtaken.retry?(overtaken.id)

        XCTAssertEqual(try writtenIndex(), try LibraryIndexSandbox.canonicalJSON(LibraryIndexSandbox.encoded(newer)))
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// A write skipped because the index could not be read is not a failure:
    /// the recovery banner already says library changes are not saved.
    @MainActor
    func testAWriteSkippedWhileTheIndexIsUnreadableIsNotAFailure() throws {
        let center = cleanSharedFailureCenter()
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        _ = LibraryPersistenceService.load()

        LibraryPersistenceService.save(LibraryIndexSandbox.sampleLibrary())
        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(center.outstandingFailures().isEmpty)
    }

    // MARK: - Helpers

    /// library.json as it is on disk, in canonical form.
    private func writtenIndex() throws -> Data {
        try LibraryIndexSandbox.canonicalJSON(Data(contentsOf: sandbox.indexURL))
    }
}
