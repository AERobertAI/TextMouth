import XCTest
import AppKit
@testable import TextMouth

/// Regression coverage for the formats advertised by the production app.
@MainActor
final class BookFormatTests: XCTestCase {
    /// Legacy binary Word documents are not Office Open XML archives and cannot
    /// be parsed by DOCXParser, so they must never be detected as DOCX input.
    /// They are read by textutil instead (FMT13): a .doc is its own format, and
    /// the Open Book panel offers the Word 97-2003 type.
    func testLegacyDocIsReadByTextutilNeverAsDOCX() {
        let legacyURL = URL(fileURLWithPath: "/tmp/legacy.doc")

        XCTAssertEqual(BookFormat.detect(from: legacyURL), .doc)
        XCTAssertFalse(BookFormat.docx.fileExtensions.contains("doc"))
        XCTAssertTrue(
            FileImportService.supportedTypes.contains {
                $0.identifier == "com.microsoft.word.doc"
            }
        )
    }

    /// Removing legacy DOC support must not affect supported DOCX documents.
    func testDOCXRemainsSupported() {
        let docxURL = URL(fileURLWithPath: "/tmp/document.docx")

        XCTAssertEqual(BookFormat.detect(from: docxURL), .docx)
        XCTAssertTrue(BookFormat.docx.fileExtensions.contains("docx"))
    }

    /// Ogg audio is an audiobook format under each of its extensions, in
    /// any case. The Open Book panel offers it, an archive's entry limits
    /// count it as audio, and a feed's enclosure named with it is audio,
    /// all from the one list of audio extensions.
    func testOggAudioIsAnAudiobookFormat() {
        for ext in ["ogg", "oga", "opus", "OGG"] {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/elegy.\(ext)")), .audio, ext)
            XCTAssertTrue(ArchiveEntryLimits.isAudio("Radio/elegy.\(ext)"), ext)
        }
        XCTAssertTrue(FileImportService.supportedTypes.contains { $0.identifier == "org.xiph.ogg-audio" })
        XCTAssertEqual(ArchiveEntryLimits.audioExtensions, Set(BookFormat.audio.fileExtensions))
        XCTAssertTrue(FeedMediaKind.audioExtensions.isSuperset(of: ["ogg", "oga", "opus"]))
    }

    /// The formats macOS decodes that the import converts (FMT09) are
    /// audiobook formats under each extension, in any case, and the Open
    /// panel offers their system types.
    func testCoreAudioFormatsAreAudiobookFormats() {
        for ext in ImportAudioConverter.coreAudioExtensions {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/track.\(ext)")), .audio, ext)
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/TRACK.\(ext.uppercased())")), .audio, ext)
            XCTAssertTrue(ArchiveEntryLimits.isAudio("Disc/track.\(ext)"), ext)
        }
        let offered = Set(FileImportService.supportedTypes.map(\.identifier))
        for identifier in ["public.ac3-audio", "public.mp2", "com.apple.coreaudio-format", "org.3gpp.adaptive-multi-rate-audio"] {
            XCTAssertTrue(offered.contains(identifier), identifier)
        }
    }

