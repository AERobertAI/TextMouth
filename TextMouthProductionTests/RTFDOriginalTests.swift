import XCTest
@testable import TextMouth

/// The original of an imported RTFD is a folder, and an import never
/// deletes a folder: `FileImportService.deleteOriginalFile(at:)` refuses
/// one. The library used to offer to delete an RTFD's original anyway, and
/// to record the refused deletion as a success. It now never offers, and
/// when "After Importing a Book" would have deleted or asked, it says that
/// the original was kept.
final class RTFDOriginalTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
    }

    // MARK: - What an Import Reports

    /// An import from an RTFD folder says it came from a folder, so its
    /// original may not be deleted.
    func testAnRTFDImportMayNotDeleteItsOriginal() throws {
        let folder = try copyOfFormatSample("rtfd/headings.rtfd")

        let imported = try importedForTest(folder)

        XCTAssertTrue(imported.isFromFolder)
        XCTAssertFalse(imported.mayDeleteOriginal)
    }

    // MARK: - The Library

    /// Whatever the preference says, the library offers no deletion of an
    /// RTFD's original and deletes nothing: the question is never asked and
    /// the folder stays whole.
    @MainActor
    func testNoDeletionIsOfferedForAnRTFD() throws {
        for behavior in [ImportDeleteBehavior.askEachTime, .deleteAfterImport, .keepOriginal] {
            let folder = try copyOfFormatSample("rtfd/headings.rtfd")
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library()
            let imported = try importedForTest(folder)

            withImportDeleteBehavior(behavior) {
                model.completeSingleImportedBook(imported, originalURL: folder)
            }

            XCTAssertTrue(model.library.books.contains { $0.id == imported.book.id }, "\(behavior)")
            XCTAssertTrue(model.importDecisions.isEmpty, "\(behavior)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("TXT.rtf").path), "\(behavior)")
        }
    }

    /// With the preference set to delete or to ask, the reader is told, in
    /// the words of every other kept original, that the original stayed and
    /// why; with the preference to keep, nothing is said, since nothing was
    /// expected.
    @MainActor
    func testTheWordsSayThatAnRTFDsOriginalWasKept() throws {
        let sentence = "The original file was kept: it is a folder, and an import never deletes a folder."
        for (behavior, says) in [
            (ImportDeleteBehavior.deleteAfterImport, true), (.askEachTime, true), (.keepOriginal, false)
        ] {
            let folder = try copyOfFormatSample("rtfd/headings.rtfd")
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library()
            let imported = try importedForTest(folder)

            withImportDeleteBehavior(behavior) {
                model.completeSingleImportedBook(imported, originalURL: folder)
            }

            XCTAssertEqual(model.showError, says, "\(behavior)")
            XCTAssertEqual(model.errorMessage, says ? sentence : nil, "\(behavior)")
            // The book was added, so the alert is no error (review item 11).
            XCTAssertEqual(model.errorTitle, says ? "Book Imported" : nil, "\(behavior)")
        }
    }

    /// The deletion itself keeps refusing a folder.
    @MainActor
    func testTheDeletionStillRefusesTheFolder() throws {
        let folder = try copyOfFormatSample("rtfd/headings.rtfd")

        try FileImportService.deleteOriginalFile(at: folder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("TXT.rtf").path))
    }

    // MARK: - Helpers

    /// Runs `body` with "After Importing a Book" set to `behavior`, and puts
    /// the preference back.
    @MainActor
    private func withImportDeleteBehavior(_ behavior: ImportDeleteBehavior, _ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = behavior
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }
}
