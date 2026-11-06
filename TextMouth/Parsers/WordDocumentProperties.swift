import Foundation

// MARK: - Formats

/// The paragraph properties a paragraph of a Word 97-2003 document names
/// directly (its PAPX), of those this reader uses.
struct WordParagraphFormat: Equatable {
    /// The paragraph's style index (`istd`).
    var style = 0
    /// The outline level set on the paragraph itself, 0 to 8, or 9 for body text.
    var outlineLevel: Int?
    /// Whether the paragraph is in a table.
    var isInTable = false
    /// Whether the paragraph is the mark that ends a row of a table.
    var isRowEnd = false
    /// The depth of the table the paragraph is in: 1 for a table, 2 for a
    /// table in a cell of a table; 0 when the paragraph does not say.
    var tableDepth = 0
    /// Whether the paragraph itself says it begins a page (`sprmPFPageBreakBefore`,
    /// on or off), or nil when it says nothing and its style decides.
    var pageBreakBefore: Bool?
    /// The list instance the paragraph names (`sprmPIlfo`, as the file
    /// stores it: a signed 16-bit number), or nil when it says nothing and
    /// its style decides.
    var listIndex: Int?
    /// The paragraph's level in its list (`sprmPIlvl`), or nil as for `listIndex`.
    var listLevel: Int?
}

/// The character properties a run of text names directly (its CHPX), of
/// those this reader uses.
struct WordCharacterFormat: Equatable {
    /// The character style's index, or nil.
    var style: Int?
    /// The direct bold property (0, 1, 0x80, or 0x81), or nil.
    var bold: Int?
    /// The direct italic property, valued as `bold` is.
    var italic: Int?
    /// The direct hidden-text property (`sprmCFVanish`), valued as `bold` is.
    var hidden: Int?
    /// Whether the characters are special characters (a picture's anchor).
    var isSpecial = false
    /// The font size in half-points, or nil.
    var fontSize: Int?
    /// Whether the characters are text a tracked change deleted, which the
    /// document no longer holds.
    var isDeleted = false
}

// MARK: - Runs of Formats

/// The formats of a document's characters as runs of character positions,
/// sorted by where they begin. A reader walks the text once, in order, so a
/// cursor that only moves forward finds each character's format in constant
/// time.
struct WordFormatRuns<Format> {
    /// One run: the characters it covers and their format.
    struct Run {
        let range: Range<Int>
        let format: Format
    }

    /// The runs, sorted by `range.lowerBound`.
    let runs: [Run]

    /// A cursor that answers `format(at:)` for positions that never decrease.
    struct Cursor {
        fileprivate let runs: [Run]
        private var index = 0

        fileprivate init(runs: [Run]) {
            self.runs = runs
        }

        /// The format of the run that covers `position`, or nil when none does.
        /// Positions asked for must not go back.
        mutating func format(at position: Int) -> Format? {
            while index < runs.count, runs[index].range.upperBound <= position { index += 1 }
            guard index < runs.count, runs[index].range.lowerBound <= position else { return nil }
            return runs[index].format
        }
    }

    /// A new cursor at the first run.
    func cursor() -> Cursor {
        Cursor(runs: runs)
    }
}

// MARK: - Reading the Bin Tables

/// Reads the paragraph and character properties of a Word 97-2003 document
/// from its bin tables and formatted disk pages (FKPs, [MS-DOC] 2.9.25 and
/// 2.9.181).
///
/// A bin table lists, for ranges of the file, the page of the
/// `WordDocument` stream (512 bytes) that holds the properties of the text in
/// that range. A page holds up to a hundred runs: a list of file offsets
/// (FCs) that bound the runs, and for each run the offset in the page of its
/// property list (a paragraph's also holds its style index). The FCs are
/// turned into character positions through the piece table.
///
/// Every page, run, and offset is checked against the stream and the page.
enum WordDocumentProperties {

    // MARK: Constants

    /// The size of a formatted disk page.
    private static let pageSize = 512
    /// A paragraph run is a 13-byte BxPap, and a character run a byte.
    private static let paragraphEntrySize = 13

    // MARK: Paragraphs

