import Foundation

// MARK: - Line ends

/// The line end a BRF file writes after each row (FMT22). Embossers and
/// braille displays read both; CR LF is the default, the user's choice of
/// October 17.
enum BrailleLineEnd: Equatable, Hashable, Sendable {
    /// Carriage return, then line feed.
    case crlf
    /// Line feed alone.
    case lf

    /// The bytes that end a row.
    var bytes: [UInt8] {
        switch self {
        case .crlf: return [0x0D, 0x0A]
        case .lf: return [0x0A]
        }
    }
}

// MARK: - PEF metadata

/// What a PEF says about its book (FMT22).
struct PEFMetadata: Equatable, Sendable {
    var title: String
    var author: String
    /// A BCP 47 language tag, such as "en".
    var language: String
    /// A unique identifier, such as "urn:uuid:" and a UUID.
    var identifier: String
    /// The day it was made, written yyyy-mm-dd.
    var date: String
}

// MARK: - Writers

/// Writes laid-out braille pages (`BrailleLayout.pages`) as a BRF or a PEF
/// file (FMT22, Phase A). Pages are rows of Unicode braille cells; the
/// writers only convert and frame them and never change a row's cells,
/// except as each method says.
enum BrailleFileWriter {
    /// The form feed that ends a page in a BRF file.
    private static let formFeed: UInt8 = 0x0C

    // MARK: Eight Dots

    /// Why braille cannot be written to a BRF or PEF file (review R1): it
    /// holds an eight-dot cell, which TextMouth's six-dot files cannot hold
    /// and never write as its six-dot part. The sentence names the print
    /// character the table writes with that cell when it is known
    /// (`BrailleDocumentWriter` finds it), and the cell's dots otherwise.
    struct EightDotCell: LocalizedError, Equatable, Sendable {
        /// The cell, U+2840 to U+28FF, but never liblouis's escape backslash.
        let cell: Unicode.Scalar
        /// The print character the table writes with the cell, when known.
        var character: Character?

        var errorDescription: String? {
            let what = character.map { "writes \u{201C}\($0)\u{201D} as an eight-dot cell" }
                ?? "writes an eight-dot cell, \(BrailleCells.dotsInWords(of: cell))"
            return "The braille table \(what), and TextMouth writes BRF and PEF files in six-dot braille only."
        }
    }

    // MARK: BRF

    /// `pages` as the bytes of a BRF file: every row in the braille file
    /// code `code` (North American Braille ASCII unless another is given)
    /// with `lineEnd` after it (the last row of a page too), and one form
    /// feed between pages and none after the last. Line ends and form feeds
    /// are the same bytes in every code. In a seven-bit code, North American
    /// Braille ASCII or Eurobraille, the result is ASCII only; in Unicode
    /// braille patterns it is UTF-8, with no byte order mark.
    ///
    /// A BRF has six dots to a cell, in every code. liblouis's escape
    /// backslash (U+2873) is written as ⠳; any other cell with dot 7 or 8 is
    /// refused, never written as its six-dot part (review R1); and a scalar
    /// that is no braille pattern is written as a blank cell, so that no row
    /// loses its columns (`sixDotCells(of:)`, which the PEF writer uses
    /// too). Trailing blank cells of a row are not written. Only then does
    /// the code decide how each cell is written (`bytes(of:in:)`).
    /// - Throws: `EightDotCell` for an eight-dot cell other than the escape
    ///   backslash.
    static func brf(
        pages: [[String]], lineEnd: BrailleLineEnd = .crlf, code: BrailleFileCode = .northAmerican
    ) throws -> Data {
        var file: [UInt8] = []
        for (index, page) in pages.enumerated() {
            if index > 0 { file.append(formFeed) }
            for row in page {
                file.append(contentsOf: try bytes(of: row, in: code))
                file.append(contentsOf: lineEnd.bytes)
            }
        }
        return Data(file)
    }

    /// `row` as the bytes of the braille file code `code`, without its
    /// trailing blank cells: the one place a BRF's row is written.
    ///
    /// A seven-bit code writes one byte for each cell, the character its
    /// table gives (the blank cell's is the space). Unicode braille patterns
    /// write each cell as its pattern's UTF-8, three bytes, and the blank
    /// cell as U+2800, never as the space.
    /// - Throws: `EightDotCell`, as `sixDotCells(of:)` does.
    private static func bytes(of row: String, in code: BrailleFileCode) throws -> [UInt8] {
        let cells = try sixDotCells(of: row)
        switch code.kind {
        case .sevenBit(let table):
            // Every six-dot cell has a character in a seven-bit code, so the
            // space is only a fallback that no table of TextMouth's needs.
            return cells.map { table.byte(forCell: $0) ?? UInt8(ascii: " ") }
        case .unicodePatterns:
            // The cells are already Unicode braille patterns, the blank cell
            // U+2800 among them: they are written as they are.
            return Array(String(String.UnicodeScalarView(cells)).utf8)
        }
    }

