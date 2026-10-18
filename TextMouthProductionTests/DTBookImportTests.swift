import XCTest
@testable import TextMouth

/// A DTBook file on its own, and a NIMAS package (a DTBook, an OPF, and
/// images), import as DAISY books (FMT04). Other XML files are refused by
/// name. Every test works on a copy of a sample in a folder of its own.
final class DTBookImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder the refusal tests import into; each test has its own.
    private let folderPath = "DTBook Import \(UUID().uuidString.prefix(8))"

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

    /// The headings the standalone sample shows a reader, with their levels.
    /// The reader opens with the book's title as a heading, and shows the
    /// sample's sidebar title ("Tip") among them.
    private let harbourHeadings = [
        "1: Harbour Notes", "1: Preface", "1: The Ferry", "2: Morning Tides", "2: Tip", "2: Timetable", "1: The Return"
    ]

    /// The names of the files in `book`'s package, folders left out.
    private func packageFiles(of book: Book) throws -> Set<String> {
        let entries = try XCTUnwrap(FileManager.default.enumerator(atPath: book.tmbDirectory.path))
        var files: Set<String> = []
        while let path = entries.nextObject() as? String {
            guard (entries.fileAttributes?[.type] as? FileAttributeType) != .typeDirectory else { continue }
            files.insert(path)
        }
        return files
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist. A refused import leaves it empty.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// The sample DTBook copied into a folder of its own with `edit` applied
    /// to its text, to test a variation of it.
    private func editedCopyOfSample(_ edit: (String) -> String) throws -> URL {
        let copy = try copyOfFormatSample("dtbook/harbour-standalone.xml")
        let text = try String(contentsOf: copy, encoding: .utf8)
        try edit(text).write(to: copy, atomically: true, encoding: .utf8)
        return copy
    }

    // MARK: - A DTBook on Its Own

    /// The standalone sample imports as a DAISY book titled and authored by
    /// its head's metadata, shows its headings and their text, and its
    /// package holds the XML file and the text cache.
    func testAStandaloneDTBookImportsAsADAISYBook() throws {
        let copy = try copyOfFormatSample("dtbook/harbour-standalone.xml")

        let imported = try importedForTest(copy)
        let book = imported.book
        let content = try openedContent(of: book)

        XCTAssertEqual(book.format, .daisy)
        XCTAssertEqual(book.title, "Harbour Notes")
        XCTAssertEqual(book.author, "A. Sample")
        XCTAssertEqual(headingLines(of: content), harbourHeadings)
        let text = allText(of: content)
        XCTAssertTrue(text.contains("Café tables"), text)
        XCTAssertTrue(text.contains("Arrive early for a window seat"), text)
        XCTAssertTrue(text.contains("Departs"), text)
        let files = try packageFiles(of: book)
        XCTAssertTrue(files.contains("harbour-standalone.xml"), "\(files)")
        XCTAssertTrue(files.contains("content.md"), "\(files)")
    }

    /// Without its `dc:Title` meta, the DTBook is titled by its `doctitle`;
    /// without that too, by its file's name.
    func testATitleFallsBackToTheDocTitleThenTheFileName() throws {
        let metaLine = "<meta name=\"dc:Title\" content=\"Harbour Notes\"/>"
        let withoutMeta = try editedCopyOfSample { $0.replacingOccurrences(of: metaLine, with: "") }
        XCTAssertFalse(try String(contentsOf: withoutMeta, encoding: .utf8).contains(metaLine))
        let docTitled = try importedForTest(withoutMeta).book
        XCTAssertEqual(docTitled.title, "Harbour Notes")
        XCTAssertEqual(docTitled.author, "A. Sample")

        let withoutBoth = try editedCopyOfSample {
            $0.replacingOccurrences(of: metaLine, with: "")
                .replacingOccurrences(of: "<doctitle>Harbour Notes</doctitle>", with: "")
        }
        let named = try importedForTest(withoutBoth).book
        XCTAssertEqual(named.title, "harbour-standalone")
    }

    // MARK: - NIMAS

    /// A NIMAS-style package imports as a DAISY book, as a folder and by
    /// its OPF, titled and authored by the OPF and showing the same
    /// headings, although the image its manifest lists is missing.
    func testANIMASPackageImportsAsAFolderAndByItsOPF() throws {
        let folder = try copyOfFormatSample("dtbook/nimas-style-package")
        let opf = folder.appendingPathComponent("harbour-nimas.opf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pier.png").path))

        for source in [folder, opf] {
            let book = try importedForTest(source).book
            XCTAssertEqual(book.format, .daisy, source.lastPathComponent)
            XCTAssertEqual(book.title, "Harbour Notes (NIMAS-style sample)", source.lastPathComponent)
            XCTAssertEqual(book.author, "A. Sample", source.lastPathComponent)
            XCTAssertEqual(headingLines(of: try openedContent(of: book)), harbourHeadings, source.lastPathComponent)
        }
    }

    // MARK: - Refusals

    /// An XML file whose root is neither a DTBook's nor Word's is refused
    /// by name, before anything is copied.
    func testAnotherKindOfXMLIsRefusedByName() throws {
        let folder = try makeSandboxDirectory("DTBookImport")
        let catalog = folder.appendingPathComponent("catalog.xml")
        try Data("<?xml version=\"1.0\"?><catalog><item>One</item></catalog>".utf8).write(to: catalog)

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: catalog, toFolder: folderPath)) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .checkingFormat)
            // FileImportError is not Equatable, so its case is told by its sentence.
            XCTAssertEqual(
                ((error as? ImportFailure)?.underlying as? FileImportError)?.errorDescription,
                FileImportError.unsupportedXML.errorDescription
            )
            XCTAssertEqual(
                error.localizedDescription,
                "Could not import “catalog.xml”. Checking its format failed: This XML file is neither a DTBook book "
                    + "nor a Word 2003 XML document, the kinds of XML file TextMouth reads."
            )
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    /// A DTBook past the document byte limit is refused with the limit's
    /// sentence (not as "not a DAISY book"), and leaves nothing in the library.
    func testADTBookPastTheByteLimitIsRefused() throws {
        let copy = try copyOfFormatSample("dtbook/harbour-standalone.xml")

        XCTAssertThrowsError(
            try DocumentByteLimit.$current.withValue(100) {
                try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Could not import “harbour-standalone.xml”. "), "\(error)")
            XCTAssertTrue(
                error.localizedDescription.hasSuffix("This document holds more than 100 bytes, the most TextMouth reads from one document."),
                "\(error)"
            )
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    /// A DTBook cut off inside its head is refused with the DAISY reader's
    /// damage sentence, which names the file and says what to do.
    func testATruncatedDTBookIsRefusedAsDamaged() throws {
        let copy = try editedCopyOfSample {
            // Everything before the Creator meta: the file ends inside its head.
            $0.components(separatedBy: "<meta name=\"dc:Creator\"").first ?? ""
        }

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Could not import “harbour-standalone.xml”. "), "\(error)")
            XCTAssertTrue(
                error.localizedDescription.contains("The file “harbour-standalone.xml” in this DAISY book is damaged or incomplete: "),
                "\(error)"
            )
            XCTAssertTrue(
                error.localizedDescription.hasSuffix("Get a fresh copy of the book, then import it again."),
                "\(error)"
            )
        }
    }

    // MARK: - The Single-File Provider

    /// The provider lists its file alone and reads, or copies, nothing else,
    /// whatever lies beside the file.
    func testTheSingleFileProviderServesItsFileAlone() throws {
        let copy = try copyOfFormatSample("dtbook/harbour-standalone.xml")
        let neighbour = copy.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try Data("not part of the book".utf8).write(to: neighbour)
        let provider = try SingleFileProvider(fileURL: copy)

        XCTAssertEqual(provider.listFiles(), ["harbour-standalone.xml"])
        XCTAssertEqual(try provider.readFile(at: "harbour-standalone.xml"), try Data(contentsOf: copy))
        for path in ["secret.txt", "../secret.txt", "harbour-standalone.xml/../secret.txt"] {
            XCTAssertThrowsError(try provider.readFile(at: path), path) { error in
                XCTAssertEqual(error.localizedDescription, "Missing DAISY content: File not found: \(path)")
            }
            XCTAssertThrowsError(
                try provider.copyFile(at: path, to: copy.deletingLastPathComponent().appendingPathComponent("copy.txt")),
                path
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: copy.deletingLastPathComponent().appendingPathComponent("copy.txt").path
        ))
    }

    // MARK: - The Head Parser

    /// The head parser takes the first non-empty `dc:Title` and `dc:Creator`
    /// metas, whatever their case, collapsing white space, and ignores a
    /// meta outside the head.
    func testTheHeadParserPrefersTheMetaElements() throws {
        let xml = """
            <dtbook><meta name="dc:Title" content="Outside"/>
            <head>
              <meta name="DC:TITLE" content="  Harbour
                 Notes  "/>
              <meta name="dc:Title" content="Second Title"/>
              <meta name="dc:Creator" content="A.   Sample"/>
            </head>
            <book><frontmatter><doctitle>Doc Title</doctitle><docauthor>Doc Author</docauthor></frontmatter></book></dtbook>
            """

        let metadata = try DAISYDTBookHeadParser(data: Data(xml.utf8), file: "book.xml").parse()

        XCTAssertEqual(metadata.title, "Harbour Notes")
        XCTAssertEqual(metadata.author, "A. Sample")
    }

    /// Without metas, the first `doctitle` and `docauthor` name the book,
    /// including text inside an inline element, with white space collapsed.
    func testTheHeadParserFallsBackToTheFrontMatter() throws {
        let xml = """
            <dtbook><head/><book><frontmatter>
            <doctitle>The   <em>Long</em>
               Ferry</doctitle><doctitle>Another</doctitle>
            <docauthor> Ottilie  Vandermeer </docauthor>
            </frontmatter></book></dtbook>
            """

        let metadata = try DAISYDTBookHeadParser(data: Data(xml.utf8), file: "book.xml").parse()

        XCTAssertEqual(metadata.title, "The Long Ferry")
        XCTAssertEqual(metadata.author, "Ottilie Vandermeer")
    }

    /// A DTBook that names neither gives empty strings, and a damaged one
    /// throws the DAISY reader's damage error.
    func testTheHeadParserGivesEmptyNamesAndRejectsDamage() throws {
        let bare = try DAISYDTBookHeadParser(data: Data("<dtbook><head/><book/></dtbook>".utf8), file: "book.xml").parse()
        XCTAssertEqual(bare.title, "")
        XCTAssertEqual(bare.author, "")

        XCTAssertThrowsError(
            try DAISYDTBookHeadParser(data: Data("<dtbook><head><meta".utf8), file: "book.xml").parse()
        ) { error in
            guard case .malformedXML(let file, _)? = error as? DAISYParserError else {
                return XCTFail("Expected malformedXML, got \(error)")
            }
            XCTAssertEqual(file, "book.xml")
        }
    }
}