    /// The paragraph formats of the document, as runs of character positions
    /// before `limit`.
    /// - Parameters:
    ///   - binTable: where the PlcfBtePapx lies in `table`.
    ///   - styles: the style sheet, for checking each paragraph's style index.
    /// - Throws: `OLEDamage` for a page, run, offset, or style index that does
    ///   not fit.
    static func paragraphRuns(
        binTable: Range<Int>, table: OLEBytes, document: OLEBytes,
        pieces: WordPieceTable, styles: WordStyleSheet, limit: Int
    ) throws -> WordFormatRuns<WordParagraphFormat> {
        try runs(binTable: binTable, table: table, document: document, pieces: pieces, limit: limit,
                 maximumRuns: (pageSize - 1 - 4) / (4 + paragraphEntrySize),
                 // A paragraph is one run, and the modifiers of the piece that
                 // holds its last character (the last range) are the ones
                 // that apply to it all ([MS-DOC] 2.4.6.1).
                 modifiersOfRange: { ranges, _ in ranges.last?.modifiers ?? [] }) { page, index, runCount, modifiers in
            var format = WordParagraphFormat()
            // The BxPap: the offset in words of the PAPX, and a PHE we skip.
            let offset = try document.u8(page + (runCount + 1) * 4 + index * paragraphEntrySize)
            if offset != 0 {
                // The PAPX: a size in words (or, when that byte is zero, a second
                // byte of the size in words), the style index, and the modifiers.
                let start = page + offset * 2
                let first = try document.u8(start)
                var listStart = start + 1
                var listSize = first * 2 - 1
                if first == 0 {
                    listStart = start + 2
                    listSize = try document.u8(start + 1) * 2
                }
                guard listSize >= 2, listStart + listSize <= page + pageSize - 1 else {
                    throw OLEDamage(reason: "a paragraph's properties run past their page")
                }
                format.style = try document.u16(listStart)
                WordSprm.forEach(in: try document.slice(offset: listStart + 2, length: listSize - 2)) { opcode, operand in
                    apply(opcode, operand, to: &format)
                }
            }
            // Then the piece's own modifiers, over the PAPX's.
            WordSprm.forEach(in: modifiers) { opcode, operand in apply(opcode, operand, to: &format) }
            guard styles.contains(styleIndex: format.style) else { throw OLEDamage(reason: "a paragraph's style \(format.style) is not in the style sheet") }
            return format
        }
    }

    /// Sets the field of `format` that the paragraph modifier `opcode` with
    /// `operand` names, if this reader uses it.
    private static func apply(_ opcode: Int, _ operand: ArraySlice<UInt8>, to format: inout WordParagraphFormat) {
        let value = number(in: operand)
        switch opcode {
        case WordSprm.paragraphStyle: format.style = value
        case WordSprm.outlineLevel: format.outlineLevel = value
        case WordSprm.inTable: format.isInTable = value != 0
        case WordSprm.rowEnd: format.isRowEnd = value != 0
        case WordSprm.tableDepth: format.tableDepth = value
        case WordSprm.pageBreakBefore: format.pageBreakBefore = value != 0
        case WordSprm.listIndex: format.listIndex = value
        case WordSprm.listLevel: format.listLevel = value
        default: break
        }
    }

    // MARK: Characters

    /// Sets the field of `format` that the character modifier `opcode` with
    /// `operand` names, if this reader uses it.
    private static func apply(_ opcode: Int, _ operand: ArraySlice<UInt8>, to format: inout WordCharacterFormat) {
        let value = number(in: operand)
        switch opcode {
        case WordSprm.bold: format.bold = value
        case WordSprm.italic: format.italic = value
        case WordSprm.hidden: format.hidden = value
        case WordSprm.characterStyle: format.style = value
        case WordSprm.special: format.isSpecial = value != 0
        case WordSprm.fontSize: format.fontSize = value
        case WordSprm.deleted: format.isDeleted = value != 0
        default: break
        }
    }

