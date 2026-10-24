import Foundation

// MARK: - Options

/// What a braille export writes (FMT22): the user's October 17 defaults,
/// each changeable in the Export dialog, whose options view sets them
/// (`BrailleExportOptionsView`); the BRF and PEF writers take them as their
/// `TextExportOptions`.
struct BrailleExportOptions: TextExportOptions {
    /// Cells per line, lines per page, and whether pages carry numbers.
    var page = BraillePageFormat()
    /// The table, by its stored value (a bundled table's file name, or "mac:"
    /// and one of this Mac's): the code and its contraction. Choosing
    /// another forgets `replacedTable`.
    var table = BrailleTableCatalog.defaultTableID {
        didSet { if table != oldValue { replacedTable = nil } }
    }
    /// The line end a BRF file writes after each row (a PEF always uses LF).
    var lineEnd = BrailleLineEnd.crlf
    /// The Braille setting's table, when this Mac cannot use it and the
    /// options start from the default table instead (review R4), which the
    /// options view says; nil otherwise.
    var replacedTable: String?

    /// The defaults (40 cells by 25 lines, page numbers on, CR LF), with the
    /// table the Braille setting chose (`BraillePreferences.importTable()`:
    /// the setting, or a test's bound table). One of this Mac's tables that
    /// this Mac does not offer (gone, or a bundled table's twin), or that its
    /// check refused this session, is replaced by the default table, so the
    /// pop-ups show what the export will use (review R4).
    static func standard() -> BrailleExportOptions {
        let setting = BraillePreferences.importTable()
        guard isUnusableMacTable(setting) else { return BrailleExportOptions(table: setting) }
        return BrailleExportOptions(table: BrailleTableCatalog.defaultTableID, replacedTable: setting)
    }

    /// Whether `table` is one of this Mac's tables that an export cannot
    /// start from: not offered, or refused by a check that lasts the session.
    static func isUnusableMacTable(_ table: String) -> Bool {
        guard BrailleTableSource.parse(table).source == .mac else { return false }
        guard BrailleTableCatalog.table(withID: table) != nil else { return true }
        if case .refused? = MacBrailleTableCheck.verdicts.verdict(for: table) { return true }
        return false
    }
}

// MARK: - Print Blocks

/// A block of print for a braille export, with the emphasis of its text
/// (FMT22; emphasis since October 21, 2026): what `BrailleDocumentWriter`
/// translates. The export model's emphasis and strong emphasis reach
/// liblouis this way (`BrailleExportBlocks.printBlocks(of:)`), and liblouis
/// writes the table's indicators for those it reads back exactly with the
/// table (`check_readable` in the helper): UEB's word, passage, and
/// terminator indicators. A table whose indicators it would misread, EBAE
/// or most of this Mac's, writes plain braille, as a table with no rules
/// for them does.
struct BraillePrintBlock: Equatable, Sendable {
    /// The block: its kind, its level or depth, and its print.
    private(set) var block: BrailleBlock
    /// The emphasis of each Unicode scalar of the block's print, in order;
    /// empty when none has any.
    private(set) var emphasis: [BrailleEmphasis]

    /// `block`, its print with no emphasis.
    init(_ block: BrailleBlock) {
        self.init(block: block, emphasis: [])
    }

    /// The block itself, with `emphasis` for its print's scalars.
    private init(block: BrailleBlock, emphasis: [BrailleEmphasis]) {
        self.block = block
        self.emphasis = emphasis
    }

    /// A heading of `level` holding `print`.
    static func heading(level: Int, _ print: EmphasizedText) -> BraillePrintBlock {
        BraillePrintBlock(block: .heading(level: level, text: print.text), emphasis: print.emphasis)
    }

    /// A paragraph holding `print`.
    static func paragraph(_ print: EmphasizedText) -> BraillePrintBlock {
        BraillePrintBlock(block: .paragraph(text: print.text), emphasis: print.emphasis)
    }

    /// A list item at `depth` holding `print`.
    static func listItem(depth: Int, _ print: EmphasizedText) -> BraillePrintBlock {
        BraillePrintBlock(block: .listItem(depth: depth, text: print.text), emphasis: print.emphasis)
    }

