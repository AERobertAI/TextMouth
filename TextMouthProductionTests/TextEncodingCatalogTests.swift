import XCTest
@testable import TextMouth

/// The catalog of text encodings the guesser draws on and a book records one
/// from (FMT16): every entry is an encoding Foundation reads, its identifier
/// finds it again, and each is named in words a listener understands.
final class TextEncodingCatalogTests: XCTestCase {

    /// The identifiers of the catalog, in order, as a book records them. A
    /// recorded identifier is looked up again on every later reading of the
    /// book, so none may be renamed or dropped without a reason: this list
    /// is what an older library holds.
    private let expectedIdentifiers = [
        "windows-1252", "macintosh", "iso-8859-15", "cp437", "cp850", "windows-1250", "iso-8859-2",
        "x-mac-centraleurroman", "windows-1251", "koi8-r", "koi8-u",
        "cp866", "iso-8859-5", "x-mac-cyrillic", "windows-1253", "iso-8859-7", "windows-1254", "iso-8859-9",
        "windows-1255", "iso-8859-8", "windows-1256", "iso-8859-6", "windows-1257", "iso-8859-13", "cp874", "cp932",
        "shift_jis", "euc-jp", "iso-2022-jp", "gb18030", "gbk", "cp936", "gb2312", "big5", "cp950", "euc-kr", "cp949",
    ]

    /// Every entry of the list is in the catalog, in order: no encoding is
    /// missing on this Mac's Core Foundation.
    func testTheCatalogHoldsEveryEncodingInOrder() {
        XCTAssertEqual(TextEncodingCatalog.entries.map(\.identifier), expectedIdentifiers)
    }

