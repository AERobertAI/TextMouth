import XCTest
import ZIPFoundation
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

    // MARK: - External Entities (U01)

    /// The text of the file on this Mac that the crafted EPUB below names.
    private static let secretText = "SECRET-FILE-TEXT"

    /// An EPUB whose package document and NCX declare an external entity
    /// naming a file on this Mac, and use it in the title, the author, a
    /// description, and a heading's label, reads that entity as nothing:
    /// neither the metadata read for the library, nor the book read for the
    /// reader, nor the package Edit Metadata writes back into the EPUB holds
    /// the file's text, and the book still reads. XMLDocument once loaded
    /// such entities, so a crafted EPUB put a local file's text into the
    /// library and, on Edit Metadata, into the EPUB itself.
    func testAnExternalEntityNeverBringsAFilesTextIntoTheBook() throws {
        let folder = try TextPipelineFixtures.temporaryFolder(for: self)
        let secret = folder.appendingPathComponent("secret.txt")
        try Data(Self.secretText.utf8).write(to: secret)
        let epub = try makeEPUBNamingAnEntity(for: secret)

        let metadata = try EPUBParser.readMetadata(url: epub)
        let content = try EPUBParser.parse(url: epub)
        var edited = metadata
        edited.title = "Harbour Lamps"
        _ = try EPUBParser.writeMetadata(edited, to: epub)
        let written = try EPUBParser.extractString(archive: Archive(url: epub, accessMode: .read), path: "OEBPS/package.opf")

        let readings: [(place: String, text: String)] = [
            ("the title read for the library", metadata.title),
            ("the author read for the library", metadata.author),
            ("the publisher read for the library", metadata.publisher),
            ("the title read for the reader", content.title),
            ("the author read for the reader", content.author),
            ("the headings", content.allHeadings.map(\.text).joined(separator: "\n")),
            ("the chapter titles", content.chapters.map(\.title).joined(separator: "\n")),
            ("the package written back by Edit Metadata", written),
        ]
        for reading in readings {
            XCTAssertFalse(reading.text.contains(Self.secretText), "\(reading.place) holds the file's text: \(reading.text)")
        }
        XCTAssertEqual(content.chapters.map(\.text), ["Harbour lamps were lit at dusk."])
    }

    /// An EPUB in the test's own temporary folder whose package document and
    /// NCX each declare the entity `leak` as the file at `secret`, using it
    /// in the title, the author, the publisher, a description, and the label
    /// of the NCX's one entry, which names the start of its one chapter.
    private func makeEPUBNamingAnEntity(for secret: URL) throws -> URL {
        let entity = "[<!ENTITY leak SYSTEM \"\(secret.absoluteString)\">]"
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE package \(entity)>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:8e3b2a71-4c5d-4f6e-9a0b-1c2d3e4f5a6b</dc:identifier>
        <dc:title>&leak;</dc:title><dc:creator>&leak;</dc:creator><dc:publisher>&leak;</dc:publisher>
        <dc:description>&leak;</dc:description>
        </metadata>
        <manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine toc="ncx"><itemref idref="c1"/></spine>
        </package>
        """
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx \(entity)>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
        <navPoint id="n1"><navLabel><text>Lamps &leak;</text></navLabel><content src="chapter.xhtml"/></navPoint>
        </navMap></ncx>
        """
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Harbour</title></head>
        <body><p>Harbour lamps were lit at dusk.</p></body></html>
        """
        let files = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", container),
            ("OEBPS/package.opf", opf),
            ("OEBPS/toc.ncx", ncx),
            ("OEBPS/chapter.xhtml", chapter),
        ]
        return try TextPipelineFixtures.writeEPUB(
            files.map { TestZIPEntry($0.0, Data($0.1.utf8)) }, named: "entity.epub", for: self
        )
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
