import SwiftSoup
import XCTest
import ZIPFoundation
@testable import TextMouth

/// SwiftSoup builds the same trees, whichever copy of it the app links.
///
/// TextMouth links a copy of SwiftSoup 2.13.9 kept in `Vendor/SwiftSoup`,
/// written from the release by `Scripts/vendor/swiftsoup/` with only
/// attributes changed. This test is the proof that the copy reads markup as
/// the release does, and the check to repeat when SwiftSoup is upgraded.
///
/// - **The corpus.** Every markup document in `TestData` (loose `.html`,
///   `.htm`, `.xhtml`, and `.xml` files, and those members of every ZIP
///   container, such as EPUBs, DAISY books, DOCX, and ODT) and, for each
///   document of at most `largestDamagedDocument` bytes,
///   `damagedCopiesPerDocument` damaged copies (a range deleted, a range
///   repeated, a piece of troublesome markup inserted), damaged the same
///   way on every run by a generator seeded from the document's name.
/// - **What is parsed.** Each document three ways, as the app parses
///   markup: the HTML parser, the XML parser through `MarkupGuard.parseXML`,
///   and a body fragment through `MarkupGuard.parseBodyFragment`.
/// - **What is compared.** One checksum for each parse (`SoupCorpusKit.summary`)
///   covering the whole tree, `text()`, `outerHtml()`, and `title()`, against
///   `TestData/soup-corpus/manifest.tsv`, recorded from the released SwiftSoup
///   package. A document the manifest does not name is not compared (a
///   checkout can hold more of TestData than another), but too few found fails
///   the test. It holds records for damaged copies of documents up to
///   `largestRecordedDamagedDocument` bytes; a run compares those up to
///   `largestDamagedDocument`.
///
/// A difference names the documents and the parse that differ. If a change to
/// SwiftSoup is meant (an upgrade), record the manifest again with
/// `TEXTMOUTH_RECORD_SOUP_MANIFEST=1` on the test run, from a checkout whose
/// TestData holds only the repository's own files, and review the diff.
final class SwiftSoupCorpusTests: XCTestCase {

    // MARK: - Size

    /// How many damaged copies each document of the corpus gets.
    static let damagedCopiesPerDocument = 3

    /// The largest document that is damaged in a run that compares, in bytes.
    /// Three damages to a small document reach its tree builder's recovery
    /// paths as often as three to a large one, and cost a fraction of the
    /// time: with 10,000, the class runs in about 40 seconds on GitHub's
    /// runner (69 seconds at 60,000, November 14, 2026).
    static let largestDamagedDocument = 10_000

    /// The largest document damaged when the manifest is recorded: it holds a
    /// record for every damaged copy up to this size, so the limit above can
    /// be raised without recording again, and a comparison uses the records
    /// it needs. (A damaged copy is the same whichever limit is in force.)
    static let largestRecordedDamagedDocument = 60_000

    /// The largest ZIP entry, or file, taken into the corpus, in bytes.
    static let largestDocument = 8 * 1024 * 1024

    /// The extensions of the markup documents, in lower case.
    static let markupExtensions: Set<String> = ["html", "htm", "xhtml", "xml", "ncx", "opf", "smil"]

    /// Fewer than this share of the inputs found in the manifest fails the
    /// test, so a test that compares nothing cannot pass.
    static let leastShareFound = 0.9

    /// The fewest inputs a comparison may cover: a TestData with most of its
    /// markup gone cannot pass for a proof.
    static let fewestInputsCompared = 1_200

    // MARK: - The Corpus

    /// One document of the corpus: its name, and its bytes.
    struct CorpusDocument {
        /// The path inside TestData, with `!` and the path inside the archive
        /// for a member of a ZIP container.
        let key: String
        /// The document's bytes.
        let bytes: [UInt8]
    }

