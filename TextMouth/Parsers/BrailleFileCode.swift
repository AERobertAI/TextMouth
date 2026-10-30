import Foundation

// MARK: - A Seven-Bit Table

/// The table of one seven-bit, six-dot braille file code (braillecodes): the
/// printable ASCII character a BRF or BRL file writes for each of the 64
/// six-dot cells, and the other characters a file may hold for the same
/// cells, which are read as those (`readingAliases`).
///
/// Which characters stand for which cells differs from country to country,
/// and nothing in a file says which code it uses
/// (BRAILLE-CODES-RESEARCH-2026-10-25.md, sections 5 and 7), so each code is
/// one table of data: the reader and the writer look cells up in it, and a
/// code's own reading rules (North American Braille ASCII's lowercase,
/// Eurobraille's capitals and DEL) are its aliases, never the reader's.
struct SevenBitBrailleTable: Equatable, Sendable {
    /// The byte the code writes for each six-dot cell, at the cell's dot
    /// value 0 to 63 (dot 1 counts 1, dot 6 counts 32): 64 distinct printable
    /// ASCII bytes, the blank cell's first.
    let bytes: [UInt8]

    /// For each of the 256 byte values, the dot value of the cell it is read
    /// as, or `noCell`: one lookup for each byte a file holds, with no branch
    /// on the byte's range.
    private let dotsByByte: [UInt8]

    /// The entry of `dotsByByte` for a byte that stands for no cell. No
    /// six-dot cell has this dot value, which needs dots 7 and 8.
    private static let noCell: UInt8 = 0xFF

    /// The table whose 64 characters, in the order of the cells' dot values,
    /// are `characters` (an ASCII string, the blank cell's character first),
    /// and which reads each byte of `readingAliases` as the byte it maps to.
    ///
    /// It never traps: the two tables TextMouth has are constants whose 64
    /// distinct bytes `BrailleFileCodeTests` pins, against liblouis's own
    /// files. A byte that repeats takes its last cell, and an alias whose
    /// target is no cell reads as no cell.
    init(characters: String, readingAliases: [UInt8: UInt8]) {
        bytes = Array(characters.utf8)
        var dots = [UInt8](repeating: Self.noCell, count: 256)
        for (value, byte) in bytes.enumerated() where value < 64 {
            dots[Int(byte)] = UInt8(value)
        }
        // Every alias reads as its target, so set them after the table's own.
        for (alias, target) in readingAliases {
            dots[Int(alias)] = dots[Int(target)]
        }
        dotsByByte = dots
    }

    /// The dot value of the cell `byte` stands for (an alias reads as its
    /// target), or nil for a byte that is no cell in this code: a control
    /// character, or a byte past ASCII, or one the code does not use.
    func dots(forByte byte: UInt8) -> UInt8? {
        let dots = dotsByByte[Int(byte)]
        return dots == Self.noCell ? nil : dots
    }

    /// The byte this code writes for the six-dot cell of `dots`, of which
    /// only the low six bits (dots 1 to 6) count. An index past `bytes`,
    /// which neither of TextMouth's tables has, gives the space, never a trap.
    func byte(forDots dots: UInt8) -> UInt8 {
        let index = Int(dots & 0x3F)
        return index < bytes.count ? bytes[index] : UInt8(ascii: " ")
    }

    /// The braille pattern, U+2800 plus the dots, of the cell `byte` stands
    /// for, or nil for a byte that is no cell in this code.
    func cell(forByte byte: UInt8) -> Unicode.Scalar? {
        dots(forByte: byte).flatMap { Unicode.Scalar(0x2800 + UInt32($0)) }
    }

    /// The byte this code writes for the six-dot braille pattern `cell`,
    /// U+2800 to U+283F; nil for any other scalar, an eight-dot cell or a
    /// letter.
    func byte(forCell cell: Unicode.Scalar) -> UInt8? {
        guard BrailleCells.isPattern(cell), !BrailleCells.usesEightDots(cell) else { return nil }
        return byte(forDots: UInt8(truncatingIfNeeded: cell.value))
    }

    // MARK: The Tables

    /// North American Braille ASCII: the space is the blank cell, "A" is dot
    /// 1, and "=" is all six dots. Verified 64 cells of 64 against liblouis's
    /// own `en-us-brf.dis`, vendored unchanged from liblouis 3.39.0
    /// (`BrailleFileCodeTests`; also FORMATS-RESEARCH-2026-10-17.md, section
    /// 3.2).
    ///
    /// Files also write it in lowercase, 0x60 to 0x7E, each standing for the
    /// same six dots as the character 0x20 below it: a lowercase letter is
    /// read as its capital, and `` ` { | } ~ `` as `@ [ \ ] ^` (in eight-dot
    /// computer braille the two differ only by dot 7, which a six-dot file
    /// has not got). liblouis's `text_nabcc.dis` agrees on all 31.
    static let northAmerican: SevenBitBrailleTable = {
        var aliases: [UInt8: UInt8] = [:]
        // Lowercase, 0x60 to 0x7E, reads as the character 0x20 below.
        for byte in UInt8(0x60)...UInt8(0x7E) {
            aliases[byte] = byte - 0x20
        }
        return SevenBitBrailleTable(
            characters: #" A1B'K2L@CIF/MSP"E3H9O6R^DJG>NTQ,*5<-U8V.%[$+X!&;:4\0Z7(_?W]#Y)="#,
            readingAliases: aliases
        )
    }()

