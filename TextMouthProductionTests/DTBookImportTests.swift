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

    // MARK: - Every Valid DTBook

    /// One DTBook file the old detection refused: its name, bytes, the title
    /// its head names, and a phrase of its text a listener must hear.
    private struct DTBookVariant {
        let fileName: String
        let bytes: Data
        let title: String
        let words: String
    }

    /// The DTBook that carries `title`, `author`, and `paragraph` in a head
    /// and body, declared as `declaredEncoding` and preceded by `prolog`.
    private func dtbookMarkup(
        declaredEncoding: String, prolog: String = "", title: String, author: String, paragraph: String
    ) -> String {
        """
        <?xml version="1.0" encoding="\(declaredEncoding)"?>
        \(prolog)<dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3" xml:lang="en">
        <head>
         <meta name="dc:Title" content="\(title)"/>
         <meta name="dc:Creator" content="\(author)"/>
        </head>
        <book><bodymatter><level1><h1>Chapter One</h1><p>\(paragraph)</p></level1></bodymatter></book>
        </dtbook>
        """
    }

    /// The four DTBooks the old detection refused, built here: a long
    /// comment before the root, ISO 8859-1 text, Cyrillic head text, and
    /// UTF-16 with a byte order mark. The old test decoded the first 500
    /// bytes as UTF-8 and looked for "dtbook" in them: a comment pushed the
    /// root past them, Latin-1 is not UTF-8, a Cyrillic head is cut inside a
    /// letter there, and UTF-16 is not UTF-8 either.
    private func dtbookVariants() throws -> [DTBookVariant] {
        let comment = "<!-- " + String(repeating: "Licensed for reading by the borrowing library. ", count: 13) + "-->\n"
        let commented = dtbookMarkup(
            declaredEncoding: "UTF-8", prolog: comment,
            title: "Harbour Notes", author: "A. Sample", paragraph: "These notes were written on the quay."
        )
        let latin1 = dtbookMarkup(
            declaredEncoding: "ISO-8859-1", title: "Caf\u{E9} Notes", author: "\u{C9}mile Bront\u{EB}",
            paragraph: "Le se\u{F1}or boit un caf\u{E9} sur le quai."
        )
        let russian = dtbookMarkup(
            declaredEncoding: "UTF-8", title: "Записки у причала", author: "Антонина Сергеевна Кулагина",
            paragraph: "Паром отходит в семь."
        )
        let utf16 = dtbookMarkup(
            declaredEncoding: "UTF-16", title: "Harbour Notes", author: "A. Sample", paragraph: "The ferry leaves at seven."
        )
        return [
            DTBookVariant(fileName: "commented.xml", bytes: Data(commented.utf8),
                          title: "Harbour Notes", words: "written on the quay"),
            DTBookVariant(fileName: "latin1.xml", bytes: try XCTUnwrap(latin1.data(using: .isoLatin1)),
                          title: "Caf\u{E9} Notes", words: "boit un caf\u{E9} sur le quai"),
            DTBookVariant(fileName: "russian.xml", bytes: Data(russian.utf8),
                          title: "Записки у причала", words: "Паром отходит в семь"),
            // `data(using: .utf16)` begins with the byte order mark.
            DTBookVariant(fileName: "utf16.xml", bytes: try XCTUnwrap(utf16.data(using: .utf16)),
                          title: "Harbour Notes", words: "The ferry leaves at seven"),
        ]
    }

    /// Each of the four variants imports as a DAISY book with its own title
    /// and its words: the sniffer's answer is the one test of a DTBook.
    func testADTBookInAnyEncodingOrProlog() throws {
        for variant in try dtbookVariants() {
            let folder = try makeSandboxDirectory("DTBookVariant")
            let file = folder.appendingPathComponent(variant.fileName)
            try variant.bytes.write(to: file)
            XCTAssertEqual(XMLDocumentSniffer.rootKind(ofFileAt: file), .dtbook, variant.fileName)

            let book = try importedForTest(file).book

            XCTAssertEqual(book.format, .daisy, variant.fileName)
            XCTAssertEqual(book.title, variant.title, variant.fileName)
            let text = allText(of: try openedContent(of: book))
            XCTAssertTrue(text.contains(variant.words), "\(variant.fileName): \(text)")
        }
    }

    /// A DTBook named metadata.xml is still a DTBook: no file name is passed
    /// over when a file is searched for the book's text.
    func testADTBookNamedMetadataXMLImports() throws {
        let sample = try copyOfFormatSample("dtbook/harbour-standalone.xml")
        let renamed = sample.deletingLastPathComponent().appendingPathComponent("metadata.xml")
        try FileManager.default.moveItem(at: sample, to: renamed)

        let book = try importedForTest(renamed).book

        XCTAssertEqual(book.format, .daisy)
        XCTAssertEqual(book.title, "Harbour Notes")
    }

    // MARK: - Refusals

    /// A DTBook with a head and a book but no words is refused, as a blank
    /// text file is, and leaves nothing in the library.
    func testABlankDTBookIsRefused() throws {
        let folder = try makeSandboxDirectory("DTBookBlank")
        let blank = folder.appendingPathComponent("blank.xml")
        try Data("<dtbook><head/><book/></dtbook>".utf8).write(to: blank)

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: blank, toFolder: folderPath)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Could not import “blank.xml”. Reading its text failed: This file has no text to read."
            )
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    /// Only a DTBook on its own is refused for having no words: a DAISY
    /// package whose DTBook carries none still imports, by its folder and by
    /// its OPF, as it always has (its audio is the book).
    func testAPackageWhoseDTBookHasNoWordsStillImports() throws {
        let package = try copyOfFormatSample("dtbook/nimas-style-package")
        try Data("<dtbook><head/><book/></dtbook>".utf8)
            .write(to: package.appendingPathComponent("harbour-dtbook.xml"))

        for source in [package, package.appendingPathComponent("harbour-nimas.opf")] {
            let book = try importedForTest(source).book
            XCTAssertEqual(book.format, .daisy, source.lastPathComponent)
        }
    }

    /// An .xml file with no bytes, or only white space, is told it has no
    /// text to read, not that it is some other kind of XML.
    func testAnEmptyOrBlankXMLFileHasNoTextToRead() throws {
        let folder = try makeSandboxDirectory("DTBookEmpty")
        for (name, bytes) in [("empty.xml", Data()), ("spaces.xml", Data(" \n\t\r\n ".utf8))] {
            let file = folder.appendingPathComponent(name)
            try bytes.write(to: file)

            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: file, toFolder: folderPath), name) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "Could not import “\(name)”. Checking its format failed: This file has no text to read.",
                    name
                )
            }
        }
        XCTAssertEqual(try folderEntries(), [])
    }

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
                "Could not import “catalog.xml”. Checking its format failed: This XML file is not a DTBook book, "
                    + "a Word 2003 XML document, or a PEF braille file, the kinds of XML file TextMouth reads."
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