    /// The cells of `row` as TextMouth writes them to a file
    /// (`sixDotCell(of:)`), and the cells after the last one that is not
    /// blank left out.
    ///
    /// TextMouth writes and reads six-dot braille only, in both formats, so
    /// that a BRF and a PEF of the same pages hold the same cells. liblouis's
    /// escape notation for a character a table lacks (an emoji, Chinese,
    /// Cyrillic) writes the escape's backslash as the eight-dot cell U+2873,
    /// which becomes ⠳, braille ASCII's own backslash, and TextMouth's reader
    /// accepts the file (review finding M6); a PEF that kept U+2873 would be
    /// refused on import as eight-dot braille. Any other eight-dot cell is a
    /// table's own, and dropping its dots 7 and 8 would change what it
    /// means, so the row is refused instead (review R1).
    /// - Throws: `EightDotCell` for an eight-dot cell other than U+2873.
    private static func sixDotCells(of row: String) throws -> [Unicode.Scalar] {
        var cells = try row.unicodeScalars.map(sixDotCell(of:))
        while cells.last == BrailleCells.blank { cells.removeLast() }
        return cells
    }

    /// The six-dot cell `scalar` is written as: itself for a six-dot cell,
    /// ⠳ for liblouis's escape backslash, and the blank cell for a scalar
    /// that is no braille pattern.
    /// - Throws: `EightDotCell` for any other eight-dot cell.
    private static func sixDotCell(of scalar: Unicode.Scalar) throws -> Unicode.Scalar {
        guard BrailleCells.isPattern(scalar) else { return BrailleCells.blank }
        guard BrailleCells.usesEightDots(scalar) else { return scalar }
        guard scalar == BrailleCells.escapeBackslash else { throw EightDotCell(cell: scalar) }
        // ⠳, braille ASCII's backslash.
        return BrailleCells.sixDotPart(of: scalar)
    }

    // MARK: PEF

    /// `pages` as the bytes of a PEF 2008-1 file (UTF-8): one volume of
    /// `format`'s cells by lines, one section, a `page` per page, and a `row`
    /// per row, with a blank row as `<row/>`. The rows hold Unicode braille
    /// cells of six dots, as a BRF does (`sixDotCells(of:)`; a scalar that
    /// is no braille pattern becomes a blank cell, as PEF allows nothing
    /// else, and an eight-dot cell but the escape backslash is refused),
    /// tabs indent, and every line ends in LF.
    ///
    /// The head holds the metadata, each text XML-escaped; an empty author
    /// leaves out `dc:creator`. The volume's size is `format` held to its
    /// ranges, as the layout holds it.
    /// - Throws: `EightDotCell`, as `brf(pages:lineEnd:)` does.
    static func pef(pages: [[String]], metadata: PEFMetadata, format: BraillePageFormat) throws -> Data {
        let format = format.clamped
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<pef version="2008-1" xmlns="http://www.daisy.org/ns/2008/pef">"#,
            "\t<head>",
            "\t\t<meta xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
            "\t\t\t<dc:format>application/x-pef+xml</dc:format>",
            "\t\t\t<dc:identifier>\(escaped(metadata.identifier))</dc:identifier>",
            "\t\t\t<dc:title>\(escaped(metadata.title))</dc:title>",
        ]
        // A book without an author has no creator element (an empty one is
        // an empty name, which a reader would show as one).
        if !metadata.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("\t\t\t<dc:creator>\(escaped(metadata.author))</dc:creator>")
        }
        lines += [
            "\t\t\t<dc:date>\(escaped(metadata.date))</dc:date>",
            "\t\t\t<dc:language>\(escaped(metadata.language))</dc:language>",
            "\t\t</meta>",
            "\t</head>",
            "\t<body>",
            "\t\t<volume cols=\"\(format.cellsPerLine)\" rows=\"\(format.linesPerPage)\" rowgap=\"0\" duplex=\"false\">",
            "\t\t\t<section>",
        ]
        for page in pages {
            lines.append("\t\t\t\t<page>")
            for row in page {
                let cells = try sixDotCells(of: row)
                if cells.isEmpty {
                    lines.append("\t\t\t\t\t<row/>")
                } else {
                    lines.append("\t\t\t\t\t<row>\(String(String.UnicodeScalarView(cells)))</row>")
                }
            }
            lines.append("\t\t\t\t</page>")
        }
        lines += ["\t\t\t</section>", "\t\t</volume>", "\t</body>", "</pef>", ""]
        return Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: XML

    /// `text` as XML element content: `&`, `<`, and `>` escaped, and the
    /// characters XML 1.0 forbids (controls other than tab, LF, and CR, and
    /// U+FFFE and U+FFFF) left out, so that an odd title cannot make the
    /// file unreadable. Every text PEF holds here is element content; the
    /// attributes are numbers.
    private static func escaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result.append(contentsOf: "&amp;".unicodeScalars)
            case "<": result.append(contentsOf: "&lt;".unicodeScalars)
            case ">": result.append(contentsOf: "&gt;".unicodeScalars)
            case "\u{9}", "\u{A}", "\u{D}": result.append(scalar)
            case "\u{0}"..."\u{1F}", "\u{FFFE}", "\u{FFFF}": continue
            default: result.append(scalar)
            }
        }
        return String(result)
    }
}