    /// The character formats of the document, as runs of character positions
    /// before `limit`.
    /// - Throws: `OLEDamage` for a page, run, offset, or style index that does
    ///   not fit.
    static func characterRuns(
        binTable: Range<Int>, table: OLEBytes, document: OLEBytes,
        pieces: WordPieceTable, styles: WordStyleSheet, limit: Int
    ) throws -> WordFormatRuns<WordCharacterFormat> {
        try runs(binTable: binTable, table: table, document: document, pieces: pieces, limit: limit,
                 maximumRuns: (pageSize - 1 - 4) / 5,
                 // Each character takes the modifiers of its own piece.
                 modifiersOfRange: { ranges, position in ranges[position].modifiers }) { page, index, runCount, modifiers in
            var format = WordCharacterFormat()
            // The run's byte: the offset in words of its CHPX.
            let offset = try document.u8(page + (runCount + 1) * 4 + index)
            if offset != 0 {
                // The CHPX: a size in bytes and the modifiers.
                let start = page + offset * 2
                let size = try document.u8(start)
                guard start + 1 + size <= page + pageSize - 1 else { throw OLEDamage(reason: "a run's properties run past their page") }
                WordSprm.forEach(in: try document.slice(offset: start + 1, length: size)) { opcode, operand in
                    apply(opcode, operand, to: &format)
                }
            }
            // Then the piece's own modifiers, over the CHPX's.
            WordSprm.forEach(in: modifiers) { opcode, operand in apply(opcode, operand, to: &format) }
            if let style = format.style, !styles.contains(styleIndex: style) {
                throw OLEDamage(reason: "a run's character style \(style) is not in the style sheet")
            }
            return format
        }
    }

    // MARK: Shared

    /// The little-endian number in the first (up to four) bytes of `operand`.
    private static func number(in operand: ArraySlice<UInt8>) -> Int {
        operand.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }

    /// Walks a bin table's pages and builds the runs of formats `format`
    /// reads from them.
    /// - Parameters:
    ///   - maximumRuns: the most runs a page of this kind can hold, by its size.
    ///   - modifiersOfRange: the property modifiers (`Pcd.prm`) that apply to
    ///     the characters of range number `position` of `ranges`, the ranges
    ///     one run covers, one for each piece it crosses.
    ///   - format: the format of run `index` of the page at `page`, which holds
    ///     `runCount` runs, with the piece modifiers laid over its properties.
    private static func runs<Format>(
        binTable: Range<Int>, table: OLEBytes, document: OLEBytes, pieces: WordPieceTable, limit: Int,
        maximumRuns: Int,
        modifiersOfRange: (_ ranges: [WordPieceTable.Placed], _ position: Int) -> ArraySlice<UInt8>,
        format: (_ page: Int, _ index: Int, _ runCount: Int, _ modifiers: ArraySlice<UInt8>) throws -> Format
    ) throws -> WordFormatRuns<Format> {
        // A PLC of n+1 file offsets and n page numbers of 4 bytes each.
        let length = binTable.count
        guard length >= 4, (length - 4) % 8 == 0 else { throw OLEDamage(reason: "a bin table is \(length) bytes long") }
        let pageCount = (length - 4) / 8
        let pageNumbersStart = binTable.lowerBound + (pageCount + 1) * 4

        // The pieces examined in all, for the overlap bound of the piece table.
        var budget = 16 * (pieces.pieces.count + pageCount * maximumRuns) + 4096
        var result: [WordFormatRuns<Format>.Run] = []
        for pageIndex in 0..<pageCount {
            // The page number is the low 22 bits.
            let page = (try table.u32(pageNumbersStart + pageIndex * 4) & 0x003F_FFFF) * pageSize
            guard document.contains(offset: page, length: pageSize) else {
                throw OLEDamage(reason: "a properties page at \(page) is past the stream")
            }
            let runCount = try document.u8(page + pageSize - 1)
            guard runCount <= maximumRuns else { throw OLEDamage(reason: "a properties page holds \(runCount) runs") }
            for index in 0..<runCount {
                let start = try document.u32(page + index * 4)
                let end = try document.u32(page + (index + 1) * 4)
                guard start <= end else { throw OLEDamage(reason: "a run ends before it begins") }
                let ranges = try pieces.characterRanges(fileStart: start, fileEnd: end, budget: &budget)
                // A run with no text in the document is not read.
                guard !ranges.isEmpty else { continue }
                for (position, placed) in ranges.enumerated() where placed.range.lowerBound < limit {
                    let runFormat = try format(page, index, runCount, modifiersOfRange(ranges, position))
                    result.append(.init(range: placed.range, format: runFormat))
                }
            }
        }
        result.sort { $0.range.lowerBound < $1.range.lowerBound }
        return WordFormatRuns(runs: result)
    }
}
