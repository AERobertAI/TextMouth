import XCTest
import ZIPFoundation
@testable import TextMouth

/// EPUBs broken before any chapter can be found (audit U17): no container,
/// a container naming no package document, a package document that is
/// missing or is not XML, a reading order with nothing in it, and one that
/// names only items the manifest does not list. They are untrusted input,
/// which must fail by name: the direct reader throws the error it throws
/// today, and an import fails while reading the book's text with that
/// error's sentence, leaving no package, adding no row, and keeping the
/// original as it was (`assertImportRefused`).
///
/// These tests pin today's behavior and wording; EPUBParser is not changed
/// here. Where a sentence seems wrong, a comment names the doubt, which was
/// reported to the bughunt team against EPUBParser.swift.
final class EPUBStructureFailureTests: XCTestCase {

    // MARK: - The Container

    /// An EPUB without META-INF/container.xml says that file is missing.
    @MainActor
    func testAnEPUBWithoutItsContainerSaysTheContainerIsMissing() throws {
        let epub = try makeEPUB(container: nil, packageDocument: Self.packageDocument())

        try assertRefused(epub, throwing: .missingContainer, saying: "The EPUB is missing META-INF/container.xml.")
    }

    /// A container that names no rootfile says the package document is
    /// missing.
    @MainActor
    func testAContainerWithoutARootfileSaysThePackageDocumentIsMissing() throws {
        let epub = try makeEPUB(container: Self.container(rootfiles: ""), packageDocument: Self.packageDocument())

        try assertRefused(epub, throwing: .missingOPF, saying: Self.missingPackageDocument)
    }

    /// A rootfile without its `full-path` attribute names no package
    /// document, which is reported as missing too.
    @MainActor
    func testARootfileWithoutItsPathSaysThePackageDocumentIsMissing() throws {
        let rootfile = #"<rootfile media-type="application/oebps-package+xml"/>"#
        let epub = try makeEPUB(container: Self.container(rootfiles: rootfile), packageDocument: Self.packageDocument())

        try assertRefused(epub, throwing: .missingOPF, saying: Self.missingPackageDocument)
    }

    // MARK: - The Package Document

    /// A rootfile naming a package document the archive does not hold is
    /// reported as a package document that could not be parsed.
    @MainActor
    func testARootfileNamingAMissingPackageDocumentSaysItCouldNotBeParsed() throws {
        let epub = try makeEPUB(container: Self.container(), packageDocument: nil)

        // Doubtful, pinned as today: the document is missing, not unparsable (posted to bughunt-lead).
        try assertRefused(epub, throwing: .invalidOPF, saying: "The EPUB package document could not be parsed.")
    }

    /// A package document that is not XML fails with the sentence of
    /// Foundation's XML reader, which the parser passes on as it is.
    @MainActor
    func testAPackageDocumentThatIsNotXMLGivesTheXMLReadersSentence() throws {
        let epub = try makeEPUB(container: Self.container(), packageDocument: "This is not a package document.")

        // Doubtful, pinned as today: libxml2's words name no file and end in a line break (posted to bughunt-lead).
        try assertRefused(
            epub,
            throwing: .foreign(domain: "NSXMLParserErrorDomain", code: 4),
            saying: "Line 1: Document is empty\n"
        )
    }

    // MARK: - A Start Tag Too Long to Parse

    /// A start tag over 64 KB (`XMLInputGuard.longestStartTag`, 21 times the
    /// longest of 264 parts of 25 real DOCX and EPUB files) in the container
    /// or the package document is refused as damage, naming the file, before
    /// the XML reader sees it: 200,000 attributes in one tag cost the reader
    /// seconds, and a hostile book could stall an import with them. The bound
    /// of five seconds is far above the refusal and below the reader's cost.
    @MainActor
    func testAStartTagTooLongToParseIsRefusedAsDamageNamingTheFile() throws {
        let many = (0..<200_000).map { "a\($0)=\"\"" }.joined(separator: " ")
        let hostileContainer = Self.container().replacingOccurrences(of: "<rootfiles>", with: "<rootfiles \(many)>")
        let hostilePackage = Self.packageDocument().replacingOccurrences(of: "<manifest>", with: "<manifest \(many)>")
        let cases: [(file: String, container: String, package: String)] = [
            ("META-INF/container.xml", hostileContainer, Self.packageDocument()),
            ("OEBPS/content.opf", Self.container(), hostilePackage),
        ]
        for testCase in cases {
            let epub = try makeEPUB(container: testCase.container, packageDocument: testCase.package)
            let clock = ContinuousClock()
            let start = clock.now
            try assertRefused(
                epub,
                throwing: .otherEPUBError(String(describing: EPUBParserError.damagedFile(
                    file: testCase.file, reason: XMLInputGuard.longStartTagProblem))),
                saying: "The file “\(testCase.file)” in this EPUB book is damaged or incomplete: "
                    + "it has a start tag longer than 64 KB, which no real file has. "
                    + "Get a fresh copy of the book, then import it again.")
            XCTAssertLessThan(clock.now - start, .seconds(5), "\(testCase.file) took too long")
        }
    }

    // MARK: - The Reading Order

    /// A package document whose spine names nothing says the book has no
    /// reading order.
    @MainActor
    func testAnEmptySpineSaysTheBookHasNoReadingOrder() throws {
        let epub = try makeEPUB(container: Self.container(), packageDocument: Self.packageDocument(spine: ""))

        try assertRefused(epub, throwing: .missingSpine, saying: "The EPUB has no reading order (spine).")
    }