    /// The block's print with its emphasis, as the translator takes it.
    var print: EmphasizedText {
        EmphasizedText(block.text, emphasis: emphasis) ?? EmphasizedText(block.text)
    }

    /// The same block with `prefix`, unemphasized, before its print: an
    /// ordered list's number before its item's words.
    func prefixed(with prefix: String) -> BraillePrintBlock {
        var prefixed = EmphasizedText(prefix)
        prefixed.append(print)
        return BraillePrintBlock(block: block.withText(prefixed.text), emphasis: prefixed.emphasis)
    }
}

// MARK: - Writer

/// Turns a document's print blocks into a BRF or PEF file (FMT22, Phase A):
/// it translates the blocks to braille through liblouis
/// (`BrailleTranslator`), lays them out in pages (`BrailleLayout`), and
/// frames the pages as a file (`BrailleFileWriter`).
///
/// Every input here is print, as the document walker (team `export`, wired
/// in by Phase B) produces it. The layout and the file writers are pure, so
/// only the translation runs a process, the watched helper, in `folder`.
enum BrailleDocumentWriter {
    /// The pages `blocks` make as braille, their print with no emphasis:
    /// `pages(of:options:workingIn:)` of print blocks, which this is.
    static func pages(
        of blocks: [BrailleBlock],
        options: BrailleExportOptions,
        workingIn folder: URL
    ) throws -> [[String]] {
        try pages(of: blocks.map { BraillePrintBlock($0) }, options: options, workingIn: folder)
    }

    /// The pages `blocks` make as braille: each block's print translated
    /// with `options.table`, with its emphasis, which liblouis writes as the
    /// table's indicators where it reads them back exactly
    /// (`BraillePrintBlock`), keeping its kind and its level or depth, then
    /// laid out at `options.page`. No blocks give no pages (the translator
    /// runs no helper for them, but still refuses an unknown table).
    /// - Parameter folder: Where the translator makes its hidden files; it is
    ///   left empty again.
    /// - Throws: whatever `BrailleTranslator.translate` throws, unchanged;
    ///   and `BrailleFileWriter.EightDotCell`, naming the character, when
    ///   the table writes a block with an eight-dot cell that TextMouth's
    ///   six-dot files cannot hold (review R1).
    static func pages(
        of blocks: [BraillePrintBlock],
        options: BrailleExportOptions,
        workingIn folder: URL
    ) throws -> [[String]] {
        let texts = blocks.map { printForBraille($0.print) }
        let braille = try BrailleTranslator.translate(
            texts, table: options.table, direction: .printToBraille, workingIn: folder
        )
        // One translation per block, in order; a mismatch would pair a block
        // with another's text, so it is refused rather than guessed at.
        guard braille.count == blocks.count else {
            throw BrailleTranslator.Failure.failed
        }
        // An eight-dot cell a table makes from an ordinary character is never
        // written as its six-dot part: the book fails, naming the character
        // (review R1). Some tables write one for a character they define so,
        // such as the Mac's Swedish tables for «. No table, bundled or on
        // this Mac, writes an emphasis indicator in eight dots (all 328 of
        // macOS 26's were measured on October 21, 2026), so emphasis adds no
        // such failure.
        for (text, cells) in zip(texts, braille) {
            guard let cell = BrailleCells.firstEightDotCell(in: cells.text) else { continue }
            let character = try character(writtenWithEightDotsIn: text.text, table: options.table, workingIn: folder)
            throw BrailleFileWriter.EightDotCell(cell: cell, character: character)
        }
        let translated = zip(blocks, braille).map { block, cells in block.block.withText(cells.text) }
        return BrailleLayout.pages(of: translated, format: options.page)
    }