    /// The TestData folder of this checkout, beside the tests' folder.
    private static var testData: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData", isDirectory: true)
    }

    /// The manifest of recorded checksums.
    private static var manifestURL: URL {
        testData.appendingPathComponent("soup-corpus/manifest.tsv")
    }

    /// Every markup document under TestData, in the order of their names
    /// (compared by bytes, so no locale changes it): each loose markup file,
    /// and each markup member of each ZIP container.
    static func gatherDocuments() -> [CorpusDocument] {
        let root = testData.standardizedFileURL.path + "/"
        var files: [(relative: String, url: URL)] = []
        let enumerator = FileManager.default.enumerator(
            at: testData, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            // The manifest itself is not a document.
            if !relative.hasPrefix("soup-corpus/") { files.append((relative, url)) }
        }
        files.sort { Array($0.relative.utf8).lexicographicallyPrecedes(Array($1.relative.utf8)) }

        var documents: [CorpusDocument] = []
        for file in files {
            let fileExtension = (file.relative as NSString).pathExtension.lowercased()
            if markupExtensions.contains(fileExtension) {
                if let data = try? Data(contentsOf: file.url), data.count <= largestDocument {
                    documents.append(CorpusDocument(key: file.relative, bytes: [UInt8](data)))
                }
            } else if isZIP(file.url), let archive = try? Archive(url: file.url, accessMode: .read, pathEncoding: nil) {
                documents += markupMembers(of: archive, named: file.relative)
            }
        }
        return documents
    }

    /// Whether the file starts with a ZIP local file header, "PK\u{3}\u{4}".
    private static func isZIP(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)).map { [UInt8]($0) == [0x50, 0x4B, 0x03, 0x04] } ?? false
    }

    /// The markup members of `archive`, as documents named after the archive
    /// `name` and each member's path, in the order of their paths.
    private static func markupMembers(of archive: Archive, named name: String) -> [CorpusDocument] {
        var members: [CorpusDocument] = []
        for entry in archive where entry.type == .file && entry.uncompressedSize <= UInt64(largestDocument) {
            let fileExtension = (entry.path as NSString).pathExtension.lowercased()
            guard markupExtensions.contains(fileExtension) else { continue }
            var bytes: [UInt8] = []
            // A member that will not extract (damaged or encrypted) is left out.
            guard (try? archive.extract(entry, skipCRC32: true, consumer: { bytes += $0 })) != nil else { continue }
            members.append(CorpusDocument(key: "\(name)!\(entry.path)", bytes: bytes))
        }
        return members.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
    }

    /// The documents to parse: each of the corpus as it is, then each of at
    /// most `largestDamagedDocument` bytes damaged `damagedCopiesPerDocument`
    /// times, each with the name `<document>#damaged<N>`.
    static func inputs(from documents: [CorpusDocument], damagingUpTo limit: Int = largestDamagedDocument) -> [CorpusDocument] {
        var inputs = documents
        for document in documents where document.bytes.count <= limit {
            var damage = SoupDamage(key: document.key)
            for copy in 1...damagedCopiesPerDocument {
                inputs.append(CorpusDocument(
                    key: "\(document.key)#damaged\(copy)", bytes: SoupCorpusKit.damaged(document.bytes, &damage)
                ))
            }
        }
        return inputs
    }

    // MARK: - The Three Parses

    /// The names of the three parses, in the order of a manifest line's columns.
    static let parseNames = ["html", "xml", "fragment"]

    /// The three summaries of `bytes`, one for each of `parseNames`.
    static func summaries(of bytes: [UInt8]) -> [String] {
        let markup = SoupCorpusKit.markup(of: bytes)
        return [
            SoupCorpusKit.outcome { try parseHTMLOnly(markup, bytes: bytes) },
            SoupCorpusKit.outcome { try MarkupGuard.parseXML(markup) },
            SoupCorpusKit.outcome { try MarkupGuard.parseBodyFragment(markup) },
        ]
    }

    /// `markup` parsed by SwiftSoup's HTML parser under the guard's two
    /// layers, whatever it opens with: `MarkupGuard.parse` hands a document
    /// that opens with `<?xml` to the XML parser, which would leave the HTML
    /// parser unchecked on every XHTML chapter.
    private static func parseHTMLOnly(_ markup: String, bytes: [UInt8]) throws -> SwiftSoup.Document {
        let limits = MarkupGuard.limits
        _ = try MarkupGuard.inspect(bytes, as: .html, limits: limits)
        return try MarkupGuard.onLargeStack {
            try MarkupGuard.requireDepth(of: SwiftSoup.parseHTML(markup, ""), atMost: limits.deepestParsedTree)
        }
    }

    /// Every input's name and its three summaries, joined by tabs, in order.
    static func lines(for inputs: [CorpusDocument]) -> [String] {
        inputs.map { ([$0.key] + summaries(of: $0.bytes)).joined(separator: "\t") }
    }

    // MARK: - The Manifest

    /// The manifest's lines by input name: each value holds the three summaries.
    private func recordedManifest() throws -> [String: [String]] {
        let text = try String(contentsOf: Self.manifestURL, encoding: .utf8)
        var manifest: [String: [String]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(columns.count, 1 + Self.parseNames.count, "A manifest line has a name and three summaries: \(line)")
            guard columns.count == 1 + Self.parseNames.count else { continue }
            manifest[columns[0]] = Array(columns.dropFirst())
        }
        return manifest
    }

    // MARK: - Tests

    /// Every document of the corpus, and its damaged copies, parse to the
    /// trees, text, and markup the manifest recorded from the released SwiftSoup.
    func testEveryParseMatchesTheRecordFromTheReleasedSwiftSoup() throws {
        let documents = Self.gatherDocuments()
        let recording = ProcessInfo.processInfo.environment["TEXTMOUTH_RECORD_SOUP_MANIFEST"] == "1"
        let inputs = Self.inputs(
            from: documents, damagingUpTo: recording ? Self.largestRecordedDamagedDocument : Self.largestDamagedDocument
        )
        let lines = Self.lines(for: inputs)

        // Recording: write the manifest, and say so rather than pass.
        if recording {
            try FileManager.default.createDirectory(
                at: Self.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let header = "# SwiftSoupCorpusTests: name, then the html, xml, and fragment summaries. "
                + "Recorded from SwiftSoup 2.13.9 as released.\n"
            try (header + lines.joined(separator: "\n") + "\n").write(to: Self.manifestURL, atomically: true, encoding: .utf8)
            throw XCTSkip("Recorded \(lines.count) inputs of \(documents.count) documents to \(Self.manifestURL.path)")
        }

        let manifest = try recordedManifest()
        var compared = 0
        var differences: [String] = []
        for line in lines {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let recorded = manifest[columns[0]] else { continue }
            compared += 1
            for (index, name) in Self.parseNames.enumerated() where recorded[index] != columns[1 + index] {
                differences.append("\(columns[0]) (\(name) parse: recorded \(recorded[index]), now \(columns[1 + index]))")
            }
        }
        XCTAssertTrue(
            differences.isEmpty,
            "\(differences.count) parses read differently from the released SwiftSoup, of \(compared) inputs compared:\n"
                + differences.prefix(40).joined(separator: "\n")
        )
        XCTAssertGreaterThanOrEqual(
            Double(compared), Double(lines.count) * Self.leastShareFound,
            "Only \(compared) of the \(lines.count) inputs are in the manifest, so the test proves little"
        )
        XCTAssertGreaterThan(compared, Self.fewestInputsCompared, "Too few inputs were compared")
    }

    /// The corpus has the documents the proof is worth something for: EPUB
    /// chapters, DAISY and DocBook XML, Word and OpenDocument parts, and loose
    /// pages, and damage that reaches them.
    func testTheCorpusIsWideEnoughToProveSomething() {
        let documents = Self.gatherDocuments()
        XCTAssertGreaterThan(documents.count, 400, "TestData holds hundreds of markup documents")
        XCTAssertTrue(documents.contains { $0.key.hasSuffix(".epub!OEBPS/content.opf") || $0.key.contains(".epub!") },
                      "EPUB members are in the corpus")
        XCTAssertTrue(documents.contains { !$0.key.contains("!") }, "loose markup files are in the corpus")
        let inputs = Self.inputs(from: documents)
        XCTAssertGreaterThan(inputs.count, documents.count, "damaged copies are in the corpus")
        XCTAssertEqual(Set(inputs.map(\.key)).count, inputs.count, "every input has a name of its own")
    }

    /// The damage is the same on every run and for every document alone.
    func testDamageIsTheSameEveryTime() {
        let bytes = Array("<p>one <b>two</b> three</p><p>four</p>".utf8)
        var first = SoupDamage(key: "a")
        var again = SoupDamage(key: "a")
        var other = SoupDamage(key: "b")
        XCTAssertEqual(SoupCorpusKit.damaged(bytes, &first), SoupCorpusKit.damaged(bytes, &again))
        XCTAssertNotEqual(SoupCorpusKit.damaged(bytes, &first), SoupCorpusKit.damaged(bytes, &other))
    }

    /// A summary changes with any part of a tree it covers, so a copy of
    /// SwiftSoup that built a different tree would show: an element's name, an
    /// attribute's name, order, or value, a text node, a comment, and the title.
    func testASummaryChangesWithEachPartOfATree() throws {
        func summary(_ markup: String) throws -> String {
            try SoupCorpusKit.summary(of: SwiftSoup.parseHTML(markup, ""))
        }
        let base = try summary("<html><head><title>T</title></head><body><p class='a' id='b'>text<!--c--></p></body></html>")
        let variants = [
            "<html><head><title>T</title></head><body><div class='a' id='b'>text<!--c--></div></body></html>",
            "<html><head><title>T</title></head><body><p id='b' class='a'>text<!--c--></p></body></html>",
            "<html><head><title>T</title></head><body><p class='a' id='x'>text<!--c--></p></body></html>",
            "<html><head><title>T</title></head><body><p class='a' id='b'>texT<!--c--></p></body></html>",
            "<html><head><title>T</title></head><body><p class='a' id='b'>text<!--d--></p></body></html>",
            "<html><head><title>U</title></head><body><p class='a' id='b'>text<!--c--></p></body></html>",
            "<html><head><title>T</title></head><body><p class='a' id='b'>text<!--c--></p><p></p></body></html>",
        ]
        for variant in variants {
            XCTAssertNotEqual(try summary(variant), base, variant)
        }
        XCTAssertEqual(try summary("<html><head><title>T</title></head><body><p class='a' id='b'>text<!--c--></p></body></html>"), base)
    }
}
