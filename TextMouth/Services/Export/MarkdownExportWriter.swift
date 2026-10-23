import Foundation

// MARK: - The Markdown Writer (T3)

/// Writes a text book as Markdown for people and other programs to read: its
/// headings, paragraphs, lists, quotes, code, breaks, and tables, with only the
/// backslashes Markdown needs (`MarkdownLiteral.minimallyEscaped`).
///
/// content.md, TextMouth's own cache, escapes every ASCII punctuation
/// character so that its reader reads exactly the book's characters, and it
/// must stay as it is. The export therefore does not copy it: it writes the
/// Markdown afresh from the same walk every other text writer reads
/// (`ExportDocumentWalker` into `ExportDocument`), so that a comma or a period
/// is a comma or a period in the file. Read back by `ExportDocumentWalker`, the
/// file walks to the blocks it was written from.
///
/// The writer is the Markdown choice of the Convert to picker, which the
/// picker lists first by `TextExportWriters.markdownID` and not through
/// `TextExportWriters.all`. It writes no `titleHeading`: the export is the
/// book's text as content.md holds it.
struct MarkdownExportWriter: TextExportWriter {
    let id = "md"
    let name = "Markdown"
    let fileExtension = "md"
    let hint = BookExportWording.markdownChoiceHint

    /// Writes the Markdown of `document` as UTF-8 to a new file at `url`; a
    /// file already there is an error, and is left as it was.
    func write(
        _ document: ExportDocument,
        options: NoTextExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        let markdown = try Self.markdown(of: document, cancellation: cancellation)
        // `.withoutOverwriting` makes a file that is already there an error.
        try Data(markdown.utf8).write(to: url, options: .withoutOverwriting)
    }

    // MARK: The Document

    /// The Markdown of `document`: its blocks apart by one blank line, the
    /// text ending in one line feed (an empty document is empty). Calls
    /// `cancellation`'s `checkCancelled()` before each top-level block.
    static func markdown(of document: ExportDocument, cancellation: BookExportCancellation? = nil) throws -> String {
        var written: [[String]] = []
        for block in document.blocks {
            try cancellation?.checkCancelled()
            written.append(writtenLines(of: block))
        }
        let lines = apart(written)
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: Blocks

    /// The lines of `blocks`, apart by a blank line: the blocks inside a list
    /// item or a quote, which the model bounds in depth
    /// (`ExportDocument.maximumNesting`), so no cancellation check is needed
    /// between them.
    private static func blockLines(_ blocks: [ExportBlock]) -> [String] {
        apart(blocks.map(writtenLines(of:)))
    }

    /// The lines of blocks already written, `written` one block each, apart by
    /// a blank line. A block that wrote no line (a list with no item, a table
    /// with no cell) is left out.
    private static func apart(_ written: [[String]]) -> [String] {
        var lines: [String] = []
        for block in written where !block.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += block
        }
        return lines
    }

    /// The lines of one block.
    private static func writtenLines(of block: ExportBlock) -> [String] {
        switch block {
        case .heading(let heading):
            return headingLines(heading)
        case .paragraph(let runs):
            return paragraphLines(runs)
        case .list(let list):
            return listLines(list)
        case .blockQuote(let blocks):
            let quoted = blockLines(blocks)
            return quoted.isEmpty ? [">"] : quoted.map { $0.isEmpty ? ">" : "> " + $0 }
        case .codeBlock(let code):
            return codeBlockLines(code)
        case .thematicBreak:
            return ["---"]
        case .table(let table):
            return tableLines(table)
        }
    }

    /// A heading: `#` as many times as its level (kept within 1 to 6), a
    /// space, and its runs on one line (a line feed in it is a space). The
    /// line's start needs no guard, because the `#` marker comes first.
    private static func headingLines(_ heading: ExportHeading) -> [String] {
        let runs = heading.runs.map { run -> ExportRun in
            var single = run
            if !run.isCode { single.text = run.text.replacingOccurrences(of: "\n", with: " ") }
            return single
        }
        let marker = String(repeating: "#", count: min(max(heading.level, 1), 6))
        let text = lineMarkdown(trimmed(runs))
        return [text.isEmpty ? marker : marker + " " + text]
    }

