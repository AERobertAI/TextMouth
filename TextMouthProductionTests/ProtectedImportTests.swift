#if os(macOS)
import Combine
import PDFKit
import XCTest
@testable import TextMouth

/// Adding a password-protected book (FR41): it comes in locked, with nothing
/// of its text read or written, and opening it afterwards writes nothing
/// into its package either. The PDF is locked by PDFKit in this test's own
/// folder, the library is the hosted test's sandbox, and the credential
/// store is in memory.
@MainActor
final class ProtectedImportTests: XCTestCase {

    /// The words in the fixture, which must reach no file of the package.
    private let words = "The sluice gate opens at dawn."
    /// The folder the source PDF is in.
    private var folder = FileManager.default.temporaryDirectory
    /// Puts the default store back.
    private var restoreStore: (() -> Void)?

    override func setUpWithError() throws {
        restoreStore = CredentialStores.use(InMemoryCredentialStore())
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProtectedImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        restoreStore?()
        super.tearDown()
    }

    /// A PDF holding `words`, locked with the user password "secret".
    private func lockedPDF() throws -> URL {
        let open = try PDFFixtures.makePDF(for: self) { [words] context, _ in
            PDFFixtures.drawText(words, size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        let url = folder.appendingPathComponent("Sluice Notes.pdf")
        let document = try XCTUnwrap(PDFDocument(url: open))
        XCTAssertTrue(document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        return url
    }

    /// The path of every file under `package`, relative to it, sorted.
    private func files(in package: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]))
        return enumerator.compactMap { ($0 as? URL).flatMap { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                ? String(url.path.dropFirst(package.path.count)) : nil
        } }.sorted()
    }

    /// No file of `package` holds `words` in plain bytes.
    private func assertNoWords(in package: URL, _ message: String = "") throws {
        for name in try files(in: package) {
            let data = try Data(contentsOf: URL(fileURLWithPath: package.path + name))
            XCTAssertNil(data.range(of: Data("sluice".utf8)), "\(name) holds the book's words. \(message)")
        }
    }

    // MARK: - Adding

    /// A locked PDF comes in locked: its file's name is its title, no cache or index of text is written, and its package holds none of its words.
    func testAProtectedPDFIsAddedLockedWithNothingRead() throws {
        let source = try lockedPDF()
        let imported = try FileImportService.importFileWithReport(from: source)
        let book = imported.book
        XCTAssertEqual(book.title, "Sluice Notes")
        XCTAssertTrue(book.isLocked)
        let package = book.tmbDirectory
        let names = try files(in: package)
        XCTAssertFalse(names.contains { $0.hasSuffix("content.md") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("bookInfo.json") }, "\(names)")
        try assertNoWords(in: package)
        // The record is the book's: an empty index, nothing read.
        let record = try BookInfo.load(from: package)
        XCTAssertEqual(record.contentIndex?.chapters.count, 0)
    }

    /// A book already added locked opens with its password, reads from memory, and writes nothing into its package.
    func testOpeningAnAddedBookWritesNothingIntoItsPackage() throws {
        let imported = try FileImportService.importFileWithReport(from: try lockedPDF())
        let book = imported.book
        let package = book.tmbDirectory
        let before = try files(in: package)
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
        addTeardownBlock { @MainActor in reader.close() }
        let asked = expectation(description: "asks")
        asked.assertForOverFulfill = false
        let watchAsk = reader.objectWillChange.sink { _ in
            DispatchQueue.main.async { if reader.unlockPrompt != nil { asked.fulfill() } }
        }
        wait(for: [asked], timeout: 30)
        watchAsk.cancel()

        reader.submitUnlock(UnlockChoice(password: Secret("secret"), remember: false, removePassword: false))
        let loaded = expectation(description: "loads")
        loaded.assertForOverFulfill = false
        let watchLoad = reader.objectWillChange.sink { _ in
            DispatchQueue.main.async { if reader.content != nil { loaded.fulfill() } }
        }
        wait(for: [loaded], timeout: 30)
        watchLoad.cancel()
        XCTAssertTrue(reader.content?.chapters.map(\.text).joined().contains("sluice gate") == true)

        reader.close()
        XCTAssertEqual(try files(in: package), before, "opening, reading, and closing wrote no file")
        try assertNoWords(in: package, "after the book was open")
    }

    /// An unprotected PDF is added as it always was, with its text read and its cache written.
    func testAnOrdinaryPDFIsStillAddedWithItsText() throws {
        let open = try PDFFixtures.makePDF(for: self) { [words] context, _ in
            PDFFixtures.drawText(words, size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        let source = folder.appendingPathComponent("Ordinary.pdf")
        try FileManager.default.copyItem(at: open, to: source)
        let imported = try FileImportService.importFileWithReport(from: source)
        XCTAssertFalse(imported.book.isLocked)
        XCTAssertTrue(try files(in: imported.book.tmbDirectory).contains { $0.hasSuffix("content.md") })
    }
}
#endif
