import XCTest
@testable import TextMouth

/// Books recorded before `.tmb` packages existed are moved into packages by
/// the startup repair. Each copy must be proven identical to its original
/// before that original is removed, and nothing already in the library may
/// be overwritten or trusted unchecked (TODO S03).
///
/// Every test works in a sandbox of its own (see `makeSandbox()`): loose
/// files in a scratch directory and packages in a library folder no other
/// test uses, all inside the isolated test root and removed afterwards.
@MainActor
final class LegacyBookMigrationTests: XCTestCase {

    // MARK: - Content Fingerprint

    /// A fingerprint is the file's size and the MD5 hash duplicate detection
    /// uses, and it matches only a file holding exactly the same bytes: a
    /// shorter copy fails on size, and a copy of the same size with a
    /// changed byte fails on the hash.
    func testFingerprintMatchesOnlyAFileWithTheSameBytes() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("original.txt", contents: "Every byte matters.")
        let fingerprint = try ContentFingerprint(of: original)

        XCTAssertEqual(fingerprint.byteCount, 19)
        XCTAssertEqual(fingerprint.md5Hash, try FileImportService.md5Hash(of: original))
        XCTAssertTrue(fingerprint.matchesFile(at: try sandbox.makeFile("copy.txt", contents: "Every byte matters.")))
        XCTAssertFalse(fingerprint.matchesFile(at: try sandbox.makeFile("partial.txt", contents: "Every byte")))
        XCTAssertFalse(fingerprint.matchesFile(at: try sandbox.makeFile("altered.txt", contents: "Every bite matters.")))
        XCTAssertFalse(fingerprint.matchesFile(at: sandbox.scratchDirectory.appendingPathComponent("missing.txt")))
    }

    /// Only a regular file has a fingerprint. A folder is refused before it
    /// is hashed, and a symbolic link is refused rather than followed, so
    /// neither can ever pass as a verified copy.
    func testFolderAndLinkHaveNoFingerprint() throws {
        let sandbox = makeSandbox()
        let target = try sandbox.makeFile("target.txt", contents: "Linked text")
        let folder = sandbox.scratchDirectory.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = sandbox.scratchDirectory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let targetFingerprint = try ContentFingerprint(of: target)

        for item in [folder, link] {
            XCTAssertThrowsError(try ContentFingerprint(of: item), item.lastPathComponent) { error in
                XCTAssertEqual(error as? ContentFingerprintError, .notARegularFile)
            }
            XCTAssertFalse(targetFingerprint.matchesFile(at: item), item.lastPathComponent)
        }
    }

    // MARK: - Moving a Book

    /// With nothing in the way, the book moves into its usual package: a
    /// verified copy, its bookInfo.json, and its text cache, and only then
    /// is the original removed. No hidden in-progress copy is left behind.
    func testBookMovesIntoItsUsualPackageAndTheOriginalIsRemoved() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Chapter one.\n\nIt begins.")
        let book = try sandbox.legacyBook("Fresh Move", original: original)

        let migration = try FileImportService.migrateBookToTMB(book)

        let package = sandbox.usualPackage(for: book)
        XCTAssertEqual(migration.book.tmbDirectoryName, package.lastPathComponent)
        XCTAssertEqual(migration.book.filePath, package.appendingPathComponent("book.txt").path)
        XCTAssertEqual(try text(of: migration.book.bookFileURL), "Chapter one.\n\nIt begins.")
        let info = try BookInfo.load(from: package)
        XCTAssertEqual(info.metadata.bookID, book.id)
        XCTAssertNotNil(info.contentIndex)
        XCTAssertEqual(migration.book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertTrue(migration.removedOriginal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(migration.warnings, [])
        XCTAssertEqual(sandbox.hiddenNames(in: package), [])
    }

    /// An identical copy already in the book's own usual package, as an
    /// interrupted run leaves it, is used as it is rather than copied again,
    /// and the original is removed.
    func testIdenticalCopyInTheUsualPackageIsReusedAndTheOriginalRemoved() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Already copied.")
        let book = try sandbox.legacyBook("Reused Copy", original: original)
        let package = try sandbox.stageUsualPackage(for: book, holding: "Already copied.")
        let copy = package.appendingPathComponent("book.txt")
        let copyInode = try LibraryIndexSandbox.inode(of: copy)

        let migration = try FileImportService.migrateBookToTMB(book)

        XCTAssertEqual(migration.book.tmbDirectoryName, package.lastPathComponent)
        XCTAssertEqual(migration.book.filePath, copy.path)
        XCTAssertEqual(try LibraryIndexSandbox.inode(of: copy), copyInode, "the copy is used as it is")
        XCTAssertEqual(try BookInfo.load(from: package).metadata.bookID, book.id)
        XCTAssertTrue(migration.removedOriginal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(migration.warnings, [])
    }

    /// A different file of the same size under the book's usual package
    /// name is neither overwritten nor trusted (the hash tells them apart).
    /// The book moves into a new package named by the same scheme, and its
    /// original is kept as a recovery copy, with a warning that says where.
    func testDifferentFileUnderTheUsualNameIsKeptAndTheBookMovesToANewPackage() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "The real book.")
        let book = try sandbox.legacyBook("Occupied Name", original: original)
        let occupied = try sandbox.stageUsualPackage(for: book, holding: "A fake volume.")

        let migration = try FileImportService.migrateBookToTMB(book)

        try assertNewPackageName(migration.book.tmbDirectoryName, for: book)
        XCTAssertEqual(try text(of: migration.book.bookFileURL), "The real book.")
        XCTAssertEqual(try BookInfo.load(from: migration.book.tmbDirectory).metadata.bookID, book.id)
        XCTAssertEqual(try text(of: occupied.appendingPathComponent("book.txt")), "A fake volume.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: occupied).path))
        XCTAssertFalse(migration.removedOriginal)
        XCTAssertEqual(try text(of: original), "The real book.")
        XCTAssertEqual(migration.warnings.count, 1)
        XCTAssertTrue(migration.warnings.first?.contains(original.path) == true)
    }

    /// A partial copy that an interrupted run left in the book's own package
    /// is detected rather than trusted: the book moves into a new package
    /// with a complete copy, the partial file is left as it was, and the
    /// original is kept.
    func testPartialCopyFromAnInterruptedRunIsNotTrusted() throws {
        let sandbox = makeSandbox()
        let fullText = String(repeating: "A long book. ", count: 400)
        let original = try sandbox.makeFile("book.txt", contents: fullText)
        let book = try sandbox.legacyBook("Interrupted Copy", original: original)
        let partialText = String(fullText.prefix(1000))
        let package = try sandbox.stageUsualPackage(for: book, holding: partialText)

        let migration = try FileImportService.migrateBookToTMB(book)

        try assertNewPackageName(migration.book.tmbDirectoryName, for: book)
        XCTAssertEqual(try text(of: migration.book.bookFileURL), fullText)
        XCTAssertEqual(try text(of: package.appendingPathComponent("book.txt")), partialText)
        XCTAssertFalse(migration.removedOriginal)
        XCTAssertEqual(try text(of: original), fullText)
    }

    /// A package under the usual name whose bookInfo.json names another book
    /// belongs to that book, even when it holds an identical file. Its
    /// metadata is never overwritten: the book moves into a new package.
    func testAnotherBooksPackageUnderTheUsualNameIsLeftAlone() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Same words, other owner.")
        let book = try sandbox.legacyBook("Shared Name", original: original)
        let package = try sandbox.stageUsualPackage(for: book, holding: "Same words, other owner.")
        let owner = Book(
            title: "Someone Else",
            format: .txt,
            filePath: package.appendingPathComponent("book.txt").path,
            md5Hash: book.md5Hash,
            folderPath: book.folderPath,
            tmbDirectoryName: package.lastPathComponent
        )
        try owner.makeBookInfo().save(to: package)

        let migration = try FileImportService.migrateBookToTMB(book)

        try assertNewPackageName(migration.book.tmbDirectoryName, for: book)
        XCTAssertEqual(try BookInfo.load(from: package).metadata.bookID, owner.id)
        XCTAssertEqual(try BookInfo.load(from: migration.book.tmbDirectory).metadata.bookID, book.id)
        XCTAssertFalse(migration.removedOriginal)
    }

    // MARK: - Refusing to Move

    /// When bookInfo.json cannot be saved (here the package is read-only),
    /// the original stays, nothing that was already in the package is
    /// removed, and the error says what failed.
    func testMetadataWriteFailureKeepsTheOriginalAndThrows() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Keep me.")
        let book = try sandbox.legacyBook("Locked Package", original: original)
        let package = try sandbox.stageUsualPackage(for: book, holding: "Keep me.")
        setPermissions(of: package, to: 0o555, restoringTo: 0o755)

        XCTAssertThrowsError(try FileImportService.migrateBookToTMB(book)) { error in
            guard case LegacyMigrationError.metadataNotSaved = error else {
                return XCTFail("Expected a metadata failure, received \(error)")
            }
        }
        XCTAssertEqual(try text(of: original), "Keep me.")
        XCTAssertEqual(try text(of: package.appendingPathComponent("book.txt")), "Keep me.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: package).path))
    }

    /// A package this migration created is removed again when its
    /// bookInfo.json cannot be saved, so nothing half-made is left behind.
    func testMetadataFailureInANewPackageRemovesThatPackage() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Nothing half-made.")
        let book = try sandbox.legacyBook("Blocked Metadata", original: original)

        XCTAssertThrowsError(
            try FileImportService.migrateBookToTMB(book, copyingWith: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                // A folder where bookInfo.json belongs makes saving it fail.
                try FileManager.default.createDirectory(
                    at: TextMouthPaths.bookInfoPath(in: destination.deletingLastPathComponent()),
                    withIntermediateDirectories: false
                )
            })
        ) { error in
            guard case LegacyMigrationError.metadataNotSaved = error else {
                return XCTFail("Expected a metadata failure, received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.usualPackage(for: book).path))
        XCTAssertEqual(try text(of: original), "Nothing half-made.")
    }

    /// A copy that does not match its original is discarded before anything
    /// uses it: the original stays, and no package is left behind.
    func testCopyThatDoesNotMatchTheOriginalIsDiscarded() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Every byte matters.")
        let book = try sandbox.legacyBook("Bad Copy", original: original)

        XCTAssertThrowsError(
            try FileImportService.migrateBookToTMB(book, copyingWith: { _, destination in
                try Data("Every byte".utf8).write(to: destination)
            })
        ) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .copyDiffers)
        }
        XCTAssertEqual(try text(of: original), "Every byte matters.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.usualPackage(for: book).path))
    }

    /// A copy that fails outright (a full disk, say) also leaves the
    /// original alone and no package behind, and the reason is kept.
    func testCopyFailureKeepsTheOriginal() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Too big for the disk.")
        let book = try sandbox.legacyBook("Failed Copy", original: original)

        XCTAssertThrowsError(
            try FileImportService.migrateBookToTMB(book, copyingWith: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
        ) { error in
            guard case LegacyMigrationError.copyFailed(let reason) = error else {
                return XCTFail("Expected a copy failure, received \(error)")
            }
            XCTAssertEqual(reason, CocoaError(.fileWriteOutOfSpace).localizedDescription)
        }
        XCTAssertEqual(try text(of: original), "Too big for the disk.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.usualPackage(for: book).path))
    }

    /// An original that cannot be read cannot have its copy verified, so it
    /// is kept, nothing is created, and the failure names the file.
    func testUnreadableOriginalIsKeptAndReported() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Unreadable for now.")
        let book = try sandbox.legacyBook("Unreadable Original", original: original)
        setPermissions(of: original, to: 0o000, restoringTo: 0o644)

        XCTAssertThrowsError(try FileImportService.migrateBookToTMB(book)) { error in
            guard case LegacyMigrationError.originalUnreadable(let path, _) = error else {
                return XCTFail("Expected an unreadable original, received \(error)")
            }
            XCTAssertEqual(path, original.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.usualPackage(for: book).path))
        XCTAssertEqual(chmod(original.path, 0o644), 0)
        XCTAssertEqual(try text(of: original), "Unreadable for now.")
    }

    /// A folder where the original should be is not a file whose copy can be
    /// checked, so the book is not moved and the folder is left alone.
    func testFolderInPlaceOfTheOriginalIsNotMoved() throws {
        let sandbox = makeSandbox()
        let folder = sandbox.scratchDirectory.appendingPathComponent("Audio Chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = try sandbox.legacyBook("Folder Original", original: folder, format: .audio, md5Hash: "recorded-hash")

        XCTAssertThrowsError(try FileImportService.migrateBookToTMB(book)) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .originalNotAFile(path: folder.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.usualPackage(for: book).path))
    }

    /// A missing original is reported with its path, and nothing is created.
    func testMissingOriginalIsReported() throws {
        let sandbox = makeSandbox()
        let missing = sandbox.scratchDirectory.appendingPathComponent("gone.txt")
        let book = try sandbox.legacyBook("Missing Original", original: missing, md5Hash: "recorded-hash")

        XCTAssertThrowsError(try FileImportService.migrateBookToTMB(book)) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .originalMissing(path: missing.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.usualPackage(for: book).path))
    }

    // MARK: - Keeping the Original

    /// When the original cannot be removed (a Trash failure, say), the book
    /// has still moved: the original is kept and the warning says where.
    func testOriginalThatCannotBeRemovedIsKeptWithAWarning() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Stays put.")
        let book = try sandbox.legacyBook("Trash Refused", original: original)

        let migration = try FileImportService.migrateBookToTMB(book, removingOriginalWith: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })

        XCTAssertEqual(migration.book.tmbDirectoryName, sandbox.usualPackage(for: book).lastPathComponent)
        XCTAssertFalse(migration.removedOriginal)
        XCTAssertEqual(try text(of: original), "Stays put.")
        XCTAssertEqual(migration.warnings.count, 1)
        XCTAssertTrue(migration.warnings.first?.contains(original.path) == true)
    }

    /// The Trash preference belongs to the main actor. Off the main thread,
    /// the default removal keeps the original and says why, rather than
    /// removing it without knowing what the user wants.
    func testOriginalIsKeptWhenTheTrashPreferenceCannotBeRead() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "No preference, no removal.")
        let outcome = ErrorBox()
        let attempted = expectation(description: "Removal attempted off the main thread")

        DispatchQueue.global().async {
            do {
                try FileImportService.removeMigratedOriginal(at: original)
            } catch {
                outcome.error = error
            }
            attempted.fulfill()
        }
        wait(for: [attempted], timeout: 10)

        XCTAssertEqual(outcome.error as? LegacyMigrationError, .trashPreferenceUnavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    /// A text cache that cannot be built does not undo the move. It is
    /// reported, and the record claims no cache, so the library's cache
    /// pass builds one later.
    func testTextCacheFailureIsReportedAndLeftForTheCachePass() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.epub", contents: "Not really an EPUB archive.")
        let book = try sandbox.legacyBook("Unparsable Book", original: original, format: .epub)

        let migration = try FileImportService.migrateBookToTMB(book)

        XCTAssertEqual(migration.book.tmbDirectoryName, sandbox.usualPackage(for: book).lastPathComponent)
        XCTAssertEqual(try BookInfo.load(from: migration.book.tmbDirectory).metadata.bookID, book.id)
        XCTAssertTrue(migration.removedOriginal)
        XCTAssertNil(migration.book.cacheFormatVersion)
        XCTAssertFalse(MarkdownCacheService.cacheExists(for: migration.book))
        XCTAssertEqual(migration.warnings.count, 1)
    }

    // MARK: - Finishing an Interrupted Move

    /// A run interrupted after removing the original, but before the library
    /// index was saved, leaves a record that still names the original. The
    /// package it finished proves it holds this book (its bookInfo.json
    /// names the book and its copy has the recorded hash), so the record is
    /// repaired instead of the book being reported missing.
    func testMoveInterruptedAfterRemovingTheOriginalIsFinished() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Moved before the crash.")
        let book = try sandbox.legacyBook("Interrupted Move", original: original)
        let package = try sandbox.stageUsualPackage(for: book, holding: "Moved before the crash.")
        try sandbox.saveBookInfo(for: book, in: package)
        try FileManager.default.removeItem(at: original)

        let migration = try FileImportService.migrateBookToTMB(book)

        XCTAssertEqual(migration.book.tmbDirectoryName, package.lastPathComponent)
        XCTAssertEqual(migration.book.filePath, package.appendingPathComponent("book.txt").path)
        XCTAssertEqual(migration.warnings, [])
    }

    /// Without proof a missing original stays missing: a package that names
    /// the book but holds other content is not taken for the book.
    func testMissingOriginalIsNotResolvedByAPackageWithOtherContent() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "The recorded text.")
        let book = try sandbox.legacyBook("Unproven Package", original: original)
        let package = try sandbox.stageUsualPackage(for: book, holding: "Some other text.")
        try sandbox.saveBookInfo(for: book, in: package)
        try FileManager.default.removeItem(at: original)

        XCTAssertThrowsError(try FileImportService.migrateBookToTMB(book)) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .originalMissing(path: original.path))
        }
    }

    /// Matching content is not proof on its own either: a package whose
    /// bookInfo.json names another book belongs to that book.
    func testMissingOriginalIsNotResolvedByAnotherBooksPackage() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("book.txt", contents: "Identical words.")
        let book = try sandbox.legacyBook("Borrowed Package", original: original)
        let package = try sandbox.stageUsualPackage(for: book, holding: "Identical words.")
        let otherBook = try sandbox.legacyBook("Someone Else", original: original)
        try sandbox.saveBookInfo(for: otherBook, in: package)
        try FileManager.default.removeItem(at: original)

        XCTAssertThrowsError(try FileImportService.migrateBookToTMB(book)) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .originalMissing(path: original.path))
        }
        XCTAssertEqual(try BookInfo.load(from: package).metadata.bookID, otherBook.id)
    }

    // MARK: - Originals That Must Stay

    /// A record whose package name was lost looks unmigrated while it still
    /// names the file inside its usual package. The copy found there is the
    /// original itself, so the record is repaired and the file never removed.
    func testFileAlreadyInTheUsualPackageIsNeverRemoved() throws {
        let sandbox = makeSandbox()
        let draft = try sandbox.legacyBook(
            "Lost Package Name",
            original: sandbox.scratchDirectory.appendingPathComponent("book.txt"),
            md5Hash: "draft-hash"
        )
        let package = try sandbox.stageUsualPackage(for: draft, holding: "The only copy.")
        var book = draft
        book.filePath = package.appendingPathComponent("book.txt").path
        book.md5Hash = try FileImportService.md5Hash(of: book.bookFileURL)

        let migration = try FileImportService.migrateBookToTMB(book)

        XCTAssertEqual(migration.book.tmbDirectoryName, package.lastPathComponent)
        XCTAssertEqual(migration.book.filePath, book.filePath)
        XCTAssertFalse(migration.removedOriginal)
        XCTAssertEqual(try text(of: migration.book.bookFileURL), "The only copy.")
        XCTAssertEqual(migration.warnings, [])
    }

    /// Two records reading one stored file each get a verified copy of their
    /// own, and the file is removed only after the second has moved.
    func testSharedOriginalIsRemovedOnlyAfterEveryReaderHasMoved() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("shared.txt", contents: "Read by two records.")
        let first = try sandbox.legacyBook("First Reader", original: original)
        let second = try sandbox.legacyBook("Second Reader", original: original)
        var library = Library(books: [first, second])

        let report = FileImportService.migrateLegacyBooks(in: &library)

        XCTAssertEqual(report.migratedCount, 2)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.warnings, [])
        XCTAssertNotEqual(library.books[0].tmbDirectory, library.books[1].tmbDirectory)
        for book in library.books {
            XCTAssertEqual(try text(of: book.bookFileURL), "Read by two records.", book.title)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    /// While a record that could not move still reads the stored file, the
    /// file stays, even after another record reading it has moved.
    func testSharedOriginalStaysWhileARecordThatCouldNotMoveReadsIt() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("shared.txt", contents: "Still needed.")
        // A read-only folder makes the first record's move fail.
        let lockedFolderPath = sandbox.folderPath + "/Locked"
        try TextMouthPaths.ensureLibrarySubfolder(lockedFolderPath)
        setPermissions(
            of: TextMouthPaths.libraryDir.appendingPathComponent(lockedFolderPath, isDirectory: true),
            to: 0o555,
            restoringTo: 0o755
        )
        var stuck = try sandbox.legacyBook("Stuck Reader", original: original)
        stuck.folderPath = lockedFolderPath
        let mover = try sandbox.legacyBook("Moving Reader", original: original)
        var library = Library(books: [stuck, mover])

        let report = FileImportService.migrateLegacyBooks(in: &library)

        XCTAssertEqual(report.failures.map(\.title), [stuck.title])
        XCTAssertEqual(report.migratedCount, 1)
        XCTAssertEqual(library.books[0], stuck)
        XCTAssertEqual(try text(of: library.books[1].bookFileURL), "Still needed.")
        XCTAssertEqual(try text(of: original), "Still needed.")
    }

    // MARK: - Migrating the Library

    /// One book's failure does not stop the pass. Every legacy book is
    /// tried; the ones that fail keep their records exactly, the report
    /// names each with its reason, in library order, and the summary reaches
    /// the debug log. Books already in packages are not touched.
    func testLibraryPassMovesWhatItCanAndListsEveryFailure() throws {
        let sandbox = makeSandbox()
        let missingOriginal = sandbox.scratchDirectory.appendingPathComponent("gone.txt")
        let missing = try sandbox.legacyBook(
            "Missing \(UUID().uuidString.prefix(8))",
            original: missingOriginal,
            md5Hash: "recorded-hash"
        )
        let movable = try sandbox.legacyBook("Movable", original: try sandbox.makeFile("movable.txt", contents: "Moves."))
        let lockedOriginal = try sandbox.makeFile("locked.txt", contents: "Cannot be read.")
        let unreadable = try sandbox.legacyBook("Unreadable", original: lockedOriginal)
        setPermissions(of: lockedOriginal, to: 0o000, restoringTo: 0o644)
        let packaged = Book(
            title: "Already Packaged",
            format: .txt,
            filePath: "/nonexistent/Already.tmb/book.txt",
            md5Hash: "packaged-hash",
            tmbDirectoryName: "Already.tmb"
        )
        var library = Library(books: [missing, movable, unreadable, packaged])

        let report = FileImportService.migrateLegacyBooks(in: &library)

        XCTAssertEqual(report.migratedCount, 1)
        XCTAssertEqual(report.failures.map(\.title), [missing.title, unreadable.title])
        XCTAssertEqual(
            report.failures.first?.reason,
            LegacyMigrationError.originalMissing(path: missingOriginal.path).localizedDescription
        )
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(library.books[0], missing)
        XCTAssertEqual(library.books[1].tmbDirectoryName, sandbox.usualPackage(for: movable).lastPathComponent)
        XCTAssertEqual(library.books[2], unreadable)
        XCTAssertEqual(library.books[3], packaged)

        TextMouthPaths.flushLogs()
        let logLines = try text(of: TextMouthPaths.debugLogFile).components(separatedBy: "\n")
        XCTAssertTrue(logLines.contains { $0.contains("LEGACY_MIGRATION:") && $0.contains(missing.title) })
    }

    /// The alert text lists failures first, since those books did not move,
    /// then books that moved with a problem, one line per book with its
    /// title and what happened; the log gets the same on one line. Counts
    /// read naturally in the singular and the plural, and a pass with
    /// nothing to report says nothing.
    func testReportSummariesNameEachBookWithWhatHappened() {
        var report = LegacyMigrationReport()
        XCTAssertNil(report.userSummary)
        XCTAssertNil(report.logSummary)

        report.recordFailure(of: summaryBook("First"), error: LegacyMigrationError.copyDiffers)
        report.record(LegacyBookMigration(book: summaryBook("Second"), removedOriginal: true, warnings: []))
        report.record(LegacyBookMigration(
            book: summaryBook("Third"),
            removedOriginal: false,
            warnings: ["Its original was kept.", "Its cache waits."]
        ))

        let copyDiffers = LegacyMigrationError.copyDiffers.localizedDescription
        XCTAssertEqual(report.migratedCount, 2)
        XCTAssertEqual(
            report.userSummary,
            "TextMouth could not move 1 book to the current library format. Its original file was not changed.\n"
                + "First: \(copyDiffers)\n\n"
                + "TextMouth moved 1 book to the current library format, but with a problem:\n"
                + "Third: Its original was kept. Its cache waits."
        )
        XCTAssertEqual(
            report.logSummary,
            "LEGACY_MIGRATION: moved 2 books into packages; could not move 1 book: \"First\" (\(copyDiffers)); "
                + "1 book moved with problems: \"Third\" (Its original was kept. Its cache waits.)"
        )

        report.recordFailure(of: summaryBook("Fourth"), error: LegacyMigrationError.noUnusedPackageName)
        let summary = report.userSummary ?? ""
        XCTAssertTrue(summary.hasPrefix(
            "TextMouth could not move 2 books to the current library format. Their original files were not changed.\n"
        ))
        XCTAssertTrue(summary.contains("Fourth: \(LegacyMigrationError.noUnusedPackageName.localizedDescription)"))
    }

    /// A long list is cut short in the alert, which is heard or read line by
    /// line at every launch, while the debug log still names every book.
    func testAlertCutsALongListShortWhileTheLogNamesEveryBook() {
        var report = LegacyMigrationReport()
        let limit = LegacyMigrationReport.booksNamedInAlert
        for number in 1...(limit + 2) {
            report.recordFailure(of: summaryBook("Book \(number)"), error: LegacyMigrationError.copyDiffers)
        }

        let lines = (report.userSummary ?? "").components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 1 + limit + 1)
        XCTAssertTrue(lines[limit].hasPrefix("Book \(limit): "))
        XCTAssertEqual(
            lines.last,
            "Plus 2 more books, all named in the debug log at \(TextMouthPaths.debugLogFile.path)."
        )
        XCTAssertTrue(report.logSummary?.contains("\"Book \(limit + 2)\"") == true)
    }

    // MARK: - Telling the User

    /// The startup repair moves every book it can and then tells the user,
    /// in one alert, about each book that could not move, with the reason.
    /// The library index is sandboxed because the repair saves it.
    func testStartupRepairShowsEveryMigrationFailureInOneAlert() throws {
        let sandbox = makeSandbox()
        let indexSandbox = try LibraryIndexSandbox.capture()
        defer { indexSandbox.restore() }
        let firstOriginal = sandbox.scratchDirectory.appendingPathComponent("first.txt")
        let first = try sandbox.legacyBook("First Missing", original: firstOriginal, md5Hash: "first-hash")
        let movable = try sandbox.legacyBook("Movable", original: try sandbox.makeFile("movable.txt", contents: "Moves."))
        let second = try sandbox.legacyBook(
            "Second Missing",
            original: sandbox.scratchDirectory.appendingPathComponent("second.txt"),
            md5Hash: "second-hash"
        )
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [first, movable, second])

        model.migrateOldBooksIfNeeded()

        XCTAssertTrue(model.showError)
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.hasPrefix("TextMouth could not move 2 books to the current library format."))
        XCTAssertTrue(message.contains(
            "First Missing: \(LegacyMigrationError.originalMissing(path: firstOriginal.path).localizedDescription)"
        ))
        XCTAssertTrue(message.contains("Second Missing: "))
        let moved = try XCTUnwrap(model.library.books.first { $0.id == movable.id })
        XCTAssertEqual(moved.tmbDirectoryName, sandbox.usualPackage(for: movable).lastPathComponent)
        XCTAssertEqual(model.library.books.first { $0.id == first.id }, first)
    }

    /// A repair whose migration went cleanly shows no alert.
    func testStartupRepairWithoutMigrationProblemsShowsNoAlert() throws {
        let sandbox = makeSandbox()
        let indexSandbox = try LibraryIndexSandbox.capture()
        defer { indexSandbox.restore() }
        let movable = try sandbox.legacyBook("Clean Move", original: try sandbox.makeFile("clean.txt", contents: "Clean."))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [movable])

        model.migrateOldBooksIfNeeded()

        XCTAssertFalse(model.showError)
        XCTAssertNil(model.errorMessage)
        let moved = try XCTUnwrap(model.library.books.first { $0.id == movable.id })
        XCTAssertEqual(moved.tmbDirectoryName, sandbox.usualPackage(for: movable).lastPathComponent)
    }

    // MARK: - Assertions

    /// Asserts that `name` comes from the usual naming scheme for `book`
    /// with a fresh identifier in place of the book's own.
    private func assertNewPackageName(
        _ name: String,
        for book: Book,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let usualName = packageName(for: book, identifier: book.id)
        let schemePrefix = String(usualName.dropLast("\(book.id.uuidString.lowercased()).tmb".count))
        XCTAssertTrue(name.hasPrefix(schemePrefix), "\(name) does not follow the naming scheme", file: file, line: line)
        let identifierText = String(name.dropFirst(schemePrefix.count).dropLast(".tmb".count))
        let identifier = try XCTUnwrap(UUID(uuidString: identifierText), file: file, line: line)
        XCTAssertNotEqual(identifier, book.id, file: file, line: line)
        XCTAssertEqual(name, packageName(for: book, identifier: identifier), file: file, line: line)
    }

    /// The usual scheme's package name for `book` with `identifier` as its
    /// unique part.
    private func packageName(for book: Book, identifier: UUID) -> String {
        TextMouthPaths.tmbName(title: book.title, author: book.author, dateAdded: book.dateAdded, bookID: identifier)
    }

    /// The UTF-8 text of the file at `url`.
    private func text(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// A record used only for its title, in report tests that touch no files.
    private func summaryBook(_ title: String) -> Book {
        Book(title: title, format: .txt, filePath: "/nonexistent/\(title).txt", md5Hash: title)
    }

    /// Sets `url`'s permissions to `mode` for the rest of the test. They go
    /// back to `restoredMode` when it ends, before the sandbox is removed.
    private func setPermissions(of url: URL, to mode: mode_t, restoringTo restoredMode: mode_t) {
        XCTAssertEqual(chmod(url.path, mode), 0)
        addTeardownBlock { _ = chmod(url.path, restoredMode) }
    }

    // MARK: - Sandbox

    /// One test's loose files and library folder.
    private struct Sandbox {
        /// A directory for loose files, such as originals, outside the library.
        let scratchDirectory: URL
        /// A library folder no other test uses; this test's packages go here.
        let folderPath: String

        /// The folder's directory under the library.
        var libraryFolder: URL {
            TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        }

        /// Writes `contents` to a file named `name` in the scratch directory.
        func makeFile(_ name: String, contents: String) throws -> URL {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            let url = scratchDirectory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        /// A record from before packages: no package name, and a file path
        /// naming `original` outside the library. The recorded hash is the
        /// original's own unless `md5Hash` is given, for an original that
        /// cannot be hashed.
        func legacyBook(
            _ title: String,
            original: URL,
            format: BookFormat = .txt,
            md5Hash: String? = nil
        ) throws -> Book {
            Book(
                title: title,
                author: "Fixture Author",
                format: format,
                filePath: original.path,
                md5Hash: try md5Hash ?? FileImportService.md5Hash(of: original),
                folderPath: folderPath,
                dateAdded: Date(timeIntervalSince1970: 1_600_000_000)
            )
        }

        /// The package `book` normally gets: the usual name, with its own ID.
        func usualPackage(for book: Book) -> URL {
            TextMouthPaths.tmbPath(
                folderPath: book.folderPath,
                tmbName: TextMouthPaths.tmbName(
                    title: book.title,
                    author: book.author,
                    dateAdded: book.dateAdded,
                    bookID: book.id
                )
            )
        }

        /// Creates `book`'s usual package as an earlier run or another record
        /// could have left it: holding `contents` under the original's name.
        func stageUsualPackage(for book: Book, holding contents: String) throws -> URL {
            let package = usualPackage(for: book)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: package.appendingPathComponent(book.bookFileURL.lastPathComponent))
            return package
        }

        /// Writes into `package` the bookInfo.json that a migration of
        /// `book` into that package saves.
        func saveBookInfo(for book: Book, in package: URL) throws {
            var packaged = book
            packaged.filePath = package.appendingPathComponent(book.bookFileURL.lastPathComponent).path
            packaged.tmbDirectoryName = package.lastPathComponent
            try packaged.saveBookInfoThrowing()
        }

        /// The hidden names in `directory`. A copy passes through one, and
        /// none may remain once a migration has returned.
        func hiddenNames(in directory: URL) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { $0.hasPrefix(".") }
        }
    }

    /// Creates this test's sandbox and removes it when the test ends. Until
    /// then the Trash preference is off, so an original the migration
    /// removes is deleted rather than put in the developer's real Trash.
    private func makeSandbox() -> Sandbox {
        let sandbox = Sandbox(
            scratchDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("LegacyBookMigration-\(UUID().uuidString)", isDirectory: true),
            folderPath: "Legacy Migration \(UUID().uuidString.prefix(8))"
        )
        let previousTrashPreference = ConfigService.shared.config.moveToTrashInsteadOfDeleting
        ConfigService.shared.config.moveToTrashInsteadOfDeleting = false
        addTeardownBlock { @MainActor in
            ConfigService.shared.config.moveToTrashInsteadOfDeleting = previousTrashPreference
            try? FileManager.default.removeItem(at: sandbox.scratchDirectory)
            try? FileManager.default.removeItem(at: sandbox.libraryFolder)
        }
        return sandbox
    }
}

/// Carries an error out of a background closure. The test reads it only
/// after waiting for the closure's expectation, which orders the write first.
private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
