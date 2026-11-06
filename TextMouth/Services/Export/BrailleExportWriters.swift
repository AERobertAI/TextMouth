import Foundation
import SwiftUI

// MARK: - From the Export Model to Braille Blocks

/// Turns an `ExportDocument` into the print blocks braille is made from
/// (FMT22, Phase B): the headings, paragraphs, and list items
/// `BrailleDocumentWriter` translates and lays out in pages.
///
/// The document's own structure decides every block, never its text's line
/// feeds: a list is walked item by item through `ExportListItem.blocks`
/// (never `plainText`, which joins an item with the lists inside it), so a
/// nested list keeps its depth. Text is print, as the walker made it.
///
/// Each block's print keeps its runs' emphasis (October 21, 2026: the user
/// asked that exported braille mark italics), which liblouis writes as the
/// table's indicators where it reads them back exactly (UEB; EBAE and most
/// of this Mac's tables write plain braille, see `BraillePrintBlock`):
/// emphasis (`*…*`) as italic and strong (`**…**`) as bold, both as both
/// (`EmphasizedText(runs:)`). Text with no runs of its own, a code block's
/// lines, a table's cells, an ordered item's number, and the book's title,
/// is plain.
enum BrailleExportBlocks {
    /// The blocks of `document` in reading order, their print without its
    /// emphasis: the blocks of `printBlocks(of:)`.
    static func blocks(of document: ExportDocument) -> [BrailleBlock] {
        printBlocks(of: document).map(\.block)
    }

    /// The blocks of `document` in reading order, each with the emphasis of
    /// its print: its title heading first, when it has one, then each block
    /// of `document.blocks`.
    static func printBlocks(of document: ExportDocument) -> [BraillePrintBlock] {
        var result: [BraillePrintBlock] = []
        if let title = document.titleHeading {
            result.append(BraillePrintBlock(.heading(level: 1, text: title.plainText)))
        }
        append(document.blocks, itemDepth: nil, to: &result)
        return result
    }

    /// Appends the braille blocks of `blocks` to `result`.
    /// - Parameter itemDepth: The depth of the list item the blocks are in
    ///   (1 for an item of a top-level list), or nil outside every list. Text
    ///   the blocks hold is a list item of that depth inside an item, and a
    ///   paragraph elsewhere; a heading is a heading wherever it is.
    private static func append(_ blocks: [ExportBlock], itemDepth: Int?, to result: inout [BraillePrintBlock]) {
        for block in blocks {
            switch block {
            case let .heading(heading):
                result.append(.heading(level: heading.level, EmphasizedText(runs: heading.runs)))
            case let .paragraph(runs):
                result.append(textBlock(EmphasizedText(runs: runs), itemDepth: itemDepth))
            case let .list(list):
                append(list, to: &result)
            case let .blockQuote(quoted):
                // A quote's text is the text of its blocks, in the place it
                // stands: braille has no quote layout of its own.
                append(quoted, itemDepth: itemDepth, to: &result)
            case let .codeBlock(code):
                // One block for each line that has text: braille wraps and
                // indents by words, so an empty line holds nothing.
                for line in code.components(separatedBy: "\n") where !line.isEmpty {
                    result.append(textBlock(EmphasizedText(line), itemDepth: itemDepth))
                }
            case let .table(table):
                // One block for each row, its cells apart by a semicolon.
                for row in table.rows {
                    result.append(textBlock(EmphasizedText(row.joined(separator: "; ")), itemDepth: itemDepth))
                }
            case .thematicBreak, .pageBreak:
                // A break holds no text, so braille has nothing to write.
                break
            }
        }
    }

