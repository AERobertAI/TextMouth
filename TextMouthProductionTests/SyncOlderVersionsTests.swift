import XCTest
@testable import TextMouth

/// What today's TextMouth, with no sync code in the path, does with the
/// package of a book it lacks the files of, a placeholder (FR43, section 6 of
/// the build plan): a bookInfo.json and a `.storeCopy.json`, and no content
/// file. Syncing is version 0.6.0 because of the points these tests pin, and
/// each test names the one it pins. They run the library's own repair code
/// over a scratch library directory, so they touch no real library.
final class SyncOlderVersionsTests: XCTestCase {
    /// Scratch directories made by a test, in the process's temporary folder.
    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for directory in scratch { try? FileManager.default.removeItem(at: directory) }
        scratch = []
    }

    // MARK: - Fixtures

    /// A new library directory with one folder-less placeholder package in it:
    /// the record of a book, the pointer, and no book file. Returns the
    /// library directory, the package, and the book.
    private func makePlaceholderLibrary(withContent: Bool = false) throws -> (library: URL, package: URL, book: Book) {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncOlderVersions-\(UUID().uuidString)", isDirectory: true)
        scratch.append(library)
        let packageName = "Placeholder-\(UUID().uuidString).tmb"
        let package = library.appendingPathComponent(packageName, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        let book = Book(
            title: "A Book Another Device Has",
            author: "Test Fixture",
            format: .txt,
            filePath: content.path,
            md5Hash: "sync-older-\(UUID().uuidString)",
            folderPath: "",
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing(inPackageAt: package)
        let pointer = StorePointer(
            formatVersion: 1, storeID: UUID(), bookID: book.id, manifest: "abc.manifest.json", uploaded: nil,
            files: [StorePointer.File(path: "book.txt", sha256: "abc", size: 10, modified: 0, onThisDevice: withContent)]
        )
        try JSONEncoder().encode(pointer).write(to: package.appendingPathComponent(StorePointer.fileName))
        if withContent { try Data("Some words.".utf8).write(to: content) }
        return (library, package, book)
    }

    // MARK: - What an older TextMouth does

    /// The pointer's dot keeps it out of what counts as a book's content, so
    /// no older code mistakes it for the book file or exports it.
    func testThePointerIsNotAPackageContentName() {
        XCTAssertEqual(StorePointer.fileName, ".storeCopy.json")
        XCTAssertFalse(FileImportService.isPackageContentName(StorePointer.fileName))
    }

    /// Once the book's file is on the device, the same package is adopted as
    /// any other, naming the book file and never the pointer.
    func testAdoptionTakesAFetchedBookByItsFileNotThePointer() throws {
        let fixture = try makePlaceholderLibrary(withContent: true)
        var adopted = Library()
        FileImportService.adoptOrphanedTMBPackages(library: &adopted, libraryDirectory: fixture.library)
        let book = try XCTUnwrap(adopted.books.first { $0.id == fixture.book.id })
        XCTAssertEqual(URL(fileURLWithPath: book.filePath).lastPathComponent, "book.txt")
    }

    /// Taking a book back from a package whose record is gone finds no
    /// content in a placeholder either: it throws, so nothing is made up.
    func testRetainedContentRefusesAPlaceholder() throws {
        let fixture = try makePlaceholderLibrary()
        XCTAssertThrowsError(try FileImportService.retainedContentURL(in: fixture.package))
    }

    /// The package's record reads back as it was written, so an older
    /// TextMouth that does read it (a rebuild's walk) sees the book's details.
    func testThePlaceholdersRecordStillReadsAsABookInfo() throws {
        let fixture = try makePlaceholderLibrary()
        let info = try BookInfo.load(from: fixture.package)
        XCTAssertEqual(info.metadata.bookID, fixture.book.id)
        XCTAssertEqual(info.metadata.title, "A Book Another Device Has")
    }
}
