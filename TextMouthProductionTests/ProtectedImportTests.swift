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

    /// Puts an in-memory store in use and makes the source folder; each test begins with it.
    private func prepare() throws {
        restoreStore = CredentialStores.use(InMemoryCredentialStore())
        addTeardownBlock { @MainActor [weak self] in self?.restoreStore?() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProtectedImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A PDF holding `words`, locked with the user password "secret".
    private func lockedPDF() throws -> URL {
        let open = try PDFFixtures.makePDF(for: self) { [words] context, _ in
            PDFFixtures.drawText(words, size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        let url = folder.appendingPathComponent("Sluice Notes.pdf")
        let document = try XCTUnwrap(PDFDocument(url: open))
        // A heading, so what the reader makes of the book has one to leak.
        let entry = PDFOutline()
        entry.label = "Zebra Heading"
        entry.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 0)), at: CGPoint(x: 0, y: 700))
        let root = PDFOutline()
        root.insertChild(entry, at: 0)
        document.outlineRoot = root
        XCTAssertTrue(document.write(to: url, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        return url
    }

    /// A .docx holding `words`, its parts zipped with the password "secret"
    /// (ZipCrypto) by the `zip` tool macOS ships; the test is skipped without it.
    private func zipLockedDocx() throws -> URL {
        let tool = "/usr/bin/zip"
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("zip is not here") }
        let parts = folder.appendingPathComponent("Parts", isDirectory: true)
        for entry in minimalDocxEntries(text: words) {
            let part = parts.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: part)
        }
        let url = folder.appendingPathComponent("Sluice Notes.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        // The folder's whole contents, so no name is read as a pattern ("[Content_Types].xml").
        process.arguments = ["-q", "-r", "-P", "secret", url.path, "."]
        process.currentDirectoryURL = parts
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("zip could not make the fixture") }
        return url
    }

    /// The path of every file under `package`, relative to it, sorted. Both
    /// sides are resolved first: the enumerator reports /private/var where
    /// the package's URL says /var.
    private func files(in package: URL) throws -> [String] {
        let root = package.resolvingSymlinksInPath().path
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: package.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey]))
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return String(url.resolvingSymlinksInPath().path.dropFirst(root.count))
        }.sorted()
    }

    /// No file of `package` holds the fixture's heading, in any case, and its record's index is empty.
    private func assertNoZebra(in package: URL) throws {
        for name in try files(in: package) {
            let data = try Data(contentsOf: URL(fileURLWithPath: package.resolvingSymlinksInPath().path + name))
            XCTAssertNil(String(decoding: data, as: UTF8.self).lowercased().range(of: "zebra"), "\(name) holds a heading")
        }
        XCTAssertEqual(try BookInfo.load(from: package).contentIndex?.chapters.count, 0)
    }

    /// No file of `package` holds `words` in plain bytes.
    private func assertNoWords(in package: URL, _ message: String = "") throws {
        for name in try files(in: package) {
            let data = try Data(contentsOf: URL(fileURLWithPath: package.resolvingSymlinksInPath().path + name))
            XCTAssertNil(data.range(of: Data("sluice".utf8)), "\(name) holds the book's words. \(message)")
        }
    }

    // MARK: - Asking First

    /// A plain PDF beside a locked one: only the locked one is found, and it is known by its import checksum.
    func testOnlyProtectedFilesAreFound() throws {
        try prepare()
        let locked = try lockedPDF()
        let open = try PDFFixtures.makePDF(for: self) { [words] context, _ in
            PDFFixtures.drawText(words, size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        let found = LibraryViewModel.protectedFiles(in: [open, locked, folder.appendingPathComponent("missing.pdf")])
        XCTAssertEqual(found.map(\.url), [locked])
        XCTAssertEqual(found.first?.key, try FileImportService.importHash(of: locked))
    }

    /// Waits until `condition` holds of `library`'s published changes.
    private func wait(for library: LibraryViewModel, _ description: String, until condition: @escaping (LibraryViewModel) -> Bool) {
        if condition(library) { return }
        let reached = expectation(description: description)
        reached.assertForOverFulfill = false
        let watch = library.objectWillChange.sink { _ in
            DispatchQueue.main.async { if condition(library) { reached.fulfill() } }
        }
        wait(for: [reached], timeout: 30)
        watch.cancel()
    }

    /// The question is asked, a wrong password keeps it open and says so, the right one remembers
    /// the password under the book's checksum and carries the import on exactly once.
    func testTheQuestionAsksThenCarriesOn() throws {
        try prepare()
        let locked = try lockedPDF()
        let library = LibraryViewModel(initializeServices: false)
        var carriedOn = 0
        XCTAssertTrue(library.askForPasswordsBeforeImporting([locked]) { carriedOn += 1 })
        XCTAssertEqual(library.importPasswordRequest?.remaining.map(\.url), [locked])

        library.submitImportPassword(UnlockChoice(password: Secret("nope"), remember: true, removePassword: false))
        wait(for: library, "the refusal") { $0.importPasswordRequest?.state.failure != nil }
        XCTAssertEqual(library.importPasswordRequest?.state.failure, ProtectionWording.wrongPassword)
        XCTAssertEqual(carriedOn, 0)
        XCTAssertTrue(CredentialStores.current.rememberedPasswords().isEmpty)

        library.submitImportPassword(UnlockChoice(password: Secret("secret"), remember: true, removePassword: false))
        wait(for: library, "the answer") { $0.importPasswordRequest == nil }
        XCTAssertEqual(carriedOn, 1)
        let key = try FileImportService.importHash(of: locked)
        XCTAssertEqual(CredentialStores.current.password(forBook: key), Secret("secret"))
        XCTAssertFalse(UnlockedSources.isUnlocked(locked), "checking the password holds nothing open")
    }

    /// Import Locked carries on with nothing remembered; Cancel adds nothing; a list with no protected book asks nothing.
    func testImportLockedAndCancel() throws {
        try prepare()
        let locked = try lockedPDF()
        let library = LibraryViewModel(initializeServices: false)
        var carriedOn = 0
        XCTAssertTrue(library.askForPasswordsBeforeImporting([locked]) { carriedOn += 1 })
        library.importProtectedBooksLocked()
        XCTAssertNil(library.importPasswordRequest)
        XCTAssertEqual(carriedOn, 1)
        XCTAssertTrue(CredentialStores.current.rememberedPasswords().isEmpty)

        XCTAssertTrue(library.askForPasswordsBeforeImporting([locked]) { carriedOn += 1 })
        library.cancelProtectedImport()
        XCTAssertNil(library.importPasswordRequest)
        XCTAssertEqual(carriedOn, 1, "Cancel adds nothing")

        XCTAssertFalse(library.askForPasswordsBeforeImporting([folder.appendingPathComponent("missing.pdf")]) { carriedOn += 1 })
    }

    // MARK: - Adding

    /// A locked PDF comes in locked: its file's name is its title, no cache or index of text is written, and its package holds none of its words.
    func testAProtectedPDFIsAddedLockedWithNothingRead() throws {
        try prepare()
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
        try prepare()
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
        // The fixture has a heading in memory, and the saves that follow a load are flushed:
        // (the load queues its save before it shows the book) none of it may reach the package, the record included (the review's serious finding).
        XCTAssertTrue(reader.content?.contentIndex.allHeadings.contains { $0.text.lowercased().contains("zebra") } == true)
        LibraryPersistenceService.flushPendingSave()
        try assertNoZebra(in: package)

        reader.close()
        XCTAssertEqual(try files(in: package), before, "opening, reading, and closing wrote no file")
        try assertNoWords(in: package, "after the book was open")
    }

    /// A book unlocked for now is protected whatever a look at its file finds meanwhile. Here
    /// its file is replaced by a plain one, as a sync can, while the plain form of the
    /// protected one is in memory: a load still writes no text cache. It took the book for
    /// plain and wrote content.md from what memory held, the protected words and all.
    func testAnUnlockedBookStaysProtectedWhenItsFileIsReplaced() throws {
        try prepare()
        let book = try FileImportService.importFileWithReport(from: try zipLockedDocx()).book
        XCTAssertTrue(book.isLocked)
        try UnlockedSources.unlock(fileAt: book.bookFileURL, format: .docx, password: Secret("secret"))
        defer { UnlockedSources.release(book.bookFileURL) }
        try minimalDocx(text: "Nothing here but gravel.").write(to: book.bookFileURL)
        XCTAssertNil(ProtectionDetector.scheme(ofFileAt: book.bookFileURL, format: .docx), "a look finds the new file plain")
        XCTAssertTrue(book.isPasswordProtected, "unlocked for now, the book is protected")

        let loaded = try BookContentAnalysisService.load(book: book)
        XCTAssertTrue(loaded.content.chapters.map(\.text).joined().contains("sluice gate"), "read from memory")
        LibraryPersistenceService.flushPendingSave()
        try assertNoWords(in: book.tmbDirectory, "after a load while the book was unlocked")
        XCTAssertFalse(try files(in: book.tmbDirectory).contains { $0.hasSuffix("content.md") })
    }

    // MARK: - The Launch

    /// The launch deletes the plain copy a crash left in a protected book's package while its
    /// password was being removed. The sweep goes through the library's books, so it must wait
    /// for the index: it ran before the index was read, over a library of no books, and left
    /// every such copy in its package, where a cloud library uploads it.
    func testTheLaunchSweepsThePlainCopyARemovalLeft() async throws {
        try prepare()
        let fixture = try LibraryFixture(test: self, label: "PasswordLeftover")
        let book = try FileImportService.importFileWithReport(from: try lockedPDF()).book
        try LibraryFixture.write(Library(books: [book], folders: [BookFolder(name: LibraryFixture.folderName)]), to: fixture.root)
        let leftover = book.tmbDirectory.appendingPathComponent(ProtectionRemoval.temporaryPrefix + UUID().uuidString)
        try Data(words.utf8).write(to: leftover)

        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)
        XCTAssertTrue(model.hasStartedLibrary, "the library did not start")
        XCTAssertTrue(model.library.books.contains { $0.id == book.id }, "the index was not read")
        let swept = await eventually(timeout: 10) { !FileManager.default.fileExists(atPath: leftover.path) }
        XCTAssertTrue(swept, "the launch left the plain copy in the package")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.bookFileURL.path), "the book's own file stays")
    }

    /// An unprotected PDF is added as it always was, with its text read and its cache written.
    func testAnOrdinaryPDFIsStillAddedWithItsText() throws {
        try prepare()
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