    func testDuplicateImportDoesNotDeleteOriginalBeforeUserDecision() throws {
        let viewModel = LibraryViewModel()
        let existing = makeBook(hash: "same-content")
        let duplicate = makeBook(hash: "same-content")
        viewModel.library = Library(books: [existing])
        let source = try makeTemporarySourceFile()
        defer { try? FileManager.default.removeItem(at: source) }

        let previousBehavior = ConfigService.shared.config.importDeleteBehavior
        ConfigService.shared.config.importDeleteBehavior = .deleteAfterImport
        defer { ConfigService.shared.config.importDeleteBehavior = previousBehavior }

        XCTAssertFalse(
            viewModel.addBookCheckingDuplicate(
                duplicate,
                originalURL: source
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(viewModel.importDecisions.current?.duplicate?.originalURL, source)

        viewModel.answerCurrentImportDecision(.cancel)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(viewModel.importDecisions.isEmpty)
    }

    func testAcceptedDuplicateProcessesOriginalDeletionPreference() throws {
        let viewModel = LibraryViewModel()
        let existing = makeBook(hash: "same-content")
        let duplicate = makeBook(hash: "same-content")
        // The new copy's package is there, as an import publishes it before
        // asking: Keep Both keeps no copy whose package is gone (TODO 3780).
        let package = duplicate.tmbDirectory
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        viewModel.library = Library(books: [existing])
        let source = try makeTemporarySourceFile()
        defer { try? FileManager.default.removeItem(at: source) }

        let previousBehavior = ConfigService.shared.config.importDeleteBehavior
        ConfigService.shared.config.importDeleteBehavior = .deleteAfterImport
        defer { ConfigService.shared.config.importDeleteBehavior = previousBehavior }

        XCTAssertFalse(
            viewModel.addBookCheckingDuplicate(
                duplicate,
                originalURL: source
            )
        )
        // Deleting goes to the Trash when that preference is on: keep this
        // test's file out of the real Trash.
        withTrashPreference(movesToTrash: false) {
            viewModel.answerCurrentImportDecision(.keepBoth)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(viewModel.importDecisions.isEmpty)
    }

    func testFailedCacheGenerationDoesNotStampCurrentVersion() {
        var book = Book(
            title: "Missing Source",
            format: .markdown,
            filePath: "/missing/\(UUID().uuidString).md",
            md5Hash: UUID().uuidString,
            tmbDirectoryName: "\(UUID().uuidString).tmb"
        )

        XCTAssertFalse(MarkdownCacheService.generateCacheAndStampVersion(for: &book))
        XCTAssertNil(book.cacheFormatVersion)
    }

    func testSuccessfulCacheGenerationStampsCurrentVersion() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let source = package.appendingPathComponent("book.md")
        try Data("# Chapter\n\nText".utf8).write(to: source)
        var book = Book(
            title: "Cached",
            format: .markdown,
            filePath: source.path,
            md5Hash: UUID().uuidString,
            tmbDirectoryName: packageName
        )

        XCTAssertTrue(MarkdownCacheService.generateCacheAndStampVersion(for: &book))
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertTrue(MarkdownCacheService.cacheExists(for: book))
    }

    func testShortReadingSessionIsIgnoredAndCleared() {
        let service = ReadingStatsService.shared
        let previousStats = service.stats
        service.stats = ReadingStats()
        defer {
            service.endSession()
            service.stats = previousStats
        }
        let start = Date(timeIntervalSince1970: 1_000)

        service.startSession(bookID: UUID(), at: start)
        service.endSession(at: start.addingTimeInterval(0.5))

        XCTAssertFalse(service.hasActiveSession)
        XCTAssertEqual(service.stats.totalListeningSeconds, 0)
    }

    func testApplicationTerminationRecordsAndFlushesActiveSession() throws {
        let service = ReadingStatsService.shared
        service.endSession()
        let previousStats = service.stats
        service.stats = ReadingStats()
        defer {
            service.stats = previousStats
            service.save()
            service.flushPendingSaves()
        }
        let bookID = UUID()
        service.startSession(bookID: bookID, at: Date().addingTimeInterval(-2))

        AppDelegate().applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        let data = try Data(contentsOf: TextMouthPaths.readingStatsFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(ReadingStats.self, from: data)
        XCTAssertGreaterThanOrEqual(persisted.totalListeningSeconds, 1.5)
        XCTAssertGreaterThanOrEqual(persisted.bookListeningSeconds[bookID.uuidString] ?? 0, 1.5)
        XCTAssertFalse(service.hasActiveSession)
    }

    private func makeBook(hash: String) -> Book {
        // Match the package/content relationship of a real imported book so
        // cancellation exercises cleanup without bypassing deletion safety.
        let packageName = "\(UUID().uuidString).tmb"
        return Book(
            title: UUID().uuidString,
            format: .txt,
            filePath: TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
                .appendingPathComponent("book.txt").path,
            md5Hash: hash,
            tmbDirectoryName: packageName
        )
    }

    private func makeTemporarySourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("source".utf8).write(to: url)
        return url
    }
}
