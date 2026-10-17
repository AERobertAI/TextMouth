import XCTest
import ZIPFoundation
@testable import TextMouth

/// Every import publishes a book only once its content can be read and its
/// bookInfo.json is on disk (TODO S02). A failure at any step leaves no
/// package, visible or hidden, adds no row, and never touches the source.
/// Each test imports into a library folder of its own, so the folder's
/// listing shows exactly what the import left, and puts the library index
/// back afterwards.
final class StagedImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// The library folder this test imports into.
    private var folderPath: String!
    /// Where this test's source files are written, outside the library.
    private var sources: URL!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "Staged Import \(UUID().uuidString.prefix(8))"
        sources = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedImportSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        if let folderPath {
            Self.forceRemove(TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
        if let sources {
            Self.forceRemove(sources)
        }
    }

    // MARK: - Content That Cannot Be Read

    /// A Word document that is not a ZIP archive fails through the
    /// library's own import: the alert names the file and the step, no row
    /// is added, nothing is left in the library folder, the source keeps its
    /// bytes although the preference says to delete it, and no deletion is
    /// offered. The failure is logged once.
    @MainActor
    func testCorruptDocumentFailsAndLeavesEverythingAsItWas() throws {
        let source = sources.appendingPathComponent("Spoke Tension \(UUID().uuidString.prefix(8)).docx")
        try AudioTestFixtures.writeNonAudioBytes(to: source)
        let bytes = try Data(contentsOf: source)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        withImportDeleteBehavior(.deleteAfterImport) {
            model.importSingleFileAsync(from: source, toFolder: folderPath)
            XCTAssertTrue(eventually(within: 20) { model.showError }, "the import never reported its failure")
        }

        XCTAssertEqual(
            model.errorMessage,
            "Could not import “\(source.lastPathComponent)”. Reading its text failed: "
                + DOCXParserError.invalidArchive.localizedDescription
        )
        XCTAssertTrue(model.library.books.isEmpty)
        XCTAssertTrue(model.importDecisions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertEqual(debugLogLines(containing: "IMPORT_FAILED: \(source.lastPathComponent): Reading its text failed: ").count, 1)
    }

    /// A file named as plain text whose bytes cannot be read as text (here
    /// a corrupted UTF-16 file) fails while reading its text and leaves
    /// nothing behind.
    func testBinaryNamedAsTextFailsAndLeavesNothingBehind() throws {
        let source = sources.appendingPathComponent("Field Notes.txt")
        try Self.undecodableBytes.write(to: source)

        assertImportFails(at: .readingText, of: source)
    }

    /// A file named as audio that holds no audio has no playable chapter,
    /// so its import fails while reading its audio, saying so as playback
    /// would, and leaves nothing.
    func testAudioFileWithoutAudioFailsAndLeavesNothingBehind() throws {
        let source = sources.appendingPathComponent("Chapter 01.mp3")
        try AudioTestFixtures.writeNonAudioBytes(to: source)

        let failure = assertImportFails(at: .readingAudio, of: source)

        XCTAssertEqual(
            failure?.reason,
            "Reading its audio failed: The file Chapter 01.mp3 is damaged, unreadable, or not an audio file."
        )
    }

    // MARK: - Writes That Fail

    /// A disk that fills up while bookInfo.json is written fails the import
    /// at that step; the staged package is removed and the source kept.
    func testFullDiskWhileSavingTheRecordFails() throws {
        let source = try makeTextSource()

        let failure = assertImportFails(at: .savingRecord, of: source, observer: { step, _ in
            if step == .savingRecord { throw CocoaError(.fileWriteOutOfSpace) }
        })

        XCTAssertEqual((failure?.underlying as? CocoaError)?.code, .fileWriteOutOfSpace)
    }

    /// A package that refuses the bookInfo.json write (it became read-only)
    /// fails the import at that step, and the package is still removed.
    func testDeniedRecordWriteFails() throws {
        let source = try makeTextSource()

        assertImportFails(at: .savingRecord, of: source, observer: { step, package in
            if step == .savingRecord { XCTAssertEqual(chmod(package.path, 0o555), 0) }
        })
    }

    /// A package that cannot take the text cache (it became read-only) fails
    /// the import while reading the text, and the package is still removed.
    func testReadOnlyPackageDuringCacheWriteFails() throws {
        let source = try makeTextSource()

        assertImportFails(at: .readingText, of: source, observer: { step, package in
            if step == .readingText { XCTAssertEqual(chmod(package.path, 0o555), 0) }
        })
    }

    // MARK: - Publishing

    /// A successful import leaves exactly one package in the folder, at its
    /// final name, holding the book, its text cache, and a record that
    /// reads back with the book's index; no staged package remains.
    func testSuccessfulImportLeavesExactlyOnePublishedPackage() throws {
        let source = try makeTextSource()

        let imported = try FileImportService.importFileWithReport(from: source, toFolder: folderPath)

        let book = imported.book
        XCTAssertEqual(try folderEntries(), [book.tmbDirectoryName])
        XCTAssertFalse(book.tmbDirectoryName.hasPrefix("."))
        XCTAssertEqual(book.tmbDirectory.path, packageURL(book.tmbDirectoryName).path)
        XCTAssertEqual(book.filePath, book.tmbDirectory.appendingPathComponent(source.lastPathComponent).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory).path))
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.metadata.bookID, book.id)
        XCTAssertEqual(record.state.tmbDirectoryName, book.tmbDirectoryName)
        XCTAssertNotNil(record.contentIndex)
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertTrue(imported.report.isComplete)
    }

    /// An import interrupted after staging its package, before the rename
    /// that publishes it (as a crash or forced quit would stop it), leaves a
    /// hidden package with a readable record. The next startup never adopts
    /// it, and the next import into the folder removes it.
    @MainActor
    func testInterruptedImportIsNeverAdoptedAndIsRemovedByTheNextImport() throws {
        let source = try makeTextSource()
        let leftover = packageURL("\(ImportStaging.namePrefix)\(UUID().uuidString).tmb")

        // The observer copies the finished staged package where a crash at
        // this point would have left it, then stops the import.
        let failure = assertImportFails(
            at: .publishing,
            of: source,
            observer: { step, package in
                if step == .publishing {
                    try FileManager.default.copyItem(at: package, to: leftover)
                    throw CocoaError(.userCancelled)
                }
            },
            leftovers: [leftover.lastPathComponent]
        )
        let stranded = try BookInfo.load(from: leftover)

        LibraryPersistenceService.flushPendingSave()
        let restarted = LibraryViewModel(initializeServices: false)
        restarted.loadLibraryIndex()
        var adopted = Library()
        FileImportService.adoptOrphanedTMBPackages(library: &adopted)
        XCTAssertNil(restarted.bookByID(stranded.metadata.bookID))
        XCTAssertFalse(adopted.books.contains { $0.id == stranded.metadata.bookID })
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(failure?.step, .publishing)

        let next = try FileImportService.importFileWithReport(from: source, toFolder: folderPath)

        XCTAssertEqual(try folderEntries(), [next.book.tmbDirectoryName])
    }

    /// Orphan adoption skips hidden package names, so a staged package with
    /// a readable record is never adopted, while the same package under a
    /// visible name is.
    func testOrphanAdoptionSkipsStagedPackages() throws {
        let library = sources.appendingPathComponent("Library", isDirectory: true)
        let staged = library.appendingPathComponent("\(ImportStaging.namePrefix)\(UUID().uuidString).tmb", isDirectory: true)
        let visible = library.appendingPathComponent("Visible Copy.tmb", isDirectory: true)
        let book = try makeOrphanPackage(at: staged)
        try FileManager.default.copyItem(at: staged, to: visible)

        var adopted = Library()
        let count = FileImportService.adoptOrphanedTMBPackages(library: &adopted, libraryDirectory: library)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(adopted.books.map(\.id), [book.id])
        XCTAssertEqual(adopted.books.first?.tmbDirectoryName, "Visible Copy.tmb")
    }

    // MARK: - Audio Archives

    /// An archive whose tracks hold no audio has no playable chapter: its
    /// import fails while reading its audio, leaves nothing in the folder,
    /// and leaves the archive as it was.
    func testAudioArchiveWithoutPlayableTracksFailsAndLeavesNothingBehind() throws {
        let archive = try makeAudioArchive("Lecture Series", tracks: ["01.mp3", "02.mp3"]) { track in
            try AudioTestFixtures.writeNonAudioBytes(to: track)
        }

        assertImportFails(at: .readingAudio, of: archive, with: FileImportService.importAudioZipWithReport(from:toFolder:observer:))
    }

    /// An archive that holds no audio file at all fails the same way.
    func testArchiveWithNoAudioFilesFailsAndLeavesNothingBehind() throws {
        let archive = try makeAudioArchive("Liner Notes", tracks: ["notes.json"]) { file in
            try Data("{}".utf8).write(to: file)
        }

        let failure = assertImportFails(
            at: .readingAudio,
            of: archive,
            with: FileImportService.importAudioZipWithReport(from:toFolder:observer:)
        )

        XCTAssertEqual(failure?.underlying as? AudioParseError, .noAudioFiles)
    }

    /// A playable archive becomes exactly one published package: its tracks
    /// in the package's audio folder and a record holding their index.
    func testAudioArchiveImportPublishesOnePackage() throws {
        let archive = try makeAudioArchive("Morning Lectures", tracks: ["01.wav", "02.wav"]) { track in
            try AudioTestFixtures.writeSilence(to: track)
        }

        let imported = try FileImportService.importAudioZipWithReport(from: archive, toFolder: folderPath)

        let book = imported.book
        XCTAssertEqual(try folderEntries(), [book.tmbDirectoryName])
        XCTAssertEqual(book.filePath, book.tmbDirectory.appendingPathComponent("audio").path)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex?.chapters.count, 2)
        XCTAssertEqual(book.sourceFilePath, archive.path)
    }

    /// A DAISY archive whose audio cannot be converted (it has no navigation
    /// document to convert from) fails at that step and, unlike before,
    /// leaves no empty package behind.
    func testDAISYAudioArchiveThatCannotBeConvertedLeavesNothingBehind() throws {
        let archive = try makeAudioArchive("Talking Book", tracks: ["01.mp3"]) { track in
            try AudioTestFixtures.writeNonAudioBytes(to: track)
        }

        assertImportFails(
            at: .convertingAudio,
            of: archive,
            with: FileImportService.importDAISYAudioZipWithReport(from:toFolder:observer:)
        )
    }

    // MARK: - Entered Text

    /// Text typed or pasted into the library becomes exactly one published
    /// package, holding the text under a safe file name, its cache, and a
    /// record with its index.
    @MainActor
    func testEnteredTextBecomesOnePublishedBook() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        model.createBookFromText(
            title: "Trail Log: Week 1",
            author: "",
            text: "Day one\n\nThe ridge path was washed out below the second cairn.",
            toFolder: folderPath
        )

        XCTAssertTrue(eventually(within: 20) { model.library.books.count == 1 }, "the book was never added")
        let book = try XCTUnwrap(model.library.books.first)
        XCTAssertEqual(book.title, "Trail Log: Week 1")
        XCTAssertEqual(book.author, "Unknown")
        XCTAssertEqual(try folderEntries(), [book.tmbDirectoryName])
        XCTAssertEqual(URL(fileURLWithPath: book.filePath).lastPathComponent, "Trail Log- Week 1.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
        XCTAssertNotNil(try BookInfo.load(from: book.tmbDirectory).contentIndex)
        XCTAssertFalse(model.showError)
    }

    /// Entered text whose record cannot be saved fails, naming the text's
    /// file and the step, and leaves nothing in the library folder.
    func testEnteredTextWhoseRecordCannotBeSavedLeavesNothing() throws {
        XCTAssertThrowsError(try FileImportService.importText(
            "A short note.",
            title: "Note",
            author: "",
            fileName: "Note.txt",
            toFolder: folderPath,
            observer: { step, _ in
                if step == .savingRecord { throw CocoaError(.fileWriteOutOfSpace) }
            }
        )) { error in
            XCTAssertEqual((error as? ImportFailure)?.fileName, "Note.txt")
            XCTAssertEqual((error as? ImportFailure)?.step, .savingRecord)
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    // MARK: - ZIP Batches

    /// A ZIP of three files, two of which cannot be read, imports the third,
    /// lists each failure with its file and reason, and keeps the ZIP
    /// although the preference says to delete it. Only the readable book's
    /// package is left in the folder.
    @MainActor
    func testBatchWithTwoUnreadableFilesReportsBothAndKeepsTheArchive() throws {
        let archive = try makeTemporaryZip(prefix: "StagedImportBatch", entries: [
            "Readable.txt": Data("A chapter anyone can read.".utf8),
            "Spoke Tension.docx": Data("not a Word document".utf8),
            "Field Notes.txt": Self.undecodableBytes
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)

        XCTAssertEqual(result.books.map(\.title), ["Readable"])
        XCTAssertEqual(Set(result.failures.map(\.fileName)), ["Spoke Tension.docx", "Field Notes.txt"])
        for failure in result.failures {
            // The summary puts the file's name before its reason, so the
            // reason does not start by naming the file again.
            XCTAssertTrue(failure.message.hasPrefix("Reading its text failed: "), failure.message)
        }
        XCTAssertEqual(try folderEntries(), Set(result.books.map(\.tmbDirectoryName)))

        try withImportDeleteBehavior(.deleteAfterImport) {
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library()

            model.completeZIPImport(result, originalURL: archive, folderPath: folderPath)

            XCTAssertEqual(model.library.books.map(\.title), ["Readable"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
            XCTAssertTrue(model.showError)
            let summary = try XCTUnwrap(model.errorMessage)
            XCTAssertTrue(summary.hasPrefix("Imported 1 book, but 2 files failed:\n"), summary)
            for failure in result.failures {
                XCTAssertTrue(summary.contains("\(failure.fileName): \(failure.message)"), summary)
            }
        }
    }

    /// An archive that cannot be extracted at all fails as a whole, naming
    /// the archive and the step in plain words, logged once, with nothing
    /// imported and the archive left as it was.
    func testArchiveThatCannotBeExtractedFailsNamingIt() throws {
        let archive = sources.appendingPathComponent("Torn Download \(UUID().uuidString.prefix(8)).zip")
        try Data("not a ZIP archive".utf8).write(to: archive)
        let bytes = try Data(contentsOf: archive)

        XCTAssertThrowsError(try FileImportService.importZip(from: archive, toFolder: folderPath)) { error in
            XCTAssertEqual((error as? ImportFailure)?.fileName, archive.lastPathComponent)
            XCTAssertEqual(
                (error as? ImportFailure)?.reason,
                "Extracting the archive failed: The archive is damaged, incomplete, or not a ZIP archive."
            )
        }

        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertEqual(debugLogLines(containing: "IMPORT_FAILED: \(archive.lastPathComponent): Extracting the archive failed: ").count, 1)
    }

    // MARK: - Files With No Text

    /// What a listener hears when a text file holds nothing to read: the
    /// step, then the import's own reason.
    private static let noTextReason = "Reading its text failed: This file has no text to read."

    /// A source named `name` (its extension picks the format) holding
    /// `bytes`, written outside the library.
    private func makeSource(named name: String, bytes: Data) throws -> URL {
        let source = sources.appendingPathComponent(name)
        try bytes.write(to: source)
        return source
    }

    /// Asserts that importing `bytes` as a file named `name` is refused with
    /// the no-text reason, at the step of reading its text, leaving nothing.
    private func assertBlankFileIsRefused(
        _ name: String,
        _ bytes: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try makeSource(named: name, bytes: bytes)
        let failure = assertImportFails(at: .readingText, of: source, file: file, line: line)
        XCTAssertEqual(failure?.reason, Self.noTextReason, name, file: file, line: line)
    }

    /// A file of no bytes, in each of the three plain formats, is refused,
    /// where it used to import as an empty book that said nothing was
    /// missing (the import fuzz sweep's first finding).
    func testAFileOfNoBytesIsRefusedInEveryPlainFormat() throws {
        for ext in ["md", "txt", "html"] {
            try assertBlankFileIsRefused("Empty \(UUID().uuidString.prefix(8)).\(ext)", Data())
        }
    }

    /// A file of only white space (spaces, tabs, blank lines, a no-break
    /// space) is refused as one of no bytes is.
    func testAFileOfWhiteSpaceAloneIsRefused() throws {
        let blank = Data(" \t\n\n  \u{00A0}\r\n\t ".utf8)
        for ext in ["md", "txt"] {
            try assertBlankFileIsRefused("Blank \(UUID().uuidString.prefix(8)).\(ext)", blank)
        }
    }

    /// A UTF-8 byte-order mark with nothing after it holds no text.
    func testAByteOrderMarkAloneIsRefused() throws {
        let mark = Data([0xEF, 0xBB, 0xBF])
        for ext in ["md", "txt"] {
            try assertBlankFileIsRefused("Mark \(UUID().uuidString.prefix(8)).\(ext)", mark)
        }
    }

    /// An HTML file of markup and a script, with no text, is refused.
    func testHTMLWithMarkupAndNoTextIsRefused() throws {
        let markup = "<html><body><div></div><script>var a = 1;</script></body></html>"
        try assertBlankFileIsRefused("Markup \(UUID().uuidString.prefix(8)).html", Data(markup.utf8))
    }

    /// Controls: a file of one word, and a Markdown file that is only a
    /// heading, still import.
    func testFilesWithEvenOneWordOfTextStillImport() throws {
        let files: [(String, String)] = [
            ("One Word", "txt"), ("One Word", "md"), ("One Word", "html"), ("Only Heading", "md")
        ]
        for (title, ext) in files {
            let text = ext == "html" ? "<p>Hello</p>" : (title == "Only Heading" ? "# Title" : "Hello")
            let source = try makeSource(named: "\(title) \(UUID().uuidString.prefix(8)).\(ext)", bytes: Data(text.utf8))

            let imported = try FileImportService.importFileWithReport(from: source, toFolder: folderPath)

            XCTAssertTrue(imported.report.isComplete, source.lastPathComponent)
            XCTAssertTrue(FileManager.default.fileExists(atPath: imported.book.tmbDirectory.path), source.lastPathComponent)
        }
    }

    /// Through the library, with "Delete After Import" on: the alert names
    /// the file and the reason, no row or decision is made, and the file is
    /// still there.
    @MainActor
    func testEmptyMarkdownFailsThroughTheLibraryAndStaysWhereItWas() throws {
        let source = try makeSource(named: "Empty Notes \(UUID().uuidString.prefix(8)).md", bytes: Data())
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        withImportDeleteBehavior(.deleteAfterImport) {
            model.importSingleFileAsync(from: source, toFolder: folderPath)
            XCTAssertTrue(eventually(within: 20) { model.showError }, "the import never reported its failure")
        }

        XCTAssertEqual(
            model.errorMessage,
            "Could not import “\(source.lastPathComponent)”. \(Self.noTextReason)"
        )
        XCTAssertTrue(model.library.books.isEmpty)
        XCTAssertTrue(model.importDecisions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the empty file is kept")
        XCTAssertEqual(try folderEntries(), [])
    }

    /// A ZIP of an empty text file and a real Markdown file imports the
    /// Markdown, lists the empty file as failed with the no-text reason, and
    /// keeps the archive although the preference says to delete it.
    @MainActor
    func testZIPWithAnEmptyTextFileImportsTheRestAndKeepsTheArchive() throws {
        let archive = try makeTemporaryZip(prefix: "StagedImportBlank", entries: [
            "Real.md": Data("# Real\n\nA chapter anyone can read.".utf8),
            "Empty.txt": Data()
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)

        XCTAssertEqual(result.books.map(\.title), ["Real"])
        XCTAssertEqual(result.failures.map(\.fileName), ["Empty.txt"])
        XCTAssertEqual(result.failures.map(\.message), [Self.noTextReason])

        withImportDeleteBehavior(.deleteAfterImport) {
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library()

            model.completeZIPImport(result, originalURL: archive, folderPath: folderPath)

            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path), "the archive is kept")
        }
    }

    // MARK: - Fixtures

    /// Bytes that no text decoder can read, saved under a text file's name,
    /// as a cut-off or corrupted UTF-16 file is: a UTF-16 byte-order mark,
    /// then high surrogates that no low surrogate follows, then one odd
    /// byte. They are not UTF-8 (0xFF never occurs in UTF-8), and a decoder
    /// that honors the mark must refuse them rather than guess another
    /// encoding, as TextMouth's does (TODO T08). Plain binary without a mark
    /// would not do: that decoder reads any other bytes as Windows-1252.
    private static let undecodableBytes: Data = {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for _ in 0..<64 {
            bytes += [0x00, 0xD8]
        }
        bytes.append(0x41)
        return Data(bytes)
    }()

    /// An import function as the tests call it: the source, the library
    /// folder, and the observer told of each step.
    private typealias Importer = (URL, String, ImportStepObserver?) throws -> ImportedBook

    /// Imports `source` into this test's folder with `importer`, telling
    /// `observer` of each step, and asserts that the import fails at `step`
    /// and leaves everything as it was: an `ImportFailure` naming the file
    /// and the step, nothing in the folder but `leftovers` (what the
    /// observer itself put there), the source's bytes unchanged, and one log
    /// line. Returns the failure.
    @discardableResult
    private func assertImportFails(
        at step: ImportStep,
        of source: URL,
        with importer: Importer = FileImportService.importFileWithReport(from:toFolder:observer:),
        observer: ImportStepObserver? = nil,
        leftovers: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ImportFailure? {
        let bytes = try? Data(contentsOf: source)
        let logged = debugLogLines(containing: "IMPORT_FAILED: \(source.lastPathComponent): ").count
        var failure: ImportFailure?

        XCTAssertThrowsError(
            try importer(source, folderPath, observer),
            file: file,
            line: line
        ) { error in
            failure = error as? ImportFailure
        }

        XCTAssertEqual(failure?.fileName, source.lastPathComponent, file: file, line: line)
        XCTAssertEqual(failure?.step, step, file: file, line: line)
        XCTAssertTrue(
            failure?.localizedDescription.hasPrefix(
                "Could not import “\(source.lastPathComponent)”. \(step.activity) failed: "
            ) == true,
            failure?.localizedDescription ?? "no failure",
            file: file,
            line: line
        )
        XCTAssertEqual((try? folderEntries()) ?? [], leftovers, "left behind", file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: source), bytes, "the source must be untouched", file: file, line: line)
        XCTAssertEqual(
            debugLogLines(containing: "IMPORT_FAILED: \(source.lastPathComponent): ").count,
            logged + 1,
            file: file,
            line: line
        )
        return failure
    }

    /// A ZIP archive named `name`.zip holding one file per name in `tracks`,
    /// each written by `write`, at the archive's top level.
    private func makeAudioArchive(
        _ name: String,
        tracks: [String],
        write: (URL) throws -> Void
    ) throws -> URL {
        let folder = sources.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for track in tracks {
            try write(folder.appendingPathComponent(track))
        }
        let archive = sources.appendingPathComponent("\(name).zip")
        try FileManager.default.zipItem(at: folder, to: archive, shouldKeepParent: false)
        return archive
    }

    /// A short, readable plain-text source with a name unique to this test.
    private func makeTextSource() throws -> URL {
        let source = sources.appendingPathComponent("Workshop Notes \(UUID().uuidString.prefix(8)).txt")
        try Data("Chain wear\n\nMeasure twelve links; replace the chain past half a percent of stretch.".utf8)
            .write(to: source)
        return source
    }

    /// Writes a complete package at `package` as an import would publish it:
    /// a text file and a bookInfo.json naming it. Returns its book.
    private func makeOrphanPackage(at package: URL) throws -> Book {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        try Data("Orphan text \(UUID().uuidString)".utf8).write(to: content)
        let book = Book(
            title: "Orphan",
            format: .txt,
            filePath: content.path,
            md5Hash: try FileImportService.md5Hash(of: content),
            tmbDirectoryName: package.lastPathComponent
        )
        try book.makeBookInfo().save(to: package)
        return book
    }

    /// The package named `name` in this test's library folder.
    private func packageURL(_ name: String) -> URL {
        TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: name)
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

    /// Removes `url` and everything in it, first giving write permission
    /// back to every directory, since some tests make a package read-only.
    private static func forceRemove(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        chmod(url.path, 0o755)
        if let items = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in items {
                chmod(item.path, 0o755)
            }
        }
        try? fileManager.removeItem(at: url)
    }
}