    /// A paragraph: its runs, each line of it (a line feed in a run is a hard
    /// break) guarded at its start (`MarkdownLiteral.guardingLineStart`), and
    /// the lines apart by a backslash and a line feed, Markdown's hard break.
    private static func paragraphLines(_ runs: [ExportRun]) -> [String] {
        let lines = hardBrokenLines(of: runs)
            .map { MarkdownLiteral.guardingLineStart(lineMarkdown($0)) }
            .filter { !$0.isEmpty }
        // The backslash joins each line to the one after it; the last has none.
        return lines.indices.map { lines[$0] + ($0 == lines.index(before: lines.endIndex) ? "" : "\\") }
    }

    // MARK: Lists and Quotes

    /// A list: an unordered item begins `- `, an ordered one with its number,
    /// a period, and a space, numbering from the list's `start`. Items are apart
    /// by a line feed only, so the list stays one tight list.
    private static func listLines(_ list: ExportList) -> [String] {
        // CommonMark reads at most nine digits of a number.
        let maximumNumber = 999_999_999
        let first = min(max(list.start, 0), maximumNumber)
        var lines: [String] = []
        for (offset, item) in list.items.enumerated() {
            let marker = list.isOrdered ? "\(min(first + offset, maximumNumber)). " : "- "
            lines += itemLines(item, marker: marker)
        }
        return lines
    }

    /// One list item: its blocks (apart by a blank line) with the first line
    /// after `marker` and the others indented by the marker's width; blank
    /// lines stay empty. An item with no block is its marker alone.
    private static func itemLines(_ item: ExportListItem, marker: String) -> [String] {
        let body = blockLines(item.blocks)
        guard let first = body.first else {
            return [String(marker.dropLast())]
        }
        let indent = String(repeating: " ", count: marker.count)
        return [marker + first] + body.dropFirst().map { $0.isEmpty ? "" : indent + $0 }
    }

    // MARK: Code

