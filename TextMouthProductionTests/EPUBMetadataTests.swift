import XCTest
@testable import TextMouth

/// Regression coverage for safe EPUB metadata persistence.
final class EPUBMetadataTests: XCTestCase {
    func testReplacementFailureLeavesOriginalEPUBUnchanged() throws {
        let workingCopy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: workingCopy) }
        let originalData = try Data(contentsOf: workingCopy)
        var metadata = try EPUBParser.readMetadata(url: workingCopy)
        metadata.title = "Prepared but Not Replaced"

        XCTAssertThrowsError(
            try EPUBParser.writeMetadata(
                metadata,
                to: workingCopy,
                replacingWith: { _, _ in throw SimulatedReplacementError() }
            )
        )

        XCTAssertEqual(try Data(contentsOf: workingCopy), originalData)
        XCTAssertEqual(try EPUBParser.readMetadata(url: workingCopy).title, "Alice's Adventures in Wonderland")
    }

    func testAtomicReplacementPersistsPreparedMetadata() throws {
        let workingCopy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: workingCopy) }
        var metadata = try EPUBParser.readMetadata(url: workingCopy)
        metadata.title = "Atomically Updated Title"

        let hash = try EPUBParser.writeMetadata(metadata, to: workingCopy)

        XCTAssertTrue(FileManager.default.fileExists(atPath: workingCopy.path))
        XCTAssertEqual(try EPUBParser.readMetadata(url: workingCopy).title, "Atomically Updated Title")
        XCTAssertEqual(hash, try FileImportService.md5Hash(of: workingCopy))
    }

    func testStoredPublisherAndDateOverrideUnchangedEPUBFile() throws {
        let workingCopy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: workingCopy) }
        let extracted = try EPUBParser.readMetadata(url: workingCopy)
        let book = Book(
            title: "Library Title",
            author: "Library Author",
            format: .epub,
            filePath: workingCopy.path,
            md5Hash: "hash",
            epubPublisher: "Library Publisher",
            epubPublicationDate: "2026-07-12"
        )

        let merged = book.mergingEditableEPUBMetadata(extracted)

        XCTAssertEqual(merged.title, "Library Title")
        XCTAssertEqual(merged.author, "Library Author")
        XCTAssertEqual(merged.publisher, "Library Publisher")
        XCTAssertEqual(merged.publicationDate, "2026-07-12")
    }

    func testBookInfoRoundTripPreservesEPUBMetadata() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let file = package.appendingPathComponent("book.epub")
        try Data().write(to: file)
        let book = Book(
            title: "Stored EPUB",
            format: .epub,
            filePath: file.path,
            md5Hash: "hash",
            tmbDirectoryName: packageName,
            epubPublisher: "Publisher",
            epubPublicationDate: "2026",
            epubISBN: "9780000000001",
            epubLanguage: "en",
            epubIdentifier: "identifier",
            epubVersion: "3.0"
        )

        book.saveBookInfo()
        let info = try BookInfo.load(from: package)

        XCTAssertEqual(info.metadata.publisher, "Publisher")
        XCTAssertEqual(info.metadata.publicationDate, "2026")
        XCTAssertEqual(info.metadata.isbn, "9780000000001")
        XCTAssertEqual(info.metadata.language, "en")
        XCTAssertEqual(info.metadata.epubIdentifier, "identifier")
        XCTAssertEqual(info.metadata.epubVersion, "3.0")
    }

    private func makeWorkingCopy() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repositoryRoot.appendingPathComponent("TestData/alice.epub")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }
}

private struct SimulatedReplacementError: Error {}
