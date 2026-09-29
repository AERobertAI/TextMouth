import XCTest
@testable import TextMouth

/// Covers the one-time startup repair of folder rows that older versions let
/// share one directory, such as `Reports` and `reports` on a case-insensitive
/// volume.
@MainActor
final class FolderDuplicateRepairTests: XCTestCase {
    private let authorDescending = FolderSortSetting(sortField: .author, sortAscending: false)
    private let dateAscending = FolderSortSetting(sortField: .dateAdded, sortAscending: true)
    private let sizeAscending = FolderSortSetting(sortField: .fileSize, sortAscending: true)
    private let manualAscending = FolderSortSetting(sortField: .manual, sortAscending: true)

    /// A book record for model-only tests; `package` names a .tmb directory
    /// so the repair's file-path rewrite can be checked.
    private func book(_ title: String, folder: String, package: String = "") -> Book {
        let filePath = package.isEmpty
            ? "/tmp/\(title).txt"
            : TextMouthPaths.tmbPath(folderPath: folder, tmbName: package)
                .appendingPathComponent("\(title).txt").path
        return Book(
            title: title,
            format: .txt,
            filePath: filePath,
            md5Hash: title,
            folderPath: folder,
            tmbDirectoryName: package
        )
    }

    /// "Reports" with subfolder "Q1", then "Archive", then the legacy
    /// duplicate "reports" with "q1" and "Drafts", holding a book and a sort
    /// setting in each.
    private func duplicatedLibrary() -> Library {
        Library(
            books: [
                book("Kept", folder: "Reports"),
                book("Loose", folder: "reports", package: "Loose.tmb"),
                book("Quarterly", folder: "reports/q1"),
                book("Draft", folder: "reports/Drafts"),
            ],
            folders: [
                BookFolder(name: "Reports"),
                BookFolder(name: "Q1", parentPath: "Reports"),
                BookFolder(name: "Archive"),
                BookFolder(name: "reports"),
                BookFolder(name: "q1", parentPath: "reports"),
                BookFolder(name: "Drafts", parentPath: "reports"),
            ],
            folderSortSettings: [
                "Reports": authorDescending,
                "reports": dateAscending,
                "reports/q1": sizeAscending,
                "reports/Drafts": manualAscending,
                "__recent__": dateAscending,
            ]
        )
    }

    /// On a case-insensitive volume the later duplicate folds into the first
    /// row: books and subfolders move onto its spelling, nested same-named
    /// subfolders merge too, and the survivor's own sort setting wins.
    func testRepairMergesCaseVariantDuplicatesIntoTheFirstFolder() {
        var library = duplicatedLibrary()

        let repair = library.mergeEquivalentFolders(equivalence: .caseInsensitive)

        XCTAssertTrue(repair.changedLibrary)
        XCTAssertEqual(repair.merges, [
            .init(duplicatePath: "reports", survivingPath: "Reports"),
            .init(duplicatePath: "reports/q1", survivingPath: "Reports/Q1"),
        ])
        XCTAssertEqual(
            library.folders.map(\.fullPath),
            ["Reports", "Reports/Q1", "Archive", "Reports/Drafts"]
        )
        XCTAssertEqual(
            library.books.map(\.folderPath),
            ["Reports", "Reports", "Reports/Q1", "Reports/Drafts"]
        )
        XCTAssertEqual(repair.relocatedBookIDs, Array(library.books.dropFirst().map(\.id)))
        XCTAssertEqual(
            library.books[1].filePath,
            TextMouthPaths.tmbPath(folderPath: "Reports", tmbName: "Loose.tmb")
                .appendingPathComponent("Loose.txt").path
        )
        XCTAssertEqual(library.folderSortSettings, [
            "Reports": authorDescending,
            "Reports/Q1": sizeAscending,
            "Reports/Drafts": manualAscending,
            "__recent__": dateAscending,
        ])
    }

    /// A second run finds nothing to merge and leaves the library as it was.
    func testRepairIsIdempotent() {
        var library = duplicatedLibrary()
        XCTAssertTrue(library.mergeEquivalentFolders(equivalence: .caseInsensitive).changedLibrary)
        let repaired = library

        let secondRun = library.mergeEquivalentFolders(equivalence: .caseInsensitive)

        XCTAssertEqual(secondRun, EquivalentFolderRepair())
        XCTAssertEqual(library.folders, repaired.folders)
        XCTAssertEqual(library.books, repaired.books)
        XCTAssertEqual(library.folderSortSettings, repaired.folderSortSettings)
    }

