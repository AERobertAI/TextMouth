import XCTest
import ZIPFoundation
@testable import TextMouth

/// Every reader takes an entry out of a book's archive through one helper,
/// `ArchiveEntryReader`, which refuses an entry larger than the most
/// TextMouth reads from one file and stops at the first excess chunk of an
/// entry whose recorded size lies (TODO I05). Each reader names such an
/// entry in its own damage sentence. Tests bind small limits, so their
/// fixtures stay a few kilobytes.
final class ArchiveEntryReaderTests: XCTestCase {

    // MARK: - Limits

    /// The documented limits: 256 MB for an audio file and 64 MB for any
    /// other entry, chosen by the entry's extension without regard to case.
    func testStandardLimitsFollowTheEntryKind() {
        let limits = ArchiveEntryLimits.standard

        XCTAssertEqual(limits.audio, 256_000_000)
        XCTAssertEqual(limits.text, 64_000_000)
        XCTAssertEqual(limits.limit(forEntryAt: "Harbor/part1.MP3"), limits.audio)
        XCTAssertEqual(limits.limit(forEntryAt: "audio/track.ogg"), limits.audio)
        XCTAssertEqual(limits.limit(forEntryAt: "OEBPS/ch01.xhtml"), limits.text)
        XCTAssertEqual(limits.limit(forEntryAt: "ncc.html"), limits.text)
        XCTAssertEqual(ArchiveEntryLimits.current, .standard)
    }

    /// Limits a test binds apply only inside the operation that binds them.
    func testBoundLimitsApplyOnlyInsideTheirOperation() {
        let small = ArchiveEntryLimits(audio: 10, text: 5)

        ArchiveEntryLimits.$current.withValue(small) {
            XCTAssertEqual(ArchiveEntryLimits.current, small)
        }
        XCTAssertEqual(ArchiveEntryLimits.current, .standard)
    }

    // MARK: - Reading Into Memory

    /// An entry within its limit reads whole, stored or compressed, with the
    /// checksum of its bytes.
    func testEntryWithinItsLimitReadsWholeWithItsChecksum() throws {
        let text = Data(String(repeating: "Keep the chain clean and lightly oiled. ", count: 200).utf8)
        for method in [CompressionMethod.none, .deflate] {
            let archive = try openArchive(["notes.txt": text], compression: method)
            let entry = try XCTUnwrap(archive["notes.txt"])

            let read = try ArchiveEntryReader.read(entry, in: archive, limit: Int64(text.count))

            XCTAssertEqual(read.data, text, "\(method)")
            XCTAssertEqual(read.checksum, entry.checksum, "\(method)")
        }
    }

