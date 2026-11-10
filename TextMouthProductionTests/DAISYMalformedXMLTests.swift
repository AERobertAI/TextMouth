import XCTest
import ZIPFoundation
@testable import TextMouth

/// A damaged DAISY file must never turn silently into a shorter book (TODO T04).
/// Structure files (OPF, NCX, SMIL) that break off or are not well-formed
/// throw an error naming the file, and every caller propagates it. DTBook
/// content keeps the text read before any damage and reports the damage
/// beside that text; content damaged before any text throws like structure.
/// The DAISY 2.02 NCC is read as HTML, so ordinary HTML markup works, and a
/// copy cut short fails by name instead of becoming a shorter table of contents.
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
    <navPoint id="n2"><navLabel><text>Breakwater Survey</text></navLabel><content src="part2.smil#p3"/></navPoint>
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

    /// The same navigation written as ordinary HTML rather than XHTML:
    /// upper-case tags, unquoted attributes, unclosed `<META>` and `<BR>`
    /// tags, and named entities, none of which an XML parser accepts.
    private static let htmlNCC = """
    <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
    <HTML><HEAD>
    <META http-equiv="Content-Type" content="text/html; charset=utf-8">
    <META name="dc:title" content="Harbor&nbsp;Soundings">
    <META name=dc:creator content="Odile Marchetti">
    <TITLE>Harbor Soundings</TITLE>
    </HEAD><BODY>
    <H1 class=title id=h1><A href="part1.smil#p1">Leadline&nbsp;Readings</A></H1>
    <P>Produced for the harbor library<BR>reading room</P>
    <H2 id=h2><A href="part2.smil#p3">Breakwater &amp; Survey</A><BR></H2>
    </BODY></HTML>
    """

    /// The first chapter's synchronization: a heading, then a paragraph,
    /// each with its text fragment and its clip of the chapter's audio.
    private static let part1SMIL = """
    <?xml version="1.0" encoding="utf-8"?>
    <smil><body><seq>
    <par id="p1"><text src="text.html#t1"/><audio src="part1.mp3" clip-begin="npt=0.000s" clip-end="npt=4.500s"/></par>
    <par id="p2"><text src="text.html#t2"/><audio src="part1.mp3" clip-begin="npt=4.500s" clip-end="npt=12.250s"/></par>
    </seq></body></smil>
    """

    /// The second chapter's synchronization, shaped like the first.
    private static let part2SMIL = """
    <?xml version="1.0" encoding="utf-8"?>
    <smil><body><seq>
    <par id="p3"><text src="text.html#t3"/><audio src="part2.mp3" clip-begin="npt=0.000s" clip-end="npt=3.000s"/></par>
    <par id="p4"><text src="text.html#t4"/><audio src="part2.mp3" clip-begin="npt=3.000s" clip-end="npt=9.750s"/></par>
    </seq></body></smil>
    """

    /// Stand-in audio files: conversion copies them without decoding.
    private static let audioFiles = ["part1.mp3": "first chapter audio", "part2.mp3": "second chapter audio"]

    /// The DAISY 2.02 text content the SMIL files point into.
    private static let contentHTML = """
    <html><body>
    <h1 id="t1">Leadline Readings</h1>
    <p id="t2">The first sounding came up at nine fathoms.</p>
    <h1 id="t3">Breakwater Survey</h1>
    <p id="t4">The second sounding struck gravel near the breakwater.</p>
    </body></html>
    """

    /// A complete DAISY 2.02 package; each entry of `changes` adds a file or
    /// replaces the standard one at that path.
    private static func daisy202Package(_ changes: [String: String] = [:]) -> [String: String] {
        let files = [
            "ncc.html": ncc,
            "part1.smil": part1SMIL,
            "part2.smil": part2SMIL,
            "text.html": contentHTML
        ]
        return files.merging(changes) { _, change in change }
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
    /// book fails, naming that file, rather than losing a paragraph. (The
    /// sentences are checked as read: the cache escapes their punctuation.)
    func testDAISY202BookWithTruncatedSMILReportsTheSynchronizationFile() throws {
        let intact = try makeTemporaryDAISYZip(entries: Self.daisy202Package())
        defer { try? FileManager.default.removeItem(at: intact) }
        let markdown = try DAISYParser.extractMarkdown(from: intact)
        let spoken = try Self.spokenText(of: markdown)
        XCTAssertTrue(spoken.contains("The first sounding came up at nine fathoms."), markdown)
        XCTAssertTrue(spoken.contains("The second sounding struck gravel near the breakwater."), markdown)

        let damaged = try makeTemporaryDAISYZip(entries: Self.daisy202Package([
            "part1.smil": Self.truncated(Self.part1SMIL, before: "<par id=\"p2\"")
        ]))
        defer { try? FileManager.default.removeItem(at: damaged) }
        malformedXMLReason(naming: "part1.smil") { try DAISYParser.extractMarkdown(from: damaged) }
    }

    // MARK: - ZIP Damage

    /// A file of the archive whose compressed data cannot be decoded is
    /// named as damaged in the DAISY sentence, read or copied, instead of
    /// surfacing ZIPFoundation's own error; the copy leaves nothing behind,
    /// and the files beside it still read.
    func testAFileWhoseCompressedDataCannotBeDecodedIsNamedAsDamaged() throws {
        let zip = try makeTemporaryZip(
            prefix: "TextMouthDAISYTest",
            entries: Self.daisy202Package().mapValues { Data($0.utf8) },
            compressionMethod: .deflate
        )
        defer { try? FileManager.default.removeItem(at: zip) }
        try damageData(of: "text.html", in: zip)
        let provider = ArchiveFileProvider(archive: try Archive(url: zip, accessMode: .read))
        let expected = "The file “text.html” in this DAISY book is damaged or incomplete: "
            + "its compressed data could not be decoded. Get a fresh copy of the book, then import it again."

        XCTAssertThrowsError(try provider.readFile(at: "text.html")) { error in
            XCTAssertEqual(error.localizedDescription, expected, "reading the file")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("TextMouthDAISYCopy-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertThrowsError(try provider.copyFile(at: "text.html", to: copy)) { error in
            XCTAssertEqual(error.localizedDescription, expected, "copying the file")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the failed copy was left behind")
        XCTAssertEqual(try provider.readFile(at: "ncc.html"), Data(Self.ncc.utf8), "a file beside it")
    }

    /// What `withinBounds` makes of each thing that can go wrong while a file
    /// is read or copied: a failed write (a full disk) is the error it was and
    /// never called damage in the book; an error of ZIPFoundation's is the
    /// damage sentence, with the raw error logged as DAISY_ZIP_ERROR; and a
    /// file past its limit is damage too.
    func testAFailedWriteIsNotCalledDamageButAnArchiveErrorIs() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let zip = try makeTemporaryZip(
            prefix: "TextMouthDAISYTest",
            entries: Self.daisy202Package().mapValues { Data($0.utf8) },
            compressionMethod: .deflate
        )
        defer { try? FileManager.default.removeItem(at: zip) }
        let archive = try Archive(url: zip, accessMode: .read)
        let provider = ArchiveFileProvider(archive: archive)
        let entry = try XCTUnwrap(archive["text.html"], "the fixture has no text.html")

        // A write that fails: the error comes out as it went in.
        XCTAssertThrowsError(
            try provider.withinBounds(of: entry, { () throws -> Void in
                throw ArchiveFileProvider.WriteFailure(underlying: CocoaError(.fileWriteOutOfSpace))
            })
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace, "a full disk was called \(error)")
            XCTAssertFalse(error is DAISYParserError, "a full disk was called damage in the book: \(error)")
        }

        // An error of the archive's own: damage, named, with the raw error logged.
        var thrown: Error?
        let marker = "text.html"
        let lines = debugLogLinesWritten {
            do {
                try provider.withinBounds(of: entry, { () throws -> Void in throw Archive.ArchiveError.invalidCRC32 })
            } catch { thrown = error }
        }
        XCTAssertEqual(
            thrown?.localizedDescription,
            "The file “\(marker)” in this DAISY book is damaged or incomplete: its compressed data could not be decoded. "
                + "Get a fresh copy of the book, then import it again."
        )
        XCTAssertEqual(
            lines.filter { $0.contains("DAISY_ZIP_ERROR: \(marker): invalidCRC32") }.count, 1,
            "ZIPFoundation's own error is logged once: \(lines)"
        )

        // A file past its limit: damage, with its own reason, nothing logged as a ZIP error.
        let overflow = ArchiveEntryOverflow.pastLimit(path: marker, limit: 10)
        XCTAssertThrowsError(try provider.withinBounds(of: entry, { () throws -> Void in throw overflow })) { error in
            XCTAssertEqual(
                error.localizedDescription,
                DAISYParserError.malformedXML(file: marker, reason: overflow.reason).localizedDescription
            )
        }
    }

    /// The debug-log lines written while `body` runs.
    private func debugLogLinesWritten(during body: () -> Void) -> [String] {
        let log = TextMouthPaths.debugLogFile
        TextMouthPaths.flushLogs()
        let before = (try? Data(contentsOf: log)) ?? Data()
        body()
        TextMouthPaths.flushLogs()
        let after = (try? Data(contentsOf: log)) ?? Data()
        let written = after.starts(with: before) ? after.dropFirst(before.count) : after
        return String(decoding: written, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Text Beyond the Audio

    /// An archive's SMIL file that the XML guard refuses (1,025 attributes on
    /// a tag) still tells that the book holds text of its own beyond the
    /// audio: the archive is then the only copy of that text and is kept,
    /// as it is when the same SMIL file is ordinary. With no text file for
    /// it to name, the refused file adds nothing.
    func testARefusedSMILStillShowsThatTheArchiveHoldsText() {
        let many = (0..<1_025).map { "a\($0)=\"\"" }.joined(separator: " ")
        let refused = Self.part1SMIL.replacingOccurrences(
            of: "<text src=\"text.html#t1\"/>", with: "<text src=\"text.html#t1\" \(many)/>"
        )
        XCTAssertNotEqual(refused, Self.part1SMIL, "the fixture's text element is not where this test looks")
        XCTAssertNotNil(XMLInputGuard.problem(with: Data(refused.utf8)), "the guard does not refuse the SMIL file")

        for (label, smil, expectsText) in [
            ("ordinary SMIL", Self.part1SMIL, true), ("refused SMIL", refused, true)
        ] {
            let package = InMemoryDAISYPackage(Self.daisy202Package(["part1.smil": smil, "part2.smil": "<smil/>"]))
            XCTAssertEqual(
                FileImportService.daisyArchiveLeftovers(of: package, archiveName: "Soundings.zip").holdsText,
                expectsText, label
            )
        }
        // Without the text file the SMIL file names, there is no text to keep.
        var files = Self.daisy202Package(["part1.smil": refused, "part2.smil": "<smil/>"])
        files["text.html"] = nil
        XCTAssertFalse(
            FileImportService.daisyArchiveLeftovers(of: InMemoryDAISYPackage(files), archiveName: "Soundings.zip").holdsText,
            "a refused SMIL file named a text file the archive does not hold"
        )
    }

    // MARK: - SMIL Audio Clips

    /// A clip list cut off after its first clip throws instead of returning
    /// the clips before the cut, which would end the chapter early.
    func testTruncatedAudioSMILThrowsErrorNamingTheFile() throws {
        let complete = try DAISYAudioSMILParser(data: Data(Self.part1SMIL.utf8), file: "part1.smil").parse()
        XCTAssertEqual(complete.map(\.parID), ["p1", "p2"])

        let damaged = Self.truncated(Self.part1SMIL, before: "<par id=\"p2\"")
        malformedXMLReason(naming: "part1.smil") {
            try DAISYAudioSMILParser(data: Data(damaged.utf8), file: "part1.smil").parse()
        }
    }

    /// An intact DAISY 2.02 audio package still yields one segment per
    /// heading, each spanning its own clips, with the audio copied.
    func testIntactDAISY202AudioPackageBuildsOneSegmentPerHeading() throws {
        let package = InMemoryDAISYPackage(Self.daisy202Package(Self.audioFiles))
        let audioDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        let manifest = try DAISYAudioConverter.convertToAudioBook(
            from: package, version: .daisy202, toDirectory: audioDirectory
        )

        XCTAssertEqual(manifest.title, "Harbor Soundings")
        XCTAssertEqual(manifest.author, "Odile Marchetti")
        let segments = try XCTUnwrap(manifest.segments)
        XCTAssertEqual(segments.map(\.title), ["Leadline Readings", "Breakwater Survey"])
        XCTAssertEqual(segments.map(\.file), ["part1.mp3", "part2.mp3"])
        XCTAssertEqual(segments.map(\.startTime), [0, 0])
        XCTAssertEqual(segments.map(\.endTime), [12.25, 9.75])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path).sorted(),
                       ["part1.mp3", "part2.mp3"])
    }

    /// DAISY 2.02 audio import stops on a damaged SMIL file before copying.
    func testDAISY202AudioImportWithTruncatedSMILReportsTheSynchronizationFile() throws {
        let package = InMemoryDAISYPackage(Self.daisy202Package(Self.audioFiles.merging([
            "part2.smil": Self.truncated(Self.part2SMIL, before: "<par id=\"p4\"")
        ]) { _, override in override }))
        let audioDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        malformedXMLReason(naming: "part2.smil") {
            try DAISYAudioConverter.convertToAudioBook(from: package, version: .daisy202, toDirectory: audioDirectory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path), [])
    }

    /// DAISY 3 audio import stops on a damaged SMIL file before copying.
    func testDAISY3AudioImportWithTruncatedSMILReportsTheSynchronizationFile() throws {
        let package = InMemoryDAISYPackage(Self.audioFiles.merging([
            "package.opf": Self.opf,
            "book.ncx": Self.ncx,
            "part1.smil": Self.part1SMIL,
            "part2.smil": Self.truncated(Self.part2SMIL, before: "</seq>")
        ]) { _, override in override })
        let audioDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        malformedXMLReason(naming: "part2.smil") {
            try DAISYAudioConverter.convertToAudioBook(from: package, version: .daisy3, toDirectory: audioDirectory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path), [])
    }

    // MARK: - DTBook Content

    /// Content cut off mid-paragraph keeps every word read before the cut
    /// and reports the damage beside the text, never inside it.
    func testTruncatedDTBookKeepsTheTextReadBeforeTheCut() throws {
        let intact = try DTBookToMarkdownConverter(data: Data(Self.dtbook.utf8), file: "book.xml").convert()
        XCTAssertNil(intact.diagnostic)

        let damaged = Self.truncated(Self.dtbook, before: "gravel near")
        let conversion = try DTBookToMarkdownConverter(data: Data(damaged.utf8), file: "book.xml").convert()

        XCTAssertTrue(conversion.markdown.hasPrefix("# Leadline Readings\n"), conversion.markdown)
        XCTAssertEqual(
            try Self.spokenText(of: conversion.markdown),
            "Leadline Readings\n\nThe first sounding came up at nine fathoms.\n\nThe second sounding struck"
        )
        guard case let .malformedXML(file, reason)? = conversion.diagnostic else {
            return XCTFail("Expected a diagnostic describing the damage")
        }
        XCTAssertEqual(file, "book.xml")
        XCTAssertFalse(conversion.markdown.contains(reason), "The diagnostic must stay out of the spoken text")
    }

    /// Markup left open by the cut is closed as its end tags would have
    /// closed it, so no emphasis or link syntax is read aloud as symbols.
    func testTruncatedDTBookClosesMarkupLeftOpenByTheCut() throws {
        let damaged = """
        <?xml version="1.0" encoding="UTF-8"?>
        <dtbook><book><bodymatter><level1>
        <p>Soundings were <em>unusually shallow</em> near the pier.</p>
        <p>See <a href="#chart">the harbor <strong>chart
        """

        let conversion = try DTBookToMarkdownConverter(data: Data(damaged.utf8), file: "book.xml").convert()

        XCTAssertNotNil(conversion.diagnostic)
        XCTAssertEqual(
            try Self.spokenText(of: conversion.markdown),
            "Soundings were unusually shallow near the pier.\n\nSee the harbor chart"
        )
    }

    /// Damage before any text leaves nothing worth reading, so the file
    /// fails like a damaged structure file, whether it breaks off in its
    /// head or before its first words.
    func testDTBookDamagedBeforeAnyTextThrows() {
        for marker in ["</head>", "<h1>"] {
            let damaged = Self.truncated(Self.dtbook, before: marker)
            malformedXMLReason(naming: "book.xml") {
                try DTBookToMarkdownConverter(data: Data(damaged.utf8), file: "book.xml").convert()
            }
        }
    }

    /// A DAISY 3 book whose content breaks off still opens with the text that
    /// was recovered, and the damaged file is reported once, by name.
    func testDAISY3BookKeepsTextBeforeDamageAndReportsTheContentFile() throws {
        let zip = try makeTemporaryDAISYZip(entries: [
            "book/package.opf": Self.opf,
            "book/book.xml": Self.truncated(Self.dtbook, before: "The second sounding")
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        var diagnostics: [DAISYParserError] = []
        let markdown = try DAISYParser.extractMarkdown(from: zip) { diagnostics.append($0) }

        XCTAssertEqual(
            try Self.spokenText(of: markdown),
            "Leadline Readings\n\nThe first sounding came up at nine fathoms."
        )
        XCTAssertEqual(diagnostics.count, 1)
        guard case let .malformedXML(file, _)? = diagnostics.first else {
            return XCTFail("Expected one malformed-XML diagnostic, got \(diagnostics)")
        }
        XCTAssertEqual(file, "book/book.xml")
    }

    /// Content damaged before any text fails the book, whether the package
    /// names it in an OPF or holds it as a standalone DTBook file.
    func testDAISY3BookWithContentDamagedBeforeAnyTextFails() throws {
        let damagedContent = Self.truncated(Self.dtbook, before: "<h1>")
        let packaged = try makeTemporaryDAISYZip(entries: [
            "book/package.opf": Self.opf,
            "book/book.xml": damagedContent
        ])
        let standalone = try makeTemporaryDAISYZip(entries: ["book.xml": damagedContent])
        defer {
            try? FileManager.default.removeItem(at: packaged)
            try? FileManager.default.removeItem(at: standalone)
        }

        malformedXMLReason(naming: "book/book.xml") { try DAISYParser.extractMarkdown(from: packaged) }
        malformedXMLReason(naming: "book.xml") { try DAISYParser.extractMarkdown(from: standalone) }
    }

    /// With no reporter supplied, as when the Markdown cache is built, the
    /// damaged file is recorded in the debug log.
    func testIncompleteContentIsWrittenToTheDebugLogByDefault() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let folder = "logged-\(UUID().uuidString)"
        let zip = try makeTemporaryDAISYZip(entries: [
            "\(folder)/package.opf": Self.opf,
            "\(folder)/book.xml": Self.truncated(Self.dtbook, before: "The second sounding")
        ])
        defer { try? FileManager.default.removeItem(at: zip) }

        _ = try DAISYParser.extractMarkdown(from: zip)
        TextMouthPaths.flushLogs()

        let log = try String(contentsOf: TextMouthPaths.debugLogFile, encoding: .utf8)
        let entry = try XCTUnwrap(log.components(separatedBy: "\n").first { $0.contains(folder) })
        XCTAssertTrue(entry.contains("DAISY_INCOMPLETE_CONTENT: The file “\(folder)/book.xml”"), entry)
    }

    // MARK: - NCC Navigation

    /// An NCC in ordinary HTML yields its metadata and headings. Forcing it
    /// through an XML parser stopped at the first unclosed `<META>`, before
    /// any heading, and left the book without navigation or text.
    func testNCCWrittenAsOrdinaryHTMLParses() throws {
        let result = try DAISY202NCCParser(html: Self.htmlNCC, file: "ncc.html").parse()

        XCTAssertEqual(result.title, "Harbor Soundings")
        XCTAssertEqual(result.author, "Odile Marchetti")
        XCTAssertEqual(Self.outline(result), [
            "h1 Leadline Readings → part1.smil#p1",
            "h2 Breakwater & Survey → part2.smil#p3"
        ])
    }

    /// A DAISY 2.02 book whose NCC is ordinary HTML opens with its full text
    /// and its title and author. (The sentences are checked as read: the
    /// cache escapes their punctuation.)
    func testDAISY202BookWithHTMLNCCReadsItsTextAndMetadata() throws {
        let zip = try makeTemporaryDAISYZip(entries: Self.daisy202Package(["ncc.html": Self.htmlNCC]))
        defer { try? FileManager.default.removeItem(at: zip) }

        let markdown = try DAISYParser.extractMarkdown(from: zip)
        let spoken = try Self.spokenText(of: markdown)
        let metadata = try XCTUnwrap(DAISYParser.readMetadata(from: zip))

        XCTAssertTrue(spoken.contains("The first sounding came up at nine fathoms."), markdown)
        XCTAssertTrue(spoken.contains("The second sounding struck gravel near the breakwater."), markdown)
        XCTAssertEqual(metadata.title, "Harbor Soundings")
        XCTAssertEqual(metadata.author, "Odile Marchetti")
    }

    /// The bundled NCC fixtures keep exactly the navigation the XML parser
    /// gave them: every title, author, level, label, and destination.
    func testNCCFixturesKeepTheirNavigation() throws {
        let tides = try Self.parseFixtureNCC("daisy202_test.zip", path: "ncc.html")
        XCTAssertEqual(tides.title, "The Manual of Tide Prediction")
        XCTAssertEqual(tides.author, "Josephine Halford")
        XCTAssertEqual(Self.outline(tides), [
            "h1 The Manual of Tide Prediction → content001.smil#txt_1",
            "h1 Chapter 1: Gravitational Forces → content001.smil#txt_2",
            "h2 The Moon's Influence → content001.smil#txt_3",
            "h1 Chapter 2: Tidal Patterns → content002.smil#txt_10",
            "h2 Spring and Neap Tides → content002.smil#txt_11"
        ])

        let treaty = try Self.parseFixtureNCC("wipo-treaty-d202-text-only.zip", path: "WIPO-Treaty-D202Fileset/ncc.html")
        XCTAssertEqual(treaty.title, "WIPO Treaty for the Visually Impaired")
        XCTAssertEqual(treaty.author, "WBU")
        XCTAssertEqual(Self.outline(treaty), [
            "h1 WIPO Treaty for the Visually Impaired → d202_1.smil#txt_1",
            "h1 WIPO Treaty for Visually Impaired → d202_2.smil#txt_4",
            "h1 Preamble → d202_3.smil#txt_11",
            "h1 Article 1. Purpose → d202_4.smil#txt_40",
            "h1 Article 2. Nature and Scope of Obligations → d202_5.smil#txt_42",
            "h1 Article 3. Relations to Other Agreements → d202_6.smil#txt_51",
            "h1 Article 4. Limitations and Exceptions to Exclusive Rights under Copyright → d202_7.smil#txt_65",
            "h1 Article 5. Acknowledgment and Moral Rights → d202_8.smil#txt_85",
            "h1 Article 6. Circumvention of Technological Measures → d202_9.smil#txt_90",
            "h1 Article 7. Relationship with Contracts → d202_10.smil#txt_92",
            "h1 Article 8. Imports and Exports of Works → d202_11.smil#txt_94",
            "h1 Article 9. Notice to Right Owners for Commercial Reproduction and Distribution of Works"
                + " → d202_12.smil#txt_105",
            "h1 Article 10. Database on Availability of Works → d202_13.smil#txt_110",
            "h1 Article 11. Remuneration for Commercial Exploitation of Works. → d202_14.smil#txt_113",
            "h1 Article 12. Orphaned Works. → d202_15.smil#txt_119",
            "h1 Article 13. Respect for Privacy. → d202_16.smil#txt_122",
            "h1 Article 14. Limitations and Exceptions Applied to Non-Copyrighted Elements of Databases"
                + " → d202_17.smil#txt_125",
            "h1 Article 15. Disabilities Covered → d202_18.smil#txt_129",
            "h1 Article 16. Additional Definitions → d202_19.smil#txt_134",
            "h1 Article 17. Conference of Parties → d202_20.smil#txt_144",
            "h1 Article 18. Optional Protocols → d202_21.smil#txt_152",
            "h1 Article 19. Reservations → d202_22.smil#txt_157",
            "h1 Article 20. Monitoring and Implementation → d202_23.smil#txt_159"
        ])
    }

    /// An NCC's headings and pages come in document order however deeply
    /// each is nested, and a heading's destination is the first link inside
    /// it in document order that has one: here a link deep in its first
    /// words, past an empty one, rather than a later link beside them.
    func testNCCEntriesKeepDocumentOrderHoweverTheyNest() throws {
        let html = """
        <html><head><meta name="dc:title" content="Harbor Soundings"/></head><body>
        <div><h1><a href="part1.smil#p1">Leadline Readings</a></h1>
          <div><span class="page-normal"><a href="part1.smil#pg1">1</a></span>
            <div><h2><span><span><a href="">Dawn</a> <a href="part1.smil#p2">soundings</a></span></span>
              <a href="part1.smil#later">at the jetty</a></h2></div>
          </div>
          <h3><span><span><a href="part1.smil#p3">Gravel Bars</a></span></span></h3>
        </div>
        <div><div><h1><a href="part2.smil#p4">Breakwater Survey</a></h1></div>
          <span class="page-front"><a href="part2.smil#pg2">ii</a></span></div>
        </body></html>
        """
        let result = try DAISY202NCCParser(html: html, file: "ncc.html").parse()

        XCTAssertEqual(result.title, "Harbor Soundings")
        XCTAssertEqual(Self.outline(result), [
            "h1 Leadline Readings → part1.smil#p1",
            "h2 Dawn soundings at the jetty → part1.smil#p2",
            "h3 Gravel Bars → part1.smil#p3",
            "h1 Breakwater Survey → part2.smil#p4"
        ])
        XCTAssertEqual(result.pages.map { "\($0.label) → \($0.href)" }, ["1 → part1.smil#pg1", "ii → part2.smil#pg2"])
    }

    /// An NCC nesting 5,000 divisions around a heading is read on a worker
    /// thread's 512 KiB stack, where an import reads it, and gives that
    /// heading. The walk once called itself for every element, which
    /// overflowed that stack and ended TextMouth during the import. (At
    /// 20,000, the guard's pass, which looks down the open elements for each
    /// division it opens, took 19 seconds of the test's 60 in a debug build.)
    ///
    /// `</body>` closes the heading and the divisions: SwiftSoup itself calls
    /// itself once for every level above an `</h1>` or `</span>` it reads,
    /// which would overflow the stack in SwiftSoup before TextMouth's walk.
    /// `MarkupGuard` refuses such a file before any of this, so its limit is
    /// lifted here, to hold the walk to itself.
    func testNCCNestedThousandsDeepIsReadOnAWorkerStack() {
        let html = "<html><head><meta name=\"dc:title\" content=\"Harbor Soundings\"/></head><body>"
            + String(repeating: "<div>", count: 5_000)
            + "<h1><a href=\"part1.smil#p1\">Leadline Readings</a></body></html>"
        let outline = onWorkerSizedStack {
            MarkupGuard.$limits.withValue(.withoutDepthLimit) { DAISYMalformedXMLTests.outlineOfNCC(html) }
        }
        XCTAssertEqual(outline, ["h1 Leadline Readings → part1.smil#p1"])
    }

    /// A heading whose link lies inside 20,000 nested spans is read on a
    /// worker thread's 512 KiB stack and keeps that link as its destination.
    /// The search for a heading's first link once called itself for every
    /// element, which overflowed that stack. `</body>` closes the spans, and
    /// `MarkupGuard`'s limit is lifted, as in
    /// `testNCCNestedThousandsDeepIsReadOnAWorkerStack`.
    func testAHeadingsLinkNestedThousandsDeepIsFoundOnAWorkerStack() {
        let html = "<html><head></head><body><h1>"
            + String(repeating: "<span>", count: 20_000)
            + "<a href=\"part1.smil#p1\">Leadline Readings</a></body></html>"
        let outline = onWorkerSizedStack {
            MarkupGuard.$limits.withValue(.withoutDepthLimit) { DAISYMalformedXMLTests.outlineOfNCC(html) }
        }
        XCTAssertEqual(outline, ["h1 Leadline Readings → part1.smil#p1"])
    }

    /// An NCC cut off partway, in XHTML or in HTML, fails by name instead of
    /// becoming a table of contents that silently ends early.
    func testTruncatedNCCThrowsErrorNamingTheFile() {
        for source in [Self.ncc, Self.htmlNCC] {
            let damaged = Self.truncated(source, before: "Survey")
            let reason = malformedXMLReason(naming: "ncc.html") {
                try DAISY202NCCParser(html: damaged, file: "ncc.html").parse()
            }
            XCTAssertTrue(reason.contains("closing body and html tags"), reason)
        }
    }

    /// A copy that lost only its final `</html>` tag lost no navigation, so
    /// it still reads in full.
    func testNCCMissingOnlyItsFinalTagKeepsItsNavigation() throws {
        let result = try DAISY202NCCParser(html: Self.truncated(Self.ncc, before: "</html>"), file: "ncc.html").parse()

        XCTAssertEqual(Self.outline(result), [
            "h1 Leadline Readings → part1.smil#p1",
            "h1 Breakwater Survey → part2.smil#p3"
        ])
    }

    /// Text extraction, metadata reading, and audio import all refuse a
    /// truncated NCC, naming it.
    func testDAISY202BookWithTruncatedNCCReportsTheNavigationFile() throws {
        let files = Self.daisy202Package(["ncc.html": Self.truncated(Self.ncc, before: "<h1 id=\"h2\"")])
        let zip = try makeTemporaryDAISYZip(entries: files)
        let audioDirectory = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: zip)
            try? FileManager.default.removeItem(at: audioDirectory)
        }

        malformedXMLReason(naming: "ncc.html") { try DAISYParser.extractMarkdown(from: zip) }
        malformedXMLReason(naming: "ncc.html") { try DAISYParser.readMetadata(from: zip) }
        malformedXMLReason(naming: "ncc.html") {
            try DAISYAudioConverter.convertToAudioBook(
                from: InMemoryDAISYPackage(files.merging(Self.audioFiles) { current, _ in current }),
                version: .daisy202,
                toDirectory: audioDirectory
            )
        }
    }

    // MARK: - Helpers

    /// An NCC's headings as "h<level> <label> → <destination>" lines, which
    /// compare and read clearly in a failure message.
    private static func outline(_ result: DAISY202NCCResult) -> [String] {
        result.headings.map { "h\($0.level) \($0.text) → \($0.href)" }
    }

    /// The outline (`outline(_:)`) of the NCC `html`; none when it cannot
    /// be parsed.
    private static func outlineOfNCC(_ html: String) -> [String] {
        (try? DAISY202NCCParser(html: html, file: "ncc.html").parse()).map(outline) ?? []
    }

    /// Parse the NCC at `path` inside the bundled test fixture `name`.
    private static func parseFixtureNCC(_ name: String, path: String) throws -> DAISY202NCCResult {
        let archive = try Archive(url: try requireFile(name), accessMode: .read)
        return try DAISY202NCCParser(path: path, in: ArchiveFileProvider(archive: archive)).parse()
    }

    /// The words a reader hears for `markdown`: its plain text as the
    /// Markdown parser extracts it for speech and display.
    private static func spokenText(of markdown: String) throws -> String {
        try MarkdownDocParser.parse(markdown: markdown).chapters[0].text
    }

    /// A new, empty directory under the temporary directory.
    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthDAISYAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
