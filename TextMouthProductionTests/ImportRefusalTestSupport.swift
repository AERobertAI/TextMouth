import XCTest
@testable import TextMouth

/// Checks that an import of a broken book is refused by name and leaves
/// everything as it was, for the tests of untrusted input (audit U17, U20).
extension XCTestCase {
    /// Asserts that importing `source` fails while reading its text, the
    /// failure saying `sentence` after the step, both through
    /// `FileImportService` and through the library's own import, whose alert
    /// reads the whole failure; and that neither leaves a package, published
    /// or staged, adds a row to the library's list, or changes the source's
    /// bytes, the library's import running with the "After Importing a Book"
    /// preference set to delete the original. Both imports go into a library
    /// folder of this call's own, removed when the test ends.
    @MainActor
    func assertImportRefused(
        _ source: URL,
        saying sentence: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let folderPath = "Refused Import \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: source)
        let stagedBefore = try stagedImportPackages()
        let failure = "Could not import “\(source.lastPathComponent)”. Reading its text failed: \(sentence)"

        // The import itself, which names the step it stopped at.
        XCTAssertThrowsError(
            try FileImportService.importFileWithReport(from: source, toFolder: folderPath),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .readingText, file: file, line: line)
            XCTAssertEqual(error.localizedDescription, failure, file: file, line: line)
        }

        // The same import as the library makes it, under a preference that
        // would delete the original after a successful one.
        let config = ConfigService.shared
        let previousBehavior = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = .deleteAfterImport
        defer { config.config.importDeleteBehavior = previousBehavior }
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library()
        library.importSingleFileAsync(from: source, toFolder: folderPath)
        XCTAssertTrue(
            eventually(within: 20) { library.showError },
            "the library never reported the failure",
            file: file,
            line: line
        )
        XCTAssertEqual(library.errorMessage, failure, file: file, line: line)
        XCTAssertNil(library.errorTitle, "a failure's alert is titled Error", file: file, line: line)
        XCTAssertEqual(library.library.books.map(\.title), [], "no row may be added", file: file, line: line)

        XCTAssertEqual(try folderEntries(of: folder), [], "no package may be left in the folder", file: file, line: line)
        XCTAssertEqual(
            try stagedImportPackages().subtracting(stagedBefore),
            [],
            "no staged package may be left",
            file: file,
            line: line
        )
        XCTAssertEqual(try Data(contentsOf: source), original, "the source must be unchanged", file: file, line: line)
    }

    /// Every name in `folder`, hidden ones included; none when the folder is
    /// not there, as an import that failed before making it leaves it.
    private func folderEntries(of folder: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// The staged packages in this Mac's Import Staging folder, where an
    /// import builds a book's package before publishing it in the library;
    /// none when the folder is not there. Tests that refuse an import for
    /// another reason than its text compare it before and after.
    func stagedImportPackages() throws -> Set<String> {
        try folderEntries(of: MachineLocalPaths.importStaging).filter(ImportStaging.isStagedPackageName)
    }
}
