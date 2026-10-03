import XCTest
@testable import TextMouth

/// An import decision taken at the real boundary (TODO Q04; repairs I06 and
/// S02): a file chosen with Open Book... goes through the library's own
/// import queue and `FileImportService.importFileWithReport`, and the
/// library's alert, its rows, and the library folder show what the user
/// would find.
@MainActor
final class IntegrationImportTests: XCTestCase {
    /// A download of a real EPUB cut off halfway is chosen to import into a
    /// library folder. The import builds the book in a hidden staged package,
    /// fails while reading its text, and leaves everything as it was: the
    /// alert names the file and the failed step, no row is added, the folder
    /// holds neither a package nor the staged copy, the original keeps its
    /// bytes, and nothing offers to delete it.
    ///
    /// A failure at "Reading its text" proves the staged package existed:
    /// that step runs only inside it, after the file was copied there. The
    /// folder's listing includes hidden names, so a staged package left
    /// behind would show.
    ///
    /// Before the repairs, an EPUB whose text could not be read was only
    /// logged and published anyway. With that decision restored in
    /// `FileImportService.readableContent` (the original commits no longer
    /// revert cleanly), this test fails first with "XCTAssertTrue failed -
    /// A row was added for a book that cannot be read", then finds the
    /// published package in the folder and no failure shown.
    func testDamagedEPUBChosenToImportLeavesNoBookAndNoStagedCopy() throws {
        let folder = makeIntegrationLibraryFolder("Integration Import")
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let epub = try makeTruncatedEPUB()
        let originalBytes = try Data(contentsOf: epub)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        importAskingAboutOriginals {
            model.importFiles(urls: [epub], toFolder: folder.path)
            // Either outcome ends the wait: the failure the repairs report,
            // or the row an import without them adds.
            XCTAssertTrue(
                waitUntil(timeout: 8) { model.showError || !model.library.books.isEmpty },
                "The import never finished"
            )
        }

        XCTAssertTrue(model.library.books.isEmpty, "A row was added for a book that cannot be read")
        XCTAssertEqual(try folder.entries(), [], "The import left a package or its staged copy behind")
        XCTAssertTrue(model.showError, "The failure was not shown")
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(
            message.hasPrefix("Could not import “\(epub.lastPathComponent)”. Reading its text failed: "),
            message
        )
        XCTAssertEqual(model.importProgressMessage, "", "The import progress is still shown")
        XCTAssertEqual(try Data(contentsOf: epub), originalBytes, "The original file changed")
        XCTAssertTrue(model.importDecisions.isEmpty, "Deleting the original was offered")
    }

    // MARK: - Fixture

    /// The bundled Alice EPUB cut off halfway through, as an interrupted
    /// download leaves it, in a folder of this test's own outside the
    /// library. Its archive directory is missing, so nothing in it can be
    /// read, although its name and first bytes are an EPUB's.
    private func makeTruncatedEPUB() throws -> URL {
        let sources = try makeSandboxDirectory("IntegrationImportSources")
        let epub = sources.appendingPathComponent("Rabbit Hole \(UUID().uuidString.prefix(8)).epub")
        let whole = try Data(contentsOf: requireFile("alice.epub"))
        try whole.prefix(whole.count / 2).write(to: epub)
        return epub
    }

    /// Runs `body` with "After Importing a Book" set to ask each time, then
    /// puts back the preference it found. Asking is the setting under which
    /// a book wrongly added gives itself away, by offering to delete its
    /// original, and under which no import ever deletes a file, so even a
    /// regression cannot touch the original.
    private func importAskingAboutOriginals(_ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = .askEachTime
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }
}
