import XCTest
@testable import TextMouth

/// A damaged DAISY file must never turn silently into a shorter book (TODO T04).
/// Structure files (OPF, NCX, SMIL) that break off or are not well-formed
/// throw an error naming the file, and every caller propagates it.
final class DAISYMalformedXMLTests: XCTestCase {

    // MARK: - Fixtures

    /// A DAISY 3 package document naming one DTBook content file.
    private static let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://openebook.org/namespaces/oeb-package/1.0/">
    <metadata><dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:Title>Harbor Soundings</dc:Title><dc:Creator>Odile Marchetti</dc:Creator>
    </dc-metadata></metadata>
    <manifest>
    <item id="text" href="book.xml" media-type="application/x-dtbook+xml"/>
    <item id="ncx" href="book.ncx" media-type="application/x-dtbncx+xml"/>
    </manifest>
    <spine><itemref idref="text"/></spine>
    </package>
    """

    /// A DAISY 3 navigation map with two top-level points.
    private static let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
    <navMap>
    <navPoint id="n1"><navLabel><text>Leadline Readings</text></navLabel><content src="part1.smil#p1"/></navPoint>
    <navPoint id="n2"><navLabel><text>Breakwater Survey</text></navLabel><content src="part2.smil#p2"/></navPoint>
    </navMap>
    </ncx>
    """

    /// DTBook content with a heading and two paragraphs.
    private static let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Harbor Soundings"/></head>
    <book><bodymatter><level1>
    <h1>Leadline Readings</h1>
    <p>The first sounding came up at nine fathoms.</p>
    <p>The second sounding struck gravel near the breakwater.</p>
    </level1></bodymatter></book></dtbook>
    """

    /// A DAISY 2.02 navigation file with two headings, one per SMIL file.
    private static let ncc = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head>
    <meta name="dc:title" content="Harbor Soundings"/>
    <meta name="dc:creator" content="Odile Marchetti"/>
    </head><body>
    <h1 id="h1"><a href="part1.smil#p1">Leadline Readings</a></h1>
    <h1 id="h2"><a href="part2.smil#p3">Breakwater Survey</a></h1>
    </body></html>
    """

    /// The first chapter's synchronization: a heading, then a paragraph.
    private static let part1SMIL = """
    <?xml version="1.0" encoding="utf-8"?>
    <smil><body><seq>
    <par id="p1"><text src="text.html#t1"/></par>
    <par id="p2"><text src="text.html#t2"/></par>
    </seq></body></smil>
    """

    /// The second chapter's synchronization: a heading, then a paragraph.
    private static let part2SMIL = """
    <?xml version="1.0" encoding="utf-8"?>
    <smil><body><seq>
    <par id="p3"><text src="text.html#t3"/></par>
    <par id="p4"><text src="text.html#t4"/></par>
    </seq></body></smil>
    """

    /// The DAISY 2.02 text content the SMIL files point into.
    private static let contentHTML = """
    <html><body>
    <h1 id="t1">Leadline Readings</h1>
    <p id="t2">The first sounding came up at nine fathoms.</p>
    <h1 id="t3">Breakwater Survey</h1>
    <p id="t4">The second sounding struck gravel near the breakwater.</p>
    </body></html>
    """

    /// A complete DAISY 2.02 text package, with `overrides` replacing files.
    private static func daisy202Package(_ overrides: [String: String] = [:]) -> [String: String] {
        let files = [
            "ncc.html": ncc,
            "part1.smil": part1SMIL,
            "part2.smil": part2SMIL,
            "text.html": contentHTML
        ]
        return files.merging(overrides) { _, override in override }
    }

    /// `text` up to, not including, the first `marker`: a copy cut off
    /// partway, as an interrupted download or extraction leaves it.
    private static func truncated(_ text: String, before marker: String) -> String {
        guard let range = text.range(of: marker) else {
            preconditionFailure("Fixture marker \(marker) not found")
        }
        return String(text[..<range.lowerBound])
    }

