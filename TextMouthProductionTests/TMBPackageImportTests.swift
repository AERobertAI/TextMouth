import XCTest
@testable import TextMouth

/// Regression coverage for validated adoption of external .tmb packages.
final class TMBPackageImportTests: XCTestCase {
    func testExternalPackageIsCopiedIntoManagedLibrary() throws {
        let external = try makePackage()
        defer { try? FileManager.default.removeItem(at: external) }

        let book = try FileImportService.importTMBPackage(from: external)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        XCTAssertTrue(book.filePath.hasPrefix(TextMouthPaths.libraryDir.path + "/"))
        XCTAssertFalse(book.filePath.hasPrefix(external.path + "/"))
        XCTAssertEqual(book.folderPath, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))

        try FileManager.default.removeItem(at: external)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
    }

    func testPackageWithTraversalFilenameIsRejected() throws {
        let external = try makePackage(originalFileName: "../outside.txt")
        defer { try? FileManager.default.removeItem(at: external) }

        XCTAssertThrowsError(try FileImportService.inspectTMBPackage(at: external))
    }

    func testPackageWithMismatchedContentHashIsRejected() throws {
        let external = try makePackage(metadataHash: "incorrect")
        defer { try? FileManager.default.removeItem(at: external) }

        XCTAssertThrowsError(try FileImportService.inspectTMBPackage(at: external)) { error in
            XCTAssertTrue(error.localizedDescription.contains("hash"))
        }
    }

    func testPackageWithSymlinkedContentIsRejected() throws {
        let external = try makePackage()
        defer { try? FileManager.default.removeItem(at: external) }
        let content = external.appendingPathComponent("book.txt")
        try FileManager.default.removeItem(at: content)
        try FileManager.default.createSymbolicLink(atPath: content.path, withDestinationPath: "/tmp")

        XCTAssertThrowsError(try FileImportService.inspectTMBPackage(at: external))
    }

    func testManagedPackageUsesActualNestedFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedPackage-\(UUID().uuidString)", isDirectory: true)
        let nestedFolder = root
            .appendingPathComponent("Science Fiction", isDirectory: true)
            .appendingPathComponent("Anthologies", isDirectory: true)
        let package = try makePackage(in: nestedFolder)
        defer { try? FileManager.default.removeItem(at: root) }
        let inspection = try FileImportService.inspectTMBPackage(at: package)

        let book = try XCTUnwrap(
            FileImportService.bookFromManagedPackage(
                inspection: inspection,
                packageURL: package,
                libraryDirectory: root
            )
        )

        XCTAssertEqual(book.folderPath, "Science Fiction/Anthologies")
        XCTAssertEqual(book.filePath, package.appendingPathComponent("book.txt").path)
        XCTAssertEqual(book.tmbDirectoryName, package.lastPathComponent)
    }

    func testExternalPackageIsNotTreatedAsManaged() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnrelatedLibrary-\(UUID().uuidString)", isDirectory: true)
        let external = try makePackage()
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: external)
        }
        let inspection = try FileImportService.inspectTMBPackage(at: external)

        XCTAssertNil(
            FileImportService.bookFromManagedPackage(
                inspection: inspection,
                packageURL: external,
                libraryDirectory: library
            )
        )
    }

    func testReconciliationRepairsLocationAndUsesNewerPackagePosition() {
        let id = UUID()
        let oldPosition = ReadingPosition(
            chapterIndex: 0,
            characterOffset: 10,
            globalCharacterOffset: 10
        )
        var newerPosition = ReadingPosition(
            chapterIndex: 2,
            characterOffset: 2_496,
            globalCharacterOffset: 950_157
        )
        newerPosition.lastUpdated = oldPosition.lastUpdated.addingTimeInterval(60)
        let existing = Book(
            id: id,
            title: "Existing Title",
            format: .epub,
            filePath: "/missing/root/Book.tmb/book.epub",
            md5Hash: "same-hash",
            folderPath: "",
            readingPosition: oldPosition,
            tmbDirectoryName: "Book.tmb",
            localWPM: 325
        )
        let managed = Book(
            id: id,
            title: "Package Title",
            format: .epub,
            filePath: "/Library/Science Fiction/Anthologies/Book.tmb/book.epub",
            md5Hash: "same-hash",
            folderPath: "Science Fiction/Anthologies",
            readingPosition: newerPosition,
            tmbDirectoryName: "Book.tmb"
        )

        let repaired = FileImportService.reconciledLibraryBook(
            existing,
            with: managed
        )

        XCTAssertEqual(repaired.folderPath, "Science Fiction/Anthologies")
        XCTAssertEqual(repaired.filePath, managed.filePath)
        XCTAssertEqual(repaired.readingPosition, newerPosition)
        XCTAssertEqual(repaired.localWPM, 325)
        XCTAssertEqual(repaired.title, "Existing Title")
    }

    func testReconciliationPreservesNewerLibraryPosition() {
        let id = UUID()
        var packagePosition = ReadingPosition(characterOffset: 10)
        let libraryPosition = ReadingPosition(characterOffset: 20)
        packagePosition.lastUpdated = libraryPosition.lastUpdated.addingTimeInterval(-60)
        let existing = Book(
            id: id,
            title: "Book",
            format: .txt,
            filePath: "/old/book.txt",
            md5Hash: "hash",
            readingPosition: libraryPosition
        )
        let managed = Book(
            id: id,
            title: "Book",
            format: .txt,
            filePath: "/managed/Book.tmb/book.txt",
            md5Hash: "hash",
            folderPath: "Managed",
            readingPosition: packagePosition,
            tmbDirectoryName: "Book.tmb"
        )

        let repaired = FileImportService.reconciledLibraryBook(
            existing,
            with: managed
        )

        XCTAssertEqual(repaired.readingPosition, libraryPosition)
        XCTAssertEqual(repaired.folderPath, "Managed")
    }

    /// Package-backed navigation defaults repair a legacy library snapshot
    /// without overwriting any explicit unit already present in the library.
    func testReconciliationRestoresMissingLocalSkipUnits() {
        let id = UUID()
        let existing = Book(
            id: id,
            title: "Book",
            format: .txt,
            filePath: "/old/book.txt",
            md5Hash: "hash",
            localSkipBackwardUnit: SkipUnit.seconds10.rawValue
        )
        let managed = Book(
            id: id,
            title: "Book",
            format: .txt,
            filePath: "/managed/Book.tmb/book.txt",
            md5Hash: "hash",
            tmbDirectoryName: "Book.tmb",
            localSkipForwardUnit: SkipUnit.heading.rawValue,
            localSkipBackwardUnit: SkipUnit.paragraph.rawValue
        )

        let repaired = FileImportService.reconciledLibraryBook(existing, with: managed)

        XCTAssertEqual(repaired.localSkipForwardUnit, SkipUnit.heading.rawValue)
        XCTAssertEqual(repaired.localSkipBackwardUnit, SkipUnit.seconds10.rawValue)
        XCTAssertNotEqual(repaired, existing)
    }

    private func makePackage(
        in parent: URL? = nil,
        originalFileName: String = "book.txt",
        metadataHash: String? = nil
    ) throws -> URL {
        let packageParent = parent ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(
            at: packageParent,
            withIntermediateDirectories: true
        )
        let package = packageParent
            .appendingPathComponent("\(UUID().uuidString).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let safeContent = package.appendingPathComponent("book.txt")
        try Data("package content".utf8).write(to: safeContent)
        let hash = try FileImportService.md5Hash(of: safeContent)
        let info = BookInfo(
            metadata: BookMetadata(
                title: "External Book",
                author: "Package Author",
                format: .txt,
                md5Hash: metadataHash ?? hash,
                originalFileName: originalFileName,
                folderPath: "Untrusted/Folder",
                bookID: UUID()
            ),
            state: BookState(tmbDirectoryName: package.lastPathComponent)
        )
        try info.save(to: package)
        return package
    }
}
