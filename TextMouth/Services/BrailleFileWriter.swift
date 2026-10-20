import Foundation

// MARK: - Line ends

/// The line end a BRF file writes after each row (FMT22). Embossers and
/// braille displays read both; CR LF is the default, the user's choice of
/// October 17.
enum BrailleLineEnd: Equatable, Sendable {
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

    // MARK: BRF

    /// `pages` as the bytes of a BRF file: every row as North American
    /// Braille ASCII with `lineEnd` after it (the last row of a page too),
    /// and one form feed between pages and none after the last. The result is
    /// ASCII only.
    ///
    /// A BRF has six dots to a cell. A cell with dot 7 or 8 (U+2840 to
    /// U+28FF) is written as its six-dot part, its value with dots 7 and 8
    /// cleared, and a scalar that is no braille pattern is written as a blank
    /// cell, so that no row loses its columns (`sixDotCells(of:)`, which the
    /// PEF writer uses too). Trailing blank cells of a row are not written.
    static func brf(pages: [[String]], lineEnd: BrailleLineEnd = .crlf) -> Data {
        var bytes: [UInt8] = []
        for (index, page) in pages.enumerated() {
            if index > 0 { bytes.append(formFeed) }
            for row in page {
                bytes.append(contentsOf: asciiBytes(of: row))
                bytes.append(contentsOf: lineEnd.bytes)
            }
        }
        return Data(bytes)
    }

    /// `row` as braille ASCII bytes, without its trailing blank cells.
    private static func asciiBytes(of row: String) -> [UInt8] {
        // A six-dot cell always has a braille ASCII character; the blank
        // cell's is the space.
        sixDotCells(of: row).map { BrailleCells.ascii(for: $0) ?? UInt8(ascii: " ") }
    }

    /// The cells of `row` as TextMouth writes them to a file: each reduced to
    /// its six-dot part (`sixDotPart(of:)`), and the cells after the last
    /// one that is not blank left out. A cell that is blank once its dots 7
    /// and 8 are cleared counts as blank, so a row never ends in cells that
    /// look empty.
    ///
    /// TextMouth writes and reads six-dot braille only, in both formats, so
    /// that a BRF and a PEF of the same pages hold the same cells. This
    /// matters for liblouis's escape notation for a character a table lacks
    /// (an emoji, Chinese, Cyrillic): it writes the escape's backslash as the
    /// eight-dot cell U+2873, which becomes ⠳, braille ASCII's own backslash,
    /// and TextMouth's reader accepts the file. A PEF that kept U+2873 would
    /// be refused on import as eight-dot braille.
    private static func sixDotCells(of row: String) -> [Unicode.Scalar] {
        var cells = row.unicodeScalars.map(sixDotPart(of:))
        while cells.last == BrailleCells.blank { cells.removeLast() }
        return cells
    }

    /// The six-dot cell of `scalar`: the same cell with dots 7 and 8
    /// cleared, or the blank cell for a scalar that is no braille pattern.
    private static func sixDotPart(of scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard BrailleCells.isPattern(scalar) else { return BrailleCells.blank }
        // The low six bits of a pattern are dots 1 to 6.
        return Unicode.Scalar(BrailleCells.blank.value + (scalar.value & 0x3F)) ?? BrailleCells.blank
    }

    // MARK: PEF

    /// `pages` as the bytes of a PEF 2008-1 file (UTF-8): one volume of
    /// `format`'s cells by lines, one section, a `page` per page, and a `row`
    /// per row, with a blank row as `<row/>`. The rows hold Unicode braille
    /// cells of six dots, as a BRF does (`sixDotCells(of:)`; a scalar that
    /// is no braille pattern becomes a blank cell, as PEF allows nothing
    /// else), tabs indent, and every line ends in LF.
    ///
    /// The head holds the metadata, each text XML-escaped; an empty author
    /// leaves out `dc:creator`. The volume's size is `format` held to its
    /// ranges, as the layout holds it.
    static func pef(pages: [[String]], metadata: PEFMetadata, format: BraillePageFormat) -> Data {
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
                let cells = sixDotCells(of: row)
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
