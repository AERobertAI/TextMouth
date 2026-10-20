import XCTest
@testable import TextMouth

/// Braille books in the library (FMT20, FMT21): the BRF, BRL, and PEF
/// samples import as `.braille` books whose text is the print the braille
/// translates to, the table a book was imported with is kept in its row and
/// its record and used by every later reading, the import's refusals say what
/// is wrong in the listener's words, and the format is found by extension and
/// by a PEF's root element. Every test works on a copy of a sample in a folder
/// of its own, and imports with the table it names, never the user's setting.
final class BrailleImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder the refusal tests import into; each test has its own.
    private let folderPath = "Braille Import \(UUID().uuidString.prefix(8))"

    /// The Grade 1 table and the Grade 2 table, by file name.
    private let grade1 = "en-ueb-g1.ctb"
    private let grade2 = "en-ueb-g2.ctb"

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

    // MARK: - Helpers

    /// The text of the format sample at `path`, read from a copy of it.
    private func sampleText(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: copyOfFormatSample(path)), as: UTF8.self)
    }

    /// The Grade 1 sample's 14 print blocks (the title, the heading, and 12
    /// paragraphs), as liblouis reads them back: with its two differences
    /// from the print named and pinned, as `BrailleTranslatorTests` pins
    /// them. UEB writes both curly double quotes with cells liblouis reads as
    /// the straight quote, and the print's _You_ (Project Gutenberg's mark
    /// for italics) comes back as You, since TextMouth keeps no emphasis.
    private func expectedGrade1Blocks() throws -> [String] {
        let blocks = try sampleText("brf/pride-and-prejudice-ch1.txt")
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, 14)
        return blocks.map {
            $0.replacingOccurrences(of: "\u{201C}", with: "\"")
                .replacingOccurrences(of: "\u{201D}", with: "\"")
                .replacingOccurrences(of: "_You_", with: "You")
        }
    }

    /// The text blocks `book` shows a reader, as the reader reads them: its
    /// text with the blank lines between blocks left out.
    private func blocks(of book: Book) throws -> [String] {
        allText(of: try openedContent(of: book))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The book a copy of the sample at `path` (named `name` when that is
    /// not nil) imports as, with `table` as the Braille setting's table.
    private func importedSample(_ path: String, named name: String? = nil, table: String) throws -> Book {
        let copy = try copyOfFormatSample(path, named: name)
        return try BraillePreferences.$tableForImports.withValue(table) {
            try importedForTest(copy).book
        }
    }

    /// A file named `name` in a new folder of this test's own, holding `bytes`.
    private func file(named name: String, holding bytes: Data) throws -> URL {
        let url = try makeSandboxDirectory("BrailleImport").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// Asserts that importing `url` (with `table` as the setting's table, when
    /// given) is refused with exactly `sentence`, the import's own words
    /// including the file's name, leaving nothing in the library.
    private func assertRefused(
        _ url: URL, table: String? = nil, saying sentence: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try BraillePreferences.$tableForImports.withValue(table ?? grade2) {
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url, toFolder: folderPath), file: file, line: line) {
                XCTAssertEqual($0.localizedDescription, sentence, file: file, line: line)
            }
        }
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(entries, [], file: file, line: line)
    }

    // MARK: - The Grade 1 BRF

    /// The Grade 1 BRF imports as a braille book titled by its file's name,
    /// keeps the table it was imported with in its row and in its record,
    /// and reads as the print text's 14 blocks, with the title and "Chapter
    /// I" as level-1 headings and no braille page number.
    func testTheGrade1BRFImportsAsBrailleText() throws {
        let book = try importedSample("brf/pride-and-prejudice-ch1-grade1.brf", table: grade1)

        XCTAssertEqual(book.format, .braille)
        XCTAssertEqual(book.title, "pride-and-prejudice-ch1-grade1")
        XCTAssertEqual(book.author, Book.unknownAuthor)
        XCTAssertEqual(book.brailleTable, grade1)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.brailleTable, grade1)

        let expected = try expectedGrade1Blocks()
        XCTAssertEqual(try blocks(of: book), expected)
        let content = try openedContent(of: book)
        XCTAssertEqual(headingLines(of: content), ["1: Pride and Prejudice", "1: Chapter I"])
        // The braille page numbers (#A and #B on the pages' last lines) are
        // layout, not text. liblouis would read a number sign and a letter
        // as the digit 1 or 2, not as "#", so a page number left in shows as
        // a digit. The sample's print has no digit at all.
        let text = allText(of: content)
        XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "a digit in the text: \(text.prefix(80))")
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("\u{283C}"))
    }

    /// The direct reading, which the reader falls back to, reads the same
    /// text as the cache does, with the book's table.
    func testTheDirectParseReadsTheCachesText() throws {
        let copy = try copyOfFormatSample("brf/pride-and-prejudice-ch1-grade1.brf")
        let direct = try BookParser.parse(url: copy, format: .braille, brailleTable: grade1)
        XCTAssertEqual(direct.chapters.first?.text.contains("Chapter I"), true)
        let cached = try MarkdownDocParser.parse(markdown: BrailleBookReader.markdown(of: copy, table: grade1), title: "x")
        XCTAssertEqual(direct.allText, cached.allText)
    }

    // MARK: - The PEF

    /// The PEF imports as the same text as the BRF, titled and authored by
    /// its own head; so does the same PEF named .xml.
    func testThePEFAndItsXMLCopyImportWithTheirNames() throws {
        let expected = try expectedGrade1Blocks()
        for name in [nil, "notes.xml"] as [String?] {
            let book = try importedSample("pef/pride-and-prejudice-ch1-grade1.pef", named: name, table: grade1)
            let label = name ?? "pef"
            XCTAssertEqual(book.format, .braille, label)
            XCTAssertEqual(book.title, "Pride and Prejudice, Chapter I (Grade 1 UEB sample)", label)
            XCTAssertEqual(book.author, "Jane Austen", label)
            XCTAssertEqual(book.brailleTable, grade1, label)
            XCTAssertEqual(try blocks(of: book), expected, label)
        }
    }

    // MARK: - The BRL

    /// The BRL has no layout: its 14 lines are 14 paragraphs of the same
    /// words, none of them a heading.
    func testTheBRLImportsAsParagraphsWithoutHeadings() throws {
        let book = try importedSample("brl/pride-and-prejudice-ch1-grade1.brl", table: grade1)

        XCTAssertEqual(book.format, .braille)
        XCTAssertEqual(try blocks(of: book), try expectedGrade1Blocks())
        XCTAssertEqual(headingLines(of: try openedContent(of: book)).filter { $0.hasPrefix("1: Chapter") }, [])
    }

    // MARK: - The Grade 2 BRF

    /// The Grade 2 BRF, with the default table, reads its three cell-1 lines
    /// as one paragraph: the three sentences joined by spaces.
    func testTheGrade2BRFReadsWithTheDefaultTable() throws {
        XCTAssertEqual(BrailleTableCatalog.defaultTableID, grade2)
        let book = try importedSample("brf/grade2-short.brf", table: BrailleTableCatalog.defaultTableID)

        XCTAssertEqual(book.brailleTable, grade2)
        let sentences = try sampleText("brf/grade2-short.txt")
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(try blocks(of: book), [sentences.joined(separator: " ")])
    }

    // MARK: - Books written without page numbers

    /// The headings of the book that the Grade 2 sample's sentences make
    /// under a title heading, "Grade Two Sample", written by TextMouth's own
    /// export as a BRF or a PEF of `cells` cells by 25 lines with page
    /// numbers off, then imported with the Grade 2 table, as "level: text"
    /// lines. The title is the one heading the book has.
    private func headingsOfGrade2BookWritten(as kind: BrailleFileKind, cells: Int) throws -> [String] {
        let sentences = try sampleText("brf/grade2-short.txt").components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(sentences.count, 3)
        let blocks: [BrailleBlock] = [.heading(level: 1, text: "Grade Two Sample")] + sentences.map { .paragraph(text: $0) }
        var options = BrailleExportOptions(table: grade2)
        options.page = BraillePageFormat(cellsPerLine: cells, linesPerPage: 25, numbersPages: false)

        // The helper makes its hidden files in a folder of its own.
        let work = try makeSandboxDirectory("BrailleImportWork")
        let url = try makeSandboxDirectory("BrailleImportBook").appendingPathComponent("book.\(kind == .pef ? "pef" : "brf")")
        switch kind {
        case .pef:
            let metadata = PEFMetadata(title: "Grade Two Sample", author: "Test Author", language: "en",
                                       identifier: "urn:uuid:5b0a3f6e-6c1d-4a35-9d57-0e2f6a1b7c10", date: "2026-10-20")
            try BrailleDocumentWriter.pef(of: blocks, metadata: metadata, options: options, workingIn: work).write(to: url)
        default:
            try BrailleDocumentWriter.brf(of: blocks, options: options, workingIn: work).write(to: url)
        }
        let book = try BraillePreferences.$tableForImports.withValue(grade2) { try importedForTest(url).book }
        return headingLines(of: try openedContent(of: book))
    }

    /// Decision 15's Grade 2 book, exported at 40 by 25 with page numbers off,
    /// keeps its title as a heading when it is imported, from the BRF (whose
    /// width is measured) and from the PEF (which declares it). With no
    /// page numbers to measure, the longest row is a few cells short of the
    /// line, and the title measured off center.
    func testTheGrade2BookWrittenWithoutPageNumbersKeepsItsTitleAsAHeading() throws {
        for kind in [BrailleFileKind.brf, .pef] {
            XCTAssertEqual(try headingsOfGrade2BookWritten(as: kind, cells: 40), ["1: Grade Two Sample"], "\(kind)")
        }
    }

    /// The same at 32 cells, where the sentences wrap to a row as long as the
    /// line and the width is the longest row.
    func testAGrade2BookOf32CellsWithoutPageNumbersKeepsItsTitleAsAHeading() throws {
        XCTAssertEqual(try headingsOfGrade2BookWritten(as: .brf, cells: 32), ["1: Grade Two Sample"])
    }

    // MARK: - A book keeps its table

    /// A change of the setting never moves an existing book's text: the cache
    /// regenerated while the setting names another table is the same text.
    /// The Grade 2 sample is used because the two tables read it in different
    /// words (the Grade 1 sample reads the same with both, which would let
    /// this pass whatever table the rebuild used), and the test shows that.
    func testABookKeepsItsTableWhenTheCacheIsRebuilt() throws {
        let book = try importedSample("brf/grade2-short.brf", table: grade2)
        let sentences = try sampleText("brf/grade2-short.txt")
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        let before = try blocks(of: book)
        XCTAssertEqual(before, [sentences.joined(separator: " ")])
        // The other table reads the same file differently, so a rebuild with
        // the setting's table instead of the book's would show.
        let otherReading = try BrailleBookReader.markdown(of: URL(fileURLWithPath: book.filePath), table: grade1)
        XCTAssertTrue(otherReading.hasPrefix("\u{222B} boy"), String(otherReading.prefix(40)))

        try BraillePreferences.$tableForImports.withValue(grade1) {
            XCTAssertNotNil(try MarkdownCacheService.generateReportedCacheContent(for: book))
        }

        XCTAssertEqual(try blocks(of: book), before)
        XCTAssertEqual(book.brailleTable, grade2)
    }

    /// A rebuild reads the book's own table, the one in its row: a book whose
    /// table is changed to Grade 1 reads its text again in the Grade 1 words,
    /// whatever the setting names.
    func testARebuildReadsTheBooksOwnTable() throws {
        var book = try importedSample("brf/grade2-short.brf", table: grade2)
        let before = try blocks(of: book)
        book.brailleTable = grade1

        try BraillePreferences.$tableForImports.withValue(grade2) {
            XCTAssertNotNil(try MarkdownCacheService.generateReportedCacheContent(for: book))
        }

        let after = try blocks(of: book)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.first?.hasPrefix("\u{222B} boy"), true, after.first ?? "no text")
    }

    /// A book whose row and record lack a table reads with the default table.
    func testABookWithoutATableReadsWithTheDefaultTable() throws {
        let copy = try copyOfFormatSample("brf/grade2-short.brf")
        let content = try BookParser.parse(url: copy, format: .braille)
        XCTAssertEqual(content.chapters.first?.text, "The boy and girl can go with you. The church shop is open. We like singing.")
    }

    // MARK: - Refusals

    /// A BRF with nothing in it, and one with only line breaks and form feeds,
    /// are refused as holding no text.
    func testABRFWithNoTextIsRefused() throws {
        let sentence = { (name: String) in "Could not import “\(name)”. Reading its text failed: This file has no text to read." }
        try assertRefused(try file(named: "empty.brf", holding: Data()), saying: sentence("empty.brf"))
        try assertRefused(
            try file(named: "blank.brf", holding: Data("\r\n\r\n\u{0C}\r\n\u{0C}\r\n".utf8)), saying: sentence("blank.brf"))
    }

    /// A BRF holding a letter that is not braille ASCII is refused naming the
    /// line and the letter.
    func testABRFThatIsNotBrailleASCIIIsRefused() throws {
        let url = try file(named: "accented.brf", holding: Data("A\r\n\u{E9}\r\n".utf8))
        try assertRefused(
            url,
            saying: "Could not import “accented.brf”. Reading its text failed: Line 2 holds “é”, which is not braille ASCII.")
    }

    /// A .pef that is a JPEG's first bytes, or plain text, is refused as
    /// damaged or another kind of file.
    func testAPEFThatIsNotAPEFIsRefused() throws {
        let damaged = "This file could not be read as a PEF braille file. It may be damaged, or another kind of file."
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        try assertRefused(
            try file(named: "photo.pef", holding: jpeg),
            saying: "Could not import “photo.pef”. Reading its text failed: \(damaged)")
        try assertRefused(
            try file(named: "letter.pef", holding: Data("Dear reader, this is not braille.".utf8)),
            saying: "Could not import “letter.pef”. Reading its text failed: \(damaged)")
    }

    /// A PEF with a row that uses dot 7 is refused as eight-dot braille.
    func testAnEightDotPEFIsRefused() throws {
        let sample = try sampleText("pef/pride-and-prejudice-ch1-grade1.pef")
        // The title's first row, which the sample writes with six-dot cells only.
        let title = "\u{2820}\u{280F}\u{2817}\u{280A}\u{2819}\u{2811}"
        XCTAssertTrue(sample.contains(title))
        let url = try file(named: "eight.pef", holding: Data(sample.replacingOccurrences(of: title, with: "\u{2841}").utf8))
        try assertRefused(
            url,
            saying: "Could not import “eight.pef”. Reading its text failed: "
                + "This file is eight-dot braille, which TextMouth does not read.")
    }

    /// A new file of `bytes` bytes, all holes (a sparse file, made at once),
    /// named `name` in a new folder of this test's own.
    private func sparseFile(named name: String, bytes: Int64) throws -> URL {
        let url = try makeSandboxDirectory("BrailleImport").appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    /// A braille file of more than 32 MB is refused before it is read, by
    /// exactly this sentence (E5), through the import.
    func testABrailleFileOver32MBIsRefused() throws {
        XCTAssertEqual(BrailleBookReader.maximumFileBytes, 32 * 1_048_576)
        let sentence = "This braille file holds more than 32 MB, the most TextMouth reads from one braille file."
        XCTAssertEqual(BrailleFileError.fileTooLarge.errorDescription, sentence)
        let url = try sparseFile(named: "huge.brf", bytes: BrailleBookReader.maximumFileBytes + 1)
        try assertRefused(url, saying: "Could not import “huge.brf”. Reading its text failed: \(sentence)")
    }

    /// A symbolic link is sized by its target, so a link to a file past the
    /// limit is refused; a file of exactly the limit passes the size check
    /// (the zeros in it are then refused as not braille).
    func testTheLimitSizesALinkByItsTargetAndAllowsTheLimitItself() throws {
        let huge = try sparseFile(named: "huge.brf", bytes: BrailleBookReader.maximumFileBytes + 1)
        let link = huge.deletingLastPathComponent().appendingPathComponent("link.brf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: huge)
        XCTAssertThrowsError(try BrailleBookReader.markdown(of: link, table: grade1)) {
            XCTAssertEqual($0 as? BrailleFileError, .fileTooLarge)
        }

        let exact = try sparseFile(named: "exact.brf", bytes: BrailleBookReader.maximumFileBytes)
        XCTAssertThrowsError(try BrailleBookReader.markdown(of: exact, table: grade1)) {
            XCTAssertNotEqual($0 as? BrailleFileError, .fileTooLarge)
        }
    }

    /// A table TextMouth does not have is refused by name.
    func testAnUnknownTableIsRefused() throws {
        let copy = try copyOfFormatSample("brf/grade2-short.brf")
        try assertRefused(
            copy, table: "en-xx.ctb",
            saying: "Could not import “grade2-short.brf”. Reading its text failed: "
                + "TextMouth has no braille table named \u{201C}en-xx.ctb\u{201D}.")
    }

    /// An XML file that is not a DTBook, Word 2003 XML, or a PEF is refused
    /// by the sentence that names PEF.
    func testAnotherKindOfXMLIsRefusedNamingPEF() throws {
        let url = try file(named: "catalog.xml", holding: Data("<?xml version=\"1.0\"?><catalog><item/></catalog>".utf8))
        try assertRefused(
            url,
            saying: "Could not import “catalog.xml”. Checking its format failed: This XML file is not a DTBook book, "
                + "a Word 2003 XML document, or a PEF braille file, the kinds of XML file TextMouth reads.")
    }

    // MARK: - The Format

    /// A PEF root in PEF's namespace is `.pef`, even from the file's first
    /// bytes alone; the same root in another namespace is not.
    func testTheSnifferKnowsAPEF() throws {
        let sample = try Data(contentsOf: copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef"))
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: sample.prefix(XMLDocumentSniffer.scanLength)), .pef)
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: Data("<pef xmlns=\"urn:example:other\"/>".utf8)), .other)
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: Data("<pef/>".utf8)), .other)
    }

    /// The braille extensions give `.braille`, in any case, and a PEF named
    /// .xml is found by its root.
    func testBrailleFilesAreDetectedByExtensionAndByRoot() throws {
        let brf = try copyOfFormatSample("brf/grade2-short.brf")
        let shouting = try copyOfFormatSample("brl/pride-and-prejudice-ch1-grade1.brl", named: "BOOK.BRL")
        let pef = try copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef")
        let xml = try copyOfFormatSample("pef/pride-and-prejudice-ch1-grade1.pef", named: "notes.xml")

        XCTAssertEqual(BookFormat.detect(from: brf), .braille)
        XCTAssertEqual(BookFormat.detect(from: shouting), .braille)
        XCTAssertEqual(BookFormat.detect(from: pef), .braille)
        XCTAssertEqual(BookFormat.detect(from: xml), .braille)
        XCTAssertEqual(XMLDocumentSniffer.bookFormat(ofFileAt: xml), .braille)
        XCTAssertEqual(BookFormat.braille.displayName, "Braille")
        XCTAssertEqual(BookFormat.braille.fileExtensions, ["brf", "brl", "pef"])
    }

    /// The kind of braille file is told by extension: BRL, PEF (and XML),
    /// and otherwise BRF.
    func testTheKindOfBrailleFileIsToldByExtension() {
        func kind(_ name: String) -> BrailleFileKind { BrailleBookReader.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) }
        XCTAssertEqual(kind("a.brl"), .brl)
        XCTAssertEqual(kind("a.BRL"), .brl)
        XCTAssertEqual(kind("a.pef"), .pef)
        XCTAssertEqual(kind("a.xml"), .pef)
        XCTAssertEqual(kind("a.brf"), .brf)
        XCTAssertEqual(kind("a.txt"), .brf)
        XCTAssertEqual(kind("a"), .brf)
    }

    // MARK: - The Table in Rows and Records

    /// A package record written before braille books, without `brailleTable`,
    /// still loads, and the book made from it has no table.
    func testARecordWithoutTheFieldStillLoads() throws {
        let book = try importedSample("brf/grade2-short.brf", table: grade2)
        let recordURL = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["brailleTable"] as? String, grade2)
        metadata["brailleTable"] = nil
        record["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL)

        let info = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertNil(info.metadata.brailleTable)
        XCTAssertNil(Book(record: info, filePath: book.filePath, folderPath: "", tmbDirectoryName: book.tmbDirectoryName).brailleTable)
    }

    /// A row whose `brailleTable` cannot be read decodes with none, and keeps
    /// the rest; a row of another book is written without the key.
    func testARowWithAnUnreadableTableDecodesWithNone() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let braille = Book(title: "Braille", format: .braille, filePath: "/tmp/b.brf", md5Hash: "x", brailleTable: grade1)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(braille)) as? [String: Any])
        XCTAssertEqual(row["brailleTable"] as? String, grade1)
        row["brailleTable"] = 17
        let decoded = try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(decoded.brailleTable)
        XCTAssertEqual(decoded.title, "Braille")
        XCTAssertEqual(decoded.format, .braille)

        let plain = Book(title: "Plain", format: .txt, filePath: "/tmp/p.txt", md5Hash: "y")
        let plainRow = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plain)) as? [String: Any])
        XCTAssertNil(plainRow["brailleTable"])
    }

    /// A save of a row that lost its table keeps the stored record's, and a
    /// row's own table wins.
    func testTheStoredRecordsTableSurvivesARowThatLostIt() {
        let book = Book(title: "Braille", format: .braille, filePath: "/tmp/b.brf", md5Hash: "x", brailleTable: grade1)
        let stored = StoredBookRecord(info: book.makeBookInfo(), keepsContentIndex: false)

        var lost = book
        lost.brailleTable = nil
        XCTAssertEqual(lost.bookInfo(replacing: stored, contentIndex: nil).metadata.brailleTable, grade1)
        XCTAssertNil(lost.bookInfo(replacing: nil, contentIndex: nil).metadata.brailleTable)

        var changed = book
        changed.brailleTable = grade2
        XCTAssertEqual(changed.bookInfo(replacing: stored, contentIndex: nil).metadata.brailleTable, grade2)
    }
}
