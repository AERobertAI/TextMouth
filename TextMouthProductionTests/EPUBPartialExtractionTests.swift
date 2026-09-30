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
