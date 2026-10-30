import Foundation

// MARK: - Cells

/// Braille cells as TextMouth handles them (FMT20, FMT22).
///
/// Inside TextMouth a cell is a Unicode braille pattern: U+2800, the blank
/// cell, to U+28FF. The low eight bits of a pattern are its dots, dot 1
/// counting 1 up to dot 8 counting 128, so the 64 six-dot cells are U+2800
/// to U+283F. Braille travels as these patterns everywhere: in a PEF file,
/// to and from liblouis (`BrailleTranslator`), and between the readers, the
/// layout, and the writers.
///
/// A BRF or BRL file writes each six-dot cell as one character, in one of
/// the braille file codes of `BrailleFileCode` (braillecodes). The three
/// conversions here are North American Braille ASCII's always, whatever a
/// book's code is: the tests' fixtures write their cells in it, by its
/// mnemonic letters.
enum BrailleCells {
    /// The blank cell, U+2800: the space between braille words.
    static let blank = Unicode.Scalar(0x2800)!

    /// The first and last Unicode braille patterns.
    private static let firstPattern: UInt32 = 0x2800
    private static let lastPattern: UInt32 = 0x28FF
    /// The last six-dot pattern: past it, every pattern uses dot 7 or 8.
    private static let lastSixDotPattern: UInt32 = 0x283F

    /// North American Braille ASCII: the character for each six-dot cell, in
    /// the order of the cells' dot values 0 to 63 (dot 1 counts 1, dot 6
    /// counts 32), so the blank cell is the space and ⠁ (dot 1) is "A"
    /// (`SevenBitBrailleTable.northAmerican`, whose bytes these are).
    static let asciiByDots: [UInt8] = SevenBitBrailleTable.northAmerican.bytes

    /// The cell a byte of North American Braille ASCII stands for, or nil
    /// for a byte that is not braille ASCII: the 64 characters 0x20 to 0x5F,
    /// and lowercase, 0x60 to 0x7E, read as the character 0x20 below
    /// (`SevenBitBrailleTable.northAmerican`).
    static func cell(forASCII byte: UInt8) -> Unicode.Scalar? {
        SevenBitBrailleTable.northAmerican.cell(forByte: byte)
    }

    /// The North American Braille ASCII character of a six-dot cell, U+2800
    /// to U+283F, in the table's uppercase form; nil for any other
    /// character, eight-dot cells included.
    static func ascii(for cell: Unicode.Scalar) -> UInt8? {
        SevenBitBrailleTable.northAmerican.byte(forCell: cell)
    }

    /// Whether `scalar` is a Unicode braille pattern, U+2800 to U+28FF.
    static func isPattern(_ scalar: Unicode.Scalar) -> Bool {
        (firstPattern...lastPattern).contains(scalar.value)
    }

    /// Whether `scalar` is a braille pattern that uses dot 7 or dot 8,
    /// U+2840 to U+28FF: eight-dot braille, which TextMouth does not read.
    static func usesEightDots(_ scalar: Unicode.Scalar) -> Bool {
        (lastSixDotPattern + 1...lastPattern).contains(scalar.value)
    }

    /// The six-dot part of the braille pattern `cell`: the same cell with
    /// dots 7 and 8 cleared, the low six bits of a pattern being dots 1 to 6.
    static func sixDotPart(of cell: Unicode.Scalar) -> Unicode.Scalar {
        Unicode.Scalar(firstPattern + (cell.value & 0x3F)) ?? blank
    }

    /// liblouis's escape backslash: the cell it writes the backslash of its
    /// escape notation with (`'\x0041'` for a character a table lacks) when
    /// the table has no backslash of its own, braille ASCII's ⠳ with dot 7
    /// (`_lou_charToFallbackDots` in `Vendor/liblouis/liblouis/utils.c`).
    /// It is liblouis's cell, not a table's, and TextMouth's files write it
    /// as ⠳ (`BrailleFileWriter`, review finding M6): the one eight-dot
    /// cell they hold in six dots.
    static let escapeBackslash = Unicode.Scalar(0x2873)!

    /// The first cell of `cells` that uses dot 7 or 8 and is not
    /// `escapeBackslash`: a cell TextMouth's six-dot files cannot hold, which
    /// they never write as its six-dot part (review R1). Nil when there is
    /// none.
    static func firstEightDotCell(in cells: String) -> Unicode.Scalar? {
        cells.unicodeScalars.first { usesEightDots($0) && $0 != escapeBackslash }
    }

    /// The dots of the braille pattern `cell` in words, as "dot 7" or
    /// "dots 4 and 7" or "dots 1, 2, and 7"; "no dots" for the blank cell.
    static func dotsInWords(of cell: Unicode.Scalar) -> String {
        let dots = (1...8).filter { cell.value & (1 << ($0 - 1)) != 0 }.map(String.init)
        switch dots.count {
        case 0: return "no dots"
        case 1: return "dot \(dots[0])"
        case 2: return "dots \(dots[0]) and \(dots[1])"
        default: return "dots \(dots.dropLast().joined(separator: ", ")), and \(dots[dots.count - 1])"
        }
    }

    /// The text of `cells` with every blank cell made a space, for a
    /// test's or a log's sake: "⠠⠮ ⠃⠕⠽" reads more easily than with U+2800.
    static func spaced(_ cells: String) -> String {
        String(String.UnicodeScalarView(cells.unicodeScalars.map { $0 == blank ? " " : $0 }))
    }
}

// MARK: - Blocks

/// One block of a braille book's structure (FMT20, FMT22): what the readers
/// find on a braille file's pages, and what the writers lay out on them. Its
/// text is braille, as Unicode cells with blank cells between the words, on
/// the braille side of a translation (`BrailleTranslator`), and print on the
/// other; a translation changes a block's text and never its kind.
enum BrailleBlock: Equatable, Sendable {
    /// A heading, of level 1 (the highest) to 6.
    case heading(level: Int, text: String)
    /// A paragraph.
    case paragraph(text: String)
    /// An item of a list, at depth 1 for an item of a top-level list, 2 for
    /// one of a list inside that item, and so on.
    case listItem(depth: Int, text: String)

    /// The block's text, braille or print.
    var text: String {
        switch self {
        case let .heading(_, text), let .paragraph(text), let .listItem(_, text): return text
        }
    }

    /// The same kind of block, at the same level or depth, holding `text`:
    /// a translation's result.
    func withText(_ text: String) -> BrailleBlock {
        switch self {
        case let .heading(level, _): return .heading(level: level, text: text)
        case .paragraph: return .paragraph(text: text)
        case let .listItem(depth, _): return .listItem(depth: depth, text: text)
        }
    }
}
