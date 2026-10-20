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
/// A BRF or BRL file writes each six-dot cell as one character of North
/// American Braille ASCII, which this type converts to and from.
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
    /// counts 32), so the blank cell is the space and ⠁ (dot 1) is "A".
    /// Verified 64 of 64 against liblouis's own en-us-brf.dis
    /// (FORMATS-RESEARCH-2026-10-17.md, section 3.2).
    static let asciiByDots: [UInt8] = Array(#" A1B'K2L@CIF/MSP"E3H9O6R^DJG>NTQ,*5<-U8V.%[$+X!&;:4\0Z7(_?W]#Y)="#.utf8)

    /// The dots of each braille ASCII character from 0x20 to 0x5F, at the
    /// character's value less 0x20: the inverse of `asciiByDots`.
    private static let dotsByASCII: [UInt8] = {
        var dots = [UInt8](repeating: 0, count: 64)
        for (value, character) in asciiByDots.enumerated() {
            dots[Int(character) - 0x20] = UInt8(value)
        }
        return dots
    }()

    /// The cell a byte of a BRF or BRL file stands for, or nil for a byte
    /// that is not braille ASCII.
    ///
    /// The 64 characters 0x20 to 0x5F are the table's. Files also write
    /// them in lowercase, 0x60 to 0x7E, which stand for the same six dots as
    /// the character 0x20 below each: a lowercase letter is read as its
    /// capital, and ` { | } ~ as @ [ \ ] ^ (in eight-dot computer braille,
    /// the two differ only by dot 7, which a six-dot file has not got).
    static func cell(forASCII byte: UInt8) -> Unicode.Scalar? {
        let folded: UInt8
        switch byte {
        case 0x20...0x5F: folded = byte
        case 0x60...0x7E: folded = byte - 0x20
        default: return nil
        }
        return Unicode.Scalar(firstPattern + UInt32(dotsByASCII[Int(folded) - 0x20]))
    }

    /// The braille ASCII character of a six-dot cell, U+2800 to U+283F, in
    /// the table's uppercase form; nil for any other character, eight-dot
    /// cells included.
    static func ascii(for cell: Unicode.Scalar) -> UInt8? {
        guard (firstPattern...lastSixDotPattern).contains(cell.value) else { return nil }
        return asciiByDots[Int(cell.value - firstPattern)]
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