    /// An entry that declares more than the limit is refused before any of
    /// it is read, and named with the limit in the sentence every format's
    /// damage report uses.
    func testEntryDeclaringMoreThanTheLimitIsRefused() throws {
        let archive = try openArchive(["Spokes/lacing.xhtml": Data(repeating: 0x41, count: 2_000)])
        let entry = try XCTUnwrap(archive["Spokes/lacing.xhtml"])

        XCTAssertThrowsError(try ArchiveEntryReader.read(entry, in: archive, limit: 1_000)) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastLimit(path: "Spokes/lacing.xhtml", limit: 1_000))
            XCTAssertEqual(
                error.localizedDescription,
                "The file “Spokes/lacing.xhtml” in this archive is damaged or incomplete: it holds more than "
                    + "\(ArchiveFigures.size(1_000)), the most TextMouth reads from one file. "
                    + "Get a fresh copy of the archive, then import it again."
            )
        }
    }

    /// Without a limit given, the reader takes the current limit for the
    /// entry's kind: the audio limit for audio, the text limit otherwise.
    func testDefaultLimitIsTheCurrentOneForTheEntryKind() throws {
        let archive = try openArchive(["track.mp3": Data(count: 300), "page.xhtml": Data(count: 300)])

        try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: 400, text: 200)) {
            let track = try XCTUnwrap(archive["track.mp3"])
            XCTAssertEqual(try ArchiveEntryReader.read(track, in: archive).data.count, 300)
            let page = try XCTUnwrap(archive["page.xhtml"])
            XCTAssertThrowsError(try ArchiveEntryReader.read(page, in: archive)) { error in
                XCTAssertEqual(error as? ArchiveEntryOverflow, .pastLimit(path: "page.xhtml", limit: 200))
            }
        }
    }

    /// An entry whose recorded size lies, tiny on record but large once
    /// inflated, stops at the reader's limit instead of being read whole.
    func testLyingEntryStopsAtTheLimit() throws {
        let archive = try openLyingArchive(member: "flood.xhtml", actualSize: 200_000, recordedSize: 10)
        let entry = try XCTUnwrap(archive["flood.xhtml"])
        XCTAssertEqual(entry.uncompressedSize, 10, "the fixture must lie about its size")

        XCTAssertThrowsError(try ArchiveEntryReader.read(entry, in: archive, limit: 50_000)) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastLimit(path: "flood.xhtml", limit: 50_000))
        }
    }

    /// An import holds an entry to the size the archive records for it: the
    /// lying entry is refused, naming that size, however generous the limit.
    func testImportHoldsAnEntryToItsRecordedSize() throws {
        let archive = try openLyingArchive(member: "flood.xhtml", actualSize: 200_000, recordedSize: 10)
        let entry = try XCTUnwrap(archive["flood.xhtml"])

        XCTAssertThrowsError(try ArchiveEntryReader.read(entry, in: archive, holdingToDeclaredSize: true)) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastDeclaredSize(path: "flood.xhtml", declared: 10))
            XCTAssertEqual(
                error.localizedDescription,
                "The file “flood.xhtml” in this archive is damaged or incomplete: it holds more than the "
                    + "\(ArchiveFigures.size(10)) the archive records for it. "
                    + "Get a fresh copy of the archive, then import it again."
            )
        }
    }

    // MARK: - Streaming

    /// Streaming hands on no byte past the recorded size: the consumer gets
    /// what fits, then the stream stops with the entry named.
    func testStreamHandsOnNothingPastTheRecordedSize() throws {
        let archive = try openLyingArchive(member: "flood.txt", actualSize: 200_000, recordedSize: 20_000)
        let entry = try XCTUnwrap(archive["flood.txt"])
        var received = 0

        XCTAssertThrowsError(try ArchiveEntryReader.stream(entry, in: archive) { received += $0.count }) { error in
            XCTAssertEqual(error as? ArchiveEntryOverflow, .pastDeclaredSize(path: "flood.txt", declared: 20_000))
        }
        XCTAssertGreaterThan(received, 0)
        XCTAssertLessThanOrEqual(received, 20_000)
    }

    /// An honest entry streams whole, with the checksum the archive stores.
    func testStreamOfAnHonestEntryDeliversEveryByte() throws {
        let text = Data(String(repeating: "True the wheel a quarter turn at a time. ", count: 2_000).utf8)
        let archive = try openArchive(["truing.txt": text], compression: .deflate)
        let entry = try XCTUnwrap(archive["truing.txt"])
        var received = Data()

        let checksum = try ArchiveEntryReader.stream(entry, in: archive) { received.append($0) }

        XCTAssertEqual(received, text)
        XCTAssertEqual(checksum, entry.checksum)
    }

    // MARK: - EPUB

    /// An EPUB whose package document holds more than the text limit is
    /// refused, naming the document and the limit in the EPUB damage
    /// sentence, instead of reading it whole.
    func testEPUBPackageDocumentPastTheLimitIsNamedAsDamaged() throws {
        let epub = try makeEPUB(chapterTexts: ["Oil the chain after every wet ride."])
        // The container fits; the larger package document does not.
        let limit = Int64(Data(Self.epubContainer.utf8).count)
        let archive = try Archive(url: epub, accessMode: .read)
        let opf = try XCTUnwrap(archive["OEBPS/content.opf"])
        XCTAssertGreaterThan(Int64(opf.uncompressedSize), limit, "the fixture's package document must pass the limit")

        try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: limit, text: limit)) {
            XCTAssertThrowsError(try EPUBParser.parse(url: epub)) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "The file “OEBPS/content.opf” in this EPUB book is damaged or incomplete: it holds more than "
                        + "\(ArchiveFigures.size(limit)), the most TextMouth reads from one file. "
                        + "Get a fresh copy of the book, then import it again."
                )
            }
        }
    }

    /// A chapter holding more than the text limit is left out and reported
    /// by number and file, while the book's other chapters are read.
    func testEPUBChapterPastTheLimitIsLeftOutWhileTheOthersAreRead() throws {
        let longChapter = String(repeating: "Spokes loosen one by one when the rim is out of true. ", count: 100)
        let epub = try makeEPUB(chapterTexts: [
            "Oil the chain after every wet ride.",
            longChapter,
            "Set each brake pad a coin's width from the rim."
        ])

        let book = try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: 4_000, text: 4_000)) {
            try EPUBParser.prepareBook(url: epub)
        }

        XCTAssertEqual(
            book.report.omissions,
            [ExtractionOmission(chapterNumber: 2, member: "OEBPS/ch2.xhtml", reason: .unreadableMember)]
        )
        XCTAssertEqual(book.chapters.count, 2)
    }

    /// Importing that book fails naming the step, the package document, and
    /// the limit, and leaves nothing in the library folder.
    func testEPUBImportPastTheLimitFailsNamingTheEntry() throws {
        let epub = try makeEPUB(chapterTexts: ["Oil the chain after every wet ride."])
        let limit = Int64(Data(Self.epubContainer.utf8).count)
        let folderPath = "Archive Entry Limits \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: limit, text: limit)) {
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: epub, toFolder: folderPath)) { error in
                XCTAssertEqual(
                    (error as? ImportFailure)?.reason,
                    "Reading its text failed: The file “OEBPS/content.opf” in this EPUB book is damaged or incomplete: "
                        + "it holds more than \(ArchiveFigures.size(limit)), the most TextMouth reads from one file. "
                        + "Get a fresh copy of the book, then import it again."
                )
            }
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [])
    }

    /// The container document every fixture EPUB holds, naming its package
    /// document.
    private static let epubContainer = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    /// An EPUB whose chapters read `chapterTexts`, one file each
    /// ("OEBPS/ch1.xhtml" on), in a file removed when the test ends.
    private func makeEPUB(chapterTexts: [String]) throws -> URL {
        let ids = chapterTexts.indices.map { "ch\($0 + 1)" }
        let manifest = ids.map { "<item id=\"\($0)\" href=\"\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let spine = ids.map { "<itemref idref=\"\($0)\"/>" }.joined()
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data(Self.epubContainer.utf8),
            "OEBPS/content.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>Roadside Repairs</dc:title><dc:creator>Ifeoma Lindqvist</dc:creator><dc:language>en</dc:language>
            </metadata>
            <manifest>\(manifest)</manifest>
            <spine>\(spine)</spine>
            </package>
            """.utf8)
        ]
        for (id, text) in zip(ids, chapterTexts) {
            entries["OEBPS/\(id).xhtml"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(id)</title></head><body><p>\(text)</p></body></html>
            """.utf8)
        }
        return try makeBookFile(named: "Roadside Repairs.epub", entries: entries)
    }

    // MARK: - DOCX

    /// A Word document whose text part holds more than the text limit fails,
    /// naming the part and the limit in the DOCX damage sentence.
    func testDOCXTextPartPastTheLimitIsNamedAsDamaged() throws {
        let paragraph = String(repeating: "Wax the thread before sewing the signatures. ", count: 60)
        let docx = try makeDOCX(paragraphs: ["Binding Notes", paragraph])

        try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: 1_000, text: 1_000)) {
            XCTAssertThrowsError(try DOCXParser.extractMarkdown(from: docx)) { error in
                guard case let .malformedXML(file, _)? = error as? DOCXParserError else {
                    return XCTFail("Expected a damaged part, got \(error)")
                }
                XCTAssertEqual(file, DOCXParser.Part.document)
                XCTAssertEqual(
                    error.localizedDescription,
                    "The file “word/document.xml” in this document is damaged or incomplete: it holds more than "
                        + "\(ArchiveFigures.size(1_000)), the most TextMouth reads from one file. "
                        + "Get a fresh copy of the document, then import it again."
                )
            }
        }
    }

    /// A document within the limit reads as it always has.
    func testDOCXWithinTheLimitStillReads() throws {
        let docx = try makeDOCX(paragraphs: ["Binding Notes", "Wax the thread before sewing the signatures."])

        let markdown = try ArchiveEntryLimits.$current.withValue(ArchiveEntryLimits(audio: 10_000, text: 10_000)) {
            try DOCXParser.extractMarkdown(from: docx)
        }

        XCTAssertTrue(markdown.contains("Wax the thread before sewing the signatures."), markdown)
    }

    /// A Word document holding only its text part, one paragraph per entry
    /// of `paragraphs`, in a file removed when the test ends.
    private func makeDOCX(paragraphs: [String]) throws -> URL {
        let body = paragraphs.map { "<w:p><w:r><w:t>\($0)</w:t></w:r></w:p>" }.joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """
        return try makeBookFile(named: "Binding Notes.docx", entries: [DOCXParser.Part.document: Data(document.utf8)])
    }

    // MARK: - Fixtures

    /// An archive holding `entries`, opened for reading. Its file is removed
    /// when the test ends.
    private func openArchive(_ entries: [String: Data], compression: CompressionMethod = .none) throws -> Archive {
        let url = try makeTemporaryZip(prefix: "ArchiveEntryReaderTests", entries: entries, compressionMethod: compression)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Archive(url: url, accessMode: .read)
    }

    /// An archive holding `member`: `actualSize` bytes that compress to
    /// almost nothing, whose headers record only `recordedSize`, opened for
    /// reading. Its file is removed when the test ends.
    private func openLyingArchive(member: String, actualSize: Int, recordedSize: UInt32) throws -> Archive {
        let url = try makeTemporaryZip(
            prefix: "ArchiveEntryReaderLie",
            entries: [member: Data(repeating: 0x61, count: actualSize)],
            compressionMethod: .deflate
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try setRecordedSize(of: member, in: url, to: recordedSize)
        return try Archive(url: url, accessMode: .read)
    }

    /// A book file named `name` holding `entries`, in a folder of its own
    /// that is removed when the test ends.
    private func makeBookFile(named name: String, entries: [String: Data]) throws -> URL {
        let zip = try makeTemporaryZip(prefix: "ArchiveEntryReaderBook", entries: entries)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveEntryReaderBook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let book = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: zip, to: book)
        return book
    }
}
