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
        XCTAssertFalse(model.showDeleteOriginalDialog)
        XCTAssertNil(model.pendingOriginalURL)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertEqual(debugLogLines(containing: "IMPORT_FAILED: \(source.lastPathComponent): Reading its text failed: ").count, 1)
    }

    /// A binary file named as plain text cannot be read as text, so its
    /// import fails at that step and leaves nothing behind.
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

    // MARK: - Fixtures

    /// Bytes that no text decoder can read, saved under a text file's name.
    /// They are not UTF-8, they carry no byte-order mark, and they include
    /// the five byte values Windows-1252 leaves undefined (0x81, 0x8D, 0x8F,
    /// 0x90, 0x9D), which Foundation refuses to decode in that encoding, so
    /// even a decoder that falls back to it cannot read them.
    private static let undecodableBytes: Data = {
        var bytes: [UInt8] = []
        for block in 0..<64 {
            bytes += [0x81, 0x00, 0x8D, 0x8F, 0x90, 0x9D, UInt8(block), 0xFF]
        }
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