    /// `text` as an export gives it to the translator (review F1). Every
    /// bundled table writes a braille pattern in the print as itself
    /// (`braille-patterns.cti`), so an eight-dot pattern there, as in braille
    /// art or a text about eight-dot braille ("⣏⣀⣹"), is written as its
    /// six-dot part, its dots 7 and 8 dropped, as every export wrote such a
    /// cell before review R1; an eight-dot cell a table makes from an
    /// ordinary character is still refused. Unicode's noncharacters
    /// (U+FDD0 to U+FDEF, and the last two code points of every plane, such
    /// as U+FFFF), which hold no text and which liblouis writes as an
    /// eight-dot cell, are removed.
    static func printForBraille(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.compactMap(printScalar)))
    }

    /// `printForBraille(_:)` of a text with its emphasis: each scalar kept
    /// keeps its emphasis, and a scalar removed takes its emphasis with it.
    static func printForBraille(_ text: EmphasizedText) -> EmphasizedText {
        guard text.hasEmphasis else { return EmphasizedText(printForBraille(text.text)) }
        var result = EmphasizedText()
        for (scalar, flags) in zip(text.text.unicodeScalars, text.emphasis) {
            guard let kept = printScalar(scalar) else { continue }
            result.append(kept, flags)
        }
        return result
    }

    /// The scalar `printForBraille(_:)` gives the translator for `scalar`:
    /// an eight-dot braille pattern's six-dot part, nothing for a
    /// noncharacter, and any other scalar as it is.
    private static func printScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let value = scalar.value
        if (0xFDD0...0xFDEF).contains(value) || value & 0xFFFE == 0xFFFE { return nil }
        return BrailleCells.usesEightDots(scalar) ? BrailleCells.sixDotPart(of: scalar) : scalar
    }

    /// The character of `text` that `table` writes with an eight-dot cell:
    /// each distinct character of `text` but white space is translated
    /// alone, in one run of the helper, and the first whose cells hold such
    /// a cell is the one. Nil when no character does so alone, as for a rule
    /// that spans several characters.
    /// - Throws: whatever `BrailleTranslator.translate` throws.
    private static func character(
        writtenWithEightDotsIn text: String,
        table: String,
        workingIn folder: URL
    ) throws -> Character? {
        var seen = Set<Character>()
        let characters = text.filter { !$0.isWhitespace && seen.insert($0).inserted }
        let cells = try BrailleTranslator.translate(
            characters.map(String.init), table: table, direction: .printToBraille, workingIn: folder
        )
        return zip(characters, cells).first { BrailleCells.firstEightDotCell(in: $0.1) != nil }?.0
    }

    /// `blocks` (print) as the bytes of a BRF file: the pages of `pages(of:…)`
    /// as braille ASCII with `options.lineEnd`. No blocks give an empty file.
    /// - Throws: the translator's errors, unchanged, and
    ///   `BrailleFileWriter.EightDotCell` (review R1).
    static func brf(of blocks: [BraillePrintBlock], options: BrailleExportOptions, workingIn folder: URL) throws -> Data {
        try BrailleFileWriter.brf(
            pages: try pages(of: blocks, options: options, workingIn: folder), lineEnd: options.lineEnd
        )
    }

    /// `brf(of:options:workingIn:)` of blocks whose print has no emphasis.
    static func brf(of blocks: [BrailleBlock], options: BrailleExportOptions, workingIn folder: URL) throws -> Data {
        try brf(of: blocks.map { BraillePrintBlock($0) }, options: options, workingIn: folder)
    }

    /// `blocks` (print) as the bytes of a PEF file: the pages of `pages(of:…)`
    /// under `metadata`, in a volume the size of `options.page`. No blocks
    /// give a PEF with no `page`.
    /// - Throws: the translator's errors, unchanged, and
    ///   `BrailleFileWriter.EightDotCell` (review R1).
    static func pef(
        of blocks: [BraillePrintBlock],
        metadata: PEFMetadata,
        options: BrailleExportOptions,
        workingIn folder: URL
    ) throws -> Data {
        try BrailleFileWriter.pef(
            pages: try pages(of: blocks, options: options, workingIn: folder), metadata: metadata, format: options.page
        )
    }

    /// `pef(of:metadata:options:workingIn:)` of blocks whose print has no
    /// emphasis.
    static func pef(
        of blocks: [BrailleBlock],
        metadata: PEFMetadata,
        options: BrailleExportOptions,
        workingIn folder: URL
    ) throws -> Data {
        try pef(of: blocks.map { BraillePrintBlock($0) }, metadata: metadata, options: options, workingIn: folder)
    }
}