    /// Run `body`, which must throw `DAISYParserError.malformedXML` naming
    /// `expectedFile`, and return the error's reason ("" after a failure).
    @discardableResult
    private func malformedXMLReason<T>(
        naming expectedFile: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> T
    ) -> String {
        do {
            _ = try body()
            XCTFail("Expected a malformed-XML error naming \(expectedFile)", file: file, line: line)
        } catch let DAISYParserError.malformedXML(damagedFile, reason) {
            XCTAssertEqual(damagedFile, expectedFile, "The error must name the damaged file", file: file, line: line)
            return reason
        } catch {
            XCTFail("Expected a malformed-XML error naming \(expectedFile), got \(error)", file: file, line: line)
        }
        return ""
    }

    // MARK: - Error Description

    /// The message a reader hears names the file and says what to do next.
    func testMalformedXMLDescriptionNamesTheFileAndTheRemedy() {
        let error = DAISYParserError.malformedXML(file: "book/package.opf", reason: "the file is empty")

        XCTAssertEqual(
            error.errorDescription,
            "The file “book/package.opf” in this DAISY book is damaged or incomplete: the file is empty. "
                + "Get a fresh copy of the book, then import it again."
        )
    }

    /// The reason gives the first error's position, which XMLParser reports
    /// only while parsing, rather than its generic final "stopped" code.
    func testReasonDescribesWhereTheMarkupBreaksOff() {
        let data = Data("<?xml version=\"1.0\"?>\n<package><metadata><title>Harbor Sound".utf8)

        let reason = malformedXMLReason(naming: "book/package.opf") {
            try DAISYOPFParser(data: data, file: "book/package.opf").parse()
        }

        XCTAssertTrue(reason.hasPrefix("its markup breaks off early"), reason)
        XCTAssertTrue(reason.contains("(line 2, column "), reason)
        XCTAssertFalse(reason.contains("111"), "The generic stop code must not replace the cause: \(reason)")
    }

    /// An empty or blank file says so instead of citing a parser code.
    func testEmptyFileIsReportedAsEmpty() {
        for contents in ["", " \n\t\r\n"] {
            let reason = malformedXMLReason(naming: "package.opf") {
                try DAISYOPFParser(data: Data(contents.utf8), file: "package.opf").parse()
            }
            XCTAssertEqual(reason, "the file is empty")
        }
    }

    /// A byte that is not UTF-8 in a file declared as UTF-8 is described as
    /// an encoding problem, the usual damage in hand-edited DAISY files.
    func testMisencodedFileIsReportedAsAnEncodingProblem() {
        var data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package><metadata><title>Caf".utf8)
        data.append(0xE9) // "é" in ISO Latin 1
        data.append(contentsOf: Data("</title></metadata></package>".utf8))

        let reason = malformedXMLReason(naming: "package.opf") {
            try DAISYOPFParser(data: data, file: "package.opf").parse()
        }

        XCTAssertTrue(reason.hasPrefix("it contains characters that are not valid in its declared text encoding"), reason)
    }

    // MARK: - OPF Package

    /// A package cut off inside its manifest throws rather than returning a
    /// manifest that silently omits the content files after the cut.
    func testTruncatedOPFThrowsErrorNamingTheFile() {
        let damaged = Self.truncated(Self.opf, before: "media-type=\"application/x-dtbook+xml\"")

        let reason = malformedXMLReason(naming: "book/package.opf") {
            try DAISYOPFParser(data: Data(damaged.utf8), file: "book/package.opf").parse()
        }

        XCTAssertTrue(reason.contains("(line 7, column "), reason)
    }

