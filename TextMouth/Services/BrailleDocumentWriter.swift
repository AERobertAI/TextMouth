import Foundation

// MARK: - Options

/// What a braille export writes (FMT22): the user's October 17 defaults,
/// each changeable in the Export dialog.
struct BrailleExportOptions: Equatable, Sendable {
    /// Cells per line, lines per page, and whether pages carry numbers.
    var page = BraillePageFormat()
    /// The table, by file name: the code and its contraction.
    var table = BrailleTableCatalog.defaultTableID
    /// The line end a BRF file writes after each row (a PEF always uses LF).
    var lineEnd = BrailleLineEnd.crlf

    /// The defaults (40 cells by 25 lines, page numbers on, CR LF), with the
    /// table the Braille setting chose (`BraillePreferences.importTable()`:
    /// the setting, or a test's bound table).
    static func standard() -> BrailleExportOptions {
        BrailleExportOptions(table: BraillePreferences.importTable())
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
    /// - Throws: whatever `BrailleTranslator.translate` throws, unchanged.
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
        let translated = zip(blocks, braille).map { block, cells in block.withText(cells) }
        return BrailleLayout.pages(of: translated, format: options.page)
    }

    /// `blocks` (print) as the bytes of a BRF file: the pages of `pages(of:…)`
    /// as braille ASCII with `options.lineEnd`. No blocks give an empty file.
    /// - Throws: the translator's errors, unchanged.
    static func brf(of blocks: [BrailleBlock], options: BrailleExportOptions, workingIn folder: URL) throws -> Data {
        BrailleFileWriter.brf(
            pages: try pages(of: blocks, options: options, workingIn: folder), lineEnd: options.lineEnd
        )
    }

    /// `blocks` (print) as the bytes of a PEF file: the pages of `pages(of:…)`
    /// under `metadata`, in a volume the size of `options.page`. No blocks
    /// give a PEF with no `page`.
    /// - Throws: the translator's errors, unchanged.
    static func pef(
        of blocks: [BrailleBlock],
        metadata: PEFMetadata,
        options: BrailleExportOptions,
        workingIn folder: URL
    ) throws -> Data {
        BrailleFileWriter.pef(
            pages: try pages(of: blocks, options: options, workingIn: folder), metadata: metadata, format: options.page
        )
    }
}
