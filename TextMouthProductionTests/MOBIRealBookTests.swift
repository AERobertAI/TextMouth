import CryptoKit
import XCTest
@testable import TextMouth

/// Real Kindle (MOBI) books that came from outside (FMT42), kept in
/// `TestData/format-samples/mobi` as regression tests of the reader: a
/// kindlegen book in HUFF/CDIC, a Windows-1252 book, an early Mobipocket
/// book in TEXtREAd whose text is HTML, a hybrid with a contents, and a
/// Mobipocket Creator book with trailing entries. Their texts were decoded
/// by an independent Python decoder (a port of foliate-js's mobi.js), and
/// each test pins the SHA-256 of the text `MOBIText.bytes(of:headers:)`
/// returns, the text cut at its declared length, against that decoder's.
final class MOBIRealBookTests: XCTestCase {

    // MARK: - Helpers

    /// The sample's database, its headers, and the text the reader decodes.
    private func decoded(_ sample: String) throws -> (headers: MOBIHeaders, text: [UInt8]) {
        let bytes = [UInt8](try Data(contentsOf: formatSampleURL("mobi/\(sample)")))
        let database = try MOBIPalmDatabase(bytes: bytes)
        let headers = try MOBIHeaders(
            record0: try database.record(0, "Record 0"),
            requiresMOBIHeader: database.type == MOBIPalmDatabase.mobiSignature.type
        )
        return (headers, try MOBIText.bytes(of: database, headers: headers))
    }

    /// The SHA-256 of `bytes`, in lowercase hexadecimal.
    private func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The sample read into chapters, as an import reads it.
    private func book(_ sample: String) throws -> MOBIParser.PreparedBook {
        try MOBIParser.prepareBook(url: copyOfFormatSample("mobi/\(sample)"))
    }

    /// The book's chapters' words as one text, white space made single spaces.
    private func words(of book: MOBIParser.PreparedBook) -> String {
        book.chapters.map(\.chapter.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The first sentence of libmobi's own sample text, which three samples begin with.
    private let libmobiOpening = "This is a sample for testing libmobi project."

    // MARK: - libmobi's HUFF/CDIC hybrid

    func testTheHuffmanBookDecodesToTheSameTextAsTheIndependentDecoder() throws {
        let sample = try decoded("libmobi-unicode-huffdic.mobi")
        XCTAssertEqual(sample.headers.compression, 17480)
        XCTAssertEqual(sample.headers.encoding, 65001)
        // The same digest as libmobi's uncompressed twin of this book.
        XCTAssertEqual(digest(sample.text), "5b71c8e745d6a9d0e7d2df6913722dee4d02b88eddc985122365598b0fb9c003")
    }

    func testTheHuffmanBookIsAHybridReadAsItsMOBI6PartAndOpensWithItsNames() throws {
        let sample = try decoded("libmobi-unicode-huffdic.mobi")
        XCTAssertEqual(sample.headers.exthNumber(MOBIHeaders.EXTHType.kf8Boundary), 46)
        let opened = try book("libmobi-unicode-huffdic.mobi")
        XCTAssertEqual(opened.author, "Bartek Fabiszewski")
        XCTAssertTrue(words(of: opened).hasPrefix(libmobiOpening), String(words(of: opened).prefix(120)))
    }

    // MARK: - libmobi's Windows-1252 book

    func testTheWindows1252BookTakesThe1252RouteAndDecodesToTheIndependentDecodersText() throws {
        let sample = try decoded("libmobi-cp1252.mobi")
        XCTAssertEqual(sample.headers.encoding, 1252)
        XCTAssertEqual(sample.headers.compression, 2)
        XCTAssertEqual(digest(sample.text), "3f53f73fb33aca66668256097ec195b1c89a3c250a1eeec45534cd65a26a37b6")
        // The book has no byte over 127, so the route is pinned, not a character.
        XCTAssertFalse(sample.text.contains { $0 > 127 })
        XCTAssertTrue(words(of: try book("libmobi-cp1252.mobi")).hasPrefix(libmobiOpening))
    }

    // MARK: - libmobi's TEXtREAd book

    func testTheTextReadBookIsPlainPalmDOCWithHTMLTextAndDecodesToTheIndependentDecodersText() throws {
        let sample = try decoded("libmobi-textread.mobi")
        XCTAssertFalse(sample.headers.hasMOBIHeader)
        XCTAssertEqual(sample.headers.compression, 1)
        XCTAssertEqual(digest(sample.text), "e8dc72cca9193b2d026aada8414a6b496c3797cc9ba4c05d7a7a19f5c7299e92")
    }

    func testTheTextReadBookIsReadAsHTMLWithItsHeadLeftOut() throws {
        let opened = try book("libmobi-textread.mobi")
        let text = words(of: opened)
        XCTAssertTrue(text.hasPrefix(libmobiOpening), String(text.prefix(120)))
        XCTAssertFalse(text.contains("<"))
        XCTAssertFalse(text.contains("dc-metadata"))
        XCTAssertFalse(text.hasPrefix("Libmobi test sample"))
    }

    // MARK: - Project Gutenberg's Ghosts, a kindlegen hybrid

    func testGhostsDecodesToTheIndependentDecodersText() throws {
        XCTAssertEqual(
            digest(try decoded("pg8121-ghosts-hybrid.mobi").text),
            "80493892a9de2e011507c02c8d631dd811b28bd18c0189c7c4ceafacb71a91b9")
    }

    func testGhostsHasItsNamesAndChaptersFromItsContents() throws {
        let opened = try book("pg8121-ghosts-hybrid.mobi")
        XCTAssertEqual(opened.title, "Ghosts")
        XCTAssertEqual(opened.author, "Henrik Ibsen")
        XCTAssertGreaterThan(opened.chapters.count, 1)
        XCTAssertTrue(words(of: opened).contains("Théâtre Libre"))
    }

    // MARK: - Langenhoven's Kootjie Totjie, from Mobipocket Creator

    func testKootjieTotjieDecodesWithItsTwoTrailingEntriesAndTheMultibyteOverlapTakenOff() throws {
        let sample = try decoded("langenhoven-kootjie-totjie.mobi")
        XCTAssertEqual(sample.headers.extraDataFlags, 0b111)
        XCTAssertEqual(digest(sample.text), "1b5e718025cb302f868a3e436d78f0ee60e233463e4d2288ca6d396f6cc6fb65")
    }

    func testKootjieTotjieHasItsNamesAndItsAfrikaansWords() throws {
        let opened = try book("langenhoven-kootjie-totjie.mobi")
        XCTAssertEqual(opened.title, "Kootjie Totjie")
        XCTAssertEqual(opened.author, "C.J. Langenhoven")
        XCTAssertTrue(words(of: opened).contains("ná die derde droom"))
    }
}