    /// Text extraction and metadata reading both refuse a damaged package
    /// instead of guessing at its content files.
    func testDAISY3BookWithTruncatedOPFReportsThePackageFile() throws {
        let zip = try makeTemporaryDAISYZip(entries: [
            "book/package.opf": Self.truncated(Self.opf, before: "<spine>"),
            "book/book.xml": Self.dtbook
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        malformedXMLReason(naming: "book/package.opf") { try DAISYParser.extractMarkdown(from: zip) }
        malformedXMLReason(naming: "book/package.opf") { try DAISYParser.readMetadata(from: zip) }
    }

    /// Audio import stops on a damaged package before copying any audio.
    func testDAISY3AudioImportWithTruncatedOPFReportsThePackageFile() throws {
        let package = InMemoryDAISYPackage([
            "package.opf": Self.truncated(Self.opf, before: "</manifest>"),
            "book.ncx": "<ncx><navMap/></ncx>"
        ])
        let audioDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        malformedXMLReason(naming: "package.opf") {
            try DAISYAudioConverter.convertToAudioBook(from: package, version: .daisy3, toDirectory: audioDirectory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path), [])
    }

    // MARK: - NCX Navigation

    /// A map cut off after its first point used to parse as a one-point map,
    /// turning a whole audio book into its first chapter without a word.
    func testTruncatedNCXThrowsErrorNamingTheFile() throws {
        let complete = try DAISYNCXParser(data: Data(Self.ncx.utf8), file: "book.ncx").parse()
        XCTAssertEqual(complete.map(\.label), ["Leadline Readings", "Breakwater Survey"])

        let damaged = Self.truncated(Self.ncx, before: "<navPoint id=\"n2\"")
        malformedXMLReason(naming: "book.ncx") {
            try DAISYNCXParser(data: Data(damaged.utf8), file: "book.ncx").parse()
        }
    }

    /// Audio import stops on a damaged navigation map before copying audio.
    func testDAISY3AudioImportWithTruncatedNCXReportsTheNavigationFile() throws {
        let package = InMemoryDAISYPackage([
            "package.opf": Self.opf,
            "book.ncx": Self.truncated(Self.ncx, before: "</navMap>")
        ])
        let audioDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        malformedXMLReason(naming: "book.ncx") {
            try DAISYAudioConverter.convertToAudioBook(from: package, version: .daisy3, toDirectory: audioDirectory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path), [])
    }

    // MARK: - SMIL Text References

    /// A synchronization file cut off after its first reference throws
    /// instead of returning the references read before the cut.
    func testTruncatedTextSMILThrowsErrorNamingTheFile() throws {
        let complete = try DAISYSMILParser(data: Data(Self.part1SMIL.utf8), file: "part1.smil").parseTextReferences()
        XCTAssertEqual(complete, ["text.html#t1", "text.html#t2"])

        let damaged = Self.truncated(Self.part1SMIL, before: "<par id=\"p2\"")
        malformedXMLReason(naming: "part1.smil") {
            try DAISYSMILParser(data: Data(damaged.utf8), file: "part1.smil").parseTextReferences()
        }
    }

    /// The package reads in full while intact; with a damaged SMIL file the
    /// book fails, naming that file, rather than losing a paragraph.
    func testDAISY202BookWithTruncatedSMILReportsTheSynchronizationFile() throws {
        let intact = try makeTemporaryDAISYZip(entries: Self.daisy202Package())
        defer { try? FileManager.default.removeItem(at: intact) }
        let markdown = try DAISYParser.extractMarkdown(from: intact)
        XCTAssertTrue(markdown.contains("The first sounding came up at nine fathoms."), markdown)
        XCTAssertTrue(markdown.contains("The second sounding struck gravel near the breakwater."), markdown)

        let damaged = try makeTemporaryDAISYZip(entries: Self.daisy202Package([
            "part1.smil": Self.truncated(Self.part1SMIL, before: "<par id=\"p2\"")
        ]))
        defer { try? FileManager.default.removeItem(at: damaged) }
        malformedXMLReason(naming: "part1.smil") { try DAISYParser.extractMarkdown(from: damaged) }
    }

    // MARK: - Helpers

    /// A new, empty directory under the temporary directory.
    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthDAISYAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
