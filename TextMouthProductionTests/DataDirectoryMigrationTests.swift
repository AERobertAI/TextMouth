import XCTest
@testable import TextMouth

/// Regression coverage for recoverable data-directory migration.
final class DataDirectoryMigrationTests: XCTestCase {
    // MARK: - Overlapping Folders (F20)

    /// An alias must not bypass the no-parent/no-child migration rule and
    /// cause the staging copy to be written recursively into its own source.
    /// The refusal says how the folders overlap and names the link and the
    /// real folders (TODO S10).
    func testSymlinkCannotDisguiseDestinationInsideSource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)
        let alias = base.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let realSource = source.resolvingSymlinksInPath().path
        let refusals: [(destination: URL, overlap: DataDirectoryOverlap, realDestination: String)] = [
            (alias, .sameFolder, realSource),
            (alias.appendingPathComponent("Nested", isDirectory: true), .destinationInsideSource, realSource + "/Nested"),
        ]

        for refusal in refusals {
            XCTAssertThrowsError(
                try DataDirectoryMigrator.prepareMigration(from: source, to: refusal.destination, library: library)
            ) { error in
                guard case DataDirectoryMigrationError.invalidRelationship(let overlap, _, let destination) = error else {
                    return XCTFail("Expected relationship rejection, received \(error)")
                }
                XCTAssertEqual(overlap, refusal.overlap)
                XCTAssertEqual(destination.named.path, refusal.destination.path)
                XCTAssertEqual(destination.real.path, refusal.realDestination)
                let explanation = error.localizedDescription
                for path in [refusal.destination.path, refusal.realDestination, realSource] {
                    XCTAssertTrue(explanation.contains(path), "\(explanation) names \(path)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("Nested").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.books[0].filePath))
    }

    /// A new location that contains the current data directory, here a link
    /// to the folder holding it, is refused before anything is copied, and
    /// the refusal names the link and both real folders.
    func testNewLocationContainingTheDataDirectoryIsRefused() throws {
        let base = try makeMigrationBase()
        let parent = base.appendingPathComponent("Parent", isDirectory: true)
        let source = parent.appendingPathComponent(".TextMouth", isDirectory: true)
        let library = try makeLibrary(at: source)
        let link = base.appendingPathComponent("ParentLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
        let before = try snapshot(of: base)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)
        ) { error in
            guard case DataDirectoryMigrationError.invalidRelationship(let overlap, _, _) = error else {
                return XCTFail("Expected relationship rejection, received \(error)")
            }
            XCTAssertEqual(overlap, .sourceInsideDestination)
            let explanation = error.localizedDescription
            for path in [link.path, parent.resolvingSymlinksInPath().path, source.resolvingSymlinksInPath().path] {
                XCTAssertTrue(explanation.contains(path), "\(explanation) names \(path)")
            }
        }
        XCTAssertEqual(try snapshot(of: base), before, "nothing was copied or changed")
    }

    /// Each overlap is explained in words that name both real folders, and
    /// every link that leads to one, exactly as the status line shows them
    /// and VoiceOver reads them.
    func testOverlapRefusalsNameBothRealFolders() {
        let current = location("/Users/reader/.TextMouth")
        let linkedCurrent = location("/Users/reader/.TextMouth", real: "/Volumes/Archive/.TextMouth")
        func refusal(_ overlap: DataDirectoryOverlap, _ source: DataDirectoryLocation, _ destination: DataDirectoryLocation) -> String {
            DataDirectoryMigrationError.invalidRelationship(overlap, source: source, destination: destination)
                .localizedDescription
        }

        XCTAssertEqual(
            refusal(.sameFolder, current, location("/Users/reader/Shortcut", real: "/Users/reader/.TextMouth")),
            "The new location, /Users/reader/Shortcut, leads to /Users/reader/.TextMouth, "
                + "which is the current data directory. Choose another location."
        )
        XCTAssertEqual(
            refusal(.sameFolder, linkedCurrent, location("/Volumes/Archive/.TextMouth")),
            "The new location, /Volumes/Archive/.TextMouth, is the current data directory, "
                + "where /Users/reader/.TextMouth leads. Choose another location."
        )
        XCTAssertEqual(
            refusal(.destinationInsideSource, current, location("/Users/reader/.TextMouth/Backup")),
            "The new location, /Users/reader/.TextMouth/Backup, is inside the current data directory, "
                + "/Users/reader/.TextMouth. Choose a location outside it."
        )
        XCTAssertEqual(
            refusal(.sourceInsideDestination, linkedCurrent, location("/Volumes/Archive")),
            "The new location, /Volumes/Archive, contains the current data directory, "
                + "/Volumes/Archive/.TextMouth, where /Users/reader/.TextMouth leads. "
                + "Choose a location that does not contain it."
        )
    }

    /// A name spelled through /private leads to the same folder as the
    /// spelling without it, so it is not described as a link.
    func testPrivateSpellingIsNotALink() {
        XCTAssertFalse(location("/private/tmp/Data/.TextMouth", real: "/tmp/Data/.TextMouth").isAlias)
        XCTAssertTrue(location("/tmp/Link/.TextMouth", real: "/tmp/Data/.TextMouth").isAlias)
    }

    // MARK: - Publication

    func testMigrationPublishesValidatedCopyAndRetainsSource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)

        let migrated = try DataDirectoryMigrator.prepareMigration(
            from: source,
            to: destination,
            library: library
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        // The copy's first book is read three times below: stop here if it is missing.
        _ = try XCTUnwrap(migrated.books[safe: 0], "the migrated library has no first book")
        XCTAssertTrue(migrated.books[0].filePath.hasPrefix(destination.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.books[0].filePath))
        let package = destination.appendingPathComponent("Library/\(migrated.books[0].tmbDirectoryName)")
        let migratedInfo = try BookInfo.load(from: package)
        XCTAssertEqual(migratedInfo.metadata.folderPath, "")
        XCTAssertEqual(migratedInfo.contentIndex?.totalWordCount, 1)
        XCTAssertEqual(migratedInfo.contentIndex?.version, BookContentIndex.currentVersion)
    }

    func testNonemptyDestinationIsNeverOverwritten() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        )
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingTrackedBookRejectsMigrationWithoutPublishingDestination() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)
        try FileManager.default.removeItem(atPath: library.books[0].filePath)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// While library index writes are suspended, migration refuses before
    /// copying anything: the copy's library.json would publish the
    /// provisional library that stands in for an unreadable index.
    func testMigrationWaitsWhileTheLibraryIndexIsUnreadable() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        _ = LibraryPersistenceService.load()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        ) { error in
            guard case LibraryIndexRecoveryError.indexUnreadable = error else {
                return XCTFail("Expected the unreadable-index refusal, received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Integrity Checks (U08)

    /// A move whose data directory is gone when it starts is refused before
    /// anything is made, in words that say so. The data directory in use,
    /// its setting, and the library stay as they were, nothing is made at
    /// the new location or staged beside it, and the data directory is not
    /// made again.
    @MainActor
    func testAMoveFromADataDirectoryThatIsGoneIsRefused() throws {
        let move = try makeMoveOfTheCurrentDataDirectory("GoneDataDirectory")
        try FileManager.default.removeItem(at: move.current)

        assertRefusedAsMissing(move)
        XCTAssertFalse(FileManager.default.fileExists(atPath: move.current.path), "the refused move made the data directory again")
    }

    /// A file where the data directory was is no data directory: the move
    /// is refused the same way, and the file is left as it was.
    @MainActor
    func testAMoveFromAFileWhereTheDataDirectoryWasIsRefused() throws {
        let move = try makeMoveOfTheCurrentDataDirectory("FileForDataDirectory")
        try FileManager.default.removeItem(at: move.current)
        let note = Data("Not a data directory.".utf8)
        try note.write(to: move.current)

        assertRefusedAsMissing(move)
        XCTAssertEqual(try Data(contentsOf: move.current), note, "the file was changed")
    }

    /// The refusal for a book whose content is missing from the copy names
    /// the book by its title, in whatever script the title is written in;
    /// nothing is published or left staged, and the data directory is left
    /// as it was.
    func testAMissingBookIsNamedInTheRefusal() throws {
        let (source, destination) = try makeMoveLocations()
        var library = try makeLibrary(at: source)
        var book = try XCTUnwrap(library.books.first, "the library has no book")
        book.title = "Ἰλιάς"
        library.books = [book]
        try FileManager.default.removeItem(atPath: book.filePath)
        let sourceBefore = try snapshot(of: source)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        ) { error in
            guard case DataDirectoryMigrationError.missingBook(let title) = error else {
                return XCTFail("Expected the missing-book refusal, received \(error)")
            }
            XCTAssertEqual(title, "Ἰλιάς")
            XCTAssertEqual(error.localizedDescription, "The migrated copy is missing the content for Ἰλιάς.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the copy was published")
        XCTAssertEqual(stagingLeft(in: destination.deletingLastPathComponent()), [], "the copy was left staged")
        XCTAssertEqual(try snapshot(of: source), sourceBefore, "the data directory changed")
    }

    /// A book whose file is stored outside the data directory is not in the
    /// copy, and the refusal says where it is and what to do, not that the
    /// copy lacks its content: it names the book and its path, nothing is
    /// published or left staged, and the data directory and the book's file
    /// are left as they were.
    func testABookStoredOutsideTheDataDirectoryIsRefusedForWhereItIs() throws {
        let (source, destination) = try makeMoveLocations()
        var library = try makeLibrary(at: source)
        var book = try XCTUnwrap(library.books.first, "the library has no book")
        book.title = "Stored Apart"
        // The book's file exists, in a folder beside the data directory.
        let apart = source.deletingLastPathComponent().appendingPathComponent("Apart", isDirectory: true)
        try FileManager.default.createDirectory(at: apart, withIntermediateDirectories: true)
        let outsideFile = apart.appendingPathComponent("stored-apart.txt")
        try Data("apart".utf8).write(to: outsideFile)
        book.filePath = outsideFile.path
        library.books = [book]
        let sourceBefore = try snapshot(of: source)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        ) { error in
            guard case DataDirectoryMigrationError.bookOutsideDataDirectory(let title, let path) = error else {
                return XCTFail("Expected the outside-the-data-directory refusal, received \(error)")
            }
            XCTAssertEqual(title, "Stored Apart")
            XCTAssertEqual(path, outsideFile.path)
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("Stored Apart"), "the book is not named: \(description)")
            XCTAssertTrue(description.contains(outsideFile.path), "its path is not given: \(description)")
            XCTAssertTrue(description.contains("outside the data directory"), "where it is is not said: \(description)")
            XCTAssertFalse(description.contains("missing"), "it was reported as missing from the copy: \(description)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the copy was published")
        XCTAssertEqual(stagingLeft(in: destination.deletingLastPathComponent()), [], "the copy was left staged")
        XCTAssertEqual(try snapshot(of: source), sourceBefore, "the data directory changed")
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("apart".utf8), "the book's file changed")
    }

    /// A staged index that does not read back as the library it was written
    /// from fails its check, and the copy is never published: the refusal
    /// says so, the copy is deleted, and the data directory is left as it
    /// was. Here the library keeps, among the rows it could not read (V03),
    /// one that this version reads as a book after all, so the staged
    /// library.json reads back with one book more than the library counts.
    /// No library loaded from disk holds such a row; it is the one way to
    /// fail the check without changing the app.
    func testAStagedIndexThatFailsItsCheckIsNeverPublished() throws {
        let (source, destination) = try makeMoveLocations()
        var library = try makeLibrary(at: source)
        library.unreadableRows = [try keptRowThatReadsAsABook()]
        let sourceBefore = try snapshot(of: source)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        ) { error in
            guard case DataDirectoryMigrationError.invalidLibrary = error else {
                return XCTFail("Expected the invalid-library refusal, received \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "The migrated library index could not be validated.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the copy was published")
        XCTAssertEqual(stagingLeft(in: destination.deletingLastPathComponent()), [], "the copy was left staged")
        XCTAssertEqual(try snapshot(of: source), sourceBefore, "the data directory changed")
    }

    // MARK: - Package Records (PERF15)

    /// A move copies each package's contentIndex.json as it is, byte for
    /// byte, and never decodes or writes it again: only analysis writes that
    /// file, which can run to hundreds of kilobytes. The index here is
    /// spelled as no encoder of this version spells it, pretty-printed with
    /// a final line break, so any rewrite, however faithful, would show. The
    /// copy's record still loads with that index, and bookInfo.json takes
    /// none in.
    func testMoveCopiesEachContentIndexFileByteForByte() throws {
        let (source, destination) = try makeMoveLocations()
        let library = try makeLibrary(at: source)
        let sourcePackage = package(of: library.books[0], in: source)
        let index = try XCTUnwrap(BookInfo.load(from: sourcePackage).contentIndex)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let unusualSpelling = try encoder.encode(index) + Data("\n".utf8)
        try unusualSpelling.write(to: TextMouthPaths.contentIndexPath(in: sourcePackage))

        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)

        let copiedBook = try XCTUnwrap(migrated.books[safe: 0], "the migrated library has no first book")
        let copiedPackage = package(of: copiedBook, in: destination)
        XCTAssertEqual(
            try Data(contentsOf: TextMouthPaths.contentIndexPath(in: copiedPackage)),
            unusualSpelling,
            "The move wrote contentIndex.json again"
        )
        XCTAssertEqual(try BookInfo.load(from: copiedPackage).contentIndex, index)
        XCTAssertNil(try recordKeys(in: copiedPackage)["contentIndex"], "bookInfo.json took the index in")
    }

    /// A package whose record an older version of TextMouth wrote, with the
    /// index inside bookInfo.json, arrives laid out as its first save would
    /// leave it: the index in a contentIndex.json of its own, and
    /// bookInfo.json without it. The data directory it came from keeps its
    /// record exactly as it was.
    func testMoveGivesAnOldFormatRecordsIndexAFileOfItsOwn() throws {
        let (source, destination) = try makeMoveLocations()
        let library = try makeLibrary(at: source)
        let sourcePackage = package(of: library.books[0], in: source)
        var record = try BookInfo.load(from: sourcePackage)
        let index = try XCTUnwrap(record.contentIndex)
        record.contentIndex = nil
        let olderRecord = try ContentIndexFileTests.olderVersionRecordBytes(record, index: index)
        try olderRecord.write(to: TextMouthPaths.bookInfoPath(in: sourcePackage))
        try FileManager.default.removeItem(at: TextMouthPaths.contentIndexPath(in: sourcePackage))

        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)

        let copiedBook = try XCTUnwrap(migrated.books[safe: 0], "the migrated library has no first book")
        let copiedPackage = package(of: copiedBook, in: destination)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: TextMouthPaths.contentIndexPath(in: copiedPackage).path),
            "The copy's index has no file of its own"
        )
        XCTAssertNil(try recordKeys(in: copiedPackage)["contentIndex"], "The copy's bookInfo.json still holds the index")
        XCTAssertEqual(try BookInfo.load(from: copiedPackage).contentIndex, index)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: sourcePackage)), olderRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.contentIndexPath(in: sourcePackage).path))
    }

    /// A move writes each copy's record as every save of a book writes one
    /// (`Book.saveBookInfoThrowing`): one revision higher than the record it
    /// replaces, so the book's revisions only rise, with the library row's
    /// own fields, such as a title edited before the move, and with the
    /// analysis fields that describe the index kept beside that index, even
    /// when the row moved with it has not taken that analysis yet.
    func testMoveWritesEachRecordAsASaveOfTheBookWould() throws {
        let (source, destination) = try makeMoveLocations()
        var library = try makeLibrary(at: source)
        let sourcePackage = package(of: library.books[0], in: source)
        var stored = try BookInfo.load(from: sourcePackage)
        stored.state.revision = 7
        try stored.save(to: sourcePackage)
        library.books[0].title = "Renamed Before The Move"
        library.books[0].contentAnalysisFields = Book.ContentAnalysisFields()

        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)

        let copiedBook = try XCTUnwrap(migrated.books[safe: 0], "the migrated library has no first book")
        let copied = try BookInfo.load(from: package(of: copiedBook, in: destination))
        XCTAssertEqual(copied.state.revision, 8)
        XCTAssertEqual(copied.metadata.title, "Renamed Before The Move")
        XCTAssertEqual(copied.state.contentAnalysisFields, stored.state.contentAnalysisFields)
        XCTAssertEqual(copied.state.totalWordCount, 1)
        XCTAssertEqual(copied.contentIndex, stored.contentIndex)
    }

    // MARK: - Linked Locations (S10)

    /// Acceptance (TODO S10): a data directory that is a link to a folder
    /// elsewhere is copied from that folder, never as the link. The new
    /// location holds a real copy whose books, named through the link or
    /// through the folder, all moved; the folder keeps its library.json,
    /// package records, and books byte for byte, and the link is untouched.
    func testLinkedDataDirectoryIsCopiedFromTheFolderItLeadsTo() throws {
        let base = try makeMigrationBase()
        let folder = base.appendingPathComponent("Elsewhere/Data", isDirectory: true)
        let home = base.appendingPathComponent("Home", isDirectory: true)
        let link = home.appendingPathComponent(".TextMouth")
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        // One book named through the link, as the app names them, and one
        // named through the folder it leads to.
        let library = Library(books: try makeLibrary(at: link).books + makeLibrary(at: folder).books)
        try LibraryIndexSandbox.encoded(library).write(to: folder.appendingPathComponent("library.json"))
        let folderBefore = try snapshot(of: folder)

        let migrated = try DataDirectoryMigrator.prepareMigration(from: link, to: destination, library: library)

        XCTAssertThrowsError(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            "the new location is a real folder, not another link to the data"
        )
        XCTAssertEqual(try snapshot(of: folder), folderBefore, "the folder the link leads to is unchanged")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), folder.path)
        XCTAssertEqual(migrated.books.count, 2)
        for book in migrated.books {
            XCTAssertTrue(book.filePath.hasPrefix(destination.path + "/Library/"), book.filePath)
            XCTAssertEqual(try String(contentsOfFile: book.filePath, encoding: .utf8), "migration")
        }
        XCTAssertEqual(try publishedLibrary(in: destination).books.map(\.filePath), migrated.books.map(\.filePath))
        XCTAssertEqual(
            DataDirectoryMigrator.doneMessage(
                dataAt: DataDirectoryLocation(destination),
                copiedFrom: DataDirectoryLocation(link)
            ),
            "Done. Data is now at \(destination.path). "
                + "It was copied from \(folder.resolvingSymlinksInPath().path), where \(link.path) leads."
        )
    }

    /// Acceptance (TODO S10): a new location that is a link to an empty
    /// folder elsewhere receives the data in that folder. The link stays,
    /// still leading there, nothing is put beside it, and the books are
    /// named through it, as the preferences will name the data directory.
    func testLinkToAnEmptyFolderReceivesTheDataInThatFolder() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
        let folder = elsewhere.appendingPathComponent("Empty", isDirectory: true)
        let chosen = base.appendingPathComponent("Chosen", isDirectory: true)
        let link = chosen.appendingPathComponent(".TextMouth")
        let library = try makeLibrary(at: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let sourceBefore = try snapshot(of: source)

        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), folder.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path), [".TextMouth"])
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
            ["Library", "Logs", "library.json"]
        )
        let book = try XCTUnwrap(migrated.books.first)
        XCTAssertTrue(book.filePath.hasPrefix(link.path + "/Library/"), book.filePath)
        XCTAssertEqual(try String(contentsOfFile: book.filePath, encoding: .utf8), "migration")
        XCTAssertEqual(try publishedLibrary(in: folder).books.map(\.filePath), [book.filePath])
        XCTAssertEqual(try snapshot(of: source), sourceBefore)
        XCTAssertEqual(stagingLeft(in: elsewhere), [])
        XCTAssertEqual(
            DataDirectoryMigrator.doneMessage(
                dataAt: DataDirectoryLocation(link),
                copiedFrom: DataDirectoryLocation(source)
            ),
            "Done. Data is now at \(link.path), which leads to \(folder.resolvingSymlinksInPath().path)."
        )
    }

    /// A new location that is a link leading nowhere, to a missing folder or
    /// back to itself, is refused before anything is copied, naming the
    /// link and what it points to. Nothing is created where it points.
    func testLinkThatLeadsNowhereIsRefused() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let library = try makeLibrary(at: source)
        let missing = base.appendingPathComponent("Unmounted/Data").path
        let dangling = base.appendingPathComponent("Dangling")
        let looping = base.appendingPathComponent("Looping")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: missing)
        try FileManager.default.createSymbolicLink(atPath: looping.path, withDestinationPath: looping.path)
        let before = try snapshot(of: base)

        for (link, target) in [(dangling, missing), (looping, looping.path)] {
            XCTAssertThrowsError(
                try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)
            ) { error in
                guard case DataDirectoryMigrationError.unreachableLink(let refused, let refusedTarget) = error else {
                    return XCTFail("Expected the unreachable-link refusal, received \(error)")
                }
                XCTAssertEqual(refused.named.path, link.path)
                XCTAssertEqual(refusedTarget, target)
                XCTAssertEqual(
                    error.localizedDescription,
                    "The new location, \(link.path), is a link to \(target), which cannot be found. "
                        + "Choose another location."
                )
            }
        }
        XCTAssertEqual(try snapshot(of: base), before, "nothing was created, copied, or changed")
    }

    /// A new location that is a link to a folder holding anything is
    /// refused as that folder would be, and the folder is left as it was.
    func testLinkToAFolderThatIsNotEmptyIsRefused() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let library = try makeLibrary(at: source)
        let folder = base.appendingPathComponent("Elsewhere/Occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        let link = base.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let before = try snapshot(of: base)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)
        ) { error in
            guard case DataDirectoryMigrationError.destinationNotEmpty = error else {
                return XCTFail("Expected the not-empty refusal, received \(error)")
            }
        }
        XCTAssertEqual(try snapshot(of: base), before)
    }

    /// A new location where a file stands, or a link to a file, is refused
    /// before anything is copied, in words that say so and name where the
    /// link leads; the file is left as it was.
    func testFileAtTheNewLocationIsRefused() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let library = try makeLibrary(at: source)
        let file = base.appendingPathComponent(".TextMouth")
        try Data("keep".utf8).write(to: file)
        let link = base.appendingPathComponent("FileLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let before = try snapshot(of: base)
        let refusals = [
            (file, "The new location, \(file.path), is a file, not a folder. Choose another location."),
            (
                link,
                "The new location, \(link.path), which leads to \(file.resolvingSymlinksInPath().path), "
                    + "is a file, not a folder. Choose another location."
            ),
        ]

        for (destination, explanation) in refusals {
            XCTAssertThrowsError(
                try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
            ) { error in
                guard case DataDirectoryMigrationError.destinationNotAFolder(let refused) = error else {
                    return XCTFail("Expected the not-a-folder refusal, received \(error)")
                }
                XCTAssertEqual(refused.named.path, destination.path)
                XCTAssertEqual(error.localizedDescription, explanation)
            }
        }
        XCTAssertEqual(try snapshot(of: base), before)
    }

    /// Done names where the data is now and, wherever a link stands in
    /// either location, the folder it leads to. A move without links reads
    /// as it always did.
    func testDoneMessageNamesTheFolderEachLinkLeadsTo() {
        let archive = location("/Volumes/Archive/.TextMouth")
        let current = location("/Users/reader/.TextMouth")
        let linkedCurrent = location("/Users/reader/.TextMouth", real: "/Volumes/Old/.TextMouth")

        XCTAssertEqual(
            DataDirectoryMigrator.doneMessage(dataAt: archive, copiedFrom: current),
            "Done. Data is now at /Volumes/Archive/.TextMouth."
        )
        XCTAssertEqual(
            DataDirectoryMigrator.doneMessage(
                dataAt: location("/Users/reader/Archive", real: "/Volumes/Archive/.TextMouth"),
                copiedFrom: current
            ),
            "Done. Data is now at /Users/reader/Archive, which leads to /Volumes/Archive/.TextMouth."
        )
        XCTAssertEqual(
            DataDirectoryMigrator.doneMessage(dataAt: archive, copiedFrom: linkedCurrent),
            "Done. Data is now at /Volumes/Archive/.TextMouth. "
                + "It was copied from /Volumes/Old/.TextMouth, where /Users/reader/.TextMouth leads."
        )
        XCTAssertEqual(
            DataDirectoryMigrator.doneMessage(dataAt: linkedCurrent, copiedFrom: linkedCurrent),
            "Done. Data is now at /Users/reader/.TextMouth, which leads to /Volumes/Old/.TextMouth.",
            "Reset to Default with the data already there copies nothing"
        )
    }

    // MARK: - Changes While Copying (S10)

    /// Acceptance (TODO S10): a file created in the empty new location while
    /// the data is being copied stops publication. The file stays and
    /// nothing joins it, the copy is deleted, the data directory is
    /// unchanged, and the refusal names what arrived and where.
    func testFileArrivingInTheEmptyNewLocationWhileCopyingIsKept() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLibrary(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let arrival = destination.appendingPathComponent("arrived.txt")
        let sourceBefore = try snapshot(of: source)
        let fileManager = InterruptingFileManager(at: .afterCopy) {
            try Data("arrived".utf8).write(to: arrival)
        }

        let change = try XCTUnwrap(destinationChange {
            try DataDirectoryMigrator.prepareMigration(
                from: source, to: destination, library: library, fileManager: fileManager
            )
        })

        XCTAssertEqual(change.finding, .items(["arrived.txt"]))
        XCTAssertEqual(change.destination.real.path, destination.path)
        XCTAssertEqual(
            DataDirectoryMigrationError.destinationChanged(change).localizedDescription,
            "While TextMouth was copying its data, 1 item appeared in \(destination.path): arrived.txt. "
                + "TextMouth left it there and is still using \(source.path). Choose an empty location and try again."
        )
        XCTAssertEqual(try String(contentsOf: arrival, encoding: .utf8), "arrived")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["arrived.txt"])
        XCTAssertEqual(stagingLeft(in: base), [], "the copy is deleted")
        XCTAssertEqual(try snapshot(of: source), sourceBefore)
        XCTAssertEqual(fileManager.moveAttempts, 0, "nothing was renamed into place")
    }

    /// A folder created at the new location while the data is being copied,
    /// with a file inside, stops publication, and both are kept.
    func testFolderCreatedAtTheNewLocationWhileCopyingIsKept() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLibrary(at: source)
        let notes = destination.appendingPathComponent("notes.txt")
        let fileManager = InterruptingFileManager(at: .afterCopy) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("notes".utf8).write(to: notes)
        }

        let change = try XCTUnwrap(destinationChange {
            try DataDirectoryMigrator.prepareMigration(
                from: source, to: destination, library: library, fileManager: fileManager
            )
        })

        XCTAssertEqual(change.finding, .items(["notes.txt"]))
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "notes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["notes.txt"])
        XCTAssertEqual(stagingLeft(in: base), [])
        XCTAssertEqual(fileManager.moveAttempts, 0)
    }

    /// A file put where the new location's folder belongs while the data is
    /// being copied stops publication and is kept.
    func testFilePutAtTheNewLocationWhileCopyingIsKept() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        // Not a directory URL: a file is written at this path.
        let destination = base.appendingPathComponent("Destination")
        let library = try makeLibrary(at: source)
        let fileManager = InterruptingFileManager(at: .afterCopy) {
            try Data("file".utf8).write(to: destination)
        }

        let change = try XCTUnwrap(destinationChange {
            try DataDirectoryMigrator.prepareMigration(
                from: source, to: destination, library: library, fileManager: fileManager
            )
        })

        XCTAssertEqual(change.finding, .replaced)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "file")
        XCTAssertEqual(stagingLeft(in: base), [])
        XCTAssertEqual(fileManager.moveAttempts, 0)
    }

    /// An item that arrives in the empty new location after publication's
    /// last look inside it, as the folder makes way for the copy, is never
    /// deleted: rmdir refuses a folder that is not empty, and publication
    /// stops, naming the item.
    func testItemArrivingAfterTheLastLookIsNeverDeleted() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLibrary(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let late = destination.appendingPathComponent("late.txt")
        let fileManager = InterruptingFileManager(at: .afterListing(destination.path)) {
            try Data("late".utf8).write(to: late)
        }

        let change = try XCTUnwrap(destinationChange {
            try DataDirectoryMigrator.prepareMigration(
                from: source, to: destination, library: library, fileManager: fileManager
            )
        })

        XCTAssertEqual(change.finding, .items(["late.txt"]))
        XCTAssertEqual(try String(contentsOf: late, encoding: .utf8), "late")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["late.txt"])
        XCTAssertEqual(stagingLeft(in: base), [])
        XCTAssertEqual(fileManager.moveAttempts, 0)
    }

    /// A folder that appears at the new location after publication's last
    /// look, just before the copy is renamed into place, is never replaced:
    /// the rename refuses, and publication stops, naming what is inside it.
    func testItemArrivingJustBeforeTheRenameIsNeverReplaced() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLibrary(at: source)
        let late = destination.appendingPathComponent("late.txt")
        let fileManager = InterruptingFileManager(at: .afterLookingAt(destination.path)) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("late".utf8).write(to: late)
        }

        let change = try XCTUnwrap(destinationChange {
            try DataDirectoryMigrator.prepareMigration(
                from: source, to: destination, library: library, fileManager: fileManager
            )
        })

        XCTAssertEqual(change.finding, .items(["late.txt"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["late.txt"])
        XCTAssertEqual(stagingLeft(in: base), [])
        XCTAssertEqual(fileManager.moveAttempts, 1, "the rename was tried, and refused")
    }

    /// An empty folder at the new location, there from the start or created
    /// while the data is being copied, holds nothing to lose: the copy takes
    /// its place.
    func testEmptyFolderAtTheNewLocationMakesWayForTheCopy() throws {
        for createdWhileCopying in [false, true] {
            let base = try makeMigrationBase()
            let source = base.appendingPathComponent("Source", isDirectory: true)
            let destination = base.appendingPathComponent("Destination", isDirectory: true)
            let library = try makeLibrary(at: source)
            if !createdWhileCopying {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            let fileManager = InterruptingFileManager(at: .afterCopy) {
                if createdWhileCopying {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                }
            }

            let migrated = try DataDirectoryMigrator.prepareMigration(
                from: source, to: destination, library: library, fileManager: fileManager
            )

            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)),
                ["Library", "Logs", "library.json"]
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(migrated.books.first).filePath))
            XCTAssertEqual(stagingLeft(in: base), [])
            XCTAssertEqual(fileManager.moveAttempts, 1)
        }
    }

    /// A new location that is a link, pointed at another folder while the
    /// data is being copied, stops publication: neither folder receives the
    /// data, and the refusal names the link and both folders.
    func testLinkRedirectedWhileCopyingStopsPublication() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let library = try makeLibrary(at: source)
        let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
        let first = elsewhere.appendingPathComponent("First", isDirectory: true)
        let second = elsewhere.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let fileManager = InterruptingFileManager(at: .afterCopy) {
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        }

        let change = try XCTUnwrap(destinationChange {
            try DataDirectoryMigrator.prepareMigration(
                from: source, to: link, library: library, fileManager: fileManager
            )
        })

        let firstPath = first.resolvingSymlinksInPath().path
        let secondPath = second.resolvingSymlinksInPath().path
        XCTAssertEqual(change.finding, .redirected(to: secondPath))
        XCTAssertEqual(
            DataDirectoryMigrationError.destinationChanged(change).localizedDescription,
            "While TextMouth was copying its data, \(link.path) was changed to lead to \(secondPath) "
                + "instead of \(firstPath). TextMouth is still using \(source.path). Try again."
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.path), [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), second.path)
        XCTAssertEqual(stagingLeft(in: elsewhere), [])
        XCTAssertEqual(fileManager.moveAttempts, 0)
    }

    /// A move stopped at publication changes nothing the app uses: the data
    /// directory in use, its setting in the preferences, and the library,
    /// whose books still name the current data directory, stay as they
    /// were. The setting and the library change only after a published
    /// copy (TODO S10).
    func testStoppedMoveKeepsTheDataDirectoryItsSettingAndTheLibrary() throws {
        let preferences = TextMouthRuntime.current.preferences
        // TextMouthPaths' private key for a custom data directory.
        let key = "textMouthDataDirectory"
        let savedLocation = preferences.string(forKey: key)
        addTeardownBlock {
            // Looked up again here: the store itself is not Sendable.
            let preferences = TextMouthRuntime.current.preferences
            if let savedLocation {
                preferences.set(savedLocation, forKey: key)
            } else {
                preferences.removeObject(forKey: key)
            }
        }
        try TextMouthPaths.ensureDirectoryStructure()
        let root = TextMouthPaths.root
        var library = try makeLibrary(at: root)
        let package = root.appendingPathComponent("Library/\(library.books[0].tmbDirectoryName)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let booksBefore = library.books.map { "\($0.id) \($0.filePath)" }
        let base = try makeMigrationBase()
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let arrival = destination.appendingPathComponent("arrived.txt")
        let fileManager = InterruptingFileManager(at: .afterCopy) {
            try Data("arrived".utf8).write(to: arrival)
        }
        // Write any waiting log lines now, so none lands in the data
        // directory while it is copied.
        TextMouthPaths.flushLogs()

        XCTAssertThrowsError(
            try TextMouthPaths.moveDataDirectory(to: destination, library: &library, fileManager: fileManager)
        ) { error in
            guard case DataDirectoryMigrationError.destinationChanged = error else {
                return XCTFail("Expected the destination change, received \(error)")
            }
        }

        XCTAssertEqual(TextMouthPaths.root, root)
        XCTAssertEqual(preferences.string(forKey: key), savedLocation, "the setting was not written")
        XCTAssertEqual(library.books.map { "\($0.id) \($0.filePath)" }, booksBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["arrived.txt"])
        XCTAssertEqual(stagingLeft(in: base), [])
    }

    /// What arrived is named, at most three names and a count of the rest,
    /// with where it arrived, the link that leads there, and the data
    /// directory still in use.
    func testChangeExplanationsNameWhatArrivedAndWhere() {
        let archive = location("/Volumes/Archive/.TextMouth")
        let linkedArchive = location("/Users/reader/Archive", real: "/Volumes/Archive/.TextMouth")
        let current = location("/Users/reader/.TextMouth")
        func explanation(_ finding: DataDirectoryDestinationChange.Finding, at destination: DataDirectoryLocation) -> String {
            DataDirectoryMigrationError.destinationChanged(
                DataDirectoryDestinationChange(finding: finding, destination: destination, source: current)
            ).localizedDescription
        }

        XCTAssertEqual(
            explanation(.items(["Library", "library.json"]), at: archive),
            "While TextMouth was copying its data, 2 items appeared in /Volumes/Archive/.TextMouth: "
                + "Library and library.json. TextMouth left them there and is still using "
                + "/Users/reader/.TextMouth. Choose an empty location and try again."
        )
        XCTAssertEqual(
            explanation(.items(["a", "b", "c", "d", "e"]), at: linkedArchive),
            "While TextMouth was copying its data, 5 items appeared in /Volumes/Archive/.TextMouth, "
                + "where /Users/reader/Archive leads: a, b, c, and 2 more. TextMouth left them there and "
                + "is still using /Users/reader/.TextMouth. Choose an empty location and try again."
        )
        XCTAssertEqual(
            explanation(.replaced, at: archive),
            "While TextMouth was copying its data, something else was put at /Volumes/Archive/.TextMouth. "
                + "TextMouth left it there and is still using /Users/reader/.TextMouth. "
                + "Choose an empty location and try again."
        )
        XCTAssertEqual(DataDirectoryDestinationChange.listing(["a"]), "a")
        XCTAssertEqual(DataDirectoryDestinationChange.listing(["a", "b", "c"]), "a, b, and c")
    }

    // MARK: - Fixtures

    /// The change that stopped the migration `migrate` runs, after failing
    /// the test when it published its copy or failed another way.
    private func destinationChange(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ migrate: () throws -> Library
    ) -> DataDirectoryDestinationChange? {
        do {
            _ = try migrate()
            XCTFail("The migration published its copy", file: file, line: line)
        } catch DataDirectoryMigrationError.destinationChanged(let change) {
            return change
        } catch {
            XCTFail("Expected the destination change, received \(error)", file: file, line: line)
        }
        return nil
    }

    /// A move of the current data directory to a new location: the data
    /// directory, a folder of the test's own made the current one until the
    /// test ends (`makeCurrentDataDirectory`), holding one book; the new
    /// location, in another folder of the test's own; and what a refused
    /// move must leave as it was.
    private struct MoveOfTheCurrentDataDirectory {
        /// The data directory in use.
        let current: URL
        /// The library naming its book.
        let library: Library
        /// The folder the new location is in, which holds nothing else.
        let base: URL
        /// The new location, which does not exist.
        let destination: URL
        /// The data-directory setting in the preferences before the move.
        let settingBefore: NSDictionary
    }

    /// Lays out a move of the current data directory; `label` names its
    /// scratch folder. Writes and log lines still queued are made first, in
    /// the data directory, so none lands there while the test changes it.
    @MainActor
    private func makeMoveOfTheCurrentDataDirectory(_ label: String) throws -> MoveOfTheCurrentDataDirectory {
        let current = try makeCurrentDataDirectory(label)
        let library = try makeLibrary(at: current)
        let base = try makeMigrationBase()
        LibraryPersistenceService.flushPendingSave()
        TextMouthPaths.flushLogs()
        return MoveOfTheCurrentDataDirectory(
            current: current,
            library: library,
            base: base,
            destination: base.appendingPathComponent("Destination", isDirectory: true),
            settingBefore: dataDirectorySetting()
        )
    }

    /// Asserts that `move`, run as the app runs a move, is refused because
    /// its data directory does not exist, in the refusal's exact words, and
    /// that nothing changed: the data directory in use, its setting, and the
    /// library stay as they were, and nothing is made at the new location
    /// or staged beside it.
    private func assertRefusedAsMissing(
        _ move: MoveOfTheCurrentDataDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var library = move.library
        XCTAssertThrowsError(
            try TextMouthPaths.moveDataDirectory(to: move.destination, library: &library),
            file: file,
            line: line
        ) { error in
            guard case DataDirectoryMigrationError.missingSource = error else {
                return XCTFail("Expected the missing-data-directory refusal, received \(error)", file: file, line: line)
            }
            XCTAssertEqual(error.localizedDescription, "The current data directory does not exist.", file: file, line: line)
        }
        XCTAssertEqual(TextMouthPaths.root.path, move.current.path, "the data directory in use changed", file: file, line: line)
        XCTAssertEqual(dataDirectorySetting(), move.settingBefore, "the data-directory setting changed", file: file, line: line)
        XCTAssertEqual(library.books, move.library.books, "the library changed", file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: move.base.path),
            [],
            "something was made at the new location or staged beside it",
            file: file,
            line: line
        )
    }

    /// The data-directory setting as this process's preferences hold it:
    /// the custom location, its bookmark, and the identity of the library
    /// expected there, each only when it is set.
    private func dataDirectorySetting() -> NSDictionary {
        let preferences = TextMouthRuntime.current.preferences
        var setting: [String: Any] = [:]
        for key in DataDirectoryPreferences.keys {
            setting[key] = preferences.object(forKey: key)
        }
        return setting as NSDictionary
    }

    /// A row kept unread (V03) that this version reads as a book after all,
    /// as no library loaded from disk holds: a book's own row, as an index
    /// writes it.
    private func keptRowThatReadsAsABook() throws -> UnreadableLibraryRow {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let book = Book(title: "Kept Row", format: .txt, filePath: "/nonexistent/kept-row.txt", md5Hash: "kept-row")
        return UnreadableLibraryRow(json: try JSONDecoder().decode(JSONValue.self, from: encoder.encode(book)))
    }

    /// The names of the hidden staging folders a migration left in `folder`.
    private func stagingLeft(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(DataDirectoryMigrator.stagingNamePrefix) }
    }

    /// The library index published in the data directory at `root`.
    private func publishedLibrary(in root: URL) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
    }

    /// A data directory's location and a move's new location, both in a new
    /// folder of the test's own (`makeMigrationBase()`); neither exists yet.
    private func makeMoveLocations() throws -> (source: URL, destination: URL) {
        let base = try makeMigrationBase()
        return (
            base.appendingPathComponent("Source", isDirectory: true),
            base.appendingPathComponent("Destination", isDirectory: true)
        )
    }

    /// The package of `book`, a book at the top of the library, in the data
    /// directory at `root`.
    private func package(of book: Book, in root: URL) -> URL {
        root.appendingPathComponent("Library/\(book.tmbDirectoryName)", isDirectory: true)
    }

    /// The top-level keys of the bookInfo.json in `package`, as written.
    private func recordKeys(in package: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: package))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    /// A new, empty folder in the temporary directory for one test's
    /// locations, removed when the test ends.
    private func makeMigrationBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataDirectoryMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    /// Everything under `folder`, by its path inside it: each file's bytes,
    /// each link's target, and each folder as an empty entry ending in "/".
    /// Equal snapshots mean nothing in the folder was added, removed, or
    /// changed. Links are recorded, never followed.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        while let relativePath = enumerator?.nextObject() as? String {
            let item = folder.appendingPathComponent(relativePath)
            switch enumerator?.fileAttributes?[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                entries[relativePath] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: item.path).utf8)
            case .typeDirectory?:
                entries[relativePath + "/"] = Data()
            default:
                entries[relativePath] = try Data(contentsOf: item)
            }
        }
        return entries
    }

    /// A location named `named` that leads to `real`, or to itself when
    /// `real` is nil, without asking the file system.
    private func location(_ named: String, real: String? = nil) -> DataDirectoryLocation {
        DataDirectoryLocation(
            named: URL(fileURLWithPath: named),
            real: URL(fileURLWithPath: real ?? named)
        )
    }
}