    /// A spine whose every itemref names an item the manifest does not list
    /// has no chapter to read, and the sentence names each chapter left out
    /// by the name the spine gives it.
    @MainActor
    func testItemrefsNamingNoManifestItemNameEveryChapterLeftOut() throws {
        let spine = #"<itemref idref="appendix"/><itemref idref="glossary"/>"#
        let epub = try makeEPUB(container: Self.container(), packageDocument: Self.packageDocument(spine: spine))
        let report = ExtractionReport(
            container: EPUBParser.bookNameInMessages,
            chapterCount: 2,
            omissions: [
                ExtractionOmission(chapterNumber: 1, member: "appendix", reason: .unlistedItem),
                ExtractionOmission(chapterNumber: 2, member: "glossary", reason: .unlistedItem)
            ]
        )

        try assertRefused(
            epub,
            throwing: .noReadableChapters(report),
            saying: "None of the 2 chapters could be read: chapter 1 (“appendix”) has no file listed in this EPUB book; "
                + "chapter 2 (“glossary”) has no file listed in this EPUB book. "
                + "Get a fresh copy of the book, then import it again."
        )
    }

    // MARK: - Assertions

    /// The sentence `missingOPF` gives.
    private static let missingPackageDocument = "The EPUB is missing its package document (OPF file)."

    /// The error a reader threw, reduced to what these tests compare: the
    /// `EPUBParserError` case, with the report `noReadableChapters` carries,
    /// or the domain and code of an error from outside the parser.
    private enum Thrown: Equatable {
        case missingContainer
        case missingOPF
        case invalidOPF
        case missingSpine
        case noReadableChapters(ExtractionReport)
        /// Another `EPUBParserError` case, as the error describes itself.
        case otherEPUBError(String)
        /// An error from outside the parser, such as Foundation's XML reader.
        case foreign(domain: String, code: Int)

        /// What `error` is, in these terms.
        init(_ error: Error) {
            guard let epubError = error as? EPUBParserError else {
                let nsError = error as NSError
                self = .foreign(domain: nsError.domain, code: nsError.code)
                return
            }
            switch epubError {
            case .missingContainer: self = .missingContainer
            case .missingOPF: self = .missingOPF
            case .invalidOPF: self = .invalidOPF
            case .missingSpine: self = .missingSpine
            case .noReadableChapters(let report): self = .noReadableChapters(report)
            default: self = .otherEPUBError(String(describing: epubError))
            }
        }
    }

    /// Asserts that `epub` is refused by name: the direct reader throws
    /// `expected`, whose sentence is `sentence`, and an import fails with
    /// that sentence and leaves everything as it was.
    @MainActor
    private func assertRefused(
        _ epub: URL,
        throwing expected: Thrown,
        saying sentence: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(try EPUBParser.parse(url: epub), file: file, line: line) { error in
            XCTAssertEqual(Thrown(error), expected, file: file, line: line)
            XCTAssertEqual(error.localizedDescription, sentence, file: file, line: line)
        }
        try assertImportRefused(epub, saying: sentence, file: file, line: line)
    }

    // MARK: - Fixtures

    /// A container document holding `rootfiles`, by default the one that
    /// names the package document at OEBPS/content.opf, as the container
    /// `ArchiveEntryReaderTests` builds its EPUBs with.
    private static func container(
        rootfiles: String = #"<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>"#
    ) -> String {
        """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>\(rootfiles)</rootfiles>
        </container>
        """
    }

    /// A package document whose manifest lists the one chapter and whose
    /// spine holds `spine`, by default an itemref naming that chapter.
    private static func packageDocument(spine: String = #"<itemref idref="ch1"/>"#) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="id">urn:uuid:5e0b7c1a-93d2-4f68-b0a4-2c7d91e3f856</dc:identifier>
        <dc:title>Rope and Splice</dc:title><dc:creator>Folasade Brandvold</dc:creator><dc:language>en</dc:language>
        </metadata>
        <manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine>\(spine)</spine>
        </package>
        """
    }

    /// The book's one chapter, which a book broken before its reading order
    /// never reaches.
    private static let chapter = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Splicing</title></head>
    <body><h1>Splicing</h1><p>Unlay the strands a hand's width before tucking the first one.</p></body></html>
    """

    /// "Rope and Splice.epub" in a sandbox folder of its own: the mimetype,
    /// then `container` at META-INF/container.xml and `packageDocument` at
    /// OEBPS/content.opf (each left out when nil), then the chapter, stored
    /// in that order with `TestZIPEntry`.
    private func makeEPUB(container: String?, packageDocument: String?) throws -> URL {
        var entries = [TestZIPEntry("mimetype", Data("application/epub+zip".utf8))]
        if let container {
            entries.append(TestZIPEntry("META-INF/container.xml", Data(container.utf8)))
        }
        if let packageDocument {
            entries.append(TestZIPEntry("OEBPS/content.opf", Data(packageDocument.utf8)))
        }
        entries.append(TestZIPEntry("OEBPS/ch1.xhtml", Data(Self.chapter.utf8)))
        let zip = try makeTemporaryZip(prefix: "EPUBStructureFailure", orderedEntries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }
        let epub = try makeSandboxDirectory("EPUBStructureFailure").appendingPathComponent("Rope and Splice.epub")
        try FileManager.default.moveItem(at: zip, to: epub)
        return epub
    }
}
