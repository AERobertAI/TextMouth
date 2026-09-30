import XCTest
import ZIPFoundation
@testable import TextMouth

/// EPUB files that cannot be read in full: a damaged file is named, and the
/// book's damage is never mistaken for its content.
final class EPUBPartialExtractionTests: XCTestCase {

    // MARK: - Damaged Package Files

    /// A package document whose bytes no longer match their checksum is
    /// named as damaged rather than read as though it were intact.
    func testPackageDocumentFailingItsChecksumIsNamedAsDamaged() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try damageData(of: "OEBPS/content.opf", in: epub)

        XCTAssertThrowsError(try EPUBParser.parse(url: epub)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The file “OEBPS/content.opf” in this EPUB book is damaged or incomplete: "
                    + "its contents do not match the checksum stored with them. "
                    + "Get a fresh copy of the book, then import it again."
            )
        }
    }

    /// A package document whose compressed data cannot be decoded is named
    /// the same way, instead of surfacing the ZIP library's own error.
    func testPackageDocumentThatCannotBeDecompressedIsNamedAsDamaged() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters, compression: .deflate)
        try damageData(of: "OEBPS/content.opf", in: epub)

        XCTAssertThrowsError(try EPUBParser.parse(url: epub)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The file “OEBPS/content.opf” in this EPUB book is damaged or incomplete: "
                    + "its compressed data could not be decoded. "
                    + "Get a fresh copy of the book, then import it again."
            )
        }
    }

    /// Checksums are compared for real books, not only for fixtures: every
    /// file in the bundled EPUB, stored or compressed, passes.
    func testBundledEPUBPassesEveryChecksum() throws {
        let archive = try Archive(url: try requireFile("alice.epub"), accessMode: .read)
        var checked = 0
        for entry in archive where entry.type == .file {
            XCTAssertNoThrow(try EPUBParser.text(of: entry, in: archive), entry.path)
            checked += 1
        }
        XCTAssertEqual(checked, 22)
    }

    // MARK: - Chapters Left Out

    /// The acceptance case: a chapter deleted from the archive is named by
    /// its number and path, and the chapters on either side are still read,
    /// by the cache's preparation and by the direct reader alike.
    func testMissingMiddleChapterIsReportedAndTheOthersAreRead() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Adjusting the Brakes"])
        XCTAssertEqual(book.report.chapterCount, 3)
        XCTAssertEqual(book.report.blankChapterCount, 0)
        XCTAssertEqual(
            book.report.omissions,
            [ExtractionOmission(chapterNumber: 2, member: "OEBPS/ch02.xhtml", reason: .missingMember)]
        )
        XCTAssertEqual(
            book.report.message,
            "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book."
        )
        XCTAssertEqual(
            try EPUBParser.parse(url: epub).chapters.map(\.title),
            ["Patching a Tube", "Adjusting the Brakes"]
        )
    }

    /// A chapter whose compressed data cannot be decoded is reported as
    /// damaged, and the rest of the book is still read.
    func testUndecodableChapterIsReportedAsDamaged() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters, compression: .deflate)
        try damageData(of: "OEBPS/ch02.xhtml", in: epub)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Adjusting the Brakes"])
        XCTAssertEqual(
            book.report.omissions,
            [ExtractionOmission(chapterNumber: 2, member: "OEBPS/ch02.xhtml", reason: .unreadableMember)]
        )
        XCTAssertEqual(
            book.report.message,
            "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is damaged or incomplete."
        )
    }

    /// A stored chapter whose bytes no longer match its checksum is left out
    /// and reported, where it used to be read as garbled text.
    func testChapterFailingItsChecksumIsReportedRatherThanGarbled() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try damageData(of: "OEBPS/ch02.xhtml", in: epub)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Adjusting the Brakes"])
        XCTAssertEqual(book.report.omissions.map(\.reason), [.unreadableMember])
    }

    /// A cover page without text is blank, not damaged: it is counted apart
    /// and never reported, and the book is complete.
    func testBlankCoverPageIsNotAnOmission() throws {
        let epub = try makeEPUB(chapters: [Self.blankPage("cover")] + Self.threeChapters)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.report.chapterCount, 4)
        XCTAssertEqual(book.report.blankChapterCount, 1)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Truing a Wheel", "Adjusting the Brakes"])
    }

    /// A complete book has nothing to report and reads every chapter.
    func testCompleteBookHasAnEmptyReport() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.report, ExtractionReport(container: "this EPUB book", chapterCount: 3))
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertTrue(book.chapters[1].chapter.text.contains("Tighten the spoke opposite the wobble"))
    }

    /// The bundled book, a real EPUB, is complete: its fifteen spine
    /// documents are all counted and none is reported missing or damaged.
    func testBundledEPUBReportsNothingLeftOut() throws {
        let book = try EPUBParser.prepareBook(url: try requireFile("alice.epub"))

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.report.chapterCount, 15)
    }

    /// A spine entry naming an item the manifest does not list is reported
    /// by the name the spine gives it.
    func testSpineEntryWithoutAManifestItemIsReported() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters, spine: ["ch01", "ch02", "appendix", "ch03"])

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(
            book.report.message,
            "1 of 4 chapters could not be read: chapter 3 (“appendix”) has no file listed in this EPUB book."
        )
    }

    /// An image in the reading order is a resource, not a chapter: it is not
    /// counted and not reported.
    func testImageInTheSpineIsNotAChapter() throws {
        let plate = FixtureChapter(id: "plate", href: "plate.jpg", markup: "JPEG bytes", mediaType: "image/jpeg")
        let epub = try makeEPUB(chapters: Self.threeChapters + [plate], spine: ["ch01", "plate", "ch02", "ch03"])

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.report.chapterCount, 3)
        XCTAssertEqual(book.chapters.count, 3)
    }

    /// With no chapter readable there is no book to open: both readers
    /// throw an error that names every chapter and says what to do.
    func testBookWithNoReadableChapterNamesEveryChapter() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        for chapter in Self.threeChapters {
            try removeMember(chapter.member, from: epub)
        }
        let expected = "None of the 3 chapters could be read: "
            + "chapter 1 (“OEBPS/ch01.xhtml”) is missing from this EPUB book; "
            + "chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book; "
            + "chapter 3 (“OEBPS/ch03.xhtml”) is missing from this EPUB book. "
            + "Get a fresh copy of the book, then import it again."

        let readers: [() throws -> Void] = [
            { _ = try EPUBParser.prepareBook(url: epub) },
            { _ = try EPUBParser.parse(url: epub) }
        ]
        for read in readers {
            XCTAssertThrowsError(try read()) { error in
                XCTAssertEqual(error.localizedDescription, expected)
                XCTAssertEqual(Self.unreadableReport(error)?.omissions.count, 3)
            }
        }
    }

    /// Missing and blank chapters together leave nothing to read, and the
    /// error accounts for the blank ones as well.
    func testMissingAndBlankChaptersTogetherLeaveNothingToRead() throws {
        let chapters = [Self.blankPage("front"), Self.threeChapters[1], Self.blankPage("back")]
        let epub = try makeEPUB(chapters: chapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        XCTAssertThrowsError(try EPUBParser.prepareBook(url: epub)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book. "
                    + "The other 2 chapters have no text. Get a fresh copy of the book, then import it again."
            )
        }
    }

    /// A book of blank pages has nothing damaged to replace; it simply has
    /// no text, and says so.
    func testBookOfBlankPagesHasNoTextToRead() throws {
        let epub = try makeEPUB(chapters: [Self.blankPage("front"), Self.blankPage("back")])

        XCTAssertThrowsError(try EPUBParser.parse(url: epub)) { error in
            XCTAssertEqual(error.localizedDescription, "This EPUB book has no text to read.")
            XCTAssertEqual(Self.unreadableReport(error)?.blankChapterCount, 2)
        }
    }

    // MARK: - Cache Generation

    /// The cache holds the chapters that could be read, and one line in the
    /// debug log names the book and what is missing from it.
    func testCacheKeepsTheReadableChaptersAndLogsTheReportOnce() throws {
        let title = Self.uniqueTitle()
        let epub = try makeEPUB(title: title, chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        let book = try importForTest(epub)

        let cached = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(cached.chapters.map(\.title), ["Patching a Tube", "Adjusting the Brakes"])
        let lines = debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): ")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasSuffix(
            "EPUB_INCOMPLETE_CONTENT: \(title): "
                + "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book."
        ) == true, "\(lines)")
    }

    /// A cache rebuild still succeeds for a book with a chapter missing: the
    /// generated content carries the report, the rebuild path gets its index,
    /// and each generation logs the omission again rather than alerting.
    func testCacheRebuildCarriesTheReportAndStillSucceeds() throws {
        let title = Self.uniqueTitle()
        let epub = try makeEPUB(title: title, chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)
        var book = try importForTest(epub)

        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &book))
        let rebuiltIndex = MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book)

        XCTAssertEqual(generated.content.chapters.count, 2)
        XCTAssertEqual(generated.report.omissions.map(\.chapterNumber), [2])
        // Indexes carry their generation time, so compare what they describe.
        XCTAssertEqual(rebuiltIndex?.chapters, generated.content.contentIndex.chapters)
        XCTAssertEqual(rebuiltIndex?.chapters.count, 2)
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): ").count, 3)
    }

    /// A rebuild that finds no readable chapter fails without touching the
    /// cache an earlier generation wrote, so a book that was readable stays
    /// readable, and its version stays unstamped for a later retry.
    func testRebuildFindingNoReadableChapterKeepsTheEarlierCache() throws {
        let title = Self.uniqueTitle()
        var book = try importForTest(try makeEPUB(title: title, chapters: Self.threeChapters))
        let cachePath = TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)
        let earlierCache = try String(contentsOf: cachePath, encoding: .utf8)
        book.cacheFormatVersion = "3.0.0"
        // The package's own copy of the book then loses every chapter.
        for chapter in Self.threeChapters {
            try removeMember(chapter.member, from: URL(fileURLWithPath: book.filePath))
        }

        XCTAssertNil(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))

        XCTAssertEqual(try String(contentsOf: cachePath, encoding: .utf8), earlierCache)
        XCTAssertEqual(book.cacheFormatVersion, "3.0.0")
        let lines = debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): None of the 3 chapters could be read: ")
        XCTAssertEqual(lines.count, 1, "\(lines)")
    }

    /// Formats that do not report omissions yet generate an empty report.
    func testFormatsThatDoNotReportGenerateAnEmptyReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Notes.md")
        try Data("# Spokes\n\nCount them twice.".utf8).write(to: source)
        let book = try importForTest(source)

        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: book))

        XCTAssertEqual(generated.report, ExtractionReport())
        XCTAssertEqual(generated.content.chapters.count, 1)
    }

    // MARK: - Fixture Books

    /// One document in a fixture EPUB, which the package lists in its
    /// manifest under `id` and stores at "OEBPS/" + `href`.
    private struct FixtureChapter {
        var id: String
        var href: String
        var markup: String
        var mediaType = "application/xhtml+xml"

        /// The document's path inside the archive.
        var member: String { "OEBPS/\(href)" }
    }

    /// A short repair manual, one chapter per file, each with its own words
    /// so a test can tell which chapters were read.
    private static let threeChapters = [
        chapter(1, "Patching a Tube", "Roughen the rubber around the puncture before the glue goes on."),
        chapter(2, "Truing a Wheel", "Tighten the spoke opposite the wobble by a quarter turn."),
        chapter(3, "Adjusting the Brakes", "Set each pad a coin's width from the rim.")
    ]

    /// Chapter `number` of the fixture manual, titled `heading`, reading `text`.
    private static func chapter(_ number: Int, _ heading: String, _ text: String) -> FixtureChapter {
        let id = String(format: "ch%02d", number)
        return FixtureChapter(id: id, href: "\(id).xhtml", markup: page("<h1>\(heading)</h1><p>\(text)</p>"))
    }

    /// A page with no text, such as a cover whose image its stylesheet sets.
    private static func blankPage(_ id: String) -> FixtureChapter {
        FixtureChapter(id: id, href: "\(id).xhtml", markup: page("<div class=\"cover\"></div>"))
    }

    /// The report carried by a `noReadableChapters` error, or nil for any
    /// other error.
    private static func unreadableReport(_ error: Error) -> ExtractionReport? {
        guard case .noReadableChapters(let report)? = error as? EPUBParserError else { return nil }
        return report
    }

    /// An XHTML document whose body is `body`.
    private static func page(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Roadside Repairs</title></head>
        <body>\(body)</body></html>
        """
    }

    /// A title no other test uses, so this test's log lines can be found.
    private static func uniqueTitle() -> String {
        "Roadside Repairs \(UUID().uuidString.prefix(8))"
    }

    /// Write an EPUB titled `title` (by default a unique title) that lists
    /// `chapters` in its manifest and reads `spine` (manifest ids, by default
    /// every chapter in order), to "book.epub" in a new temporary directory
    /// that is removed when the test ends. `compression` says how the archive
    /// stores its files.
    private func makeEPUB(
        title: String? = nil,
        chapters: [FixtureChapter],
        spine: [String]? = nil,
        compression: CompressionMethod = .none
    ) throws -> URL {
        let title = title ?? Self.uniqueTitle()
        let manifest = chapters.map {
            "<item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"\($0.mediaType)\"/>"
        }.joined()
        let itemRefs = (spine ?? chapters.map(\.id)).map { "<itemref idref=\"\($0)\"/>" }.joined()
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OEBPS/content.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(title)</dc:title><dc:creator>Adaeze Kowalczyk</dc:creator><dc:language>en</dc:language>
            </metadata>
            <manifest>\(manifest)</manifest>
            <spine>\(itemRefs)</spine>
            </package>
            """.utf8)
        ]
        for chapter in chapters {
            entries[chapter.member] = Data(chapter.markup.utf8)
        }

        let zip = try makeTemporaryZip(prefix: "TextMouthEPUBTest", entries: entries, compressionMethod: compression)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let epub = directory.appendingPathComponent("book.epub")
        try FileManager.default.moveItem(at: zip, to: epub)
        return epub
    }

    /// Import `source` through the production path into the hosted tests'
    /// isolated library, removing its package when the test ends.
    private func importForTest(_ source: URL) throws -> Book {
        let book = try FileImportService.importFile(from: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        return book
    }

    /// Delete `member` from the ZIP at `url`, as a copy of a book can lack
    /// one of its files.
    private func removeMember(_ member: String, from url: URL) throws {
        let archive = try Archive(url: url, accessMode: .update)
        let entry = try XCTUnwrap(archive[member], "No member named \(member)")
        try archive.remove(entry)
    }

    /// Overwrite the first bytes of `member`'s data in the ZIP at `url` with
    /// 0xFF, as a failing disk or an interrupted copy can: compressed data
    /// then cannot be decoded, and stored data no longer matches its checksum.
    private func damageData(of member: String, in url: URL, byteCount: Int = 8) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        let start = try XCTUnwrap(Self.dataOffset(of: member, in: bytes), "No local file header names \(member)")
        bytes.replaceSubrange(start..<start + byteCount, with: repeatElement(0xFF, count: byteCount))
        try Data(bytes).write(to: url)
    }

    /// Where `member`'s data starts in the ZIP `bytes`: just past its local
    /// file header, which is the signature "PK\3\4", 26 bytes of fields
    /// (the name's length at offset 26, the extra field's at 28), the name,
    /// and the extra field. ZIPFoundation keeps this offset internal.
    private static func dataOffset(of member: String, in bytes: [UInt8]) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let name = Array(member.utf8)
        /// The little-endian 16-bit field at `offset` in the header at `header`.
        func field(_ header: Int, _ offset: Int) -> Int {
            Int(bytes[header + offset]) | Int(bytes[header + offset + 1]) << 8
        }
        for header in 0..<max(0, bytes.count - 30) where bytes[header..<header + 4].elementsEqual(signature) {
            let nameStart = header + 30
            let nameEnd = nameStart + field(header, 26)
            guard nameEnd <= bytes.count, bytes[nameStart..<nameEnd].elementsEqual(name) else { continue }
            return nameEnd + field(header, 28)
        }
        return nil
    }
}