/// How Storage settings report a data-directory move that a change at the
/// new location stopped (TODO S10).
@MainActor
final class DataDirectoryMigrationReportTests: XCTestCase {
    /// The status line shows the stopped move as a failure, in the words of
    /// the library's error alert, naming what arrived and where, and
    /// VoiceOver announces those words once.
    func testStoppedMoveIsShownAndAnnouncedAsAFailure() {
        let change = DataDirectoryDestinationChange(
            finding: .items(["library.json"]),
            destination: DataDirectoryLocation(
                named: URL(fileURLWithPath: "/Volumes/Archive/.TextMouth"),
                real: URL(fileURLWithPath: "/Volumes/Archive/.TextMouth")
            ),
            source: DataDirectoryLocation(
                named: URL(fileURLWithPath: "/Users/reader/.TextMouth"),
                real: URL(fileURLWithPath: "/Users/reader/.TextMouth")
            )
        )
        let outcome = LibraryViewModel.maintenanceOutcome(
            .failure(DataDirectoryMigrationError.destinationChanged(change)),
            failureContext: "Failed to move directory",
            done: "Done."
        )
        var status: StorageStatus?

        let recorder = recordingAnnouncements {
            status = .announced(after: outcome)
        }

        let expected = "Failed to move directory: While TextMouth was copying its data, 1 item appeared in "
            + "/Volumes/Archive/.TextMouth: library.json. TextMouth left it there and is still using "
            + "/Users/reader/.TextMouth. Choose an empty location and try again."
        XCTAssertEqual(status, StorageStatus(message: expected, isFailure: true))
        XCTAssertEqual(recorder.announcements, [VoiceOverAnnouncement(message: expected, priority: .high)])
    }
}

