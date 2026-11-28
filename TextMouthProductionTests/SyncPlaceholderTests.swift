import XCTest
@testable import TextMouth

/// The package of a book another device has (FR43): what `SyncPlaceholder`
/// makes of a merge's new book, in a scratch library directory.
final class SyncPlaceholderTests: XCTestCase {
    /// Scratch library directories made by a test.
    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for directory in scratch { try? FileManager.default.removeItem(at: directory) }
        scratch = []
    }

    /// A new, empty library directory.
    private func makeLibraryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncPlaceholder-\(UUID().uuidString)", isDirectory: true)
        scratch.append(directory)
        return directory
    }

    /// A book as sync-core's merge makes one for a book it lacks, and the
    /// content the book's manifest gave.
    private func makeNewBook(folderPath: String = "", packageName: String = "") -> SyncNewBook {
        let book = Book(
            id: UUID(), title: "Placeholder Subject", author: "Test Fixture", format: .epub,
            filePath: "", md5Hash: "", folderPath: folderPath, tmbDirectoryName: packageName
        )
        let content = SyncContent(
            manifest: "0123abcd.manifest.json", format: .epub,
            dateAdded: Date(timeIntervalSince1970: 1_790_000_000),
            md5Hash: "hash-\(UUID().uuidString)", totalWordCount: 1234, audioDuration: nil
        )
        return SyncNewBook(book: book, content: content)
    }

    /// The package holds the record and the pointer and no book file, and
    /// the row is made from the content.
    func testAPackageHoldsARecordAndAPointerAndNoBookFile() throws {
        let library = makeLibraryDirectory()
        let storeID = UUID()
        let newBook = makeNewBook(folderPath: "Shelf")
        let book = try SyncPlaceholder.makePackage(for: newBook, storeID: storeID, libraryDirectory: library)

        let package = SyncPlaceholder.packageDirectory(of: book, in: library)
        let names = try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
        XCTAssertEqual(names, [StorePointer.fileName, TextMouthPaths.bookInfoFileName].sorted())
        XCTAssertEqual(book.md5Hash, newBook.content.md5Hash)
        XCTAssertEqual(book.format, .epub)
        XCTAssertEqual(book.totalWordCount, 1234)
        XCTAssertTrue(book.tmbDirectoryName.hasSuffix(".tmb"))
        XCTAssertEqual(URL(fileURLWithPath: book.filePath).deletingLastPathComponent().lastPathComponent, book.tmbDirectoryName)

        let pointer = try XCTUnwrap(StoreFetch.pointer(in: package))
        XCTAssertEqual(pointer.storeID, storeID)
        XCTAssertEqual(pointer.bookID, book.id)
        XCTAssertEqual(pointer.manifest, "0123abcd.manifest.json")
        XCTAssertEqual(try BookInfo.load(from: package).metadata.bookID, book.id)
    }

    /// Until the book's file arrives the package is a placeholder; once it
    /// is there, the same package with its pointer is a fetched book.
    func testAPackageIsAPlaceholderUntilItsFileArrives() throws {
        let library = makeLibraryDirectory()
        let book = try SyncPlaceholder.makePackage(for: makeNewBook(), storeID: UUID(), libraryDirectory: library)
        let package = SyncPlaceholder.packageDirectory(of: book, in: library)
        XCTAssertTrue(SyncPlaceholder.isPlaceholder(package: package, contentFile: book.bookFileURL))
        try Data("words".utf8).write(to: book.bookFileURL)
        XCTAssertFalse(SyncPlaceholder.isPlaceholder(package: package, contentFile: book.bookFileURL))
    }

    /// Making a package twice, as after a crash, changes nothing: the same
    /// files, the same pointer.
    func testMakingAPackageTwiceChangesNothing() throws {
        let library = makeLibraryDirectory()
        let newBook = makeNewBook()
        let storeID = UUID()
        let first = try SyncPlaceholder.makePackage(for: newBook, storeID: storeID, libraryDirectory: library)
        var again = newBook
        again.book = first
        let second = try SyncPlaceholder.makePackage(for: again, storeID: storeID, libraryDirectory: library)
        XCTAssertEqual(first.tmbDirectoryName, second.tmbDirectoryName)
        let package = SyncPlaceholder.packageDirectory(of: second, in: library)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path).count, 2)
        XCTAssertEqual(StoreFetch.pointer(in: package)?.manifest, "0123abcd.manifest.json")
    }

    /// Orphan adoption keeps a placeholder as a book, its file named as its
    /// record names it, and never takes the pointer for the book's file.
    func testAdoptionKeepsAPlaceholder() throws {
        let library = makeLibraryDirectory()
        var newBook = makeNewBook()
        newBook.book.filePath = "/ignored/book.epub"
        let made = try SyncPlaceholder.makePackage(for: newBook, storeID: UUID(), libraryDirectory: library)
        var adopted = Library()
        FileImportService.adoptOrphanedTMBPackages(library: &adopted, libraryDirectory: library)
        let book = try XCTUnwrap(adopted.books.first { $0.id == made.id })
        XCTAssertEqual(URL(fileURLWithPath: book.filePath).lastPathComponent, "book.epub")
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.filePath))
    }

    /// A package with a record and no book file and no pointer is not a
    /// placeholder: it is adopted as before, which is to say not at all.
    func testAdoptionStillLeavesAPackageWithNeitherFileNorPointer() throws {
        let library = makeLibraryDirectory()
        let made = try SyncPlaceholder.makePackage(for: makeNewBook(), storeID: UUID(), libraryDirectory: library)
        let package = SyncPlaceholder.packageDirectory(of: made, in: library)
        try FileManager.default.removeItem(at: package.appendingPathComponent(StorePointer.fileName))
        var adopted = Library()
        FileImportService.adoptOrphanedTMBPackages(library: &adopted, libraryDirectory: library)
        XCTAssertTrue(adopted.books.isEmpty)
    }

    /// A folder path or a package name the library refuses makes no package.
    func testARefusedFolderOrNameMakesNothing() throws {
        let library = makeLibraryDirectory()
        XCTAssertThrowsError(
            try SyncPlaceholder.makePackage(for: makeNewBook(folderPath: "../Escape"), storeID: UUID(), libraryDirectory: library)
        ) { XCTAssertEqual($0 as? SyncPlaceholder.Failure, .invalidFolderPath) }
        XCTAssertThrowsError(
            try SyncPlaceholder.makePackage(for: makeNewBook(packageName: "../up.tmb"), storeID: UUID(), libraryDirectory: library)
        ) { XCTAssertEqual($0 as? SyncPlaceholder.Failure, .invalidPackageName) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }
}
