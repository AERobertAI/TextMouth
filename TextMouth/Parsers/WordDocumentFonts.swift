import Foundation

// MARK: - The Font Table

/// The fonts of a Word document (SttbfFfn, [MS-DOC] 2.9.268): for each, in the order a run's font index
/// (`sprmCFtc` in Word 6 and Word 95, `sprmCSymbol`'s font in every version) counts them, the name and the
/// character set. Two things are read from them: the character set names the code page a Word 6 or Word 95
/// run's text is in, and the name says whether a symbol is a character of the Symbol font, which has words
/// to read, or of a font of pictures (Wingdings and the like), which has none.
///
/// A font is a size byte (the bytes after it), a byte of flags, the 16-bit weight, the character set, and a
/// byte for the place of a second name; Word 97 then has 10 bytes of PANOSE and 24 of font signature before
/// the name in UTF-16, where Word 6 and Word 95 have the name in 8 bits at once. Every size is checked
/// against the table, and what does not fit is where the table ends.
struct WordFontTable {

    /// The most fonts read: a table is short, and a file could make it as long as its stream.
    private static let mostFonts = 4096

    /// The fonts' names, lowercased, in order.
    let names: [String]
    /// The fonts' character sets (`chs`: 0 ANSI, 2 symbol, 128 Shift JIS, 204 Cyrillic, and so on), in order.
    let characterSets: [Int]

    /// A document with no font table.
    static let none = WordFontTable(names: [], characterSets: [])

    /// The indexes of the fonts whose codes are the Symbol encoding's (the font named Symbol and its clones).
    var symbolFonts: Set<Int> {
        Set(names.indices.filter { reading(ofFont: $0) == .adobeSymbol })
    }

    /// How the codes of font `font` are read (`WordSymbolFontEncodings`), or nil for a font the table does not hold.
    func reading(ofFont font: Int) -> WordSymbolFontEncodings.Reading? {
        guard names.indices.contains(font), characterSets.indices.contains(font) else { return nil }
        return WordSymbolFontEncodings.reading(ofFontNamed: names[font], characterSet: characterSets[font])
    }

    /// The character the code `code` of font `font` stands for, or nil when it stands for none a voice can
    /// speak (the caller reads a space): the code through the font's own layout. A font not in the table
    /// is read as pictures.
    func symbolScalar(forCode code: Int, inFont font: Int) -> Unicode.Scalar? {
        guard let reading = reading(ofFont: font) else { return nil }
        // An ordinary font's code is a character of the code page of the font's own character set.
        let page = WordLegacyCharacters.codePage(ofFontCharacterSet: characterSets[font]).flatMap {
            WordLegacyCharacters.encoding(named: $0)
        }
        return WordSymbolFontEncodings.scalar(forCode: code, reading: reading, codePage: page)
    }

    // MARK: Reading

    /// The font table of a Word 6 or Word 95 document at `range` in `document`: a 16-bit size, then the
    /// fonts, each with its name in 8 bits (ASCII is all a name is asked for) after 6 bytes.
    /// - Throws: `OLEDamage` when a read runs past the stream (the fonts read before it are not kept).
    static func legacy(range: Range<Int>, in document: OLEBytes) throws -> WordFontTable {
        guard range.count >= 2 else { return .none }
        return try fonts(in: range, after: 2, nameOffset: 6, bytesPerCharacter: 1, in: document)
    }

    /// The font table of a Word 97 or later document at `range` in `table`: a count and a size of extra data
    /// (both 16 bits), then the fonts, each with its name in UTF-16 after 40 bytes.
    static func modern(range: Range<Int>, in table: OLEBytes) throws -> WordFontTable {
        guard range.count >= 4 else { return .none }
        let extra = try table.u16(range.lowerBound + 2)
        return try fonts(in: range, after: 4 + extra, nameOffset: 40, bytesPerCharacter: 2, in: table)
    }

    /// The fonts that follow `skipped` bytes from the start of `range`.
    private static func fonts(
        in range: Range<Int>, after skipped: Int, nameOffset: Int, bytesPerCharacter: Int, in bytes: OLEBytes
    ) throws -> WordFontTable {
        var names: [String] = []
        var sets: [Int] = []
        var position = range.lowerBound + skipped
        // Each font takes at least its fixed part, which bounds the walk.
        while position + nameOffset <= range.upperBound, names.count < mostFonts {
            let size = try bytes.u8(position)
            let end = position + size + 1
            guard size >= nameOffset - 1, end <= range.upperBound else { break }
            sets.append(try bytes.u8(position + 4))
            // The name, up to its null or the font's end.
            var name = ""
            var at = position + nameOffset
            while at + bytesPerCharacter <= end {
                let unit = try bytesPerCharacter == 1 ? bytes.u8(at) : bytes.u16(at)
                if unit == 0 { break }
                name.unicodeScalars.append(Unicode.Scalar(UInt32(unit)) ?? " ")
                at += bytesPerCharacter
            }
            names.append(name.lowercased())
            position = end
        }
        return WordFontTable(names: names, characterSets: sets)
    }
}
