import XCTest
@testable import TextMouth

/// RTF, RTFD, Word 97-2003, OpenDocument text, and Word 2003 XML documents
/// import as books through textutil (FMT13): each format sample, imported
/// from a copy in a folder of the test's own, opens with its headings and
/// text; refusals say what is wrong in the listener's words and leave
/// nothing behind; and no run of textutil leaves a hidden file anywhere.
final class TextutilImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder the refusal tests import into; each test has its own.
    private let folderPath = "Textutil Import \(UUID().uuidString.prefix(8))"
    /// The folder this test's conversions make their working folders in
    /// (`TextutilDocumentReader.temporaryRoot`), so its scan for leftovers
    /// never meets those of another build's textutil, which the shared
    /// temporary directory would show it. Replaced in set-up.
    private var temporaryRoot = URL(fileURLWithPath: "/var/empty", isDirectory: true)

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        temporaryRoot = try makeSandboxDirectory("TextutilTemporaryRoot")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

    // MARK: - Helpers

    /// What one sample should import as and show.
    private struct Expectation {
        /// The sample's path inside `TestData/format-samples`.
        var sample: String
        /// The name the copy is given, or nil to keep the sample's own.
        var copyName: String?
        var format: BookFormat
        /// The title and author the book is listed under.
        var title: String
        var author: String = Book.unknownAuthor
        /// Every heading the reader shows, as "level: text", in order.
        var headings: [String]
        /// Words that must be in the text, and words that must not.
        var contains: [String] = []
        var excludes: [String] = []
    }

    /// Imports a copy of the sample `expected` names and asserts everything
    /// it says: the format, the title and author, every heading with its
    /// level, and the words present and absent.
    private func assertImports(_ expected: Expectation, file: StaticString = #filePath, line: UInt = #line) throws {
        let copy = try copyOfFormatSample(expected.sample, named: expected.copyName)
        let imported = try importedForTest(copy)
        let book = imported.book
        let label = expected.sample

        XCTAssertEqual(book.format, expected.format, label, file: file, line: line)
        XCTAssertEqual(book.title, expected.title, label, file: file, line: line)
        XCTAssertEqual(book.author, expected.author, label, file: file, line: line)

        let content = try openedContent(of: book)
        XCTAssertEqual(headingLines(of: content), expected.headings, label, file: file, line: line)
        let text = allText(of: content)
        for word in expected.contains {
            XCTAssertTrue(text.contains(word), "\(label) lacks “\(word)”", file: file, line: line)
        }
        for word in expected.excludes {
            XCTAssertFalse(text.contains(word), "\(label) holds “\(word)”", file: file, line: line)
        }
        // A successful import leaves no hidden file of textutil's in its package.
        XCTAssertEqual(textutilFiles(under: book.tmbDirectory), [], label, file: file, line: line)
    }

    /// Whether `name` ends as a hidden file textutil writes does: the HTML
    /// run's, or the plain-text run's for a document's pages
    /// (`TextutilConverter.temporarySuffixes`). The check looked for the
    /// HTML run's alone, so a plain-text file a run left behind went
    /// unseen.
    private func isTextutilTemporary(_ name: String) -> Bool {
        TextutilConverter.temporarySuffixes.contains { name.hasSuffix($0) }
    }

    /// The paths, relative to `folder`, of the hidden files textutil writes
    /// (`TextutilConverter.temporarySuffixes`) anywhere inside it.
    private func textutilFiles(under folder: URL) -> [String] {
        let paths = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return paths.filter(isTextutilTemporary).sorted()
    }

    /// Every textutil leftover in the places a conversion could write: the
    /// import staging folder, and this test's temporary root (the hidden
    /// file, and the folders `TextutilDocumentReader` makes there).
    private func textutilLeftovers() -> Set<String> {
        var found = Set<String>()
        for path in textutilFiles(under: MachineLocalPaths.importStaging) {
            found.insert("staging/\(path)")
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
        where name.hasPrefix("TextMouth-textutil-") || isTextutilTemporary(name) {
            found.insert("temporary/\(name)")
        }
        return found
    }

    /// Runs `body`, its conversions working in this test's temporary root,
    /// and asserts that it left no textutil file in any place a conversion
    /// could write (the leftovers present before are ignored, so a sibling
    /// process's run in the shared staging folder never fails this test).
    private func assertLeavesNoTextutilFiles(
        file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void
    ) throws {
        let before = textutilLeftovers()
        try TextutilDocumentReader.$temporaryRoot.withValue(temporaryRoot) {
            try body()
        }
        XCTAssertEqual(textutilLeftovers().subtracting(before), [], file: file, line: line)
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist. A refused import leaves it empty.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Asserts that importing `url` into this test's library folder fails
    /// with exactly `sentence` (the import's own words, including the file's
    /// name), leaving nothing in the library and no textutil file anywhere.
    private func assertRefused(
        _ url: URL, saying sentence: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try assertLeavesNoTextutilFiles(file: file, line: line) {
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url, toFolder: folderPath), file: file, line: line) {
                XCTAssertEqual($0.localizedDescription, sentence, file: file, line: line)
            }
        }
        XCTAssertEqual((try? folderEntries()) ?? ["unreadable"], [], file: file, line: line)
    }

    /// A file named `name` in a new folder of this test's own, holding `bytes`.
    private func file(named name: String, holding bytes: Data) throws -> URL {
        let url = try makeSandboxDirectory("TextutilImport").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    // MARK: - Samples: Rich Text

    func testRichTextSamplesImportWithTheirHeadings() throws {
        try assertImports(Expectation(
            sample: "rtf/headings.rtf", format: .rtf, title: "headings", author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"],
            contains: ["Bread from the bakery on Rue Ménard", "Departs"]
        ))
        try assertImports(Expectation(
            sample: "rtf/word-styles.rtf", format: .rtf, title: "Word Styles Sample", author: "A. Sample",
            // The paragraph with outline level 3 but no heading style is a heading too.
            headings: [
                "1: Chapter One: The Quay", "2: Morning Tides",
                "3: A paragraph with outline level 3 but no heading style", "3: A third-level heading",
            ],
            contains: ["The last paragraph is plain."]
        ))
        try assertImports(Expectation(
            sample: "rtf/word-list-table.rtf", format: .rtf, title: "List and Table", author: "A. Sample",
            headings: ["1: Shopping and Timetable", "2: Shopping", "2: Timetable"],
            contains: ["Bread from the bakery", "After the table."]
        ))
    }

    func testRichTextWithAttachmentsImportsAndKeepsItsFolder() throws {
        try assertImports(Expectation(
            sample: "rtfd/headings.rtfd", format: .rtfd, title: "headings", author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"],
            contains: ["Bread from the bakery on Rue Ménard"]
        ))
        try assertImports(Expectation(
            sample: "rtfd/with-image.rtfd", format: .rtfd, title: "with-image",
            headings: ["1: The Pier"],
            contains: ["After the picture, the text goes on."],
            excludes: ["Attachment"]
        ))

        // The package holds the .rtfd folder whole, picture and all.
        let book = try importedForTest(try copyOfFormatSample("rtfd/with-image.rtfd")).book
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.bookFileURL.path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        XCTAssertEqual(book.bookFileURL.lastPathComponent, "with-image.rtfd")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: book.bookFileURL.path)),
            Set(try FileManager.default.contentsOfDirectory(atPath: try formatSampleURL("rtfd/with-image.rtfd").path))
        )
    }

    // MARK: - Samples: Word and OpenDocument

    func testWordSamplesImportAsDocWhateverTheirTemplateBit() throws {
        // This test pins textutil's reading of the Word sample, so the sample goes to textutil whatever reads .doc in the app (`OwnDocumentReaders.forcesTextutil`).
        try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            let harbour = ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"]
            for sample in ["doc/headings.doc", "dot/headings-synthetic.dot"] {
                try assertImports(Expectation(
                    sample: sample, format: .doc, title: String(sample.dropFirst(4).dropLast(4)), author: "A. Sample",
                    headings: harbour,
                    contains: ["Bread from the bakery on Rue Ménard", "A newspaper already a day old"],
                    excludes: ["•"]
                ))
            }
            try assertImports(Expectation(
                sample: "dot/libreoffice-tdf120761_zOrder.dot", format: .doc, title: "libreoffice-tdf120761_zOrder",
                headings: [], contains: ["Blah blah blah"]
            ))
            try assertImports(Expectation(
                sample: "doc/libreoffice-tdf104239_chapterNumbering.doc", format: .doc,
                title: "libreoffice-tdf104239_chapterNumbering",
                headings: ["1: Heading 1", "2: Heading 2", "3: Heading 3", "4: Heading 4", "5: Heading 5", "5: Heading 6"]
            ))
            try assertImports(Expectation(
                sample: "doc/libreoffice-tdf81705_outlineLevel.doc", format: .doc,
                title: "libreoffice-tdf81705_outlineLevel", author: "user", headings: ["1: Contents"]
            ))
        }
    }

    /// The author is the document's own (`dc:creator`), which textutil's
    /// reading lost and TextMouth's own reader reads.
    func testOpenDocumentSamplesImportAsODTWhateverTheirTemplateName() throws {
        let harbour = ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"]
        try assertImports(Expectation(
            sample: "odt/handwritten.odt", format: .odt, title: "Harbour Notes", author: "A. Sample", headings: harbour,
            contains: ["Bread from the bakery on Rue Ménard"]
        ))
        try assertImports(Expectation(
            sample: "odt/headings.odt", format: .odt, title: "headings", author: "A. Sample", headings: harbour,
            contains: ["A newspaper already a day old"]
        ))
        try assertImports(Expectation(
            sample: "ott/handwritten.ott", format: .odt, title: "Harbour Notes", author: "A. Sample", headings: harbour
        ))
    }

    /// A WordML file is an .xml file, known by its root element: what the
    /// reader shows for the sample is pinned as it is.
    ///
    /// The sample's "Boat" and "Departs" are bold paragraphs in the file
    /// itself, not cells: textutil's WordML writer flattened the table when
    /// the sample was made, so the heading rule takes them for headings.
    /// A real WordML table is pinned by
    /// `testACellOfAWordMLTableIsNeverAHeading`.
    func testWordMLImportsUnderAnXMLName() throws {
        try assertImports(Expectation(
            sample: "wordml/headings.wordml", copyName: "headings.xml", format: .wordml, title: "headings",
            author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable", "3: Boat", "3: Departs"],
            contains: ["Bread from the bakery on Rue Ménard"], excludes: ["•"]
        ))
    }

    /// A WordML file with a real table (`w:tbl`): its header cells are bold,
    /// as a header row's are, and still never headings. The text of every
    /// cell is read, and only the title above the table is a heading. The
    /// file is made by hand, because the WordML sample has no table.
    func testACellOfAWordMLTableIsNeverAHeading() throws {
        func cell(_ text: String, bold: Bool = false) -> String {
            "<w:tc><w:p><w:r>\(bold ? "<w:rPr><w:b/></w:rPr>" : "")<w:t>\(text)</w:t></w:r></w:p></w:tc>"
        }
        func row(_ cells: String...) -> String { "<w:tr>\(cells.joined())</w:tr>" }
        let wordML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <?mso-application progid="Word.Document"?>
            <w:wordDocument xmlns:w="http://schemas.microsoft.com/office/word/2003/wordml" \
            xmlns:wx="http://schemas.microsoft.com/office/word/2003/auxHint"><w:body><wx:sect>
            <w:p><w:r><w:rPr><w:sz w:val="48"/><w:b/></w:rPr><w:t>Harbour Notes</w:t></w:r></w:p>
            <w:p><w:r><w:t>The ferry leaves at seven, and the cafe tables fill early with people who read the news.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Gulls argue over crusts while the crane operators wave from their cabs above the quay.</w:t></w:r></w:p>
            <w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
            \(row(cell("Boat", bold: true), cell("Departs", bold: true)))
            \(row(cell("Ferry"), cell("07:00")))
            \(row(cell("Launch"), cell("09:30")))
            </w:tbl>
            <w:p><w:r><w:t>Prices are posted by the quay.</w:t></w:r></w:p>
            </wx:sect></w:body></w:wordDocument>
            """
        let folder = try makeSandboxDirectory("WordMLTable")
        let file = folder.appendingPathComponent("table.xml")
        try Data(wordML.utf8).write(to: file)

        let imported = try importedForTest(file)
        XCTAssertEqual(imported.book.format, .wordml)
        let content = try openedContent(of: imported.book)
        XCTAssertEqual(headingLines(of: content), ["1: Harbour Notes"])
        let text = allText(of: content)
        for word in ["Boat", "Departs", "Ferry", "07:00", "Launch", "09:30", "Prices are posted"] {
            XCTAssertTrue(text.contains(word), word)
        }
    }

    /// textutil writes the title and author of some real Word files as NUL
    /// characters: the listener meets the file's name and an unknown author,
    /// or the part of the author that is text, never control characters.
    func testControlCharactersInAWordDocumentsMetadataAreDropped() throws {
        let nulTitle = try copyOfFormatSample("dot/libreoffice-tdf120761_zOrder.dot")
        let none = try TextutilDocumentReader.readMetadata(from: nulTitle, bookFormat: .doc)
        XCTAssertEqual(none.title, "")
        XCTAssertEqual(none.author, "")
        let parsed = try TextutilDocumentReader.parse(url: nulTitle, bookFormat: .doc)
        XCTAssertEqual(parsed.title, "libreoffice-tdf120761_zOrder")
        XCTAssertEqual(parsed.author, Book.unknownAuthor)

        let nulAuthor = try copyOfFormatSample("doc/libreoffice-tdf81705_outlineLevel.doc")
        let user = try TextutilDocumentReader.readMetadata(from: nulAuthor, bookFormat: .doc)
        XCTAssertEqual(user.title, "")
        XCTAssertEqual(user.author, "user")
    }

    /// An RTF file named .doc imports as a .doc and reads as the RTF does.
    func testRTFNamedDocReadsAsRTF() throws {
        try assertImports(Expectation(
            sample: "rtf/headings.rtf", copyName: "notes.doc", format: .doc, title: "notes", author: "A. Sample",
            headings: ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"],
            contains: ["Bread from the bakery on Rue Ménard", "Departs"]
        ))
    }

    // MARK: - A Web Page or WordML Named .doc

    /// Word's "Web Page" format keeps the name .doc, and textutil told
    /// `-format doc` refuses it as damaged. It is read as the web page it is,
    /// by TextMouth's own HTML reader, never by textutil, and the book stays
    /// a .doc: it takes the title and author the page names.
    func testAWebPageNamedDocImportsWithoutTextutil() throws {
        let recorder = TextutilToolRecorder()
        let copy = try copyOfFormatSample("rtf/headings-source.html", named: "page.doc")
        let imported = try TextutilConverter.$tool.withValue(recorder.countingTool()) {
            try importedForTest(copy)
        }
        // No textutil ran: it would have refused the file.
        XCTAssertEqual(recorder.outputs.count, 0)
        XCTAssertEqual(imported.book.format, .doc)
        XCTAssertEqual(imported.book.title, "Harbour Notes")
        XCTAssertEqual(imported.book.author, "A. Sample")

        let content = try openedContent(of: imported.book)
        XCTAssertEqual(headingLines(of: content), ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"])
        XCTAssertTrue(allText(of: content).contains("Bread from the bakery on Rue Ménard"))
    }

    /// The same page named .rtf or .odt is a web page too, and the direct
    /// reader reads it as the cache does.
    func testAWebPageNamedAnyTextutilFormatReadsAsAWebPage() throws {
        let recorder = TextutilToolRecorder()
        try TextutilConverter.$tool.withValue(recorder.countingTool()) {
            for name in ["page.rtf", "page.odt", "page.dot"] {
                let copy = try copyOfFormatSample("rtf/headings-source.html", named: name)
                let format = try XCTUnwrap(BookFormat.detect(from: copy), name)
                let parsed = try TextutilDocumentReader.parse(url: copy, bookFormat: format)
                XCTAssertEqual(parsed.title, "Harbour Notes", name)
                XCTAssertEqual(parsed.author, "A. Sample", name)
                XCTAssertEqual(headingLines(of: parsed), ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"], name)
                let named = try TextutilDocumentReader.readMetadata(from: copy, bookFormat: format)
                XCTAssertEqual(named.title, "Harbour Notes", name)
                XCTAssertEqual(named.author, "A. Sample", name)
            }
        }
        XCTAssertEqual(recorder.outputs.count, 0)
    }

    /// A page past the byte limit is refused before it is read, as a
    /// document is, and a web page with nothing in it is refused as empty.
    func testAWebPageNamedDocIsHeldToTheLimitAndRefusedWhenEmpty() throws {
        let copy = try copyOfFormatSample("rtf/headings-source.html", named: "big.doc")
        try assertLeavesNoTextutilFiles {
            XCTAssertThrowsError(
                try DocumentByteLimit.$current.withValue(100) {
                    try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)
                }
            ) {
                XCTAssertEqual(
                    $0.localizedDescription,
                    "Could not import “big.doc”. Reading its text failed: "
                        + "This document holds more than 100 bytes, the most TextMouth reads from one document."
                )
            }
        }
        XCTAssertEqual(try folderEntries(), [])

        let blank = try file(named: "blank.doc", holding: Data("<html><body> </body></html>".utf8))
        try assertRefused(blank, saying: "Could not import “blank.doc”. Reading its text failed: This file has no text to read.")
    }

    /// A web page named .doc honors `includesPages` as an .html file does: its
    /// page-break element is a page marker when pages are included, and the
    /// page as it was read before pages (no marker, the element's text read)
    /// when they are not, which the launch re-read's compare depends on.
    func testAWebPageNamedDocHonorsIncludesPages() throws {
        let page = "<html><head><title>Harbour</title></head><body><p>One <span role=\"doc-pagebreak\" aria-label=\"12\">12</span>two</p></body></html>"
        let url = try file(named: "page.doc", holding: Data(page.utf8))
        let with = try TextutilDocumentReader.extract(from: url, bookFormat: .doc, includesPages: true).markdown
        XCTAssertTrue(with.contains("<!-- page: 12 -->"), with)
        let without = try TextutilDocumentReader.extract(from: url, bookFormat: .doc, includesPages: false).markdown
        XCTAssertFalse(without.contains("<!--"), without)
        XCTAssertTrue(without.contains("One 12two"), without)
    }

    /// A Word 2003 XML document named .doc is read as WordML, whatever its
    /// name says: it imports as the same text the .xml copy does, and the
    /// book is a .doc.
    func testWordMLNamedDocReadsAsWordML() throws {
        let asXML = try importedForTest(try copyOfFormatSample("wordml/headings.wordml", named: "headings.xml")).book
        let expected = try openedContent(of: asXML)
        XCTAssertFalse(headingLines(of: expected).isEmpty)

        let imported = try importedForTest(try copyOfFormatSample("wordml/headings.wordml", named: "notes.doc"))
        XCTAssertEqual(imported.book.format, .doc)
        XCTAssertEqual(imported.book.title, "notes")
        XCTAssertEqual(imported.book.author, "A. Sample")
        let content = try openedContent(of: imported.book)
        XCTAssertEqual(headingLines(of: content), headingLines(of: expected))
        XCTAssertEqual(allText(of: content), allText(of: expected))
    }

    // MARK: - One Conversion per Import

    /// An import runs textutil once, not twice: the conversion that reads
    /// the text names the title and author, which the book is listed under.
    func testAnImportRunsTextutilOnceAndTakesTheNamesFromIt() throws {
        let cases: [(sample: String, title: String, author: String)] = [
            ("rtf/word-styles.rtf", "Word Styles Sample", "A. Sample"),
            ("odt/handwritten.odt", "Harbour Notes", Book.unknownAuthor),
            // A document that names no title is listed by its file name.
            ("rtf/headings.rtf", "headings", "A. Sample"),
        ]
        for expected in cases {
            let recorder = TextutilToolRecorder()
            let copy = try copyOfFormatSample(expected.sample)
            // The rich text samples are textutil's here, whatever reads them
            // in the app (`OwnDocumentReaders.forcesTextutil`).
            let book = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
                try TextutilConverter.$tool.withValue(recorder.countingTool()) {
                    try importedForTest(copy).book
                }
            }
            // One HTML conversion makes the text and the names; a second run
            // of textutil writes the plain text that holds the page breaks (PG11).
            let htmlRuns = recorder.outputs.filter { $0.lastPathComponent.hasSuffix(TextutilConverter.temporarySuffix) }
            XCTAssertEqual(htmlRuns.count, 1, expected.sample)
            XCTAssertEqual(book.title, expected.title, expected.sample)
            XCTAssertEqual(book.author, expected.author, expected.sample)

            // The record the package keeps holds the same names.
            let record = try BookInfo.load(from: book.tmbDirectory)
            XCTAssertEqual(record.metadata.title, expected.title, expected.sample)
            XCTAssertEqual(record.metadata.author, expected.author, expected.sample)
        }
    }

    /// The launch refresh still reads a textutil book's names (one
    /// conversion); an import's own reading of the metadata reads none.
    func testOnlyTheRefreshReadsTextutilNamesApartFromTheText() throws {
        let copy = try copyOfFormatSample("rtf/word-styles.rtf")
        let refresh = TextutilToolRecorder()
        // The rich text sample is textutil's here (`OwnDocumentReaders.forcesTextutil`).
        let read = OwnDocumentReaders.$forcesTextutil.withValue(true) {
            TextutilDocumentReader.$temporaryRoot.withValue(temporaryRoot) {
                TextutilConverter.$tool.withValue(refresh.countingTool()) {
                    ImportedFileMetadata.read(from: copy, format: .rtf)
                }
            }
        }
        XCTAssertEqual(refresh.outputs.count, 1)
        XCTAssertEqual(read.title, "Word Styles Sample")
        XCTAssertEqual(read.author, "A. Sample")

        let beforeStaging = TextutilToolRecorder()
        let named = TextutilConverter.$tool.withValue(beforeStaging.countingTool()) {
            ImportedFileMetadata.read(from: copy, format: .rtf, readingTextutilNames: false)
        }
        XCTAssertEqual(beforeStaging.outputs.count, 0)
        XCTAssertEqual(named.title, "word-styles")
        XCTAssertEqual(named.author, Book.unknownAuthor)
    }

    // MARK: - An Import's Cancel Stops textutil

    /// What a test's queued import threw, set on the import queue's thread
    /// and read on the test's.
    private let thrown = LockedValue<(any Error)?>(nil)

    /// Queues the import of `url` on `queue`, converting through `tool`, and
    /// returns an expectation fulfilled when the import ends; `thrown` holds
    /// what it threw, if anything.
    private func queueImport(of url: URL, on queue: SerialImportQueue, using tool: TextutilConverter.Tool) -> XCTestExpectation {
        let ended = expectation(description: "the import ended")
        let folderPath = folderPath
        let thrown = thrown
        queue.enqueue {
            do {
                // The stand-in tool is bound here, on the queue's own thread,
                // and so is the rule that sends rich text to textutil, which
                // these tests exercise (`OwnDocumentReaders.forcesTextutil`).
                _ = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
                    try TextutilConverter.$tool.withValue(tool) {
                        try FileImportService.importFileWithReport(from: url, toFolder: folderPath)
                    }
                }
            } catch {
                thrown.value = error
            }
            ended.fulfill()
        }
        return ended
    }

    /// The import queue's Cancel kills the textutil child an import waits
    /// for, within a second or two: the import ends as a cancelled import
    /// does (`ImportCancelled`, no failure), nothing is left in the library
    /// or the staging folder, no child runs, and a conversion made outside
    /// an import afterwards is not stopped. The child is counted as launched
    /// (`WatchedProcess.launchCount`), the count by which the next test
    /// sees that a cancelled import started none.
    func testCancellingTheQueueStopsARunningTextutilAndLeavesNothing() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let recorder = TextutilToolRecorder()
        let queue = SerialImportQueue()
        let childrenBefore = WatchedProcess.runningChildCount
        let launchesBefore = WatchedProcess.launchCount

        try assertLeavesNoTextutilFiles {
            let ended = queueImport(of: copy, on: queue, using: recorder.hangingTool())
            let started = Date().addingTimeInterval(10)
            while WatchedProcess.runningChildCount <= childrenBefore, Date() < started {
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertGreaterThan(WatchedProcess.runningChildCount, childrenBefore, "The child never started")
            XCTAssertGreaterThan(WatchedProcess.launchCount, launchesBefore, "the running child was not counted as launched")

            let cancelledAt = Date()
            queue.cancelEnqueued()
            wait(for: [ended], timeout: 5)
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3)
        }

        XCTAssertTrue(thrown.value is ImportCancelled, "\(String(describing: thrown.value))")
        XCTAssertEqual(WatchedProcess.runningChildCount, childrenBefore)
        XCTAssertEqual(try folderEntries(), [])

        // The cancel was the import's: a reader's conversion is not stopped.
        let named = try TextutilDocumentReader.$temporaryRoot.withValue(temporaryRoot) {
            try TextutilDocumentReader.readMetadata(from: copy, bookFormat: .rtf)
        }
        XCTAssertEqual(named.author, "A. Sample")
    }

    /// An import cancelled while it waits behind another never starts its
    /// child: it ends cancelled as soon as its turn comes. No child is
    /// launched at all (`WatchedProcess.launchCount`): the count of children
    /// running, and the files left, are the same after a child started and
    /// killed at once.
    func testAnImportCancelledWhileItWaitsStartsNoChild() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let recorder = TextutilToolRecorder()
        let queue = SerialImportQueue()
        let childrenBefore = WatchedProcess.runningChildCount
        let launchesBefore = WatchedProcess.launchCount

        // A first import holds the queue until the test lets it go.
        let gate = DispatchSemaphore(value: 0)
        let firstEnded = expectation(description: "the first import ended")
        queue.enqueue {
            gate.wait()
            firstEnded.fulfill()
        }
        let ended = queueImport(of: copy, on: queue, using: recorder.hangingTool())
        queue.cancelEnqueued()
        gate.signal()
        wait(for: [firstEnded, ended], timeout: 5)

        XCTAssertTrue(thrown.value is ImportCancelled, "\(String(describing: thrown.value))")
        XCTAssertEqual(WatchedProcess.runningChildCount, childrenBefore)
        XCTAssertEqual(WatchedProcess.launchCount, launchesBefore, "a cancelled import started textutil")
        XCTAssertEqual(try folderEntries(), [])
    }

    /// A ZIP batch whose book is cancelled mid-conversion stops there, as it
    /// stops between books: the cancelled book is no failure, and the
    /// books before it are kept.
    func testABatchStopsWhereABookWasCancelledMidConversion() throws {
        let files = [URL(fileURLWithPath: "/tmp/one.rtf"), URL(fileURLWithPath: "/tmp/two.rtf"), URL(fileURLWithPath: "/tmp/three.rtf")]
        let result = FileImportService.importSupportedFiles(
            files,
            toFolder: "",
            checksum: { $0.lastPathComponent },
            importer: { url, _, _, _ in
                // The second book is the one the cancel catches.
                if url.lastPathComponent == "two.rtf" { throw ImportCancelled() }
                return ImportedBook(book: Book(title: url.lastPathComponent, format: .rtf, filePath: url.path, md5Hash: url.lastPathComponent))
            }
        )
        XCTAssertEqual(result.books.map(\.title), ["one.rtf"])
        XCTAssertEqual(result.failures.count, 0)
        XCTAssertEqual(result.cancellation, .afterBooks(completed: 1, total: 3))
    }

    /// An import the reader cancelled raises no alert, and one that failed does.
    @MainActor
    func testACancelledImportRaisesNoAlertButAFailedOneDoes() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let model = LibraryViewModel(initializeServices: false)
        let queue = model.importOperationQueue
        // The import fails (or is cancelled) as it begins to copy the file.
        let failure = LockedValue<(any Error)?>(ImportCancelled())
        queue.stepObserver = { step, _ in
            if step == .copying, let error = failure.value { throw error }
        }
        addTeardownBlock { queue.stepObserver = nil }

        /// Waits until the import queued before has ended and the main queue
        /// has run what that import left on it.
        func settle() {
            let settled = expectation(description: "the queue settled")
            model.enqueueImport { DispatchQueue.main.async { settled.fulfill() } }
            wait(for: [settled], timeout: 10)
        }

        model.importSingleFileAsync(from: copy, toFolder: folderPath)
        settle()
        XCTAssertFalse(model.showError)

        failure.value = FileImportError.noTextToRead
        model.importSingleFileAsync(from: copy, toFolder: folderPath)
        settle()
        XCTAssertTrue(model.showError)
        XCTAssertTrue((model.errorMessage ?? "").contains("This file has no text to read."), model.errorMessage ?? "nil")
    }

    // MARK: - Refusals

    /// Every sentence is what the listener hears: the import's own words,
    /// the file's name, the step, then the reason.
    func testRefusalsReadWordForWord() throws {
        // A Word document with the encrypted bit set.
        let word = try copyOfFormatSample("doc/headings.doc")
        let offset = try fibOffset(of: word)
        try setFibFlags(try fibFlags(of: word, at: offset) | 0x0100, of: word, at: offset)
        let password = "This document is protected by a password. Save a copy without the password, then import that copy."
        try assertRefused(word, saying: "Could not import “headings.doc”. Reading its text failed: \(password)")

        // An OpenDocument text file with encryption data in its manifest.
        let open = try copyOfFormatSample("odt/handwritten.odt")
        try replaceManifest(in: open, with: encryptedManifest)
        try assertRefused(open, saying: "Could not import “handwritten.odt”. Reading its text failed: \(password)")

        // Random bytes named .doc.
        let random = try file(named: "random.doc", holding: Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }))
        try assertRefused(random, saying: "Could not import “random.doc”. Reading its text failed: "
            + "This file could not be read as a Word 97-2003 document. It may be damaged, or another kind of file.")

        // Nothing, and only white space.
        let noText = "Reading its text failed: This file has no text to read."
        try assertRefused(try file(named: "empty.rtf", holding: Data()), saying: "Could not import “empty.rtf”. \(noText)")
        try assertRefused(
            try file(named: "blank.rtf", holding: Data(#"{\rtf1\ansi \par \par }"#.utf8)),
            saying: "Could not import “blank.rtf”. \(noText)"
        )
    }

    func testAnRTFPastTheByteLimitIsRefused() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        try assertLeavesNoTextutilFiles {
            XCTAssertThrowsError(
                try DocumentByteLimit.$current.withValue(100) {
                    try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)
                }
            ) {
                XCTAssertEqual(
                    $0.localizedDescription,
                    "Could not import “headings.rtf”. Reading its text failed: "
                        + "This document holds more than 100 bytes, the most TextMouth reads from one document."
                )
            }
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    // MARK: - Where Conversions Work

    /// A conversion outside a staged package (a reader's load, the launch
    /// refresh) works in a new folder of `temporaryRoot`, which a test binds
    /// to a folder of its own, and removes it: the root is empty after.
    func testAConversionOutsideAStagedPackageWorksInTheBoundRoot() throws {
        let copy = try copyOfFormatSample("rtf/headings.rtf")
        let recorder = TextutilToolRecorder()
        // The rich text sample is textutil's here (`OwnDocumentReaders.forcesTextutil`).
        let named = try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            try TextutilDocumentReader.$temporaryRoot.withValue(temporaryRoot) {
                try TextutilConverter.$tool.withValue(recorder.countingTool()) {
                    try TextutilDocumentReader.readMetadata(from: copy, bookFormat: .rtf)
                }
            }
        }
        XCTAssertEqual(named.author, "A. Sample")

        // The hidden file went in one working folder made directly in the root.
        let outputs = recorder.outputs
        XCTAssertEqual(outputs.count, 1)
        let working = try XCTUnwrap(outputs.first).deletingLastPathComponent()
        XCTAssertTrue(working.lastPathComponent.hasPrefix("TextMouth-textutil-"), working.lastPathComponent)
        XCTAssertEqual(
            working.deletingLastPathComponent().resolvingSymlinksInPath().path,
            temporaryRoot.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [])
    }

    // MARK: - Nothing Left Behind

    func testASuccessfulImportLeavesNoTextutilFileAnywhere() throws {
        // This test is about the files textutil leaves, so the samples go to textutil whatever reads them in the app (`OwnDocumentReaders.forcesTextutil`).
        try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            try assertLeavesNoTextutilFiles {
                for sample in ["rtf/headings.rtf", "rtfd/headings.rtfd", "doc/headings.doc", "odt/handwritten.odt"] {
                    _ = try importedForTest(try copyOfFormatSample(sample))
                }
            }
        }
    }

    /// Regenerating the text of an imported RTF and of an imported RTFD
    /// gives the same headings and leaves nothing in the package or the
    /// temporary directory.
    func testRegeneratingTheTextOfRTFAndRTFDLeavesNothing() throws {
        for sample in ["rtf/headings.rtf", "rtfd/headings.rtfd"] {
            let book = try importedForTest(try copyOfFormatSample(sample)).book
            let before = headingLines(of: try openedContent(of: book))
            XCTAssertFalse(before.isEmpty, sample)

            try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: book))
            try assertLeavesNoTextutilFiles {
                let regenerated = try BookContentAnalysisService.load(book: book, regenerateTextCache: true).content
                XCTAssertEqual(headingLines(of: regenerated), before, sample)
            }
            XCTAssertEqual(textutilFiles(under: book.tmbDirectory), [], sample)
            XCTAssertTrue(MarkdownCacheService.cacheExists(for: book), sample)
        }
    }

    // MARK: - The Cases

    func testTheNewFormatsKeepTheirRawValuesAndNames() {
        XCTAssertEqual(BookFormat(rawValue: "rtf"), .rtf)
        XCTAssertEqual(BookFormat(rawValue: "rtfd"), .rtfd)
        XCTAssertEqual(BookFormat(rawValue: "doc"), .doc)
        XCTAssertEqual(BookFormat(rawValue: "odt"), .odt)
        XCTAssertEqual(BookFormat(rawValue: "wordml"), .wordml)

        XCTAssertEqual(BookFormat.rtf.displayName, "Rich Text")
        XCTAssertEqual(BookFormat.rtfd.displayName, "Rich Text with Attachments")
        XCTAssertEqual(BookFormat.doc.displayName, "Word 97-2003 Document")
        XCTAssertEqual(BookFormat.odt.displayName, "OpenDocument Text")
        XCTAssertEqual(BookFormat.wordml.displayName, "Word 2003 XML")

        XCTAssertEqual(BookFormat.doc.fileExtensions, ["doc", "dot"])
        XCTAssertEqual(BookFormat.odt.fileExtensions, ["odt", "ott"])
        XCTAssertEqual(BookFormat.wordml.fileExtensions, [])
    }

    func testABookOfEachNewFormatEncodesAndDecodesWithItsFormat() throws {
        for format in [BookFormat.rtf, .rtfd, .doc, .odt, .wordml] {
            let book = Book(title: "Pier", format: format, filePath: "/tmp/pier", md5Hash: "hash")
            let data = try JSONEncoder().encode(book)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(format.rawValue)\""), format.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(Book.self, from: data).format, format)
        }
    }

    func testEachExtensionIsDetectedAndAnXMLFileIsKnownByItsRoot() throws {
        for (name, format) in [("a.rtf", BookFormat.rtf), ("a.RTFD", .rtfd), ("a.doc", .doc), ("a.dot", .doc),
                               ("a.odt", .odt), ("a.ott", .odt)] {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/\(name)")), format, name)
        }
        XCTAssertEqual(BookFormat.detect(from: try copyOfFormatSample("wordml/headings.wordml", named: "headings.xml")), .wordml)
        XCTAssertEqual(BookFormat.detect(from: try copyOfFormatSample("dtbook/harbour-standalone.xml")), .daisy)
        // WordML under its own name has no extension that says what it is.
        XCTAssertNil(BookFormat.detect(from: try copyOfFormatSample("wordml/headings.wordml")))
    }

    // MARK: - The Checksum of a Folder

    /// An RTFD's checksum is that of its files: stable, changed by a change
    /// in its text, unchanged by a hidden file, and never a thrown error.
    func testAnRTFDChecksumIsStableAndFollowsItsFiles() throws {
        let copy = try copyOfFormatSample("rtfd/with-image.rtfd")
        let first = try FileImportService.importHash(of: copy)
        XCTAssertEqual(try FileImportService.importHash(of: copy), first)
        XCTAssertEqual(first.count, 32)

        // Finder's mark of a visit changes nothing.
        try Data("x".utf8).write(to: copy.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try FileImportService.importHash(of: copy), first)

        // A change in the text does.
        let text = copy.appendingPathComponent("TXT.rtf")
        try (try Data(contentsOf: text) + Data(" ".utf8)).write(to: text)
        XCTAssertNotEqual(try FileImportService.importHash(of: copy), first)
    }

    /// The checksum recorded for an imported RTFD is the one of its file
    /// in the package, which a package import compares.
    func testAnImportedRTFDIsKnownByTheChecksumOfItsFolder() throws {
        let book = try importedForTest(try copyOfFormatSample("rtfd/headings.rtfd")).book
        XCTAssertEqual(try FileImportService.importHash(of: book.bookFileURL), book.md5Hash)
    }

    /// A folder never reaches `FileHandle`, whose legacy read raises an
    /// exception that cannot be caught: every reader of a book's file
    /// refuses or skips one. The one folder that is a book's file, an RTFD,
    /// is measured and digested as a folder instead (`FileStamp`,
    /// `FingerprintHasher.md5`); any other folder is still refused.
    func testNoReaderOfABookFileRaisesOnAFolder() throws {
        let folder = try copyOfFormatSample("rtfd/headings.rtfd")
        XCTAssertThrowsError(try FileImportService.md5Hash(of: folder))
        XCTAssertThrowsError(try ContentFingerprint(of: folder))
        XCTAssertNotNil(FileStamp(of: folder))
        XCTAssertNotNil(FileFingerprint(of: folder, hasher: .md5))
        XCTAssertEqual(try FingerprintHasher.md5.digestOfFile(folder), try FileImportService.importHash(of: folder))

        let other = try copyOfFormatSample("rtfd/headings.rtfd", named: "headings-folder")
        XCTAssertNil(FileStamp(of: other))
        XCTAssertNil(FileFingerprint(of: other, hasher: .md5))
        XCTAssertThrowsError(try FingerprintHasher.md5.digestOfFile(other))
    }

    /// A plain file named .rtfd is hashed as a file, not walked as a folder.
    func testAFileNamedRTFDIsHashedAsAFile() throws {
        let plain = try file(named: "plain.rtfd", holding: Data("not a folder".utf8))
        XCTAssertEqual(try FileImportService.importHash(of: plain), try FileImportService.md5Hash(of: plain))
    }
}

// MARK: - A Stand-In for textutil

/// Stands in for the tool of `TextutilConverter` in a test: it records where
/// each conversion was told to write, then runs real textutil (`countingTool()`)
/// or a child that never ends (`hangingTool()`). Its list is the conversions
/// an operation made.
final class TextutilToolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    /// The hidden output file of each conversion started, in order.
    var outputs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Notes one conversion that will write `output`.
    private func record(_ output: URL) {
        lock.lock()
        recorded.append(output)
        lock.unlock()
    }

    /// Real textutil under its own limits, with each run recorded.
    func countingTool() -> TextutilConverter.Tool {
        let real = TextutilConverter.Tool.textutil
        return TextutilConverter.Tool(
            command: { [self] input, format, output in
                record(output)
                return real.command(input, format, output)
            },
            limits: real.limits,
            residentMemory: real.residentMemory
        )
    }

    /// A child that sleeps for a minute and writes nothing, with each run
    /// recorded: only its being killed ends it early. Its limits are loose,
    /// so the watchdog never ends it within a test.
    func hangingTool() -> TextutilConverter.Tool {
        TextutilConverter.Tool(
            command: { [self] _, _, output in
                record(output)
                return (URL(fileURLWithPath: "/bin/sleep"), ["60"])
            },
            limits: { _ in
                WatchedProcess.Limits(
                    maximumSeconds: 120, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 120, pollInterval: 0.1
                )
            },
            residentMemory: { _ in nil }
        )
    }
}
