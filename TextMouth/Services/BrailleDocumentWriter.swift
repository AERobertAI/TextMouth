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
    /// The pages `blocks` make as braille: each block's print translated
    /// with `options.table` (keeping its kind and its level or depth), then
    /// laid out at `options.page`. No blocks give no pages (the translator runs no helper
    /// for them, but still refuses an unknown table).
    /// - Parameter folder: Where the translator makes its hidden files; it is
    ///   left empty again.
    /// - Throws: whatever `BrailleTranslator.translate` throws, unchanged;
    ///   and `BrailleFileWriter.EightDotCell`, naming the character, when
    ///   the table writes a block with an eight-dot cell that TextMouth's
    ///   six-dot files cannot hold (review R1).
    static func pages(
        of blocks: [BrailleBlock],
        options: BrailleExportOptions,
        workingIn folder: URL
    ) throws -> [[String]] {
        let braille = try BrailleTranslator.translate(
            blocks.map(\.text), table: options.table, direction: .printToBraille, workingIn: folder
        )
        // One translation per block, in order; a mismatch would pair a block
        // with another's text, so it is refused rather than guessed at.
        guard braille.count == blocks.count else {
            throw BrailleTranslator.Failure.failed
        }
        // An eight-dot cell is never written as its six-dot part: the book
        // fails, naming the character (review R1). Some tables write one for
        // a character they define so, such as the Mac's Swedish tables for «.
        for (block, cells) in zip(blocks, braille) {
            guard let cell = BrailleCells.firstEightDotCell(in: cells) else { continue }
            let character = try character(writtenWithEightDotsIn: block.text, table: options.table, workingIn: folder)
            throw BrailleFileWriter.EightDotCell(cell: cell, character: character)
        }
        let translated = zip(blocks, braille).map { block, cells in block.withText(cells) }
        return BrailleLayout.pages(of: translated, format: options.page)
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
    static func brf(of blocks: [BrailleBlock], options: BrailleExportOptions, workingIn folder: URL) throws -> Data {
        try BrailleFileWriter.brf(
            pages: try pages(of: blocks, options: options, workingIn: folder), lineEnd: options.lineEnd
        )
    }

    /// `blocks` (print) as the bytes of a PEF file: the pages of `pages(of:…)`
    /// under `metadata`, in a volume the size of `options.page`. No blocks
    /// give a PEF with no `page`.
    /// - Throws: the translator's errors, unchanged, and
    ///   `BrailleFileWriter.EightDotCell` (review R1).
    static func pef(
        of blocks: [BrailleBlock],
        metadata: PEFMetadata,
        options: BrailleExportOptions,
        workingIn folder: URL
    ) throws -> Data {
        try BrailleFileWriter.pef(
            pages: try pages(of: blocks, options: options, workingIn: folder), metadata: metadata, format: options.page
        )
    }
}