    /// On a case-sensitive volume `Reports` and `reports` are distinct
    /// folders, so the repair leaves every row, book, and setting alone.
    func testRepairLeavesCaseVariantsAloneOnCaseSensitiveVolumes() {
        let original = duplicatedLibrary()
        var library = original

        let repair = library.mergeEquivalentFolders(equivalence: .caseSensitive)

        XCTAssertEqual(repair, EquivalentFolderRepair())
        XCTAssertEqual(library.folders, original.folders)
        XCTAssertEqual(library.books, original.books)
        XCTAssertEqual(library.folderSortSettings, original.folderSortSettings)
    }

    /// Composed and decomposed spellings name one directory on every volume,
    /// so they merge under both policies, and a duplicate's sort setting
    /// fills in when the survivor has none.
    func testRepairMergesNormalizationVariantsUnderBothPolicies() {
        for rule in [FolderPathEquivalence.caseInsensitive, .caseSensitive] {
            let composed = BookFolder(name: "Caf\u{E9}")
            var library = Library(
                books: [book("Menu", folder: "Cafe\u{301}")],
                folders: [composed, BookFolder(name: "Cafe\u{301}")],
                folderSortSettings: ["Cafe\u{301}": sizeAscending]
            )

            let repair = library.mergeEquivalentFolders(equivalence: rule)

            XCTAssertEqual(repair.merges.count, 1)
            XCTAssertEqual(library.folders, [composed])
            XCTAssertTrue(BookFolder.spellingsMatch(library.books[0].folderPath, composed.name))
            XCTAssertEqual(library.sortSetting(for: composed.name), sizeAscending)
        }
    }

    /// The view-model repair keeps both packages where they are on disk and
    /// rewrites the moved book's package record; a second run reports nothing.
    func testViewModelRepairRewritesPackageRecordsWithoutDeletingAnything() throws {
        try XCTSkipIf(
            FolderPathEquivalence.library.isCaseSensitive,
            "Two case variants share one directory only on a case-insensitive volume."
        )
        let token = UUID().uuidString
        let first = "Ledger-\(token)"
        let duplicate = "ledger-\(token)"
        defer {
            try? FileManager.default.removeItem(
                at: TextMouthPaths.libraryDir.appendingPathComponent(first, isDirectory: true)
            )
        }
        let kept = try makeManagedBook(title: "Kept", folderPath: first)
        let moved = try makeManagedBook(title: "Moved", folderPath: duplicate)
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library(
            books: [kept, moved],
            folders: [BookFolder(name: first), BookFolder(name: duplicate)]
        )

        XCTAssertTrue(viewModel.repairEquivalentFolderDuplicates(equivalence: .caseInsensitive))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(viewModel.library.folders.map(\.fullPath), [first])
        let repaired = try XCTUnwrap(viewModel.library.books.first { $0.id == moved.id })
        XCTAssertEqual(repaired.folderPath, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repaired.filePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.filePath))
        XCTAssertEqual(try BookInfo.load(from: repaired.tmbDirectory).metadata.folderPath, first)
        XCTAssertFalse(viewModel.repairEquivalentFolderDuplicates(equivalence: .caseInsensitive))
    }

    /// The repair runs in the existing startup repair path.
    func testStartupRepairPathMergesDuplicates() {
        let token = UUID().uuidString
        let viewModel = LibraryViewModel(initializeServices: false)
        viewModel.library = Library(
            books: [book("Startup-\(token)", folder: "notes-\(token)")],
            folders: [BookFolder(name: "Notes-\(token)"), BookFolder(name: "notes-\(token)")]
        )

        FolderPathEquivalence.withLibraryRule(.caseInsensitive) {
            viewModel.migrateOldBooksIfNeeded()
        }

        XCTAssertEqual(viewModel.library.folders.map(\.fullPath), ["Notes-\(token)"])
        XCTAssertEqual(
            viewModel.library.books.first { $0.title == "Startup-\(token)" }?.folderPath,
            "Notes-\(token)"
        )
    }

    /// Creates a real package with a book file and record in `folderPath`.
    private func makeManagedBook(title: String, folderPath: String) throws -> Book {
        try TextMouthPaths.ensureLibrarySubfolder(folderPath)
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("\(title).txt")
        try Data(title.utf8).write(to: content)
        let book = Book(
            title: title,
            format: .txt,
            filePath: content.path,
            md5Hash: try FileImportService.md5Hash(of: content),
            folderPath: folderPath,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }
}