    /// Appends the items of `list`: the text of an item is list items one
    /// deeper than the list, and a list inside an item recurses. An ordered
    /// list's item begins with its number and a period (BANA lays an
    /// unordered list out by its margins, so those items have no mark).
    private static func append(_ list: ExportList, to result: inout [BraillePrintBlock]) {
        let depth = list.depth + 1
        for (index, item) in list.items.enumerated() {
            let before = result.count
            append(item.blocks, itemDepth: depth, to: &result)
            guard list.isOrdered else { continue }
            // The number goes before the item's first block when that is one
            // of this item's own lines of text; any other first block (a
            // heading or a list inside it) leaves the number a line alone.
            let mark = "\(list.start + index)."
            if result.count > before, result[before].block.isListItem(atDepth: depth) {
                result[before] = result[before].prefixed(with: "\(mark) ")
            } else {
                result.insert(BraillePrintBlock(.listItem(depth: depth, text: mark)), at: before)
            }
        }
    }

    /// A block of `text`: a list item at `itemDepth` inside a list item, a
    /// paragraph elsewhere.
    private static func textBlock(_ text: EmphasizedText, itemDepth: Int?) -> BraillePrintBlock {
        if let itemDepth {
            return .listItem(depth: itemDepth, text)
        }
        return .paragraph(text)
    }
}

extension EmphasizedText {
    /// The text of `runs`, joined, each run's scalars with its emphasis:
    /// emphasis (`*…*`) as italic, strong (`**…**`) as bold.
    ///
    /// Code (`isCode`) keeps the emphasis it stands in and nothing more.
    /// liblouis has a typeform for computer braille, but liblouis 3.39.0
    /// only declares it (`liblouis.h`) and never reads it: all four bundled
    /// tables write a code span with it exactly as without it, in six dots
    /// (measured October 21, 2026). EBAE writes Computer Braille Code only
    /// where its own `compbrl` rules match the text, such as "www." or "()",
    /// with the typeform or without. So code is sent as the text it is.
    init(runs: [ExportRun]) {
        self.init()
        for run in runs {
            var flags: BrailleEmphasis = []
            if run.isEmphasis { flags.insert(.italic) }
            if run.isStrong { flags.insert(.bold) }
            append(contentsOf: run.text, flags)
        }
    }
}

private extension BrailleBlock {
    /// Whether this is a list item of exactly `depth`.
    func isListItem(atDepth depth: Int) -> Bool {
        if case let .listItem(itemDepth, _) = self { return itemDepth == depth }
        return false
    }
}

// MARK: - The Writers

/// What the BRF and PEF writers share (FMT22, Phase B): the blocks of the
/// document, the cancellation checks, the translation errors in the
/// dialog's words, and the file's single write. Only the bytes differ.
private enum BrailleExportWriting {
    /// Writes `document` as a new file at `url`: the bytes `makeData` makes
    /// of its print blocks, with their emphasis, given the folder the
    /// translator may make its hidden files in (the export's scratch folder,
    /// which holds `url`).
    /// - Throws: `CancellationError` when stopped before, during, or after
    ///   the translation; a `TextExportError` saying why the translator
    ///   failed; and whatever writing the file throws (a file already at
    ///   `url` is an error, and is left as it was).
    static func write(
        _ document: ExportDocument,
        to url: URL,
        cancellation: BookExportCancellation,
        makeData: ([BraillePrintBlock], _ folder: URL) throws -> Data
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        let data: Data
        do {
            // The braille helper listens to the export's Stop as it listens
            // to an import's Cancel (TODO 3985): Stop kills a translation
            // under way at once, rather than waiting up to its time limit.
            data = try ImportCancellation.$current.withValue(cancellation.childProcesses) {
                try makeData(BrailleExportBlocks.printBlocks(of: document), url.deletingLastPathComponent())
            }
        } catch is ImportCancelled {
            // Stop killed the helper: the book ends as one stopped between
            // its steps does, and nothing is written.
            throw CancellationError()
        } catch let failure as BrailleTranslator.Failure {
            // The dialog names the file before this sentence.
            throw TextExportError(failure.localizedDescription)
        } catch let cell as BrailleFileWriter.EightDotCell {
            // A cell TextMouth's six-dot files cannot hold, never masked
            // (review R1): the sentence names the character.
            throw TextExportError(cell.localizedDescription)
        }
        // The translation may have taken a while; Stop may have been pressed.
        try cancellation.checkCancelled()
        try data.write(to: url, options: .withoutOverwriting)
    }
}