    /// An identifier is the encoding's IANA name in lowercase, as Core
    /// Foundation spells it, and finds the same encoding again.
    func testEachIdentifierIsTheEncodingsLowercaseNameAndFindsItAgain() {
        for entry in TextEncodingCatalog.entries {
            XCTAssertEqual(entry.identifier, entry.identifier.lowercased(), entry.identifier)
            let found = CFStringConvertIANACharSetNameToEncoding(entry.identifier as CFString)
            XCTAssertNotEqual(found, kCFStringEncodingInvalidId, entry.identifier)
            XCTAssertEqual(
                String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(found)), entry.encoding, entry.identifier
            )
            // The identifier is also the name Core Foundation gives the encoding.
            let canonicalName = CFStringConvertEncodingToIANACharSetName(found) as String?
            XCTAssertEqual(canonicalName?.lowercased(), entry.identifier)
        }
    }

    /// No two entries share an identifier, and none share an encoding: each
    /// entry is an encoding of its own.
    func testIdentifiersAndEncodingsAreUnique() {
        let identifiers = TextEncodingCatalog.entries.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        let encodings = TextEncodingCatalog.entries.map(\.encoding.rawValue)
        XCTAssertEqual(Set(encodings).count, encodings.count)
    }

    /// An identifier is found in any letter case, and an unknown one is not
    /// found.
    func testAnEntryIsFoundByItsIdentifierInAnyLetterCase() {
        XCTAssertEqual(TextEncodingCatalog.entry(forIdentifier: "windows-1251")?.name, "Windows-1251 (Cyrillic)")
        XCTAssertEqual(TextEncodingCatalog.entry(forIdentifier: "Windows-1251")?.identifier, "windows-1251")
        XCTAssertEqual(TextEncodingCatalog.entry(forIdentifier: "KOI8-R")?.identifier, "koi8-r")
        XCTAssertNil(TextEncodingCatalog.entry(forIdentifier: "x-klingon"))
        XCTAssertNil(TextEncodingCatalog.entry(forIdentifier: ""))
    }

    /// An entry is found by its encoding, and an encoding the catalog does
    /// not hold is not.
    func testAnEntryIsFoundByItsEncoding() {
        XCTAssertEqual(TextEncodingCatalog.entry(for: .windowsCP1251)?.identifier, "windows-1251")
        XCTAssertEqual(TextEncodingCatalog.entry(for: .macOSRoman)?.identifier, "macintosh")
        XCTAssertEqual(TextEncodingCatalog.entry(for: .windowsCP1252)?.identifier, TextEncodingCatalog.windows1252Identifier)
        XCTAssertNil(TextEncodingCatalog.entry(for: .utf8))
        XCTAssertNil(TextEncodingCatalog.entry(for: .isoLatin1))
    }

    /// A listener hears the encoding's name, then the language or script it
    /// is for; a name for an identifier the catalog does not know is the
    /// identifier itself, so that nothing recorded is left unnamed.
    func testNamesSayTheEncodingAndWhatItIsFor() {
        let names: [(identifier: String, name: String)] = [
            ("windows-1252", "Windows-1252 (Western European)"),
            ("macintosh", "Mac Roman (Western European)"),
            ("cp437", "CP437 (US DOS)"),
            ("cp850", "CP850 (Western European DOS)"),
            ("windows-1250", "Windows-1250 (Central European)"),
            ("iso-8859-2", "ISO 8859-2 (Central European)"),
            ("x-mac-centraleurroman", "Mac Central European"),
            ("windows-1251", "Windows-1251 (Cyrillic)"),
            ("koi8-r", "KOI8-R (Russian)"),
            ("cp866", "CP866 (Russian DOS)"),
            ("windows-1253", "Windows-1253 (Greek)"),
            ("cp874", "Windows-874 (Thai)"),
            ("cp932", "Shift JIS (Japanese)"),
            ("euc-jp", "EUC-JP (Japanese)"),
            ("gb18030", "GB 18030 (Simplified Chinese)"),
            ("big5", "Big5 (Traditional Chinese)"),
            ("euc-kr", "EUC-KR (Korean)"),
        ]
        for (identifier, name) in names {
            XCTAssertEqual(TextEncodingCatalog.name(forIdentifier: identifier), name, identifier)
        }
        XCTAssertEqual(TextEncodingCatalog.name(forIdentifier: "x-klingon"), "x-klingon")
    }

    /// The DOS code pages and Mac Central European are in the catalog, so a
    /// Foundation guess of them is no longer dropped: found by their
    /// encodings, named apart so the Text Encoding pop-up offers each, and
    /// taken only on Foundation's word.
    func testTheDOSCodePagesAndMacCentralEuropeanAreCataloguedAndOnlyHinted() throws {
        for (identifier, name) in [
            ("cp437", "CP437 (US DOS)"), ("cp850", "CP850 (Western European DOS)"),
            ("x-mac-centraleurroman", "Mac Central European"),
        ] {
            let entry = try XCTUnwrap(TextEncodingCatalog.entry(forIdentifier: identifier), identifier)
            XCTAssertEqual(entry.name, name)
            XCTAssertFalse(entry.isAlwaysTried, "\(identifier) is tried only when Foundation names it")
            XCTAssertEqual(TextEncodingCatalog.entry(for: entry.encoding), entry, "found by its encoding, as a Foundation guess is")
            XCTAssertTrue(
                TextEncodingChoices.options.contains(.encoding(identifier)),
                "\(identifier) is offered by the Text Encoding pop-up"
            )
        }
    }

    /// The only 7-bit encoding is ISO-2022-JP, which is valid UTF-8 and so is
    /// looked for before UTF-8 is.
    func testOnlyISO2022JPIsASevenBitEncoding() {
        XCTAssertEqual(TextEncodingCatalog.entries.filter(\.isSevenBit).map(\.identifier), ["iso-2022-jp"])
    }

    /// The guesser always tries the encodings Foundation's own guess cannot
    /// find (Mac Roman, ISO 8859-15, Central European, Cyrillic) and the one
    /// it confuses with them (Hebrew, which a short text reads as clean
    /// Cyrillic), and takes the rest only when Foundation names them.
    func testTheEncodingsAlwaysTriedAreTheOnesFoundationMisses() {
        let tried = TextEncodingCatalog.entries.filter(\.isAlwaysTried).map(\.identifier)
        XCTAssertEqual(tried, [
            "macintosh", "iso-8859-15", "windows-1250", "iso-8859-2", "windows-1251", "koi8-r", "koi8-u", "cp866",
            "iso-8859-5", "x-mac-cyrillic", "windows-1255",
        ])
        XCTAssertFalse(tried.contains(TextEncodingCatalog.windows1252Identifier))
    }
}
