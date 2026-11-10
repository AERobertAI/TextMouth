import XCTest
@testable import TextMouth

/// A library save that fails at the real boundary (TODO Q04; repair S09):
/// the data directory itself refuses the write, the library's own save
/// path reports it to `PersistenceFailureCenter`, and the Library window's
/// banner model, which the banner draws row for row, shows it and retries it.
@MainActor
final class IntegrationPersistenceTests: XCTestCase {
    /// The data directory becomes read-only, as a permissions change or a
    /// volume remounted read-only leaves it, and the user creates a folder.
    /// The folder's directory is made, but the library index that would
    /// list it cannot be written: the banner shows one row naming library
    /// changes and the reason, with Retry, and VoiceOver hears it once.
    /// Retry while the directory is still read-only keeps the row and says
    /// so. Once write permission is back, Retry writes the very library
    /// that failed, the row disappears, and VoiceOver hears that the
    /// library changes were saved.
    ///
    /// Before the repair, a failed index write was only printed. With the
    /// repair's change to `LibraryPersistenceService` reverted (commit
    /// 7d6b179, which still reverts cleanly), this test fails with
    /// "XCTAssertTrue failed - No banner row appeared for the library save
    /// that failed".
    func testReadOnlyDataDirectoryShowsTheFailedSaveUntilRetryWritesIt() throws {
        let folder = makeIntegrationLibraryFolder("Integration Shelf")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let center = cleanSharedFailureCenter()
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let indexBefore = try? Data(contentsOf: sandbox.indexURL)
        // Registered last, so write permission is back before the index and
        // the folder are put back.
        let giveWritePermissionBack = makeReadOnly(TextMouthPaths.root)

        let failing = recordingAnnouncements {
            XCTAssertTrue(model.createFolderReturningOutcome(name: folder.path, parentPath: "").succeeded)
            XCTAssertTrue(
                waitUntil(timeout: 5) { !model.failureCenter.bannerRows.isEmpty },
                "No banner row appeared for the library save that failed; the center holds "
                    + "\(model.failureCenter.outstandingFailures().count) outstanding failures, publishes "
                    + "\(model.failureCenter.failures.count), and has dismissed \(model.failureCenter.dismissedSubsystems)"
            )
        }

        let row = try XCTUnwrap(model.failureCenter.bannerRows.first)
        XCTAssertEqual(model.failureCenter.bannerRows.map(\.subsystem), [.libraryIndex])
        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(
            URL(fileURLWithPath: failure.path).standardizedFileURL,
            sandbox.indexURL.standardizedFileURL
        )
        XCTAssertEqual(row.text, failure.sentence)
        XCTAssertTrue(row.text.hasPrefix("Library changes could not be saved: "), row.text)
        XCTAssertTrue(row.canRetry, "The banner offers no Retry")
        XCTAssertTrue(center.hasUnsavedChanges)
        XCTAssertEqual(failing.announcements.map(\.message), [row.announcement])
        XCTAssertEqual(try? Data(contentsOf: sandbox.indexURL), indexBefore, "The index changed on disk")

        // Retry while the directory is still read-only fails again, and says so.
        let stillFailing = recordingAnnouncements { center.retry(.libraryIndex) }
        XCTAssertEqual(model.failureCenter.bannerRows.map(\.subsystem), [.libraryIndex])
        XCTAssertEqual(stillFailing.announcements.map(\.message), ["Retry did not succeed. \(row.text)"])

        // Retry once write permission is back writes the library that failed.
        giveWritePermissionBack()
        let retried = recordingAnnouncements { center.retry(.libraryIndex) }

        XCTAssertEqual(model.failureCenter.bannerRows, [], "The banner still shows the failure")
        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(retried.announcements.map(\.message), ["Library changes saved."])
        let saved = try JSONDecoder.libraryIndex.decode(Library.self, from: Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.folders.map(\.fullPath), [folder.path], "The saved index lacks the new folder")
    }
}

private extension JSONDecoder {
    /// A decoder for library.json, whose dates `LibraryPersistenceService`
    /// writes in ISO 8601.
    static var libraryIndex: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
