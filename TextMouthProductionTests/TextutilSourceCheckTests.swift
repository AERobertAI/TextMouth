import XCTest
import ZIPFoundation
@testable import TextMouth

/// What a document's own bytes say before `textutil` reads it (FMT13): RTF
/// under another name, and a password in a Word 97-2003 or OpenDocument
/// file. Every sample is a copy in the test's own folder.
final class TextutilSourceCheckTests: XCTestCase {

    // MARK: - Helpers

    /// A file named `name` in a new folder of this test's own, holding `bytes`.
    private func file(named name: String, holding bytes: Data) throws -> URL {
        let url = try makeSandboxDirectory("SourceCheck").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A ZIP holding one file, `path`, with `text` as its contents, removed
    /// when the test ends.
    private func zip(holding path: String, _ text: String) throws -> URL {
        let url = try makeTemporaryZip(prefix: "SourceCheck", entries: [path: Data(text.utf8)])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The first 14 bytes of a File Information Block: `wIdent`, `nFib`, six
    /// bytes of other fields, the flags word `flags`, and `nFibBack`.
    private func fibBytes(version: UInt16, back: UInt16 = 0x00BF, flags: UInt16 = 0) -> [UInt8] {
        [0xEC, 0xA5, UInt8(version & 0xFF), UInt8(version >> 8), 0, 0, 0, 0, 0, 0,
         UInt8(flags & 0xFF), UInt8(flags >> 8), UInt8(back & 0xFF), UInt8(back >> 8)]
    }

    /// `data` with `bytes` written over it from `offset` on.
    private func writing(_ bytes: [UInt8], at offset: Int, over data: Data) -> Data {
        var data = data
        data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        return data
    }

    // MARK: - RTF under another name

    func testRTFSamplesBeginAsRTFWhateverTheirName() throws {
        XCTAssertTrue(TextutilSourceCheck.beginsAsRTF(try copyOfFormatSample("rtf/headings.rtf")))
        XCTAssertTrue(TextutilSourceCheck.beginsAsRTF(try copyOfFormatSample("rtf/headings.rtf", named: "notes.doc")))
    }

    func testRTFBehindAByteOrderMarkAndBlankLinesStillBeginsAsRTF() throws {
        let sample = try copyOfFormatSample("rtf/headings.rtf")
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("\n \t\r\n".utf8) + (try Data(contentsOf: sample))
        XCTAssertTrue(TextutilSourceCheck.beginsAsRTF(try file(named: "bom.doc", holding: bytes)))
    }

    // MARK: - HTML under another name

    func testAWebPageBeginsAsHTMLWhateverItsNameOrCase() throws {
        XCTAssertTrue(TextutilSourceCheck.beginsAsHTML(try copyOfFormatSample("rtf/headings-source.html")))
        XCTAssertTrue(TextutilSourceCheck.beginsAsHTML(try copyOfFormatSample("rtf/headings-source.html", named: "page.doc")))
        for (index, text) in [
            "<html>", "<HTML lang=\"en\">", "<Html\n>", "<!doctype html>", "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\">",
            "<html/>", "<html",
        ].enumerated() {
            XCTAssertTrue(TextutilSourceCheck.beginsAsHTML(try file(named: "page\(index).doc", holding: Data(text.utf8))), text)
        }
    }

    func testAWebPageBehindAByteOrderMarkAndBlankLinesStillBeginsAsHTML() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("\r\n \t\n".utf8) + Data("<html><body>Hi</body></html>".utf8)
        XCTAssertTrue(TextutilSourceCheck.beginsAsHTML(try file(named: "bom.doc", holding: bytes)))
    }

    func testOtherFilesDoNotBeginAsHTML() throws {
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try copyOfFormatSample("rtf/headings.rtf")))
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try copyOfFormatSample("doc/headings.doc")))
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try copyOfFormatSample("odt/headings.odt")))
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try copyOfFormatSample("wordml/headings.wordml")))
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try copyOfFormatSample("rtfd/headings.rtfd")))
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try file(named: "empty.doc", holding: Data())))
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(URL(fileURLWithPath: "/nonexistent/missing.doc")))
        // Near misses: a longer name, another tag, text that only mentions the tag, a different doctype.
        for (index, text) in ["<htmlx>", "<head><title>t</title></head>", "Use <html> to start a page.", "<!DOCTYPE html5>", "<!DOCTYPE svg>", "<ht"]
            .enumerated() {
            XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try file(named: "near\(index).doc", holding: Data(text.utf8))), text)
        }
    }

    /// Only the first 1,024 bytes are read: a page whose first tag comes
    /// after more white space than that is not recognized.
    func testOnlyTheFirstKilobyteIsLookedAt() throws {
        let page = Data("<html>".utf8)
        let near = Data(repeating: 0x20, count: 1_024 - page.count) + page
        XCTAssertTrue(TextutilSourceCheck.beginsAsHTML(try file(named: "near.doc", holding: near)))
        let far = Data(repeating: 0x20, count: 1_024) + page
        XCTAssertFalse(TextutilSourceCheck.beginsAsHTML(try file(named: "far.doc", holding: far)))
    }

    func testOtherFilesDoNotBeginAsRTF() throws {
        XCTAssertFalse(TextutilSourceCheck.beginsAsRTF(try copyOfFormatSample("doc/headings.doc")))
        XCTAssertFalse(TextutilSourceCheck.beginsAsRTF(try copyOfFormatSample("odt/headings.odt")))
        XCTAssertFalse(TextutilSourceCheck.beginsAsRTF(try file(named: "empty.rtf", holding: Data())))
        XCTAssertFalse(TextutilSourceCheck.beginsAsRTF(try file(named: "plain.txt", holding: Data("Just some words.".utf8))))
        // A near miss: the control word is cut short.
        XCTAssertFalse(TextutilSourceCheck.beginsAsRTF(try file(named: "near.rtf", holding: Data(#"{\rt"#.utf8))))
        // The folder of an RTFD package, and a file that is not there.
        XCTAssertFalse(TextutilSourceCheck.beginsAsRTF(try copyOfFormatSample("rtfd/headings.rtfd")))
        let missing = try makeSandboxDirectory("SourceCheck").appendingPathComponent("missing.rtf")
        XCTAssertFalse(TextutilSourceCheck.beginsAsRTF(missing))
    }

    // MARK: - The File Information Block

    func testTheBlockIsFoundInEachWordSample() throws {
        let samples = [
            "doc/headings.doc",
            "doc/libreoffice-tdf104239_chapterNumbering.doc",
            "doc/libreoffice-tdf81705_outlineLevel.doc",
            "dot/headings-synthetic.dot",
            "dot/libreoffice-tdf120761_zOrder.dot",
        ]
        for sample in samples {
            let copy = try copyOfFormatSample(sample)
            XCTAssertNotNil(TextutilSourceCheck.fibOffset(in: try Data(contentsOf: copy)), sample)
            XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(copy), "\(sample) is not encrypted")
        }
    }

    func testTheBlockOfAShortDocumentLiesOffASectorBoundary() throws {
        // A stream under 4096 bytes lives in the compound file's mini
        // stream, so this real Word file's block is 64-aligned only.
        let copy = try copyOfFormatSample("doc/libreoffice-tdf104239_chapterNumbering.doc")
        XCTAssertEqual(try fibOffset(of: copy), 5312)
    }

    func testTheFoundBlockIsTheRealOneBecauseItsTemplateBitMatchesTheSample() throws {
        // The synthetic template sets fDot; the LibreOffice one does not.
        let synthetic = try copyOfFormatSample("dot/headings-synthetic.dot")
        XCTAssertEqual(try fibFlags(of: synthetic, at: try fibOffset(of: synthetic)) & 0x0001, 0x0001)
        let libreOffice = try copyOfFormatSample("dot/libreoffice-tdf120761_zOrder.dot")
        XCTAssertEqual(try fibFlags(of: libreOffice, at: try fibOffset(of: libreOffice)) & 0x0001, 0)
    }

    func testTheFinderSkipsTheHeaderSectorAndBadVersions() {
        // A valid block in the header sector is passed over, versions outside
        // 0x0065...0x0068 and 0x00C1...0x0200 are refused, and the good
        // Word 6 block at 1024 is found.
        var data = Data(count: 2048)
        data = writing(fibBytes(version: 0x00C1), at: 0, over: data)
        data = writing(fibBytes(version: 0x0064), at: 512, over: data)
        data = writing(fibBytes(version: 0x0201), at: 576, over: data)
        data = writing(fibBytes(version: 0x0065, back: 0), at: 1024, over: data)
        XCTAssertEqual(TextutilSourceCheck.fibOffset(in: data), 1024)
    }

    func testAModernBlockWithAWrongNFibBackIsPassedOver() {
        // A look-alike at 576 (nFib 0x00C1, nFibBack 0x0000) is passed over
        // and the valid block at 1024 is found; 0x00C1 is a valid nFibBack too.
        var data = Data(count: 2048)
        data = writing(fibBytes(version: 0x00C1, back: 0x0000), at: 576, over: data)
        data = writing(fibBytes(version: 0x0101, back: 0x00BF), at: 1024, over: data)
        XCTAssertEqual(TextutilSourceCheck.fibOffset(in: data), 1024)
        data = writing(fibBytes(version: 0x0101, back: 0x00C1), at: 1024, over: data)
        XCTAssertEqual(TextutilSourceCheck.fibOffset(in: data), 1024)
        data = writing(fibBytes(version: 0x0101, back: 0x00C0), at: 1024, over: data)
        XCTAssertNil(TextutilSourceCheck.fibOffset(in: data))
    }

    func testAVersionBetweenTheTwoRangesIsPassedOver() {
        // 0x0069 is above Word 95's range and below Word 97's.
        var data = Data(count: 2048)
        data = writing(fibBytes(version: 0x0069), at: 576, over: data)
        XCTAssertNil(TextutilSourceCheck.fibOffset(in: data))
        data = writing(fibBytes(version: 0x00C0), at: 576, over: data)
        XCTAssertNil(TextutilSourceCheck.fibOffset(in: data))
    }

    func testAFalseMatchBeforeTheRealBlockDoesNotMakeAReadableDocumentEncrypted() throws {
        // A look-alike with the encrypted bit set lies before the real,
        // unencrypted block, in a compound file.
        var bytes = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 2040)
        bytes = writing(fibBytes(version: 0x00C1, back: 0x1234, flags: 0x0100), at: 640, over: bytes)
        bytes = writing(fibBytes(version: 0x00C1, flags: 0x0000), at: 1024, over: bytes)
        XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(try file(named: "lookalike.doc", holding: bytes)))
    }

    func testABlockCutOffBeforeItsNFibBackIsNotFound() {
        // Only 12 of the block's 14 bytes lie in the data.
        let data = writing(Array(fibBytes(version: 0x00C1).prefix(12)), at: 512, over: Data(count: 512 + 12))
        XCTAssertNil(TextutilSourceCheck.fibOffset(in: data))
        // With its 14 bytes it is found.
        let whole = writing(fibBytes(version: 0x00C1), at: 512, over: Data(count: 512 + 14))
        XCTAssertEqual(TextutilSourceCheck.fibOffset(in: whole), 512)
    }

    // MARK: - A Word document with a password

    func testTheEncryptedBitMakesAWordDocumentEncrypted() throws {
        let copy = try copyOfFormatSample("doc/headings.doc")
        let offset = try fibOffset(of: copy)
        let flags = try fibFlags(of: copy, at: offset)

        try setFibFlags(flags | 0x0100, of: copy, at: offset)
        XCTAssertTrue(TextutilSourceCheck.isEncryptedWordDocument(copy))

        // Only the template bit set (everything else clear) is not encrypted.
        try setFibFlags(0x0001, of: copy, at: offset)
        XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(copy))
    }

    func testTheEncryptedBitIsFoundInAShortDocumentToo() throws {
        let copy = try copyOfFormatSample("doc/libreoffice-tdf104239_chapterNumbering.doc")
        let offset = try fibOffset(of: copy)
        try setFibFlags(try fibFlags(of: copy, at: offset) | 0x0100, of: copy, at: offset)
        XCTAssertTrue(TextutilSourceCheck.isEncryptedWordDocument(copy))
    }

    func testABlockPastTheFirstChunkIsFound() throws {
        // A compound-file header, zeros, then a block 200,000 bytes in
        // (past the 64 KB chunks the file is read in) with the bit set.
        var bytes = Data(count: 200_064)
        bytes.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        let offset = 200_000 - 200_000 % 64
        bytes = writing(fibBytes(version: 0x00C1, flags: 0x0100), at: offset, over: bytes)
        XCTAssertTrue(TextutilSourceCheck.isEncryptedWordDocument(try file(named: "late.doc", holding: bytes)))
    }

    func testFilesWithNoBlockAreNotEncryptedWordDocuments() throws {
        XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(try copyOfFormatSample("rtf/headings.rtf", named: "notes.doc")))
        XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(try file(named: "empty.doc", holding: Data())))
        // The compound-file signature followed by zeros holds no block.
        let signature = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 4096)
        XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(try file(named: "zeros.doc", holding: signature)))
        // A block with the bit set but no signature is no Word document.
        var unsigned = Data(count: 1024)
        unsigned = writing(fibBytes(version: 0x00C1, flags: 0x0100), at: 512, over: unsigned)
        XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(try file(named: "unsigned.doc", holding: unsigned)))
        let missing = try makeSandboxDirectory("SourceCheck").appendingPathComponent("missing.doc")
        XCTAssertFalse(TextutilSourceCheck.isEncryptedWordDocument(missing))
    }

    // MARK: - An OpenDocument package with a password

    func testAManifestWithEncryptionDataIsEncrypted() throws {
        let copy = try copyOfFormatSample("odt/handwritten.odt")
        try replaceManifest(in: copy, with: encryptedManifest)
        XCTAssertTrue(TextutilSourceCheck.isEncryptedOpenDocument(copy))
    }

    func testThePrefixOfTheElementDoesNotMatter() throws {
        let copy = try copyOfFormatSample("odt/handwritten.odt")
        let manifest = """
            <m:manifest xmlns:m="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">\
            <m:file-entry m:full-path="content.xml"><m:encryption-data m:checksum="AAAA"/></m:file-entry>\
            </m:manifest>
            """
        try replaceManifest(in: copy, with: manifest)
        XCTAssertTrue(TextutilSourceCheck.isEncryptedOpenDocument(copy))
    }

    func testThePlainOpenDocumentSamplesAreNotEncrypted() throws {
        for sample in ["odt/handwritten.odt", "odt/headings.odt", "ott/handwritten.ott"] {
            XCTAssertFalse(TextutilSourceCheck.isEncryptedOpenDocument(try copyOfFormatSample(sample)), sample)
        }
    }

    func testFilesThatAreNoOpenDocumentPackageAreNotEncrypted() throws {
        XCTAssertFalse(TextutilSourceCheck.isEncryptedOpenDocument(try copyOfFormatSample("rtf/headings.rtf")))
        XCTAssertFalse(TextutilSourceCheck.isEncryptedOpenDocument(try file(named: "empty.odt", holding: Data())))
        let missing = try makeSandboxDirectory("SourceCheck").appendingPathComponent("missing.odt")
        XCTAssertFalse(TextutilSourceCheck.isEncryptedOpenDocument(missing))

        // A ZIP with no manifest.
        XCTAssertFalse(TextutilSourceCheck.isEncryptedOpenDocument(try zip(holding: "content.xml", "<a/>")))
    }

    func testAManifestPastTheLimitIsNotRead() throws {
        // Padding takes the manifest past 1,000,000 bytes; its encryption
        // data lies after the padding and is never reached.
        let padding = String(repeating: " ", count: 1_000_001)
        let manifest = "<manifest>\(padding)<encryption-data/></manifest>"
        XCTAssertFalse(TextutilSourceCheck.isEncryptedOpenDocument(try zip(holding: "META-INF/manifest.xml", manifest)))
    }

    func testAManifestThatIsNotXMLIsNotEncrypted() throws {
        XCTAssertFalse(TextutilSourceCheck.isEncryptedOpenDocument(try zip(holding: "META-INF/manifest.xml", "not xml at all")))
    }

    // MARK: - The refusal

    func testThePasswordRefusalReadsWordForWord() {
        XCTAssertEqual(
            PasswordProtectedDocument().errorDescription,
            "This document is protected by a password. Save a copy without the password, then import that copy."
        )
    }
}
