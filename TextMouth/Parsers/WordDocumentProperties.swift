import Foundation

// MARK: - Formats

/// The paragraph properties a paragraph of a Word document (any version) names
/// directly (its PAPX), of those this reader uses.
struct WordParagraphFormat: Equatable {
    /// The paragraph's style index (`istd`).
    var style = 0
    /// The outline level set on the paragraph itself, 0 to 8, or 9 for body text.
    var outlineLevel: Int?
    /// Whether the paragraph is in a table.
    var isInTable = false
    /// Whether the paragraph is the mark that ends a row of a table (or of a nested table).
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
    /// For a Word 6 or Word 95 paragraph, the `ANLD` that numbers it (its
    /// 52 bytes) and its level (1 to 9, 10 for a simple list), as it names
    /// them; the reader turns them into a list instance and level
    /// (`WordLegacyNumbering`), which `listIndex` and `listLevel` then hold.
    var legacyNumbering: [UInt8]?
    var legacyNumberingLevel: Int?
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
    /// Whether the characters are a style separator (`sprmCFSpecVanish`):
    /// a hidden mark that ends a paragraph in one style where the next
    /// begins in another.
    var isStyleSeparator = false
    /// Whether the characters are special characters (a picture's anchor).
    var isSpecial = false
    /// The font size in half-points, or nil.
    var fontSize: Int?
    /// Whether the characters are text a tracked change deleted, which the
    /// document no longer holds.
    var isDeleted = false
    /// The font the run sets itself (an index into the font table), for a Word 6 or
    /// Word 95 document, whose font's character set names the code page of the
    /// run's text (`sprmCFtc`); nil when it says nothing and its styles decide.
    var fontIndex: Int?
    /// The character set the run says its text is in (`sprmCChse`), when it says it differs
    /// from the document's: 256 for the Macintosh's, 0 for Windows'; nil when it says nothing.
    var characterSet: Int?
    /// The font and the character (0 to 255 in practice) of a symbol the run holds
    /// (`sprmCSymbol`): the run's text is a placeholder ("(") for it.
    var symbolFont: Int?
    var symbolCharacter: Int?
    /// Whether Word 97 stored the symbol's character as U+F0xx (the code plus 0xF000).
    var symbolIsPrivateUse = false
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

/// Reads the paragraph and character properties of a Word document (Word 6 and Word 95 in their form: `dialect`)
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
    /// A paragraph run is a 13-byte BxPap, and a character run a byte. In
    /// Word 6 and Word 95 the BxPap is 7 bytes: the PAPX's offset, and a
    /// 6-byte PHE.
    private static func paragraphEntrySize(_ dialect: WordSprm.Dialect) -> Int { dialect == .modern ? 13 : 7 }

    // MARK: Paragraphs