/// A file manager that changes the file system at one chosen moment of a
/// data-directory migration, to show what publication does with whatever
/// arrives then, without waiting on a clock. It also counts the renames
/// into place the migration asks it for.
final class InterruptingFileManager: FileManager, @unchecked Sendable {
    /// The moments a test can choose. Each follows the copy of the data.
    enum Moment: Equatable {
        /// As soon as the data is copied: an arrival while the copy runs.
        case afterCopy
        /// The first time the folder at this path is listed: an arrival
        /// between publication's last look inside it and the removal of the
        /// empty folder.
        case afterListing(String)
        /// The first time the item at this path is looked at: an arrival
        /// between publication's last look and the rename into place.
        case afterLookingAt(String)
    }

    /// When the interruption runs.
    private let moment: Moment
    /// What changes the file system then.
    private let interruption: () throws -> Void
    /// Whether the data has been copied; every moment follows the copy.
    private var copied = false
    /// Whether the interruption has run. It runs once.
    private var interrupted = false
    /// How many renames into place the migration asked for.
    private(set) var moveAttempts = 0

    /// A file manager that runs `interruption` once, at `moment`.
    init(at moment: Moment, _ interruption: @escaping () throws -> Void) {
        self.moment = moment
        self.interruption = interruption
        super.init()
    }

