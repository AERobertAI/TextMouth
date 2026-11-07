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
    private static let symbolClones: Set<String> = ["symbol", "mt symbol", "symbolps"]

    /// The codes of the WordPerfect fonts that the real documents settle, by font name (lowercased).
    private static let tables: [String: [Int: Unicode.Scalar]] = [
        // Typographic symbols: the curly quotation marks, the bullet, the section sign, the inverted question mark.
        "wp typographicsymbols": [
            0x3D: "\u{2019}", 0x3E: "\u{2018}", 0x41: "\u{201C}", 0x40: "\u{201D}",
            0x24: "\u{2022}", 0x27: "\u{00A7}", 0x29: "\u{00BF}", 0x43: "\u{2014}",
        ],
        // Math symbols: the degree sign, the bullet, and the micro sign (a unit: "100 micrometres" must not read "100 m").
        "wp matha": [0x45: "\u{00B0}", 0x43: "\u{2022}", 0x46: "\u{00B5}"],
        // The Greek fonts: the micro sign, in a unit.
        "wp greek courier": [0x3A: "\u{00B5}"],
        "wp greek century": [0x3A: "\u{00B5}"],
    ]

    /// The names (lowercased) that begin the fonts of pictures.
    private static let pictureFontPrefixes = ["wingdings", "webdings", "zapfdingbats", "zapf dingbats", "monotype sorts", "dingbats", "wp "]

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
    /// - Parameter isPrivateUse: whether Word 97 stored the code as U+F0xx (its code plus 0xF000: text typed in a
    ///   symbol font, or a symbol whose character is so stored). In an ordinary text font that is read through the
    ///   Symbol table, not the font's code page, as textutil reads it. What the rule buys: maths typed this way reads
    ///   as itself (`p` is pi, `D` is delta, `m` is mu: the code page would read 100 micrometres as `100mm`, a
    ///   measurement a thousand times out). What it costs: of the 134 such characters in 11 real documents only about
    ///   half are maths. The rest are checkboxes or nothing (one government form sets its checkboxes in Arial, and
    ///   they read as theta; the code page would read them as `q`, no better), a digit that is a picture's code, and
    ///   spaces.
    static func scalar(forCode code: Int, reading: Reading, codePage: String.Encoding? = nil, isPrivateUse: Bool = false) -> Unicode.Scalar? {
        switch reading {
        case .adobeSymbol:
            return AdobeSymbolEncoding.wordScalar(forCode: code)
        case .table(let table):
            return table[code]
        case .pictures:
            return nil
        case .text:
            return isPrivateUse ? AdobeSymbolEncoding.wordScalar(forCode: code) : textScalar(forCode: code, codePage: codePage)
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

    /// The character the code `code` of the font named `name` stands for, or nil when it stands for none a
    /// voice can speak: the font's reading (`reading(ofFontNamed:characterSet:)`) and, for an ordinary font,
    /// the code page of its character set. The one place a font and a code become a character, for the Word 97
    /// reader (`WordFontTable.symbolScalar`) and for the readers of DOCX and Word 2003 XML (`WordXMLFonts`).
    /// - Parameter name: the font's name, in any case.
    /// - Parameter characterSet: the font's `chs` (0 when the document does not say).
    static func scalar(forCode code: Int, inFontNamed name: String, characterSet: Int, isPrivateUse: Bool) -> Unicode.Scalar? {
        let page = WordLegacyCharacters.codePage(ofFontCharacterSet: characterSet).flatMap {
            WordLegacyCharacters.encoding(named: $0)
        }
        return scalar(
            forCode: code, reading: reading(ofFontNamed: name.lowercased(), characterSet: characterSet),
            codePage: page, isPrivateUse: isPrivateUse)
    }
}

// MARK: - A Document's Fonts, as XML Names Them

/// What the readers of DOCX (`w:sym`, `w:rFonts`) and of Word 2003 XML need of a document's fonts to read a
/// symbol as the Word 97 reader does: the character set each font declares (`w:charset` in the font table,
/// a hexadecimal byte, 2 for a font of symbols), by lowercased name. The tables that say what a code of a font
/// means are `WordSymbolFontEncodings`'s, the Word 97 reader's, and not a second set.
struct WordXMLFonts: Equatable {

    /// The character set (`chs`) each font declares, by the font's name in lowercase.
    var characterSets: [String: Int] = [:]

    /// Notes that the font named `name` declares the character set given as the hexadecimal `value`
    /// (`w:charset w:val`); a value that is not a byte is no declaration.
    mutating func declare(font name: String, characterSet value: String?) {
        guard !name.isEmpty, let value, let set = Int(value, radix: 16), (0...255).contains(set) else { return }
        characterSets[name.lowercased()] = set
    }

    /// What a symbol (`w:sym`, with its `w:font` and `w:char`) reads as: the character the font's own layout
    /// gives the code, as in Word 97, where a character in U+F000 to U+F0FF stands for its low byte; and a
    /// space where the font gives none (a font of pictures, a code no table settles, no font named), so that the
    /// words on either side do not run together. `character` is nil when `w:char` is not hexadecimal.
    func symbol(font: String?, character: Int?) -> Unicode.Scalar {
        guard let font, !font.isEmpty, let character else { return " " }
        let isPrivateUse = (0xF000...0xF0FF).contains(character)
        return WordSymbolFontEncodings.scalar(
            forCode: isPrivateUse ? character & 0xFF : character, inFontNamed: font,
            characterSet: characterSets[font.lowercased()] ?? 0, isPrivateUse: isPrivateUse) ?? " "
    }

    /// The font a `w:rFonts` element names: the first of `keys` (its attributes for the Latin letters and symbols, in
    /// the order to try) that holds a name, or nil when none does. A font named by a theme only is none.
    static func name(in attributes: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let name = attributes[key], !name.isEmpty { return name }
        }
        return nil
    }

    /// The most that `w:char` may say: four hexadecimal digits.
    private static let mostCharacterDigits = 4

    /// The number a `w:char` value gives, or nil when it is not up to four hexadecimal digits (a sign, which
    /// `Int(_:radix:)` accepts, is no digit: a negative code would trap the tables).
    static func character(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.utf8.count <= mostCharacterDigits,
              value.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) })
        else { return nil }
        return Int(value, radix: 16)
    }

    /// Whether `text` may hold text typed in a symbol font (a character in U+F020 to U+F0FF, which is three
    /// bytes in UTF-8 and begins with 0xEF): a cheap look for the callers that ask for every piece of text.
    static func mayHoldSymbolText(_ text: String) -> Bool {
        text.utf8.contains(0xEF)
    }

    /// `text` with each character in U+F020 to U+F0FF, which Word 97 and later store for text typed in a symbol
    /// font (its code plus 0xF000), read through the font of the run, `fontName`, as the Word 97 reader reads it:
    /// the code through the font's layout, and a space where it gives none. An ordinary font reads such a
    /// character through the Symbol table, as textutil does. With no font named the text is left as it is.
    func readingSymbolText(_ text: String, inFont fontName: String?) -> String {
        guard let fontName, !fontName.isEmpty, Self.mayHoldSymbolText(text),
              text.unicodeScalars.contains(where: { (0xF020...0xF0FF).contains($0.value) }) else { return text }
        let characterSet = characterSets[fontName.lowercased()] ?? 0
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if (0xF020...0xF0FF).contains(scalar.value) {
                result.append(WordSymbolFontEncodings.scalar(
                    forCode: Int(scalar.value & 0xFF), inFontNamed: fontName, characterSet: characterSet, isPrivateUse: true) ?? " ")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