    /// The paragraph formats of the document, as runs of character positions
    /// before `limit`.
    /// - Parameters:
    ///   - binTable: where the PlcfBtePapx lies in `table`.
    ///   - data: the `Data` stream, where a paragraph's properties are kept
    ///     when they do not fit its page (`sprmPHugePapx`, `sprmPTableProps`).
    /// - Throws: `OLEDamage` for a page, run, offset, or style index that does
    ///   not fit.
    static func paragraphRuns(
        binTable: Range<Int>, table: OLEBytes, document: OLEBytes,
        pieces: WordPieceTable, limit: Int, data: OLEBytes? = nil, dialect: WordSprm.Dialect = .modern,
        declaredPageCount: Int = 0, checkCancellation: () throws -> Void = { try ImportCancellation.throwIfCancelled() }
    ) throws -> WordFormatRuns<WordParagraphFormat> {
        let entrySize = paragraphEntrySize(dialect)
        return try runs(binTable: binTable, table: table, document: document, pieces: pieces, limit: limit,
                 dialect: dialect, declaredPageCount: declaredPageCount, checkCancellation: checkCancellation,
                 maximumRuns: (pageSize - 1 - 4) / (4 + entrySize),
                 // A paragraph is one run, and the modifiers of the piece that
                 // holds its last character (the last range) are the ones
                 // that apply to it all ([MS-DOC] 2.4.6.1).
                 modifiersOfRange: { ranges, _ in ranges.last?.modifiers ?? [] }) { page, index, runCount, modifiers in
            var format = WordParagraphFormat()
            // The BxPap: the offset in words of the PAPX, and a PHE we skip.
            let offset = try document.u8(page + (runCount + 1) * 4 + index * entrySize)
            if offset != 0 {
                // The PAPX: a size in words (or, when that byte is zero, a second
                // byte of the size in words), the style index, and the modifiers.
                // In Word 6 and Word 95 the size in words is of the bytes after
                // it (so the PAPX takes one byte more than twice it), and a
                // size of zero says the paragraph has no properties.
                let start = page + offset * 2
                let first = try document.u8(start)
                var listStart = start + 1
                var listSize = dialect == .modern ? first * 2 - 1 : first * 2
                if first == 0, dialect == .modern {
                    listStart = start + 2
                    listSize = try document.u8(start + 1) * 2
                }
                // A Word 6 or Word 95 PAPX of size zero has no properties.
                if listSize > 0 || dialect == .modern {
                    guard listSize >= 2, listStart + listSize <= page + pageSize - 1 else {
                        throw OLEDamage(reason: "a paragraph's properties run past their page")
                    }
                    format.style = try document.u16(listStart)
                    apply(try document.slice(offset: listStart + 2, length: listSize - 2), to: &format, data: data, dialect: dialect)
                }
            }
            // Then the piece's own modifiers, over the PAPX's.
            apply(modifiers, to: &format, data: data)
            // A style that is not in the sheet (or 0xFFFF, none) has the default
            // formatting: the sheet's questions answer nothing for it.
            return format
        }
    }

    /// The most `Data` stream property lists a paragraph's properties are followed through.
    private static let mostDataHops = 8

    /// Applies the paragraph modifiers `grpprl` to `format`. When the first of
    /// them is `sprmPHugePapx` or `sprmPTableProps` (a paragraph whose properties
    /// are too many for its page, or a table's), its operand is the offset
    /// in the `Data` stream of a `PrcData` (a 16-bit size, at least 10, and
    /// the modifiers), which is applied in its place and processes no more of
    /// this list; that one may name another, so a chain is followed, but only
    /// so far, since a file can make it a loop. One that is not first is ignored
    /// ([MS-DOC] sprmPHugePapx).
    private static func apply(
        _ grpprl: ArraySlice<UInt8>, to format: inout WordParagraphFormat, data: OLEBytes?, dialect: WordSprm.Dialect = .modern
    ) {
        var group = grpprl
        for _ in 0...mostDataHops {
            var next: ArraySlice<UInt8>?
            var isFirst = true
            var isRedirected = false
            WordSprm.forEach(in: group, dialect: dialect) { opcode, operand in
                defer { isFirst = false }
                if isRedirected { return }
                if isFirst, opcode == WordSprm.hugeParagraphProperties || opcode == WordSprm.tableProperties {
                    isRedirected = true
                    next = prcData(at: WordSprm.value(of: operand), in: data)
                    return
                }
                apply(opcode, operand, to: &format)
            }
            guard let next else { return }
            group = next
        }
    }

    /// The modifiers of the `PrcData` at `offset` in the `Data` stream: its
    /// 16-bit size, which must be at least 10, and that many bytes.
    private static func prcData(at offset: Int, in data: OLEBytes?) -> ArraySlice<UInt8>? {
        guard let data, let size = try? data.u16(offset), size >= 10 else { return nil }
        return try? data.slice(offset: offset + 2, length: size)
    }

