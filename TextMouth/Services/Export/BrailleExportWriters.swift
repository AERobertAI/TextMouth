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
enum BrailleExportBlocks {
    /// The blocks of `document` in reading order: its title heading first,
    /// when it has one, then each block of `document.blocks`.
    static func blocks(of document: ExportDocument) -> [BrailleBlock] {
        var result: [BrailleBlock] = []
        if let title = document.titleHeading {
            result.append(.heading(level: 1, text: title.plainText))
        }
        append(document.blocks, itemDepth: nil, to: &result)
        return result
    }

    /// Appends the braille blocks of `blocks` to `result`.
    /// - Parameter itemDepth: The depth of the list item the blocks are in
    ///   (1 for an item of a top-level list), or nil outside every list. Text
    ///   the blocks hold is a list item of that depth inside an item, and a
    ///   paragraph elsewhere; a heading is a heading wherever it is.
    private static func append(_ blocks: [ExportBlock], itemDepth: Int?, to result: inout [BrailleBlock]) {
        for block in blocks {
            switch block {
            case let .heading(heading):
                result.append(.heading(level: heading.level, text: heading.plainText))
            case let .paragraph(runs):
                result.append(textBlock(runs.plainText, itemDepth: itemDepth))
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
                    result.append(textBlock(line, itemDepth: itemDepth))
                }
            case let .table(table):
                // One block for each row, its cells apart by a semicolon.
                for row in table.rows {
                    result.append(textBlock(row.joined(separator: "; "), itemDepth: itemDepth))
                }
            case .thematicBreak:
                // A break holds no text, so braille has nothing to write.
                break
            }
        }
    }

    /// Appends the items of `list`: the text of an item is list items one
    /// deeper than the list, and a list inside an item recurses. An ordered
    /// list's item begins with its number and a period (BANA lays an
    /// unordered list out by its margins, so those items have no mark).
    private static func append(_ list: ExportList, to result: inout [BrailleBlock]) {
        let depth = list.depth + 1
        for (index, item) in list.items.enumerated() {
            let before = result.count
            append(item.blocks, itemDepth: depth, to: &result)
            guard list.isOrdered else { continue }
            // The number goes before the item's first block when that is one
            // of this item's own lines of text; any other first block (a
            // heading or a list inside it) leaves the number a line alone.
            let mark = "\(list.start + index)."
            if result.count > before, result[before].isListItem(atDepth: depth) {
                result[before] = .listItem(depth: depth, text: "\(mark) \(result[before].text)")
            } else {
                result.insert(.listItem(depth: depth, text: mark), at: before)
            }
        }
    }

    /// A block of `text`: a list item at `itemDepth` inside a list item, a
    /// paragraph elsewhere.
    private static func textBlock(_ text: String, itemDepth: Int?) -> BrailleBlock {
        if let itemDepth {
            return .listItem(depth: itemDepth, text: text)
        }
        return .paragraph(text: text)
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
    /// of its blocks, given the folder the translator may make its hidden
    /// files in (the export's scratch folder, which holds `url`).
    /// - Throws: `CancellationError` when stopped before or after the
    ///   translation; a `TextExportError` saying why the translator failed;
    ///   and whatever writing the file throws (a file already at `url` is an
    ///   error, and is left as it was).
    static func write(
        _ document: ExportDocument,
        to url: URL,
        cancellation: BookExportCancellation,
        makeData: ([BrailleBlock], _ folder: URL) throws -> Data
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        let data: Data
        do {
            data = try makeData(BrailleExportBlocks.blocks(of: document), url.deletingLastPathComponent())
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

/// Writes a text book as a BRF file (FMT22): pages of braille ASCII, for
/// braille displays and embossers. The text is translated with the options'
/// table and laid out as BANA's Braille Formats says
/// (`BrailleDocumentWriter`).
struct BRFExportWriter: TextExportWriter {
    let id = "brf"
    let name = "BRF"
    let hint = "Braille Ready Format: pages of braille ASCII, for braille displays and embossers."
    let fileExtension = "brf"

    /// The user's defaults: 40 cells by 25 lines, page numbers on, CR LF,
    /// and the Braille setting's table.
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