    /// Eurobraille, six-dot, as the Swiss library for the blind (SBS Zürich,
    /// 2009) wrote it in liblouis's `de-eurobrl6.dis`: "widely being used in
    /// german speaking parts of europe". Its letters are lowercase, and 33 of
    /// its 64 characters stand for other cells than in North American Braille
    /// ASCII (the digits, most punctuation, and the cells of ä, ö, ü, and ß),
    /// none of them invalid there. Verified 64 cells of 64 against that file,
    /// vendored unchanged from liblouis 3.39.0 (`BrailleFileCodeTests`).
    ///
    /// Its aliases read the code's other written forms:
    /// - the capitals A to Z as the letters a to z, and `@ [ \ ] ^` as
    ///   `` ` { | } ~ ``: the same code in capitals, `de-eurobrl6u.dis`,
    ///   which is "sometimes" used in Switzerland, is the lowercase form with
    ///   every character 0x60 to 0x7E written 0x20 lower;
    /// - DEL, 0x7F, as `_` (dots 4-5-6): the standard writes that cell as
    ///   DEL, and the table as `_`, which its author found "more convenient
    ///   and used more widely".
    static let eurobraille: SevenBitBrailleTable = {
        var aliases: [UInt8: UInt8] = [:]
        // The capitals A to Z read as the letters a to z.
        for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") {
            aliases[byte] = byte + 0x20
        }
        // @ [ \ ] ^ read as ` { | } ~, the capitals form's five punctuation cells.
        for byte in [UInt8(ascii: "@"), UInt8(ascii: "["), UInt8(ascii: "\\"), UInt8(ascii: "]"), UInt8(ascii: "^")] {
            aliases[byte] = byte + 0x20
        }
        // DEL reads as _, the standard's character for dots 4-5-6.
        aliases[0x7F] = UInt8(ascii: "_")
        return SevenBitBrailleTable(
            characters: #" a,b.k;l"cif|msp!e:h*o+r>djg`ntq'1?2-u(v$3960x~&<5/8)z={_4w7#y}%"#,
            readingAliases: aliases
        )
    }()
}

// MARK: - A Code

/// How a BRF or BRL file writes each braille cell as a character: its braille
/// file code, which the listener knows as its "braille file characters"
/// (braillecodes, BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8.2).
///
/// It is not the braille code a book is written in (`Book.brailleTable`, UEB
/// or German braille), which says what print a run of cells means: it says
/// which character stands for each cell. The two are independent, though
/// they travel together by country. North American Braille ASCII is the code
/// of nearly every braille file, whatever its language, and the code of
/// every book that records none.
///
/// A code is data in one catalog (`all`): adding one is an entry, a test,
/// and a line in the documents, never a new branch in the reader.
struct BrailleFileCode: Identifiable, Hashable, Sendable {
    /// How a code writes cells.
    enum Kind: Equatable, Sendable {
        /// One printable ASCII character for each six-dot cell, by a table.
        case sevenBit(SevenBitBrailleTable)
        /// Unicode braille patterns, U+2800 to U+28FF, in UTF-8: the cell's
        /// dots are the pattern's low bits, so no table is needed.
        case unicodePatterns
    }

    /// The code's identity: lowercase, permanent, and never reused, since
    /// books, their records and removal markers, and config.json store it. A
    /// corrected table gets a new id.
    let id: String
    /// The name the pop-ups list and VoiceOver speaks, such as "North
    /// American Braille ASCII".
    let name: String
    /// What the reader's refusal calls this code's characters, after "which
    /// is not": "Line 3 holds “é”, which is not braille ASCII."
    let characterName: String
    /// How the code writes cells.
    let kind: Kind

    /// The code's seven-bit table, or nil for Unicode braille patterns.
    var sevenBitTable: SevenBitBrailleTable? {
        guard case .sevenBit(let table) = kind else { return nil }
        return table
    }

    /// Two codes are the same code when their ids are: an id names one table
    /// forever.
    static func == (lhs: BrailleFileCode, rhs: BrailleFileCode) -> Bool {
        lhs.id == rhs.id
    }

    /// Hashes the id alone, as `==` compares it.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - The Catalog

extension BrailleFileCode {
    /// North American Braille ASCII: the default, the code of nearly every
    /// braille file, and of every book that records no code.
    static let northAmerican = BrailleFileCode(
        id: "ascii-na",
        name: "North American Braille ASCII",
        characterName: "braille ASCII",
        kind: .sevenBit(.northAmerican)
    )

    /// Eurobraille, six-dot, of German-speaking Europe (SBS Zürich's table).
    static let eurobraille = BrailleFileCode(
        id: "ascii-eurobraille",
        name: "Eurobraille, six-dot (German-speaking countries)",
        characterName: "Eurobraille",
        kind: .sevenBit(.eurobraille)
    )

    /// Unicode braille patterns, as a PEF's rows and eBraille hold them: the
    /// one code a file can be known to use by its bytes alone.
    static let unicode = BrailleFileCode(
        id: "unicode",
        name: "Unicode braille patterns",
        characterName: "a Unicode braille pattern",
        kind: .unicodePatterns
    )

    /// Every code this TextMouth reads and writes, in the order every pop-up
    /// lists them.
    static let all: [BrailleFileCode] = [northAmerican, eurobraille, unicode]

    /// The code a book that records none is read in, and the setting's
    /// default.
    static let defaultCode = northAmerican

    /// The code of `all` whose id is exactly `id` (ids are lowercase), or nil.
    static func code(withID id: String) -> BrailleFileCode? {
        all.first { $0.id == id }
    }

    /// The code a book's stored value names: `defaultCode` for none (nil, or
    /// an empty string), the code for a known id, and nil for an id this
    /// TextMouth does not know, such as a later TextMouth's. Such a book is
    /// refused by name, never read as another code, which would give wrong
    /// text with no error.
    static func code(forStored stored: String?) -> BrailleFileCode? {
        guard let stored, !stored.isEmpty else { return defaultCode }
        return code(withID: stored)
    }
}