    /// Sets the field of `format` that the paragraph modifier `opcode` with
    /// `operand` names, if this reader uses it.
    private static func apply(_ opcode: Int, _ operand: ArraySlice<UInt8>, to format: inout WordParagraphFormat) {
        let value = WordSprm.value(of: operand)
        switch opcode {
        case WordSprm.paragraphStyle: format.style = value
        case WordSprm.incrementLevel:
            // A signed 8-bit offset to the Heading 1 to 9 style (style 1 to 9)
            // the paragraph is in, held to them; of another style's paragraph, to its own outline level.
            let offset = value >= 0x80 ? value - 0x100 : value
            if (1...9).contains(format.style) {
                format.style = min(max(format.style + offset, 1), 9)
            } else if let level = format.outlineLevel, level != 9 {
                format.outlineLevel = min(max(level + offset, 0), 9)
            }
        case WordSprm.outlineLevel: format.outlineLevel = value
        case WordSprm.inTable: format.isInTable = value != 0
        case WordSprm.rowEnd, WordSprm.innerRowEnd: format.isRowEnd = value != 0
        case WordSprm.tableDepth: format.tableDepth = value
        case WordSprm.pageBreakBefore: format.pageBreakBefore = value != 0
        case WordSprm.listIndex: format.listIndex = value
        case WordSprm.listLevel: format.listLevel = value
        case WordSprm.legacyNumbering: format.legacyNumbering = Array(operand.dropFirst())
        case WordSprm.legacyNumberingLevel: format.legacyNumberingLevel = value
        default: break
        }
    }

    // MARK: Characters

    /// Sets the field of `format` that the character modifier `opcode` with
    /// `operand` names, if this reader uses it.
    private static func apply(_ opcode: Int, _ operand: ArraySlice<UInt8>, to format: inout WordCharacterFormat) {
        let value = WordSprm.value(of: operand)
        switch opcode {
        case WordSprm.bold: format.bold = value
        case WordSprm.italic: format.italic = value
        case WordSprm.hidden: format.hidden = value
        case WordSprm.characterStyle:
            // A character style brings its own properties: those set directly before it do not stay.
            resetDirectFormatting(&format)
            format.style = value
        case WordSprm.plain:
            // Plain text has no direct formatting and no character style.
            resetDirectFormatting(&format)
            format.style = nil
        case WordSprm.styleSeparator: format.isStyleSeparator = value == 1 || value == 0x81
        case WordSprm.special: format.isSpecial = value != 0
        case WordSprm.legacyFont, WordSprm.fontAscii: format.fontIndex = value
        case WordSprm.legacyCharacterSet:
            // A flag byte (non-zero when the run's set differs from the document's), then 16 bits.
            if operand.count >= 3, value & 0xFF != 0 { format.characterSet = (value >> 8) & 0xFFFF }
        case WordSprm.symbol:
            // A 16-bit font, then a 16-bit character; one in 0xF000 to 0xF0FF stands for its low byte.
            if operand.count >= 4 {
                format.symbolFont = value & 0xFFFF
                let character = (value >> 16) & 0xFFFF
                format.symbolIsPrivateUse = (0xF000...0xF0FF).contains(character)
                format.symbolCharacter = format.symbolIsPrivateUse ? character & 0xFF : character
            }
        case WordSprm.fontSize: format.fontSize = value
        // A toggle ([MS-DOC] 2.6.1): 0x80 keeps what a style gives, and no style
        // gives a deletion, so only 1 and 0x81 delete.
        case WordSprm.deleted: format.isDeleted = value == 1 || value == 0x81
        default: break
        }
    }

