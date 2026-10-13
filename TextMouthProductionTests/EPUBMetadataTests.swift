import XCTest
@testable import TextMouth

/// Regression coverage for safe EPUB metadata persistence.
final class EPUBMetadataTests: XCTestCase {
    func testLegacyAliceFixtureExtractsCoreMetadataThroughProductionParser() throws {
        let metadata = try EPUBParser.readMetadata(url: requireFile("alice.epub"))

        XCTAssertEqual(metadata.title, "Alice's Adventures in Wonderland")
        XCTAssertEqual(metadata.author, "Lewis Carroll")
        XCTAssertEqual(metadata.language, "en")
        XCTAssertEqual(metadata.identifier, "http://www.gutenberg.org/11")
        XCTAssertEqual(metadata.epubVersion, "2.0")
    }

    func testLegacyAliceFixtureExtractsOptionalPublisherAndPublicationDate() throws {
        let metadata = try EPUBParser.readMetadata(url: requireFile("alice.epub"))

        XCTAssertEqual(metadata.publisher, "")
        XCTAssertEqual(metadata.publicationDate, "2008-06-27")
    }

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

    /// The hash returned describes the bytes the replacement installs, and
    /// is taken before the original is replaced, so a write that has
    /// replaced the file cannot then report a failure (TODO A09). Here the
    /// replaced file is made unreadable at once; reading it back afterwards,
    /// as the write once did, would throw.
    func testHashIsTakenFromThePreparedCopyBeforeReplacing() throws {
        let workingCopy = try makeWorkingCopy()
        defer {
            _ = chmod(workingCopy.path, 0o644)
            try? FileManager.default.removeItem(at: workingCopy)
        }
        var metadata = try EPUBParser.readMetadata(url: workingCopy)
        metadata.title = "Hashed Before Replacing"
        var preparedHash: String?

        let hash = try EPUBParser.writeMetadata(
            metadata,
            to: workingCopy,
            replacingWith: { original, prepared in
                preparedHash = try FileImportService.md5Hash(of: prepared)
                _ = try FileManager.default.replaceItemAt(original, withItemAt: prepared)
                XCTAssertEqual(chmod(original.path, 0o000), 0, "could not make the replaced file unreadable")
            }
        )

        XCTAssertEqual(hash, preparedHash)
        XCTAssertEqual(chmod(workingCopy.path, 0o644), 0)
        XCTAssertEqual(hash, try FileImportService.md5Hash(of: workingCopy))
        XCTAssertEqual(try EPUBParser.readMetadata(url: workingCopy).title, "Hashed Before Replacing")
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

    // MARK: - The Metadata a Book's Row Keeps

    /// An imported EPUB's row keeps its package metadata, which the reader
    /// shows without reading the file: every field exactly as reading the
    /// file and laying the book's own edits over it gives.
    func testTheRowKeepsAnImportedEPUBsMetadataAsReadingTheFileGivesIt() throws {
        let book = try importedWorkingCopy()

        let kept = try XCTUnwrap(book.keptEPUBMetadata, "the imported book's row keeps no EPUB metadata")

        let read = book.mergingEditableEPUBMetadata(try EPUBParser.readMetadata(url: book.bookFileURL))
        XCTAssertEqual(kept.allFields, read.allFields)
        XCTAssertEqual(kept.title, "Alice's Adventures in Wonderland")
        XCTAssertEqual(kept.author, "Lewis Carroll")
        XCTAssertEqual(kept.language, "en")
    }

    /// An edit written into the library's copy of the file, as the metadata
    /// editor writes it (TODO A09), changes only the fields the row keeps
    /// the edit in, so the row's metadata is still what reading the file
    /// and laying the book's edits over it gives.
    func testTheRowsMetadataStaysTheFilesOnceAnEditIsWrittenIntoIt() throws {
        var book = try importedWorkingCopy()
        var edited = try XCTUnwrap(book.keptEPUBMetadata)
        edited.title = "Under the Hill"
        edited.author = "Ottoline Pryce-Mbeki"
        edited.publisher = "Harbour Steps Press"
        edited.publicationDate = "1907-03-02"

        _ = try EPUBParser.writeMetadata(edited, to: book.bookFileURL)
        book.title = edited.title
        book.author = edited.author
        book.epubPublisher = edited.publisher
        book.epubPublicationDate = edited.publicationDate

        let read = book.mergingEditableEPUBMetadata(try EPUBParser.readMetadata(url: book.bookFileURL))
        XCTAssertEqual(book.keptEPUBMetadata?.allFields, read.allFields)
        XCTAssertEqual(book.keptEPUBMetadata?.allFields, edited.allFields)
    }

    /// A row without any one of the fields, as the row of a book imported
    /// before rows kept them is, keeps no metadata, so the reader reads it
    /// from the file; nor does the row of a book of another format.
    func testARowWithoutEveryFieldKeepsNoMetadata() throws {
        let book = try importedWorkingCopy()
        XCTAssertNotNil(book.keptEPUBMetadata, "the imported book's row keeps no EPUB metadata")
        let fields: [(name: String, field: WritableKeyPath<Book, String?>)] = [
            ("publisher", \.epubPublisher),
            ("publication date", \.epubPublicationDate),
            ("ISBN", \.epubISBN),
            ("language", \.epubLanguage),
            ("identifier", \.epubIdentifier),
            ("EPUB version", \.epubVersion),
        ]

        for (name, field) in fields {
            var missing = book
            missing[keyPath: field] = nil
            XCTAssertNil(missing.keptEPUBMetadata, "a row without the \(name)")
        }
        var text = book
        text.format = .txt
        XCTAssertNil(text.keptEPUBMetadata, "a book that is not an EPUB")
    }

    /// A working copy of the Alice EPUB, imported as the developer imports a
    /// book into the hosted tests' library. The copy and the book's package
    /// are removed when the test ends.
    private func importedWorkingCopy() throws -> Book {
        let copy = try makeWorkingCopy()
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return try TextPipelineFixtures.imported(copy, for: self)
    }

    private func makeWorkingCopy() throws -> URL {
        let fixture = try requireFile("alice.epub")
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }
}

private struct SimulatedReplacementError: Error {}

extension EPUBMetadata {
    /// Every field, by name, so that comparing two metadata names each field
    /// that differs.
    var allFields: [String: String] {
        [
            "title": title,
            "author": author,
            "publisher": publisher,
            "publicationDate": publicationDate,
            "isbn": isbn,
            "language": language,
            "identifier": identifier,
            "epubVersion": epubVersion,
        ]
    }
}