    /// Copies as FileManager does, then interrupts if this is the moment.
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        copied = true
        try interrupt(at: .afterCopy)
    }

    /// Lists as FileManager does, then interrupts if this is the moment; the
    /// names returned are those found before the interruption.
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        let names = try super.contentsOfDirectory(atPath: path)
        try interrupt(at: .afterListing(path))
        return names
    }

    /// Looks as FileManager does, then interrupts if this is the moment,
    /// whether or not anything was there to see.
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        defer { try? interrupt(at: .afterLookingAt(path)) }
        return try super.attributesOfItem(atPath: path)
    }

    /// Renames as FileManager does, counting the attempt.
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveAttempts += 1
        try super.moveItem(at: srcURL, to: dstURL)
    }

    /// Runs the interruption when `now` is its moment, the first time only.
    private func interrupt(at now: Moment) throws {
        guard copied, !interrupted, now == moment else { return }
        interrupted = true
        try interruption()
    }
}

extension XCTestCase {
    /// Lays out a data directory at `root` holding one packaged plain-text
    /// book with its analysis, and returns the library naming that book.
    /// The library is not written as `root`'s library.json. Shared by the
    /// data-directory and sandbox-container migration tests.
    func makeLibrary(at root: URL) throws -> Library {
        let packageName = "\(UUID().uuidString).tmb"
        let package = root.appendingPathComponent("Library/\(packageName)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        let content = package.appendingPathComponent("book.txt")
        try Data("migration".utf8).write(to: content)
        var book = Book(
            title: "Migrated Book",
            format: .txt,
            filePath: content.path,
            md5Hash: "hash",
            tmbDirectoryName: packageName
        )
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "Migration", text: "migration")],
            format: .txt
        )
        book.applyContentIndexSummary(index)
        var info = book.makeBookInfo()
        info.contentIndex = index
        try info.save(to: package)
        return Library(books: [book])
    }
}
