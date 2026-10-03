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

    // MARK: - Staged Package Imports (TODO S02)

    /// An imported package is published once, at its final name in the
    /// library's top level, with its reading position and bookmarks, a text
    /// cache, and a record that reads back with the book's index. Nothing
    /// staged is left beside it.
    func testImportedPackageKeepsItsStateAndPublishesARecordThatReadsBack() throws {
        var position = ReadingPosition(characterOffset: 12, globalCharacterOffset: 12)
        position.lastUpdated = Date(timeIntervalSince1970: 1_790_000_000)
        // Whole seconds, since bookInfo.json stores dates to the second.
        let bookmark = Bookmark(
            number: 1,
            chapterIndex: 0,
            characterOffset: 12,
            label: "Valve stem",
            dateCreated: Date(timeIntervalSince1970: 1_790_000_100)
        )
        let external = try makeStatefulPackage(position: position, bookmarks: [bookmark])

        let imported = try FileImportService.importTMBPackageWithReport(from: external.url)
        let book = imported.book
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        XCTAssertEqual(book.id, external.bookID)
        XCTAssertEqual(book.tmbDirectory.deletingLastPathComponent().path, TextMouthPaths.libraryDir.path)
        XCTAssertFalse(book.tmbDirectoryName.hasPrefix("."))
        XCTAssertEqual(book.readingPosition, position)
        XCTAssertEqual(book.bookmarks, [bookmark])
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory).path))
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.metadata.bookID, book.id)
        XCTAssertEqual(record.state.tmbDirectoryName, book.tmbDirectoryName)
        XCTAssertEqual(record.bookmarks, [bookmark])
        XCTAssertNotNil(record.contentIndex)
        XCTAssertEqual(try stagedNamesInLibrary(), [])
    }

    /// A package that still carries a removal marker (a copy taken of a
    /// removed book's package) is published without it, so the book stays
    /// in the library at the next launch. The source keeps its marker.
    func testRemovalMarkerTheSourceCarriesIsClearedBeforePublishing() throws {
        let external = try makeStatefulPackage()
        let removed = Book(
            id: external.bookID,
            title: "Puncture Repair",
            format: .txt,
            filePath: external.url.appendingPathComponent("Puncture Repair.txt").path,
            md5Hash: "unused"
        )
        try RemovedFromLibraryMarker(book: removed).write(into: external.url)

        let book = try FileImportService.importTMBPackageWithReport(from: external.url).book
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TextMouthPaths.removedFromLibraryMarkerPath(in: book.tmbDirectory).path
        ))
        XCTAssertFalse(RemovedFromLibraryMarker.retires(book))
        var library = Library(books: [book])
        XCTAssertTrue(RemovedFromLibraryMarker.removeRetiredBooks(from: &library).isEmpty)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: external.url).bookID, external.bookID)
    }

    /// A package whose document cannot be read fails while reading its
    /// text: nothing is published or left staged, and the source package is
    /// exactly as it was.
    func testPackageWhoseContentCannotBeReadFailsAndLeavesNothing() throws {
        let external = try makeStatefulPackage(fileName: "Brake Pads.docx", content: Data("not a Word document".utf8))
        let before = try snapshot(of: external.url)

        XCTAssertThrowsError(try FileImportService.importTMBPackageWithReport(from: external.url)) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .readingText)
            XCTAssertEqual((error as? ImportFailure)?.fileName, external.url.lastPathComponent)
        }

        XCTAssertFalse(try libraryHoldsPackage(of: external.bookID))
        XCTAssertEqual(try stagedNamesInLibrary(), [])
        XCTAssertEqual(try snapshot(of: external.url), before)
    }

    /// A package whose record cannot be saved (the disk is full) is not
    /// published, and nothing staged is left.
    func testPackageWhoseRecordCannotBeSavedLeavesNothing() throws {
        let external = try makeStatefulPackage()

        XCTAssertThrowsError(try FileImportService.importTMBPackageWithReport(
            from: external.url,
            observer: { step, _ in
                if step == .savingRecord { throw CocoaError(.fileWriteOutOfSpace) }
            }
        )) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .savingRecord)
        }

        XCTAssertFalse(try libraryHoldsPackage(of: external.bookID))
        XCTAssertEqual(try stagedNamesInLibrary(), [])
    }

    /// Importing a package whose name the library already holds fails
    /// before anything is copied, and the package already there is kept.
    func testPackageAlreadyInTheLibraryUnderItsNameIsNotReplaced() throws {
        let external = try makeStatefulPackage()
        let first = try FileImportService.importTMBPackageWithReport(from: external.url).book
        addTeardownBlock { try? FileManager.default.removeItem(at: first.tmbDirectory) }
        let record = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: first.tmbDirectory))

        XCTAssertThrowsError(try FileImportService.importTMBPackageWithReport(from: external.url)) { error in
            let failure = error as? ImportFailure
            XCTAssertEqual(failure?.step, .preparingPackage)
            guard case TMBPackageImportError.destinationExists(let name)? = failure?.underlying else {
                return XCTFail("Expected destinationExists, got \(String(describing: failure?.underlying))")
            }
            XCTAssertEqual(name, first.tmbDirectoryName)
        }

        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: first.tmbDirectory)), record)
        XCTAssertEqual(try stagedNamesInLibrary(), [])
    }

    /// A package book that is missing chapters is added and its warning
    /// told, instead of its reader window opening over the warning; a
    /// complete one is added without any alert. (Nothing here asks for a
    /// reader window, which the hosted app would really open.)
    @MainActor
    func testPackageBookMissingChaptersIsAnnouncedInsteadOfOpened() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        let partial = Book(title: "Partial", format: .epub, filePath: "/tmp/partial.epub", md5Hash: UUID().uuidString)
        let report = ExtractionReport(
            container: "this EPUB book",
            chapterCount: 3,
            omissions: [ExtractionOmission(chapterNumber: 2, member: "OEBPS/ch02.xhtml", reason: .missingMember)]
        )
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let notOpened = XCTNSNotificationExpectation(name: .openBookWindow)
        notOpened.isInverted = true

        model.completePackageImport(ImportedBook(book: partial, report: report), openAfterImport: true)

        wait(for: [notOpened], timeout: 0.2)
        XCTAssertEqual(model.library.books.map(\.id), [partial.id])
        XCTAssertTrue(model.showError)
        XCTAssertEqual(model.errorMessage, ImportedBook(book: partial, report: report).warning)

        model.showError = false
        model.errorMessage = nil
        let complete = Book(title: "Complete", format: .txt, filePath: "/tmp/complete.txt", md5Hash: UUID().uuidString)
        model.completePackageImport(ImportedBook(book: complete), openAfterImport: false)
        XCTAssertEqual(model.library.books.map(\.id), [partial.id, complete.id])
        XCTAssertFalse(model.showError)
    }

    // MARK: - The Book a Package Record Describes

    /// A book built from a package's record keeps every field the record
    /// holds, its text cache's fingerprints included, exactly as
    /// `Book(record:)` builds it, so the cache of an imported package is not
    /// read for its digests again when the book first opens (finding #17).
    func testBookFromAPackageRecordKeepsItsTextCacheFingerprint() throws {
        let fingerprint = TextCacheFingerprint(
            source: FileFingerprint(
                stamp: FileStamp(byteCount: 61, modificationTimeNanoseconds: 1_790_000_000_123_456_789),
                digest: "8f14e45fceea167a5a36dedd4bea2543"
            ),
            cache: FileFingerprint(
                stamp: FileStamp(byteCount: 64, modificationTimeNanoseconds: 1_790_000_001_000_000_000),
                digest: "c9f0f895fb98ab9159f51fd0297e236d"
            )
        )
        let info = BookInfo(
            metadata: BookMetadata(
                title: "Puncture Repair",
                author: "Workshop Notes",
                format: .txt,
                md5Hash: "45c48cce2e2d7fbdea1afc51c7c6ad26",
                originalFileName: "Puncture Repair.txt"
            ),
            state: BookState(
                readingPosition: ReadingPosition(characterOffset: 12),
                tmbDirectoryName: "Puncture Repair.tmb",
                cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
                textCacheFingerprint: fingerprint
            ),
            bookmarks: []
        )
        let package = TextMouthPaths.libraryDir.appendingPathComponent("Workshop/Puncture Repair.tmb", isDirectory: true)

        let book = FileImportService.bookFromPackageInfo(
            info,
            packageURL: package,
            folderPath: "Workshop",
            tmbName: "Puncture Repair.tmb"
        )

        XCTAssertEqual(book.textCacheFingerprint, fingerprint)
        XCTAssertEqual(book, Book(
            record: info,
            filePath: package.appendingPathComponent("Puncture Repair.txt").path,
            folderPath: "Workshop",
            tmbDirectoryName: "Puncture Repair.tmb"
        ))
    }

    // MARK: - Fixtures

    /// A package outside the library holding one document and a record that
    /// describes it, with `position` and `bookmarks`, removed after the test.
    private func makeStatefulPackage(
        fileName: String = "Puncture Repair.txt",
        content: Data = Data("Find the hole by its hiss, then roughen the rubber around it.".utf8),
        position: ReadingPosition? = nil,
        bookmarks: [Bookmark] = []
    ) throws -> (url: URL, bookID: UUID) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedPackage-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let package = parent.appendingPathComponent("Puncture Repair.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let contentURL = package.appendingPathComponent(fileName)
        try content.write(to: contentURL)
        let bookID = UUID()
        let info = BookInfo(
            metadata: BookMetadata(
                title: "Puncture Repair",
                author: "Workshop Notes",
                format: try XCTUnwrap(BookFormat.detect(from: contentURL)),
                md5Hash: try FileImportService.md5Hash(of: contentURL),
                originalFileName: fileName,
                bookID: bookID
            ),
            state: BookState(readingPosition: position, tmbDirectoryName: package.lastPathComponent),
            bookmarks: bookmarks
        )
        try info.save(to: package)
        return (package, bookID)
    }

    /// Every file in `package` by its path inside it, with its bytes.
    private func snapshot(of package: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: package.path) {
            files[name] = try Data(contentsOf: package.appendingPathComponent(name))
        }
        return files
    }

    /// The staged package names in the library's top level.
    private func stagedNamesInLibrary() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path)
            .filter(ImportStaging.isStagedPackageName)
    }

    /// Whether the library's top level holds a package named for `bookID`.
    private func libraryHoldsPackage(of bookID: UUID) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path)
            .contains { $0.hasSuffix("\(bookID.uuidString.lowercased()).tmb") }
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
