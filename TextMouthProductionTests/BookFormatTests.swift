import XCTest
import AppKit
@testable import TextMouth

/// Regression coverage for the formats advertised by the production app.
final class BookFormatTests: XCTestCase {
    /// Hosted tests must never initialize services against the user's real data.
    func testProductionTestsUseIsolatedDataDirectory() {
        XCTAssertTrue(TextMouthPaths.root.path.contains("TextMouthTests-"))
        XCTAssertNotEqual(TextMouthPaths.root.standardizedFileURL, TextMouthPaths.defaultRoot.standardizedFileURL)
    }

    /// Legacy binary Word documents are not Office Open XML archives and cannot
    /// be parsed by DOCXParser, so they must not be detected as DOCX input.
    func testLegacyDocIsNotAdvertisedAsDOCX() {
        let legacyURL = URL(fileURLWithPath: "/tmp/legacy.doc")

        XCTAssertNil(BookFormat.detect(from: legacyURL))
        XCTAssertFalse(BookFormat.docx.fileExtensions.contains("doc"))
        XCTAssertFalse(
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
                toFolder: "",
                originalURL: source
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        viewModel.cancelDuplicate()

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNil(viewModel.pendingDuplicateOriginalURL)
    }

    func testAcceptedDuplicateProcessesOriginalDeletionPreference() throws {
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
                toFolder: "",
                originalURL: source
            )
        )
        viewModel.keepDuplicate()

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNil(viewModel.pendingDuplicateOriginalURL)
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
        Book(
            title: UUID().uuidString,
            format: .txt,
            filePath: "/tmp/book.txt",
            md5Hash: hash,
            tmbDirectoryName: "\(UUID().uuidString).tmb"
        )
    }

    private func makeTemporarySourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("source".utf8).write(to: url)
        return url
    }
}
