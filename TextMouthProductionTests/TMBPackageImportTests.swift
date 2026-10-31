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

    /// A package whose own folder cannot be written to, as a locked folder
    /// can be, is imported all the same, and left exactly as it was: the
    /// import stages a package of its own and copies the source's items
    /// into it. Until October 10, 2026 it staged a copy of the whole
    /// folder, which kept the folder's read-only permissions, so the book's
    /// text cache and record could not be written into it (REV13).
    func testAPackageWhoseFolderCannotBeWrittenToIsImported() throws {
        let external = try makeStatefulPackage()
        let before = try snapshot(of: external.url)
        XCTAssertEqual(chmod(external.url.path, 0o555), 0)
        // Before the package's own removal, which needs the folder writable.
        addTeardownBlock { chmod(external.url.path, 0o755) }

        let book = try FileImportService.importTMBPackageWithReport(from: external.url).book
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        XCTAssertEqual(book.id, external.bookID)
        XCTAssertNotNil(try BookInfo.load(from: book.tmbDirectory).contentIndex)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: book.tmbDirectory.path))
        XCTAssertEqual(try snapshot(of: external.url), before)
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

    /// A copy of a duplicate's package, sent to the Trash by Cancel or by
    /// the launch's discard while its question waited, still holds the
    /// marker saying it waits for an answer (`DuplicateQuestionMarker`).
    /// Imported again, the published package holds no marker, so no
    /// adoption passes it over and no launch discards it; the source keeps
    /// its own.
    func testDuplicateQuestionMarkerTheSourceCarriesIsClearedBeforePublishing() throws {
        let external = try makeStatefulPackage()
        try DuplicateQuestionMarker.write(into: external.url)

        let book = try FileImportService.importTMBPackageWithReport(from: external.url).book
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        XCTAssertFalse(DuplicateQuestionMarker.isHeld(by: book.tmbDirectory))
        XCTAssertTrue(DuplicateQuestionMarker.isHeld(by: external.url))
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
        // The book was added, so the alert is no error (review item 11).
        XCTAssertEqual(model.errorTitle, "Book Imported")

        model.showError = false
        model.errorMessage = nil
        let complete = Book(title: "Complete", format: .txt, filePath: "/tmp/complete.txt", md5Hash: UUID().uuidString)
        model.completePackageImport(ImportedBook(book: complete), openAfterImport: false)
        XCTAssertEqual(model.library.books.map(\.id), [partial.id, complete.id])
        XCTAssertFalse(model.showError)
    }

    // MARK: - Choosing a Package in Open Book…

    /// A package chosen in the Open Book… panel, which offers packages, is
    /// opened as the book it holds, as from Finder, instead of refused as
    /// an unsupported format ("Unsupported file format: .tmb"): the library
    /// lists its book, no error is set, and the book opens (recorded here in
    /// place of a reader window).
    @MainActor
    func testAPackageChosenInOpenBookIsOpenedAsItsBook() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        let package = try makeStatefulPackage()
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let opened = OpenedBooks(recordingFor: model)

        model.importFiles(urls: [package.url], toFolder: "")
        drainImports(of: model)

        let book = try XCTUnwrap(model.library.books.first, model.errorMessage ?? "no book was added")
        // The copy the import made in the library goes when the test ends.
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        XCTAssertEqual(model.library.books.map(\.id), [package.bookID])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.showError)
        XCTAssertEqual(opened.ids, [package.bookID])
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

    // MARK: - Text Changed with Edit Text (B12)

    /// A package whose content.md holds an edit the user took with Edit Text,
    /// opened from Finder while the library holds nothing of its book (a
    /// backup, another Mac's copy, a book deleted since), imports with the
    /// edit: the published content.md is the edited text byte for byte, and
    /// the book and its record keep the record of the edit with the
    /// fingerprints that describe it, so later re-reads keep it too. Until
    /// October 30, 2026 such an import failed while reading the text, with
    /// the sentence an automatic re-read says when it keeps an edit
    /// (`EditedTextKept`).
    func testAPackageHoldingATakenEditImportsWithTheEdit() throws {
        let external = try makeEditedPackageOutsideTheLibrary()

        let imported = try FileImportService.importTMBPackageWithReport(from: external.url)
        let book = imported.book
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        XCTAssertEqual(book.id, external.book.id)
        XCTAssertEqual(book.tmbDirectory.deletingLastPathComponent().path, TextMouthPaths.libraryDir.path)
        XCTAssertEqual(
            try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)),
            external.edited,
            "the book's file was read over the edit"
        )
        let digest = FingerprintHasher.md5.digestOfData(external.edited)
        XCTAssertEqual(book.editedText?.cacheDigest, digest)
        XCTAssertEqual(book.textCacheFingerprint?.cache.digest, digest)
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.editedText?.cacheDigest, digest)
        XCTAssertEqual(record.state.textCacheFingerprint?.cache.digest, digest)
        XCTAssertTrue(BookTextEditSessions.holdsTakenEdit(book, access: .live), "a later re-read would not keep the edit")
        XCTAssertTrue(imported.report.isComplete)
        XCTAssertEqual(try stagedNamesInLibrary(), [])
    }

    /// A fresh file's import never meets the path that keeps an edit (B12):
    /// its book records no edit, and its newly staged package holds no
    /// record and no content.md, so its text is read from its file.
    /// content.md is exactly what reading the file writes, the cache is
    /// stamped current with the fingerprints of the file and of that text,
    /// no edit is recorded, and no TEXT_EDIT_KEPT line is logged for it.
    func testAFreshFilesImportReadsItsTextFromItsFile() throws {
        let file = try makeSandboxDirectory("Fresh Import")
            .appendingPathComponent("Valve Cores \(UUID().uuidString.prefix(8)).md")
        try Data("Unscrew the core with the tool on the valve cap.\n".utf8).write(to: file)

        let imported = try FileImportService.importFileWithReport(from: file)
        let book = imported.book
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        let cache = try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
        XCTAssertEqual(cache, try MarkdownCacheService.extractedText(for: book, includesPages: true)?.bytes)
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(book.textCacheFingerprint?.cache.digest, FingerprintHasher.md5.digestOfData(cache))
        XCTAssertEqual(book.textCacheFingerprint?.source.digest, try FileImportService.md5Hash(of: book.bookFileURL))
        XCTAssertNil(book.editedText)
        XCTAssertNil(try BookInfo.load(from: book.tmbDirectory).state.editedText)
        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_KEPT: \(book.title)"), [])
    }

    // MARK: - Fixtures

    /// A package outside the library holding a Markdown book whose text the
    /// user changed with Edit Text, as a backup or another Mac keeps one:
    /// the book is made in a folder of the test root's library, where its
    /// text is cached and edited (`takingTextEdit(of:changing:)`), and its
    /// package is copied out before that folder is removed, as when the book
    /// is deleted, so the library holds nothing of it. The text names a new
    /// UUID, so no other package anywhere holds the same content.
    private func makeEditedPackageOutsideTheLibrary() throws -> (url: URL, book: Book, edited: Data) {
        let folder = "Edited Text \(UUID().uuidString.prefix(8))"
        try TextMouthPaths.ensureLibrarySubfolder(folder)
        let folderURL = TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true)
        // The folder goes once the package is copied out, or when making it
        // fails partway.
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let packageName = "Spoke Tension-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("Spoke Tension.md")
        try Data("# Truing\n\nPluck each spoke and tune it by ear. Notes \(UUID().uuidString).\n".utf8).write(to: file)
        let book = Book(
            title: "Spoke Tension",
            author: "Workshop Notes",
            format: .markdown,
            filePath: file.path,
            md5Hash: try FileImportService.md5Hash(of: file),
            folderPath: folder,
            dateAdded: Date(timeIntervalSince1970: 1_790_000_000),
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        let taken = try takingTextEdit(of: book) { $0.replacingOccurrences(of: "by ear", with: "with a gauge") }

        let copy = try makeSandboxDirectory("Edited Package Backup")
            .appendingPathComponent(packageName, isDirectory: true)
        try FileManager.default.copyItem(at: package, to: copy)
        return (copy, taken.book, taken.edited)
    }

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

    /// Waits until every import `model` has queued so far has run, then
    /// until the main queue has run the work those imports sent it. Each
    /// expectation is fulfilled once; a second fulfilment, were one ever to
    /// come, is let pass rather than abort the test host.
    @MainActor
    private func drainImports(of model: LibraryViewModel) {
        let imported = expectation(description: "the import queue ran everything queued before")
        imported.assertForOverFulfill = false
        model.importOperationQueue.enqueue { imported.fulfill() }
        wait(for: [imported], timeout: 60)
        let mainQueue = expectation(description: "the main queue ran what the imports sent it")
        mainQueue.assertForOverFulfill = false
        DispatchQueue.main.async { mainQueue.fulfill() }
        wait(for: [mainQueue], timeout: 10)
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

// MARK: - A Text Edit Taken (B12)

extension XCTestCase {
    /// Edits the text of `book`, a text book in the test root's library whose
    /// package holds its file and its record, as the user does with Edit
    /// Text: its text cache is written as an import writes it, content.md is
    /// changed by `change`, and the change is taken as the book's text as an
    /// Edit Text session takes a save (`BookTextEditSessions.check`), which
    /// records the edit (B12).
    /// - Returns: The book as its record then holds it, with the edit
    ///   recorded (`Book.editedText`) and fingerprinted, and the edited
    ///   bytes content.md holds.
    func takingTextEdit(of book: Book, changing change: (String) -> String) throws -> (book: Book, edited: Data) {
        var cached = book
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &cached))
        let committed = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: cached, index: index, cacheFormatVersion: cached.cacheFormatVersion
        ))
        let cache = MarkdownCacheService.cacheURL(for: committed)
        let extracted = try Data(contentsOf: cache)
        let edited = Data(change(String(decoding: extracted, as: UTF8.self)).utf8)
        XCTAssertNotEqual(edited, extracted, "the edit changed nothing")

        // The text as the session opened it, then the user's save.
        let baseline = try BookTextEditSessions.baseline(of: committed, access: .live).get()
        try edited.write(to: cache, options: .atomic)
        let readingTexts = ReadingTextCache(folder: try makeSandboxDirectory("Taken Edit Reading Texts"))
        let checked = BookTextEditSessions.check(committed, against: baseline, access: .live, readingTexts: readingTexts)
        var taken: Book?
        if case .adopted(let edit) = checked.found {
            taken = edit.committed
        }
        return (try XCTUnwrap(taken, "Edit Text did not take the edit: \(checked.found)"), edited)
    }
}
