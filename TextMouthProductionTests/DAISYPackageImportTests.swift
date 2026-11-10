import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// A DAISY book kept as loose files imports with every file it needs, laid
/// out in its package as in its folder, so it reads in full after its
/// folder is gone (TODO I02). It is known by its package's checksum, so a
/// second import of it is a duplicate, and its folder is never deleted.
/// Each test imports into a library folder of its own and puts the library
/// index back afterwards.
final class DAISYPackageImportTests: XCTestCase {
    private typealias Fixtures = DAISYPackageFixtures

    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// The library folder this test imports into.
    private var folderPath: String!
    /// Where this test's DAISY books are written, outside the library.
    private var sources: URL!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "DAISY Package Import \(UUID().uuidString.prefix(8))"
        sources = try makeSandboxDirectory("daisy-package-sources")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
    }

    // MARK: - Loose Books

    /// A DAISY 3 book chosen by its package file imports with every file
    /// its manifest lists, laid out as in its folder, and nothing else from
    /// beside it. With its folder deleted, it reads every section from the
    /// copied files, as the reader reads it.
    func testLoosePackageFileReadsInFullAfterItsFolderIsGone() throws {
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles),
            named: "Ferry Timetables",
            in: sources
        )
        let source = folder.appendingPathComponent("book.opf")

        let imported = try FileImportService.importFileWithReport(from: source, toFolder: folderPath)
        try FileManager.default.removeItem(at: folder)

        let book = imported.book
        XCTAssertEqual(book.title, "Ferry Timetables of the Outer Sound")
        XCTAssertEqual(book.author, "Ottilie Vandermeer")
        XCTAssertEqual(book.format, .daisy)
        XCTAssertEqual(book.filePath, book.tmbDirectory.appendingPathComponent("book.opf").path)
        XCTAssertEqual(book.sourceFilePath, source.path)
        XCTAssertTrue(imported.isFromFolder)
        XCTAssertFalse(imported.mayDeleteOriginal)
        XCTAssertEqual(try bookFiles(of: book), Fixtures.packageBookFiles)
        try assertReadsInFull(book, sentences: Fixtures.packageBookSentences, headings: Fixtures.packageBookHeadings)
    }

    /// A DAISY 2.02 book chosen by its folder imports with its navigation
    /// file, the SMIL, text, and audio files it leads to, and the style
    /// sheets and images those use, laid out as in its folder. With the
    /// folder deleted, it reads every section.
    func testNavigationFolderReadsInFullAfterItIsGone() throws {
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, changing: Fixtures.unrelatedFiles),
            named: "Rope Splicing",
            in: sources
        )

        let imported = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)
        try FileManager.default.removeItem(at: folder)

        let book = imported.book
        XCTAssertEqual(book.title, "Notes on Rope Splicing")
        XCTAssertEqual(book.author, "Casimir Oyelaran")
        XCTAssertEqual(book.format, .daisy)
        XCTAssertEqual(book.filePath, book.tmbDirectory.appendingPathComponent("ncc.html").path)
        XCTAssertEqual(book.sourceFilePath, folder.path)
        XCTAssertTrue(imported.isFromFolder)
        XCTAssertEqual(try bookFiles(of: book), Fixtures.navigationBookFiles)
        try assertReadsInFull(book, sentences: Fixtures.navigationBookSentences, headings: Fixtures.navigationBookHeadings)
    }

    /// The same kind of book chosen by its ncc.html imports the same files.
    /// When its navigation names no title, it is listed under its folder's
    /// name, since every navigation file is called ncc.
    func testNavigationFileImportsItsBookUnderTheFoldersNameWhenUntitled() throws {
        let untitled = Fixtures.navigationBook["ncc.html", default: ""]
            .replacingOccurrences(of: "<title>Notes on Rope Splicing</title>", with: "")
            .replacingOccurrences(of: "<meta name=\"dc:title\" content=\"Notes on Rope Splicing\"/>", with: "")
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, changing: ["ncc.html": untitled]),
            named: "Splicing Lessons",
            in: sources
        )

        let book = try FileImportService.importFileWithReport(
            from: folder.appendingPathComponent("ncc.html"),
            toFolder: folderPath
        ).book

        XCTAssertEqual(book.title, "Splicing Lessons")
        XCTAssertEqual(book.author, "Casimir Oyelaran")
        XCTAssertEqual(try bookFiles(of: book), Fixtures.navigationBookFiles)
    }

    /// A package file whose name holds characters a reference reads
    /// otherwise ("#" a fragment, "%" an escape, ":" a scheme) is still the
    /// book's own file: it is listed and copied with the book, which reads.
    func testPackageFileNamedWithReferenceCharactersIsTheBooksOwnFile() throws {
        let opf = Fixtures.packageBook["book.opf", default: ""]
            .replacingOccurrences(of: "<item id=\"opf\" href=\"book.opf\" media-type=\"text/xml\"/>\n", with: "")
        for (name, folderName) in [
            ("Timetables #2 (100%).opf", "Numbered Timetables"),
            ("Ferry: Timetables.opf", "Ferry Timetables")
        ] {
            let files = Fixtures.files(Fixtures.packageBook, changing: [name: opf], removing: ["book.opf"])
            let folder = try Fixtures.writeFolder(files, named: folderName, in: sources)

            let inventory = try DAISYPackageInventory.make(for: folder)
            let book = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath).book

            XCTAssertEqual(inventory.entryPath, name)
            XCTAssertEqual(inventory.paths, files.keys.sorted(), name)
            XCTAssertEqual(book.bookFileURL.lastPathComponent, name)
            XCTAssertEqual(try bookFiles(of: book), files.keys.sorted(), name)
            try assertReadsInFull(book, sentences: Fixtures.packageBookSentences, headings: Fixtures.packageBookHeadings)
        }
    }

    // MARK: - Failures

    /// A manifest entry leading out of the book's folder fails the import
    /// while the file is read, naming the entry and the file making it.
    /// Nothing is left in the library folder, and the file outside is
    /// neither copied nor changed.
    func testReferenceLeavingTheFolderFailsTheImportByName() throws {
        let shared = sources.appendingPathComponent("shared.xml")
        try Data("a file outside the book".utf8).write(to: shared)
        let opf = Fixtures.packageBook["book.opf", default: ""]
            .replacingOccurrences(of: "images/harbor%20map.png", with: "../shared.xml")
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: ["book.opf": opf]),
            named: "Ferry Timetables",
            in: sources
        )

        XCTAssertThrowsError(
            try FileImportService.importFileWithReport(from: folder.appendingPathComponent("book.opf"), toFolder: folderPath)
        ) { error in
            let failure = error as? ImportFailure
            XCTAssertEqual(failure?.step, .readingSource)
            XCTAssertEqual(
                failure?.underlying as? DAISYPackageError,
                .referenceOutsidePackage(reference: "../shared.xml", file: "book.opf")
            )
            XCTAssertEqual(
                failure?.localizedDescription,
                "Could not import “book.opf”. Reading the file failed: The file “book.opf” in this DAISY book "
                    + "refers to “../shared.xml”, which is outside the book's folder. Only files inside the folder can be imported."
            )
        }
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "a file outside the book")
    }

    /// A folder that holds no DAISY book fails while its format is checked,
    /// saying in words what is wrong, and leaves nothing behind.
    func testFolderWithoutABookFailsSayingSo() throws {
        let folder = try Fixtures.writeFolder(["notes.txt": "Nothing to read here."], named: "Harbor Notes", in: sources)

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .checkingFormat)
            XCTAssertEqual(
                error.localizedDescription,
                "Could not import “Harbor Notes”. Checking its format failed: “Harbor Notes” holds no DAISY book "
                    + "and no audio tracks to import as one book. It holds 1 .txt file."
            )
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    /// A folder in another book format is never taken for a DAISY package,
    /// even with a package file at its top: an unpacked EPUB named like one
    /// fails as before, and nothing of it is copied.
    func testFolderInAnotherFormatIsNeverTakenForADAISYPackage() throws {
        let folder = try Fixtures.writeFolder(
            ["content.opf": Fixtures.packageBook["book.opf", default: ""], "mimetype": "application/epub+zip"],
            named: "Harbor Guide.epub",
            in: sources
        )

        XCTAssertEqual(BookFormat.detect(from: folder), .epub)
        XCTAssertThrowsError(try FileImportService.importHash(of: folder))
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .readingSource)
            XCTAssertNil((error as? ImportFailure)?.underlying as? DAISYPackageError)
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    // MARK: - Duplicates

    /// The same book imported again, here from a copy of its folder
    /// elsewhere, has the same checksum: its package's, which
    /// `importHash(of:)` computes before anything is copied. The library
    /// recognizes it as a duplicate and asks, and never offers to delete
    /// the book's folder.
    @MainActor
    func testReimportingThePackageIsRecognizedAsADuplicate() throws {
        let folder = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let copy = try Fixtures.writeFolder(
            Fixtures.navigationBook,
            named: "Rope Splicing",
            in: sources.appendingPathComponent("Downloads", isDirectory: true)
        )

        let first = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)
        let second = try FileImportService.importFileWithReport(
            from: copy.appendingPathComponent("ncc.html"),
            toFolder: folderPath
        )

        XCTAssertEqual(first.book.md5Hash, try DAISYPackageInventory.make(for: folder).contentHash())
        XCTAssertEqual(try FileImportService.importHash(of: folder), first.book.md5Hash)
        XCTAssertEqual(second.book.md5Hash, first.book.md5Hash)
        XCTAssertNotEqual(second.book.sourceFilePath, first.book.sourceFilePath)

        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [first.book])
        model.completeSingleImportedBook(second, originalURL: copy.appendingPathComponent("ncc.html"))

        let duplicate = try XCTUnwrap(model.importDecisions.current?.duplicate)
        XCTAssertEqual(duplicate.existing.id, first.book.id)
        XCTAssertEqual(duplicate.book.id, second.book.id)
        XCTAssertNil(duplicate.originalURL)
    }

    /// Any other source's import checksum is the MD5 of its file, as before.
    func testImportHashOfASingleFileIsItsMD5() throws {
        let epub = try requireFile("alice.epub")

        XCTAssertEqual(try FileImportService.importHash(of: epub), try FileImportService.md5Hash(of: epub))
    }

    // MARK: - The Original

    /// A DAISY book's folder is never deleted after its import, nor offered
    /// for deletion, whatever the "After Importing a Book" preference says:
    /// it holds files that are not the book's.
    @MainActor
    func testPackageImportNeverDeletesOrOffersToDeleteItsFolder() throws {
        let packageFolder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles),
            named: "Ferry Timetables",
            in: sources
        )
        let navigationFolder = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        for (folder, original, behavior) in [
            (packageFolder, packageFolder.appendingPathComponent("book.opf"), ImportDeleteBehavior.deleteAfterImport),
            (navigationFolder, navigationFolder, ImportDeleteBehavior.askEachTime)
        ] {
            let imported = try FileImportService.importFileWithReport(from: original, toFolder: folderPath)
            withImportDeleteBehavior(behavior) {
                model.completeSingleImportedBook(imported, originalURL: original)
            }

            XCTAssertTrue(model.library.books.contains { $0.id == imported.book.id }, folder.lastPathComponent)
            XCTAssertTrue(model.importDecisions.isEmpty, folder.lastPathComponent)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), folder.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageFolder.appendingPathComponent("notes.txt").path))
    }

    /// What the reader is told when the preference would have deleted the
    /// archive a DAISY book's audio was imported from, or asked about it.
    private static func talkingBookKeptNotice(archive: URL) -> String {
        "The original file was kept: TextMouth imported the audio of “Ferry Timetables of the Outer Sound” "
            + "from the archive “\(archive.lastPathComponent)”, and the archive is the only copy of its text."
    }

    /// An archive holding a DAISY book with audio imports as its audio
    /// alone: its text, the DTBook a braille reader reads, stays in the
    /// archive, which is then its only copy. So the archive is never
    /// deleted after the import, nor offered for deletion, whatever the
    /// "After Importing a Book" preference says; when the preference would
    /// have deleted it or asked, the reader is told it was kept, and why,
    /// and with the preference to keep, nothing is said. The deletion runs
    /// with the Trash off, so a regression removes only this test's file.
    @MainActor
    func testADAISYArchiveWhoseAudioIsImportedIsNeverDeleted() throws {
        keepDeletionsOutOfTheTrash()
        for (behavior, says) in [
            (ImportDeleteBehavior.deleteAfterImport, true), (.askEachTime, true), (.keepOriginal, false)
        ] {
            let label = "\(behavior)"
            let archive = try makeArchive(Self.talkingBookEntries())
            XCTAssertTrue(DAISYParser.isDAISYZip(url: archive), label)
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library()
            // Only a question about the original may wait here, never an
            // offer to transcribe the audiobook, whatever this Mac offers.
            model.offersTranscription = { _ in false }

            let imported = try FileImportService.importDAISYAudioZipWithReport(from: archive, toFolder: folderPath)
            XCTAssertTrue(imported.tookOnlyPartOfOriginal, label)
            XCTAssertFalse(imported.mayDeleteOriginal, label)
            XCTAssertEqual(imported.originalKeptNotice, Self.talkingBookKeptNotice(archive: archive), label)
            withImportDeleteBehavior(behavior) {
                model.completeSingleImportedBook(imported, originalURL: archive)
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path), "\(label): the archive is kept")
            XCTAssertTrue(model.library.books.contains { $0.id == imported.book.id }, label)
            XCTAssertTrue(model.importDecisions.isEmpty, "\(label): no question about the archive")
            XCTAssertEqual(model.errorMessage, says ? Self.talkingBookKeptNotice(archive: archive) : nil, label)
            // The book was added, so the alert is no error.
            XCTAssertEqual(model.errorTitle, says ? "Book Imported" : nil, label)
        }
    }

    /// A talking book of audio and navigation only, the common kind, in an
    /// archive of its own, leaves no text behind in the archive: the
    /// "After Importing a Book" preference stands, so Delete After Import
    /// deletes the archive, and no sentence says it was kept (data review,
    /// finding 5). The deletion runs with the Trash off, so a regression
    /// removes only this test's file.
    @MainActor
    func testAnAudioOnlyTalkingBookArchiveIsDeletedLikeAnyOther() throws {
        keepDeletionsOutOfTheTrash()
        var entries = try Self.talkingBookEntries()
        // No DTBook: the SMIL files' text elements name a file that is not there.
        entries["content/timetables.xml"] = nil
        let archive = try makeArchive(entries)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        model.offersTranscription = { _ in false }

        let imported = try FileImportService.importDAISYAudioZipWithReport(from: archive, toFolder: folderPath)

        XCTAssertFalse(imported.tookOnlyPartOfOriginal)
        XCTAssertTrue(imported.mayDeleteOriginal)
        XCTAssertNil(imported.originalKeptNotice)
        withImportDeleteBehavior(.deleteAfterImport) {
            model.completeSingleImportedBook(imported, originalURL: archive)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path), "the archive of an audio-only book was kept")
        XCTAssertNil(model.errorMessage)
    }

    /// An archive holding a DAISY book with text beside two other books (an
    /// EPUB and a PDF) keeps its archive, and the sentence names the book
    /// and the archive and says how many books were not imported and that
    /// unzipping the archive lets them be imported (data review, finding 5).
    @MainActor
    func testAnArchiveWithOtherBooksBesideTheDAISYFolderSaysHowManyWereNotImported() throws {
        var entries: [String: Data] = [:]
        for (path, data) in try Self.talkingBookEntries() { entries["Ferry/\(path)"] = data }
        entries["reader.epub"] = Data("not really an EPUB".utf8)
        entries["extras/handout.pdf"] = Data("not really a PDF".utf8)
        entries["extras/cover.jpg"] = Data("not a book".utf8)
        let archive = try makeArchive(entries)
        XCTAssertTrue(DAISYParser.isDAISYZip(url: archive))

        let imported = try FileImportService.importDAISYAudioZipWithReport(from: archive, toFolder: folderPath)

        XCTAssertTrue(imported.tookOnlyPartOfOriginal)
        XCTAssertEqual(
            imported.originalKeptNotice,
            "The original file was kept: TextMouth imported the audio of “Ferry Timetables of the Outer Sound” "
                + "from the archive “\(archive.lastPathComponent)”, and the archive is the only copy of its text. "
                + "The archive also holds 2 other books that were not imported; unzip it to import them."
        )
    }

    /// An audio-only DAISY book beside one other book keeps its archive too,
    /// since deleting it would lose the other book, and the sentence says so
    /// in the words of a book with no text of its own to keep.
    @MainActor
    func testAnAudioOnlyTalkingBookBesideAnotherBookKeepsItsArchive() throws {
        var entries: [String: Data] = [:]
        for (path, data) in try Self.talkingBookEntries() where path != "content/timetables.xml" {
            entries["Ferry/\(path)"] = data
        }
        entries["reader.epub"] = Data("not really an EPUB".utf8)
        let archive = try makeArchive(entries)

        let imported = try FileImportService.importDAISYAudioZipWithReport(from: archive, toFolder: folderPath)

        XCTAssertFalse(imported.mayDeleteOriginal)
        XCTAssertEqual(
            imported.originalKeptNotice,
            "The original file was kept: TextMouth imported only the DAISY book “Ferry Timetables of the Outer Sound” "
                + "from the archive “\(archive.lastPathComponent)”. "
                + "The archive also holds 1 other book that was not imported; unzip it to import it."
        )
    }

    /// An archive holding a DAISY book without audio is imported whole, the
    /// archive copied into the book's package, so its original may still be
    /// deleted, as before, and nothing is said about keeping it.
    func testADAISYArchiveWithoutAudioMayStillBeDeleted() throws {
        let archive = try makeArchive(Fixtures.packageBook.mapValues { Data($0.utf8) })

        let imported = try FileImportService.importFileWithReport(from: archive, toFolder: folderPath)

        XCTAssertFalse(imported.tookOnlyPartOfOriginal)
        XCTAssertTrue(imported.mayDeleteOriginal)
        XCTAssertNil(imported.originalKeptNotice)
    }

    // MARK: - Folders of Tracks

    /// The files `makeNightFerries(in:)` writes, as paths inside the folder.
    private static let nightFerriesFiles = ["01.wav", "02.wav", "cover.jpg", "lyrics.txt", "Bonus/liner notes.txt"]

    /// Writes the folder `Night Ferries` into `parent`: two real silent
    /// tracks, and the files an import does not copy (a cover, lyrics, and a
    /// `Bonus` folder), and returns it.
    @discardableResult
    private func makeNightFerries(in parent: URL) throws -> URL {
        let folder = try Fixtures.writeFolder(
            ["cover.jpg": "not really a picture", "lyrics.txt": "Words.", "Bonus/liner notes.txt": "Notes."],
            named: "Night Ferries",
            in: parent
        )
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"), duration: 0.2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("02.wav"), duration: 0.2)
        return folder
    }

    /// A folder of audio tracks is never deleted after its import, nor
    /// offered for deletion, whatever the "After Importing a Book"
    /// preference says: it holds files the import did not copy (a cover,
    /// lyrics, a Bonus folder).
    @MainActor
    func testFolderOfTracksImportNeverDeletesOrOffersToDeleteItsFolder() throws {
        // A regression must remove only this test's sandbox, never reach the user's Trash.
        keepDeletionsOutOfTheTrash()

        for behavior in [ImportDeleteBehavior.deleteAfterImport, .askEachTime] {
            // Each behavior imports its own fresh folder: a second import of one folder is a duplicate.
            let label = "\(behavior)"
            let folder = try makeNightFerries(in: sources.appendingPathComponent(label, isDirectory: true))
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library()

            let imported = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)
            XCTAssertTrue(imported.isFromFolder, label)
            XCTAssertFalse(imported.mayDeleteOriginal, label)
            withImportDeleteBehavior(behavior) {
                model.completeSingleImportedBook(imported, originalURL: folder)
            }

            XCTAssertTrue(model.library.books.contains { $0.id == imported.book.id }, label)
            XCTAssertTrue(model.importDecisions.isEmpty, label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), label)
            for file in Self.nightFerriesFiles {
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path), "\(label): \(file)")
            }
        }
    }

    /// The same folder of tracks imported again, here from a copy of it
    /// under another parent, is a duplicate; the duplicate question never
    /// offers to delete the folder.
    @MainActor
    func testReimportingAFolderOfTracksIsADuplicateThatNeverOffersItsFolder() throws {
        keepDeletionsOutOfTheTrash()
        let folder = try makeNightFerries(in: sources)
        let copy = try makeNightFerries(in: sources.appendingPathComponent("Downloads", isDirectory: true))

        let first = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)
        let second = try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)
        XCTAssertEqual(second.book.md5Hash, first.book.md5Hash)

        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [first.book])
        withImportDeleteBehavior(.deleteAfterImport) {
            model.completeSingleImportedBook(second, originalURL: copy)
        }

        let duplicate = try XCTUnwrap(model.importDecisions.current?.duplicate)
        XCTAssertEqual(duplicate.existing.id, first.book.id)
        XCTAssertEqual(duplicate.book.id, second.book.id)
        XCTAssertNil(duplicate.originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    /// `files` with `prefix` put before each path, so a book's files can be
    /// written inside a folder of a larger folder.
    private func inside(_ prefix: String, _ files: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: files.map { (prefix + $0.key, $0.value) })
    }

    /// Asserts that importing `folder` fails while its format is checked,
    /// because it holds no book of its own (`FolderWithoutBookError`), and
    /// that nothing was copied. Returns the error's message.
    @discardableResult
    private func assertRefusedAsNoBook(_ folder: URL, file: StaticString = #filePath, line: UInt = #line) -> String? {
        var message: String?
        XCTAssertThrowsError(
            try FileImportService.importFileWithReport(from: folder, toFolder: folderPath), file: file, line: line
        ) { error in
            let failure = error as? ImportFailure
            XCTAssertEqual(failure?.step, .checkingFormat, file: file, line: line)
            XCTAssertEqual(
                (failure?.underlying as? FolderWithoutBookError)?.folderName,
                folder.lastPathComponent,
                file: file,
                line: line
            )
            message = error.localizedDescription
        }
        XCTAssertEqual((try? folderEntries()) ?? ["unreadable"], [], file: file, line: line)
        return message
    }

    /// A folder of DAISY book folders is not itself a book: it is refused
    /// like any folder without a book, not imported as one audiobook of
    /// every book's audio files, and nothing in it is copied or changed.
    func testAParentOfDAISYBookFoldersIsRefusedNotImportedAsOneAudiobook() throws {
        // Each book's folder holds its DAISY files and an (empty) audio track.
        var files = inside("Rope Splicing/", Fixtures.navigationBook)
        files["Rope Splicing/track.mp3"] = ""
        files.merge(inside("Ferry Timetables/", Fixtures.packageBook)) { $1 }
        files["Ferry Timetables/track.mp3"] = ""
        let parent = try Fixtures.writeFolder(files, named: "Audiobooks", in: sources)
        let before = try FileManager.default.subpathsOfDirectory(atPath: parent.path).sorted()

        XCTAssertEqual(LibraryViewModel.importSources(for: parent), [parent])
        XCTAssertFalse(FileImportService.isFolderOfTracks(parent))
        // The refusal's sentence is the one for any folder without a book of its own.
        XCTAssertEqual(
            assertRefusedAsNoBook(parent),
            "Could not import “Audiobooks”. Checking its format failed: “Audiobooks” holds no DAISY book and no "
                + "audio tracks to import as one book. It holds 4 .mp3 files, 3 .css files, 3 .smil files, and 7 other files."
        )
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: parent.path).sorted(), before)
    }

    /// A symbolic link to a folder of DAISY book folders is imported as the
    /// folder itself is: refused, with the folder's own sentence, and not as
    /// one audiobook of every book's tracks. The enumerator does not enter a
    /// link, so the walks that find a DAISY book beneath the folder, and the
    /// files it holds, must start at the folder the link leads to.
    func testALinkToAParentOfDAISYBookFoldersIsRefusedAsTheFolderItselfIs() throws {
        var files = inside("Rope Splicing/", Fixtures.navigationBook)
        files["Rope Splicing/track.mp3"] = ""
        files.merge(inside("Ferry Timetables/", Fixtures.packageBook)) { $1 }
        files["Ferry Timetables/track.mp3"] = ""
        let parent = try Fixtures.writeFolder(files, named: "Audiobooks", in: sources)
        let link = sources.appendingPathComponent("Linked Audiobooks")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)

        XCTAssertFalse(FileImportService.isFolderOfTracks(parent), "the folder itself")
        XCTAssertFalse(FileImportService.isFolderOfTracks(link), "a link to it is a folder of tracks")
        let direct = assertRefusedAsNoBook(parent)
        var viaLink: String?
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: link, toFolder: folderPath)) { error in
            let failure = error as? ImportFailure
            XCTAssertEqual(failure?.step, .checkingFormat, "\(error)")
            XCTAssertEqual((failure?.underlying as? FolderWithoutBookError)?.folderName, "Audiobooks", "\(error)")
            viaLink = error.localizedDescription
        }
        XCTAssertEqual(viaLink, direct, "the sentence for a link differs from the folder's")
        XCTAssertEqual((try? folderEntries()) ?? ["unreadable"], [], "something was copied")
    }

    /// A positive control: a symbolic link to a folder of tracks imports as
    /// one audiobook, named and made as the folder itself is, from the folder
    /// the link leads to, and the folder is kept.
    func testALinkToAFolderOfTracksImportsAsTheFolderItselfDoes() throws {
        let folder = try Fixtures.writeFolder(
            ["Bonus/notes.txt": "Notes.", "Bonus/cover.jpg": "not really a picture"],
            named: "Night Ferries",
            in: sources
        )
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"), duration: 0.2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("02.wav"), duration: 0.2)
        let link = sources.appendingPathComponent("Linked Ferries")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        XCTAssertTrue(FileImportService.isFolderOfTracks(link))
        let imported = try FileImportService.importFileWithReport(from: link, toFolder: folderPath)
        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertEqual(imported.book.title, "Night Ferries", "the book is named by the folder it leads to")
        XCTAssertTrue(imported.isFromFolder)
        XCTAssertFalse(imported.mayDeleteOriginal, "a folder is never deleted as an original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("01.wav").path))
    }

    /// A DAISY book two folders deep also makes its parent a folder that is
    /// not a book, whatever audio sits at the parent's top.
    func testADAISYBookTwoFoldersDeepAlsoRefusesTheParent() throws {
        var files = inside("Author/Rope Splicing/", Fixtures.navigationBook)
        files["track.mp3"] = ""
        let parent = try Fixtures.writeFolder(files, named: "Library", in: sources)

        XCTAssertFalse(FileImportService.isFolderOfTracks(parent))
        assertRefusedAsNoBook(parent)
    }

    /// A positive control: a plain subfolder, holding no DAISY book, does not
    /// stop a folder of tracks importing as one audiobook.
    func testAFolderOfTracksWithAPlainSubfolderStillImportsAsOneAudiobook() throws {
        let folder = try Fixtures.writeFolder(
            ["Bonus/notes.txt": "Notes.", "Bonus/cover.jpg": "not really a picture"],
            named: "Night Ferries",
            in: sources
        )
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"), duration: 0.2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("02.wav"), duration: 0.2)

        XCTAssertTrue(FileImportService.isFolderOfTracks(folder))
        let imported = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)
        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertEqual(imported.book.title, "Night Ferries")
    }

    /// A DAISY book inside Finder's __MACOSX folder or a hidden folder is
    /// not a book of the folder's: tracks beside them still import as one.
    func testADAISYBookInsideMACOSXOrAHiddenFolderDoesNotBlockAFolderOfTracks() throws {
        var files = inside("__MACOSX/Night Ferries/", Fixtures.navigationBook)
        files.merge(inside(".hidden/", Fixtures.navigationBook)) { $1 }
        let folder = try Fixtures.writeFolder(files, named: "Night Ferries", in: sources)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"), duration: 0.2)

        XCTAssertTrue(DAISYParser.isDAISYDirectory(url: folder.appendingPathComponent("__MACOSX/Night Ferries")))
        XCTAssertTrue(DAISYParser.isDAISYDirectory(url: folder.appendingPathComponent(".hidden")))
        XCTAssertTrue(FileImportService.isFolderOfTracks(folder))
    }

    // MARK: - What Is Copied Instead

    /// A DAISY 3 book whose manifest names no DTBook is copied whole, since
    /// the reader searches its folder for one, and it still reads in full;
    /// the debug log says the whole folder was copied, and why.
    func testBookCopiedWholeReadsInFullAndIsLogged() throws {
        let opf = Fixtures.packageBook["book.opf", default: ""]
            .replacingOccurrences(of: "application/x-dtbook+xml", with: "text/xml")
        let files = Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles.merging(["book.opf": opf]) { _, new in new })
        let folder = try Fixtures.writeFolder(files, named: "Ferry Timetables Whole", in: sources)

        let book = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath).book

        XCTAssertEqual(try bookFiles(of: book), files.keys.filter { !$0.hasPrefix(".") }.sorted())
        try assertReadsInFull(book, sentences: Fixtures.packageBookSentences, headings: Fixtures.packageBookHeadings)
        let logged = debugLogLines(containing: "DAISY_PACKAGE_WHOLE_FOLDER: \(folder.lastPathComponent): ")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.first?.contains("lists no DTBook content file") == true, logged.first ?? "")
    }

    /// A book referring to a file that does not exist still imports, as it
    /// read before, and the debug log names the missing file.
    func testMissingFileIsLoggedByNameAndTheBookStillImports() throws {
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, removing: ["images/eye splice.png"]),
            named: "Rope Splicing Without Pictures",
            in: sources
        )

        let book = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath).book

        XCTAssertEqual(try bookFiles(of: book), Fixtures.navigationBookFiles.filter { $0 != "images/eye splice.png" })
        XCTAssertEqual(
            debugLogLines(containing: "DAISY_PACKAGE_MISSING: \(folder.lastPathComponent)/ncc.html: ").last
                .map { $0.hasSuffix("refers to 1 file(s) that do not exist: images/eye splice.png") },
            true
        )
    }

    // MARK: - Archives

    /// An archive holding two DAISY books, each in a folder of its own, and
    /// an EPUB imports three books, each once: each DAISY book as one
    /// package holding every file it needs, with none of the files in its
    /// folder (notes, unused audio) imported as books of their own, and
    /// macOS's `__MACOSX` copies passed over. Both DAISY books read in full
    /// once the archive's extraction is gone.
    func testArchiveOfTwoPackagedBooksAndAnEPUBImportsEachBookOnce() throws {
        let archive = try makeArchive(Self.twoPackagedBooksAndAnEPUB())
        XCTAssertFalse(DAISYParser.isDAISYZip(url: archive))

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.incompleteBooks, [])
        XCTAssertNil(result.failureSummary)
        XCTAssertEqual(result.books.map(\.format.rawValue).sorted(), ["daisy", "daisy", "epub"])
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
        let navigationBook = try XCTUnwrap(result.books.first { $0.title == "Notes on Rope Splicing" })
        let packageBook = try XCTUnwrap(result.books.first { $0.title == "Ferry Timetables of the Outer Sound" })
        XCTAssertEqual(try bookFiles(of: navigationBook), Fixtures.navigationBookFiles)
        XCTAssertEqual(try bookFiles(of: packageBook), Fixtures.packageBookFiles)
        try assertReadsInFull(
            navigationBook,
            sentences: Fixtures.navigationBookSentences,
            headings: Fixtures.navigationBookHeadings
        )
        try assertReadsInFull(packageBook, sentences: Fixtures.packageBookSentences, headings: Fixtures.packageBookHeadings)
    }

    /// The library's own ZIP import takes such an archive as a batch, not as
    /// one DAISY book: it adds the three books, reports no failure, and
    /// offers to put them in a folder of their own.
    @MainActor
    func testLibraryImportsAnArchiveOfPackagedBooksAsABatch() throws {
        let archive = try makeArchive(Self.twoPackagedBooksAndAnEPUB())
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        withImportDeleteBehavior(.keepOriginal) {
            model.importZipAsync(from: archive, toFolder: folderPath)
            XCTAssertTrue(
                eventually(within: 60) { model.importDecisions.current?.zipBatch != nil || model.showError },
                "the batch never finished"
            )
        }

        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.library.books.map(\.format.rawValue).sorted(), ["daisy", "daisy", "epub"])
        XCTAssertEqual(
            Set(model.importDecisions.current?.zipBatch?.books.map(\.id) ?? []),
            Set(model.library.books.map(\.id))
        )
    }

    /// The library's own ZIP import reads an archive holding one DAISY book
    /// and no audio as a text book: it opens the archive a second time,
    /// finds no audio there, and imports the book's text (TODO Q06 pins
    /// this before the archive is opened through another initializer;
    /// `AudioMediaImportTests` covers the archive with audio).
    @MainActor
    func testLibraryImportsADAISYArchiveWithoutAudioAsATextBook() throws {
        let archive = try makeArchive(Fixtures.packageBook.mapValues { Data($0.utf8) })
        XCTAssertTrue(DAISYParser.isDAISYZip(url: archive))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        withImportDeleteBehavior(.keepOriginal) {
            model.importZipAsync(from: archive, toFolder: folderPath)
            XCTAssertTrue(
                eventually(within: 60) { !model.library.books.isEmpty || model.showError },
                "the import never finished"
            )
        }

        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.library.books.map(\.format), [.daisy])
        XCTAssertEqual(model.library.books.map(\.title), ["Ferry Timetables of the Outer Sound"])
    }

    /// A DAISY book that appears twice in an archive, in two folders, is
    /// imported once, and a book the library already holds is not imported
    /// again: both are recognized by the package's checksum before anything
    /// is copied, so neither leaves a package behind.
    func testArchiveImportsEachDAISYBookOnceByItsChecksum() throws {
        var entries: [String: Data] = [:]
        for folder in ["Rope Splicing", "Rope Splicing Copy"] {
            entries.merge(Self.archiveEntries(Fixtures.navigationBook, inFolder: folder)) { first, _ in first }
        }
        let archive = try makeArchive(entries)

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)
        let again = try FileImportService.importZip(
            from: archive,
            toFolder: folderPath,
            existingHashes: Set(result.books.map(\.md5Hash))
        )

        XCTAssertEqual(result.books.map(\.title), ["Notes on Rope Splicing"])
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(again.books, [])
        XCTAssertEqual(again.failures, [])
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
    }

    /// A DAISY book in an archive that cannot be imported is named once in
    /// the batch's summary, by its folder, with the reason; the archive's
    /// other books still import.
    func testFailingPackagedBookIsNamedOnceByItsFolder() throws {
        let opf = Fixtures.packageBook["book.opf", default: ""]
            .replacingOccurrences(of: "images/harbor%20map.png", with: "../../outside.xml")
        let archive = try makeArchive(
            Self.archiveEntries(Fixtures.files(Fixtures.packageBook, changing: ["book.opf": opf]), inFolder: "Ferry Timetables")
                .merging(Self.archiveEntries(Fixtures.navigationBook, inFolder: "Rope Splicing")) { first, _ in first }
        )

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)

        XCTAssertEqual(result.books.map(\.title), ["Notes on Rope Splicing"])
        XCTAssertEqual(result.failures, [ZipImportFailure(
            fileName: "Ferry Timetables",
            message: "Reading the file failed: The file “book.opf” in this DAISY book refers to “../../outside.xml”, "
                + "which is outside the book's folder. Only files inside the folder can be imported."
        )])
        let summary = try XCTUnwrap(result.failureSummary)
        XCTAssertEqual(summary.components(separatedBy: "Ferry Timetables").count, 2, summary)
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))
    }

    /// A folder in an archive holding two books' package files imports each
    /// book from its own package file.
    func testArchiveFolderOfTwoPackageFilesImportsEachBook() throws {
        let archive = try makeArchive(Self.archiveEntries(Fixtures.twoBooksFolder, inFolder: "Two Books"))

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(Set(result.books.map(\.title)), ["Ferry Timetables of the Outer Sound", "Harbor Almanac"])
        let almanacBook = try XCTUnwrap(result.books.first { $0.title == "Harbor Almanac" })
        XCTAssertEqual(almanacBook.bookFileURL.lastPathComponent, "almanac.opf")
        XCTAssertTrue(
            try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: almanacBook.bookFileURL))
                .contains(Fixtures.almanacSentence)
        )
    }

    /// An archive inside the archive that holds several DAISY books is
    /// unpacked and searched like the archive itself, each of its books
    /// imported once as a package, while one that is a single DAISY book is
    /// imported as the DAISY ZIP it is, as before.
    func testNestedArchivesAreSearchedForPackagedBooks() throws {
        let inner = try makeArchive(Self.twoPackagedBooksAndAnEPUB())
        let archive = try makeArchive([
            "Collection.zip": try Data(contentsOf: inner),
            "Tides.zip": try Data(contentsOf: requireFile("daisy202_test.zip"))
        ])

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(
            Set(result.books.map(\.title)),
            Set(["Notes on Rope Splicing", "Ferry Timetables of the Outer Sound", "The Manual of Tide Prediction"])
                .union(result.books.filter { $0.format == .epub }.map(\.title))
        )
        XCTAssertEqual(result.books.count, 4)
        let tides = try XCTUnwrap(result.books.first { $0.title == "The Manual of Tide Prediction" })
        XCTAssertEqual(tides.bookFileURL.lastPathComponent, "Tides.zip")
        XCTAssertFalse(result.books.contains { $0.bookFileURL.lastPathComponent == "Collection.zip" })
    }

    // MARK: - Choosing a Book in the Open Panel

    /// The standard Open Book... panel offers files only, as it always did,
    /// so Return on a folder there keeps opening the folder, as keyboard
    /// and VoiceOver users rely on: no type it allows is a plain folder. The
    /// only ones that are directories at all are packages, which the panel
    /// shows as a single file: TextMouth's own package, and an RTFD (rich
    /// text with attachments, FMT13). A DAISY book's ncc.html stays
    /// choosable, as the HTML file it is.
    func testOpenBookPanelOffersFilesOnly() throws {
        let types = FileImportService.supportedTypes
        let packageType = try XCTUnwrap(UTType("com.textmouth.book-package"))
        let navigationFile = try XCTUnwrap(UTType(filenameExtension: "html"))

        XCTAssertFalse(types.contains(.folder))
        XCTAssertFalse(types.contains(.directory))
        XCTAssertEqual(Set(types.filter { $0.conforms(to: .directory) }), [packageType, .rtfd])
        XCTAssertTrue(types.contains { navigationFile.conforms(to: $0) })
    }

    /// A folder chosen or dropped whose top level holds several DAISY
    /// books' package files is imported as each of those files, one book
    /// each. Any other item, a folder holding one book or none included,
    /// is imported as itself.
    func testFolderOfSeveralBooksIsImportedAsEachPackageFile() throws {
        let twoBooks = try Fixtures.writeFolder(Fixtures.twoBooksFolder, named: "Two Books", in: sources)
        let oneBook = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let notes = try Fixtures.writeFolder(["notes.txt": "Nothing to read here."], named: "Harbor Notes", in: sources)
        let epub = try requireFile("alice.epub")

        XCTAssertEqual(LibraryViewModel.importSources(for: twoBooks).map(\.lastPathComponent), ["almanac.opf", "book.opf"])
        XCTAssertEqual(LibraryViewModel.importSources(for: oneBook), [oneBook])
        XCTAssertEqual(LibraryViewModel.importSources(for: notes), [notes])
        XCTAssertEqual(LibraryViewModel.importSources(for: epub), [epub])
    }

    /// DAISY books' folders chosen with Import DAISY Folder… import into the
    /// folder being viewed, each book with every file it needs: one folder
    /// as its one book, a folder of two package files as two books. No
    /// folder is deleted, and no reader window opens.
    @MainActor
    func testFoldersChosenWithImportDAISYFolderImportTheirBooks() throws {
        let navigationFolder = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let twoBooks = try Fixtures.writeFolder(Fixtures.twoBooksFolder, named: "Two Books", in: sources)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        withImportDeleteBehavior(.deleteAfterImport) {
            model.importDAISYFolders([navigationFolder, twoBooks], toFolder: folderPath)
            XCTAssertTrue(
                eventually(within: 60) { model.library.books.count == 3 || model.showError },
                "the imports never finished"
            )
        }

        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(
            Set(model.library.books.map(\.title)),
            ["Notes on Rope Splicing", "Ferry Timetables of the Outer Sound", "Harbor Almanac"]
        )
        XCTAssertTrue(model.library.books.allSatisfy { $0.format == .daisy && $0.folderPath == folderPath })
        let navigationBook = try XCTUnwrap(model.library.books.first { $0.title == "Notes on Rope Splicing" })
        XCTAssertEqual(try bookFiles(of: navigationBook), Fixtures.navigationBookFiles)
        XCTAssertTrue(FileManager.default.fileExists(atPath: navigationFolder.appendingPathComponent("ncc.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: twoBooks.appendingPathComponent("almanac.opf").path))
    }

    /// A folder holding no DAISY book chosen with Import DAISY Folder… is
    /// refused through the library's alert, which says what is wrong, and
    /// nothing is added.
    @MainActor
    func testFolderWithoutABookChosenWithImportDAISYFolderSaysWhy() throws {
        let notes = try Fixtures.writeFolder(["notes.txt": "Nothing to read here."], named: "Harbor Notes", in: sources)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        model.importDAISYFolders([notes], toFolder: folderPath)

        XCTAssertTrue(eventually(within: 20) { model.showError }, "the import never reported its failure")
        XCTAssertEqual(
            model.errorMessage,
            "Could not import “Harbor Notes”. Checking its format failed: “Harbor Notes” holds no DAISY book "
                + "and no audio tracks to import as one book. It holds 1 .txt file."
        )
        XCTAssertTrue(model.library.books.isEmpty)
        XCTAssertEqual(try folderEntries(), [])
    }

    // MARK: - Import DAISY Folder…

    /// The running app's Library menu offers Import DAISY Folder… as an
    /// ordinary menu item, enabled, with Command-Shift-O, its action's
    /// default since the key became editable (FR12's branch D), which
    /// neither the app's other menu items nor any other action's default key
    /// bindings use. The item is only read, never chosen: choosing it would
    /// present a real panel.
    /// Skipped when this run's menu bar has no Library menu at all.
    @MainActor
    func testLibraryMenuOffersImportDAISYFolder() throws {
        guard let libraryMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Library" })?.submenu else {
            throw XCTSkip("This run's menu bar has no Library menu")
        }
        // Brings the items up to date, as the menu does before it opens.
        libraryMenu.delegate?.menuNeedsUpdate?(libraryMenu)

        let item = try XCTUnwrap(
            libraryMenu.items.first { $0.title == "Import Folder…" },
            "The Library menu holds \(libraryMenu.items.map(\.title))"
        )
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(
            Self.answersCommandShiftO(item),
            "key \(item.keyEquivalent), modifiers \(item.keyEquivalentModifierMask.rawValue)"
        )

        // The shortcut is the command's alone.
        let otherItems = Self.allItems(of: NSApp.mainMenu).filter { $0 !== item && Self.answersCommandShiftO($0) }
        XCTAssertEqual(otherItems.map(\.title), [])
        let commandShiftO = KeyBinding(key: "o", command: true, shift: true)
        XCTAssertEqual(ShortcutAction.defaultBindings[.importDAISYFolder], [commandShiftO])
        XCTAssertFalse(
            ShortcutAction.defaultBindings.filter { $0.key != .importDAISYFolder }.values.joined().contains(commandShiftO)
        )
    }

    /// Whether `item` answers Command-Shift-O. A shortcut can be stored as
    /// "o" with the Shift modifier, or as the shifted "O".
    @MainActor
    private static func answersCommandShiftO(_ item: NSMenuItem) -> Bool {
        let modifiers = item.keyEquivalentModifierMask
        return item.keyEquivalent.lowercased() == "o"
            && modifiers.contains(.command)
            && (modifiers.contains(.shift) || item.keyEquivalent == "O")
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)
    }

    /// Every item of `menu` and of the menus inside it, each menu brought up
    /// to date first, as it is before it opens.
    @MainActor
    private static func allItems(of menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.flatMap { [$0] + allItems(of: $0.submenu) }
    }

    /// The command's panel chooses folders, several at once, and no files,
    /// with a title, message, and button that say what it does. The panel
    /// is only built here, never presented.
    @MainActor
    func testImportDAISYFolderPanelChoosesSeveralFoldersAndNoFiles() {
        let panel = LibraryViewModel.makeDAISYFolderPanel()

        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertEqual(panel.title, "Import Folder")
        XCTAssertEqual(panel.prompt, "Import")
        XCTAssertEqual(
            panel.message,
            "Choose each folder to import: a DAISY book's folder, which holds its ncc.html or .opf file, "
                + "or a folder of audio tracks, which becomes one audiobook."
        )
    }

    // MARK: - The Book's Own Package

    /// The package a loose DAISY book was imported into checks out against
    /// its record, as opening or importing a .tmb package requires: the
    /// checksum the record holds is the package's. A copy of the package
    /// imported as a .tmb reads in full, while a copy whose files changed is
    /// refused.
    func testImportedPackageChecksOutAgainstItsRecordAsATMBPackage() throws {
        let folder = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let book = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath).book

        let inspection = try FileImportService.inspectTMBPackage(at: book.tmbDirectory)
        XCTAssertEqual(inspection.contentURL.lastPathComponent, "ncc.html")
        XCTAssertEqual(inspection.info.metadata.md5Hash, book.md5Hash)

        let exported = try copyOfPackage(book, into: "Exported")
        let copy = try FileImportService.importTMBPackageWithReport(from: exported).book
        addTeardownBlock { try? FileManager.default.removeItem(at: copy.tmbDirectory) }
        XCTAssertEqual(copy.id, book.id)
        XCTAssertEqual(copy.md5Hash, book.md5Hash)
        XCTAssertEqual(try bookFiles(of: copy), Fixtures.navigationBookFiles)
        try assertReadsInFull(copy, sentences: Fixtures.navigationBookSentences, headings: Fixtures.navigationBookHeadings)

        let tampered = try copyOfPackage(book, into: "Tampered")
        let audio = try FileHandle(forWritingTo: tampered.appendingPathComponent("audio/part1.mp3"))
        try audio.seekToEnd()
        try audio.write(contentsOf: Data(" and a little more".utf8))
        try audio.close()
        XCTAssertThrowsError(try FileImportService.inspectTMBPackage(at: tampered)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                TMBPackageImportError.invalidPackage("the content hash does not match bookInfo.json").localizedDescription
            )
        }
    }

    /// When the library index is lost, the packages of loose DAISY books
    /// are adopted with their book's file as the OPF or ncc.html their
    /// record names, not whichever of their many files happens to be listed
    /// first, so each still opens and reads in full.
    func testOrphanedPackageIsAdoptedByTheFileItsRecordNames() throws {
        let packageFolder = try Fixtures.writeFolder(Fixtures.packageBook, named: "Ferry Timetables", in: sources)
        let navigationFolder = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let books = [
            (try FileImportService.importFileWithReport(from: packageFolder, toFolder: folderPath).book, Fixtures.packageBookSentences),
            (try FileImportService.importFileWithReport(from: navigationFolder, toFolder: folderPath).book, Fixtures.navigationBookSentences)
        ]
        // A library of the packages alone, in the same folder, as a lost
        // index leaves them: nothing else in the shared test library joins.
        let library = sources.appendingPathComponent("Recovered Library", isDirectory: true)
        let folder = library.appendingPathComponent(folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (book, _) in books {
            try FileManager.default.copyItem(at: book.tmbDirectory, to: folder.appendingPathComponent(book.tmbDirectoryName))
        }

        var recovered = Library()
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &recovered, libraryDirectory: library)

        XCTAssertEqual(adopted, 2)
        for (book, sentences) in books {
            let adoptedBook = try XCTUnwrap(recovered.books.first { $0.id == book.id })
            XCTAssertEqual(adoptedBook.bookFileURL.lastPathComponent, book.bookFileURL.lastPathComponent)
            XCTAssertEqual(adoptedBook.tmbDirectoryName, book.tmbDirectoryName)
            XCTAssertEqual(adoptedBook.folderPath, folderPath)
            let spoken = try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: adoptedBook.bookFileURL))
            for sentence in sentences {
                XCTAssertTrue(spoken.contains(sentence), "\(book.title): missing “\(sentence)”")
            }
        }
    }

    // MARK: - Helpers

    /// A copy of `book`'s package, record and cache included, in a new
    /// folder named `folder` among this test's sources, outside the library.
    private func copyOfPackage(_ book: Book, into folder: String) throws -> URL {
        let parent = sources.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let copy = parent.appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
        try FileManager.default.copyItem(at: book.tmbDirectory, to: copy)
        return copy
    }

    /// The archive the batch tests import: two DAISY books, each in a folder
    /// of its own beside files that are not books (notes, unused audio, a
    /// DTD, a hidden file), an EPUB in another folder, and the copies macOS
    /// adds under `__MACOSX`, which begin as AppleDouble files do.
    private static func twoPackagedBooksAndAnEPUB() throws -> [String: Data] {
        let appleDouble = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00])
        return archiveEntries(Fixtures.files(Fixtures.navigationBook, changing: Fixtures.unrelatedFiles), inFolder: "Rope Splicing")
            .merging(archiveEntries(Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles), inFolder: "Ferry Timetables")) { first, _ in first }
            .merging([
                "Novels/Alice.epub": try Data(contentsOf: requireFile("alice.epub")),
                "__MACOSX/Rope Splicing/._ncc.html": appleDouble,
                "__MACOSX/Novels/._Alice.epub": appleDouble
            ]) { first, _ in first }
    }

    /// The entries of an archive holding the package book (DAISY 3) read
    /// aloud: its SMIL file plays each of its two sections from one silent
    /// two-second WAVE file beside it, a second for each, so the book has
    /// audio as well as its DTBook text.
    private static func talkingBookEntries() throws -> [String: Data] {
        let smil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/2001/SMIL20/"><body><seq>
        <par id="s1"><text src="timetables.xml#c1"/>\
        <audio src="timetables.wav" clipBegin="0:00:00.000" clipEnd="0:00:01.000"/></par>
        <par id="s2"><text src="timetables.xml#c2"/>\
        <audio src="timetables.wav" clipBegin="0:00:01.000" clipEnd="0:00:02.000"/></par>
        </seq></body></smil>
        """
        // The WAVE file is written in a folder of its own, then read in.
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wave = folder.appendingPathComponent("timetables.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)
        var entries = Fixtures.files(Fixtures.packageBook, changing: ["content/timetables.smil": smil])
            .mapValues { Data($0.utf8) }
        entries["content/timetables.wav"] = try Data(contentsOf: wave)
        return entries
    }

    /// `files` as an archive's entries, each path moved into `folder`.
    private static func archiveEntries(_ files: [String: String], inFolder folder: String) -> [String: Data] {
        Fixtures.entries(files, inFolder: folder).mapValues { Data($0.utf8) }
    }

    /// A ZIP archive holding `entries`, removed when the test ends.
    private func makeArchive(_ entries: [String: Data]) throws -> URL {
        let archive = try makeTemporaryZip(prefix: "DAISYPackageBatch", entries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    /// Asserts that `book` reads each of `sentences` and `headings` from
    /// its own package: as the reader rebuilds its text cache from the
    /// copied files (the import's cache is removed first, so it cannot
    /// stand in for them), and straight from the files.
    private func assertReadsInFull(
        _ book: Book,
        sentences: [String],
        headings: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try FileManager.default.removeItem(at: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory))
        let loaded = try BookContentAnalysisService.load(book: book).content
        let text = loaded.chapters.map(\.text).joined(separator: "\n\n")
        let loadedHeadings = loaded.chapters.flatMap(\.headings).map(\.text)
        let direct = try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: book.bookFileURL))

        for sentence in sentences {
            XCTAssertTrue(text.contains(sentence), "missing “\(sentence)” in:\n\(text)", file: file, line: line)
            XCTAssertTrue(direct.contains(sentence), "missing “\(sentence)” in:\n\(direct)", file: file, line: line)
        }
        for heading in headings {
            XCTAssertTrue(loadedHeadings.contains(heading), "missing heading “\(heading)” in \(loadedHeadings)", file: file, line: line)
        }
    }

    /// The paths of the book's own files in its package, in order, leaving
    /// out the files TextMouth keeps beside them; the record and the text
    /// cache must be among those.
    private func bookFiles(of book: Book) throws -> [String] {
        let package = book.tmbDirectory
        let entries = try XCTUnwrap(FileManager.default.enumerator(atPath: package.path))
        var files: [String] = []
        while let path = entries.nextObject() as? String {
            guard (entries.fileAttributes?[.type] as? FileAttributeType) != .typeDirectory else { continue }
            files.append(path)
        }
        XCTAssertTrue(files.contains("bookInfo.json"))
        XCTAssertTrue(files.contains("content.md"))
        return files.filter(DAISYPackageInventory.isBookPath).sorted()
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Runs `body` with the "After Importing a Book" preference set to
    /// `behavior`, restoring the previous preference afterwards.
    @MainActor
    private func withImportDeleteBehavior(_ behavior: ImportDeleteBehavior, _ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = behavior
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }
}