    /// A fenced code block: the fence is backticks, one more than the longest
    /// run of backticks in the code, and at least three; the code's lines are
    /// written as they are.
    private static func codeBlockLines(_ code: String) -> [String] {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: code) + 1))
        let body = code.isEmpty ? [] : code.components(separatedBy: "\n")
        return [fence] + body + [fence]
    }

    /// A code span: a backtick string one longer than the longest run of
    /// backticks in the code, padded with a space on each side when the code
    /// begins or ends with a backtick, or begins and ends with a space and is
    /// not all spaces (Markdown strips one space from each end of such code).
    /// Line feeds in it are spaces.
    private static func codeSpan(_ code: String) -> String {
        let text = code.replacingOccurrences(of: "\n", with: " ")
        let fence = String(repeating: "`", count: longestBacktickRun(in: text) + 1)
        let needsPadding = text.first == "`" || text.last == "`"
            || (text.first == " " && text.last == " " && text.contains { $0 != " " })
        return needsPadding ? "\(fence) \(text) \(fence)" : fence + text + fence
    }

    /// The length of the longest run of backticks in `text`.
    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    // MARK: Tables

    /// A table in GitHub's form. The walker leaves out a header row whose
    /// cells are all empty (`ExportTable.hasHeaderRow` is then false), so a
    /// table without one is written with an empty header row, which walks back
    /// as it was. Every row has as many cells as the longest; a cell is
    /// minimally escaped, its line feeds spaces.
    private static func tableLines(_ table: ExportTable) -> [String] {
        let columns = table.rows.map(\.count).max() ?? 0
        guard columns > 0 else { return [] }
        /// A row padded to `columns` cells, as one line of the table.
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: columns - cells.count)
            let escaped = padded.map { cell in
                MarkdownLiteral.minimallyEscaped(cell.replacingOccurrences(of: "\n", with: " "))
            }
            return "| " + escaped.joined(separator: " | ") + " |"
        }
        let header = table.hasHeaderRow ? (table.rows.first ?? []) : []
        let body = table.hasHeaderRow ? Array(table.rows.dropFirst()) : table.rows
        let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        return [line(header), delimiter] + body.map(line)
    }

    // MARK: Runs

    /// `runs` as lines of runs: a line feed in a run that is not code begins a
    /// new line (a hard break), a line feed in code is a space, and each line
    /// is trimmed of spaces and tabs at its ends and dropped if nothing is left.
    private static func hardBrokenLines(of runs: [ExportRun]) -> [[ExportRun]] {
        var lines: [[ExportRun]] = [[]]
        for run in runs {
            var piece = run
            if run.isCode {
                piece.text = run.text.replacingOccurrences(of: "\n", with: " ")
                lines[lines.count - 1].append(piece)
                continue
            }
            for (index, part) in run.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { lines.append([]) }
                piece.text = String(part)
                lines[lines.count - 1].append(piece)
            }
        }
        return lines.map(trimmed).filter { !$0.isEmpty }
    }

    /// `runs` without empty runs and without spaces and tabs at either end of
    /// the line (code is kept as it is).
    private static func trimmed(_ runs: [ExportRun]) -> [ExportRun] {
        var runs = runs.filter { !$0.text.isEmpty }
        /// Whether `character` is a space or a tab.
        func isBlank(_ character: Character) -> Bool { character == " " || character == "\t" }
        while let first = runs.first, !first.isCode {
            let rest = first.text.drop(while: isBlank)
            if rest.isEmpty {
                runs.removeFirst()
            } else {
                runs[0].text = String(rest)
                break
            }
        }
        while let last = runs.last, !last.isCode {
            var text = last.text
            while let end = text.last, isBlank(end) { text.removeLast() }
            if text.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.count - 1].text = text
                break
            }
        }
        return runs
    }

    /// One line of runs as Markdown: the runs of one link written as one link
    /// (`[`, their Markdown, `](<`, the address, `>)`), and every other run
    /// by itself (`inlineMarkdown`).
    private static func lineMarkdown(_ runs: [ExportRun]) -> String {
        runs.linkGroups.map { group in
            let inner = inlineMarkdown(group.runs)
            guard let address = group.link, !inner.isEmpty else { return inner }
            // Inside `<…>` only a backslash and the angle brackets need escapes.
            let escapedAddress = address.reduce(into: "") { result, character in
                if character == "\\" || character == "<" || character == ">" { result.append("\\") }
                result.append(character)
            }
            return "[\(inner)](<\(escapedAddress)>)"
        }.joined()
    }

    /// `runs`, none of them in a link, as Markdown: neighbouring plain and
    /// emphasised runs go through `MarkdownEmphasis` with the minimal escapes
    /// as its literal writer, and a code run is a code span, which holds no
    /// emphasis of its own.
    private static func inlineMarkdown(_ runs: [ExportRun]) -> String {
        var result = ""
        var text = ""
        var styles: [MarkdownEmphasis.Style] = []
        /// Writes the text and styles gathered so far.
        func flush() {
            result += MarkdownEmphasis.markdown(text, styles: styles, literal: { MarkdownLiteral.minimallyEscaped($0) })
            text = ""
            styles = []
        }
        for run in runs {
            if run.isCode {
                flush()
                result += codeSpan(run.text)
                continue
            }
            var style: MarkdownEmphasis.Style = []
            if run.isEmphasis { style.insert(.emphasis) }
            if run.isStrong { style.insert(.strong) }
            text += run.text
            styles += Array(repeating: style, count: run.text.unicodeScalars.count)
        }
        flush()
        return result
    }
}