/// Writes a text book as a BRF file (FMT22): pages of braille, each cell a
/// character of the braille file characters the options choose (North
/// American Braille ASCII unless another is chosen, braillecodes), for
/// braille displays and embossers. The text is translated with the options'
/// table, its emphasis written as the table's indicators where liblouis
/// reads them back exactly, and laid out as BANA's Braille Formats says
/// (`BrailleDocumentWriter`).
struct BRFExportWriter: TextExportWriter {
    let id = "brf"
    let name = "BRF"
    /// The picker's hint. It says "braille", not "braille ASCII": the options
    /// may write a BRF in Eurobraille or in Unicode braille patterns.
    let hint = "Braille Ready Format: pages of braille, for braille displays and embossers."
    let fileExtension = "brf"

    /// The user's defaults: 40 cells by 25 lines, page numbers on, CR LF,
    /// and the Braille setting's table and braille file characters
    /// (`BrailleExportOptions.standard()`).
    @MainActor func defaultOptions() -> BrailleExportOptions {
        BrailleExportOptions.standard()
    }

    /// The options under the Convert to picker, with the line ends a BRF has.
    @MainActor func optionsView(_ options: Binding<BrailleExportOptions>) -> BrailleExportOptionsView {
        BrailleExportOptionsView(options: options, choosesLineEnds: true)
    }

    func write(
        _ document: ExportDocument,
        options: BrailleExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        try BrailleExportWriting.write(document, to: url, cancellation: cancellation) { blocks, folder in
            try BrailleDocumentWriter.brf(of: blocks, options: options, workingIn: folder)
        }
    }
}

/// Writes a text book as a PEF file (FMT22): pages of Unicode braille in
/// XML, for embossers. The book's title, author, and language go in the
/// file's metadata. A PEF always ends its rows with a line feed, so its
/// options view has no line ends.
struct PEFExportWriter: TextExportWriter {
    let id = "pef"
    let name = "PEF"
    let hint = "Portable Embosser Format: pages of Unicode braille in XML, for embossers."
    let fileExtension = "pef"

    /// The user's defaults, as the BRF writer's.
    @MainActor func defaultOptions() -> BrailleExportOptions {
        BrailleExportOptions.standard()
    }

    /// The options under the Convert to picker, without line ends.
    @MainActor func optionsView(_ options: Binding<BrailleExportOptions>) -> BrailleExportOptionsView {
        BrailleExportOptionsView(options: options, choosesLineEnds: false)
    }

    func write(
        _ document: ExportDocument,
        options: BrailleExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        let metadata = Self.metadata(of: document.book)
        try BrailleExportWriting.write(document, to: url, cancellation: cancellation) { blocks, folder in
            try BrailleDocumentWriter.pef(of: blocks, metadata: metadata, options: options, workingIn: folder)
        }
    }

    /// The PEF's metadata for `book`: its title, its author or nothing when
    /// unknown, its language or English when it names none, an identifier
    /// made of `id`, and the day `date` falls on.
    static func metadata(of book: ExportBookDetails, id: UUID = UUID(), date: Date = Date()) -> PEFMetadata {
        PEFMetadata(
            title: book.title,
            author: book.author ?? "",
            language: book.language ?? "en",
            identifier: "urn:uuid:\(id.uuidString.lowercased())",
            date: dayString(of: date)
        )
    }

    /// `date` as yyyy-MM-dd in the Gregorian calendar and the POSIX locale,
    /// the form a PEF's date takes, whatever the Mac's own calendar.
    static func dayString(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