    /// The character formats of the document, as runs of character positions
    /// before `limit`.
    /// - Throws: `OLEDamage` for a page, run, offset, or style index that does
    ///   not fit.
    static func characterRuns(
        binTable: Range<Int>, table: OLEBytes, document: OLEBytes,
        pieces: WordPieceTable, limit: Int, dialect: WordSprm.Dialect = .modern, declaredPageCount: Int = 0,
        checkCancellation: () throws -> Void = { try ImportCancellation.throwIfCancelled() }
    ) throws -> WordFormatRuns<WordCharacterFormat> {
        try runs(binTable: binTable, table: table, document: document, pieces: pieces, limit: limit,
                 dialect: dialect, declaredPageCount: declaredPageCount, checkCancellation: checkCancellation,
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
                WordSprm.forEach(in: try document.slice(offset: start + 1, length: size), dialect: dialect) { opcode, operand in
                    apply(opcode, operand, to: &format)
                }
            }
            // Then the piece's own modifiers, over the CHPX's.
            WordSprm.forEach(in: modifiers) { opcode, operand in apply(opcode, operand, to: &format) }
            return format
        }
    }

    // MARK: Shared

    /// Takes off the direct formatting that a style or "plain" replaces: the
    /// emphasis, hiding, and size. A tracked deletion, and a special character
    /// (a picture's anchor), are not formatting a style gives or takes.
    private static func resetDirectFormatting(_ format: inout WordCharacterFormat) {
        format.bold = nil
        format.italic = nil
        format.hidden = nil
        format.fontSize = nil
        format.fontIndex = nil
    }

    /// Walks a bin table's pages and builds the runs of formats `format`
    /// reads from them.
    /// - Parameters:
    ///   - declaredPageCount: for a Word 6 or Word 95 document, how many pages of this kind the FIB
    ///     says the file holds (the table may list fewer); 0 for none.
    ///   - maximumRuns: the most runs a page of this kind can hold, by its size.
    ///   - modifiersOfRange: the property modifiers (`Pcd.prm`) that apply to
    ///     the characters of range number `position` of `ranges`, the ranges
    ///     one run covers, one for each piece it crosses.
    ///   - format: the format of run `index` of the page at `page`, which holds
    ///     `runCount` runs, with the piece modifiers laid over its properties.
    private static func runs<Format>(
        binTable: Range<Int>, table: OLEBytes, document: OLEBytes, pieces: WordPieceTable, limit: Int,
        dialect: WordSprm.Dialect, declaredPageCount: Int, checkCancellation: () throws -> Void, maximumRuns: Int,
        modifiersOfRange: (_ ranges: [WordPieceTable.Placed], _ position: Int) -> ArraySlice<UInt8>,
        format: (_ page: Int, _ index: Int, _ runCount: Int, _ modifiers: ArraySlice<UInt8>) throws -> Format
    ) throws -> WordFormatRuns<Format> {
        // A PLC of n+1 file offsets and n page numbers of 4 bytes each (2 in
        // Word 6 and Word 95).
        let numberSize = dialect == .modern ? 4 : 2
        let length = binTable.count
        guard length >= 4, (length - 4) % (4 + numberSize) == 0 else { throw OLEDamage(reason: "a bin table is \(length) bytes long") }
        let pageCount = (length - 4) / (4 + numberSize)
        let pageNumbersStart = binTable.lowerBound + (pageCount + 1) * 4

        // The pages the table lists, then (in a Word 6 or Word 95 document saved in full) the pages
        // the FIB says exist beyond the last listed: a bin table that stops short leaves the formatting
        // of the rest of the file on pages that follow the last, one after another.
        var pageNumbers: [Int] = []
        for pageIndex in 0..<pageCount {
            pageNumbers.append(try dialect == .modern
                ? table.u32(pageNumbersStart + pageIndex * 4) & 0x003F_FFFF
                : table.u16(pageNumbersStart + pageIndex * 2))
        }
        if dialect == .legacy, declaredPageCount > pageCount, let last = pageNumbers.last {
            for offset in 1...(declaredPageCount - pageCount) {
                // A page past the stream ends the pages there are.
                guard document.contains(offset: (last + offset) * pageSize, length: pageSize) else { break }
                pageNumbers.append(last + offset)
            }
        }
        let listedCount = pageCount

        // The pieces examined in all, for the overlap bound of the piece table.
        var budget = 16 * (pieces.pieces.count + pageNumbers.count * maximumRuns) + 4096
        var result: [WordFormatRuns<Format>.Run] = []
        for (pageIndex, number) in pageNumbers.enumerated() {
            // A page of runs is a unit of work; a cancelled import stops between them.
            try checkCancellation()
            let page = number * pageSize
            let isFollowing = pageIndex >= listedCount
            guard document.contains(offset: page, length: pageSize) else {
                throw OLEDamage(reason: "a properties page at \(page) is past the stream")
            }
            // A page that follows the listed ones and is no page of runs (its count of runs is too
            // large) is not one: the formatting is a help, and this is not what the table said.
            if isFollowing, try document.u8(page + pageSize - 1) > maximumRuns { continue }
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
        result.sortStably { $0.range.lowerBound < $1.range.lowerBound }
        return WordFormatRuns(runs: result)
    }
}
