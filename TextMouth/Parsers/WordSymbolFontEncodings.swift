import Foundation

// MARK: - How a Symbol-Like Font's Codes Are Read

/// What a code of a font stands for when Word shows it as a symbol, for the fonts a real document uses
/// for symbols. Word's Insert Symbol stores a character as the font and a code of that font, and Word 97
/// stores text typed in a symbol font as U+F020 to U+F0FF (the code plus 0xF000). The code means
/// something only in the font's own layout, so the font decides, by its name:
/// - the font named Symbol, and its clones: the Adobe Symbol encoding (`AdobeSymbolEncoding`);
/// - the WordPerfect fonts that carry punctuation and letters, by the small tables below;
/// - a font of pictures (Wingdings, Webdings, Zapf Dingbats, Monotype Sorts, a WordPerfect font with
///   no table, any font of the symbol character set): nothing a voice can say;
/// - any other font is a text font, and its code is the character of its own code page.
///
/// Each code in the tables below was settled from the real documents, not from a reader of WordPerfect's
/// files: it stands, over and over, in the middle of a word or between the quotes of a sentence that has
/// only one reading (a code inside `firm_s` is an apostrophe; a code that opens and one that closes a
/// quotation are the two quotation marks). A code with no such reading is not in a table, and is read as
/// a space, so that the words on either side of it do not run together.
enum WordSymbolFontEncodings {

    /// How a font's codes are read.
    enum Reading: Equatable {
        /// The Adobe Symbol encoding.
        case adobeSymbol
        /// The characters of the code page of the font's own character set, as an ordinary font's are.
        case text
        /// Only the codes of a table mean a character; the rest, and every other code, are pictures.
        case table([Int: Unicode.Scalar])
        /// Pictures only.
        case pictures
    }

    /// The fonts that are the Symbol encoding under another name (lowercased).
    private static let symbolClones: Set<String> = ["symbol", "mt symbol"]

    /// The codes of the WordPerfect fonts that the real documents settle, by font name (lowercased).
    private static let tables: [String: [Int: Unicode.Scalar]] = [
        // Typographic symbols: the curly quotation marks, the bullet, the section sign, the inverted question mark.
        "wp typographicsymbols": [
            0x3D: "\u{2019}", 0x3E: "\u{2018}", 0x41: "\u{201C}", 0x40: "\u{201D}",
            0x24: "\u{2022}", 0x27: "\u{00A7}", 0x29: "\u{00BF}",
        ],
        // Math symbols: the degree sign and the bullet.
        "wp matha": [0x45: "\u{00B0}", 0x43: "\u{2022}"],
        // The Greek fonts: the micro sign, in a unit.
        "wp greek courier": [0x3A: "\u{00B5}"],
        "wp greek century": [0x3A: "\u{00B5}"],
    ]

    /// The names (lowercased) that begin the fonts of pictures.
    private static let pictureFontPrefixes = ["wingdings", "webdings", "zapf", "monotype sorts", "dingbats", "wp "]

    /// The character set (`chs`) of a font of symbols: its codes are the font's own and no code page's.
    private static let symbolCharacterSet = 2

    /// How the font named `name` (lowercased), of character set `characterSet`, is read.
    static func reading(ofFontNamed name: String, characterSet: Int) -> Reading {
        if symbolClones.contains(name) { return .adobeSymbol }
        if let table = tables[name] { return .table(table) }
        if characterSet == symbolCharacterSet || pictureFontPrefixes.contains(where: { name.hasPrefix($0) }) { return .pictures }
        return .text
    }

    /// The character the code `code` of a font read as `reading` stands for, or nil when it stands for
    /// none a voice can speak (a picture, a code the font's table does not settle, a space or control).
    /// - Parameter codePage: the encoding of an ordinary font's own character set (nil: Windows-1252).
    static func scalar(forCode code: Int, reading: Reading, codePage: String.Encoding? = nil) -> Unicode.Scalar? {
        switch reading {
        case .adobeSymbol:
            return AdobeSymbolEncoding.wordScalar(forCode: code)
        case .table(let table):
            return table[code]
        case .pictures:
            return nil
        case .text:
            return textScalar(forCode: code, codePage: codePage)
        }
    }

    /// The character of an ordinary font's code: a code of one byte is the character of the font's code
    /// page, a larger one is the character itself. A control or a space is none.
    private static func textScalar(forCode code: Int, codePage: String.Encoding?) -> Unicode.Scalar? {
        var scalar: Unicode.Scalar?
        if (0x80...0xFF).contains(code) {
            let decoded = String(data: Data([UInt8(code)]), encoding: codePage ?? .windowsCP1252)
            scalar = decoded?.unicodeScalars.first
        } else {
            scalar = Unicode.Scalar(UInt32(code))
        }
        guard let scalar, scalar.value > 0x20, !scalar.properties.isWhitespace, scalar != "\u{FFFD}",
              !(0x7F...0x9F).contains(scalar.value) else { return nil }
        return scalar
    }
}
