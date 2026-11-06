import Foundation

// MARK: - The RTF Writer (FMT19)

/// Writes a text book as Rich Text Format whose headings carry real outline
/// levels, for Word, Pages, and TextEdit.
///
/// TextMouth writes the RTF itself rather than asking Apple's writer for it,
/// because Apple's RTF writer drops outline levels: a heading there is only
/// larger bold text. Here each heading uses a paragraph style (`\s1` to
/// `\s6`, "heading 1" to "heading 6") that carries `\outlinelevel`, so Word's
/// navigation pane and VoiceOver's heading navigation list it.
///
/// The sizes also rank the headings by themselves (22, 19, 17, 15, 14, and
/// 13 points over a 12 point body, all bold), so a reader that ignores styles
/// (`textutil`, and TextMouth's own reader) still finds levels 1 to 6.
///
/// The text is pure ASCII: every other character is written as a Unicode
/// escape (`escaped(_:)`), so the file does not depend on a code page.
///
/// It reads the `ExportDocument` and never parses Markdown.
struct RTFExportWriter: TextExportWriter {
    let id = "rtf"
    let name = "RTF"
    let fileExtension = "rtf"
    let hint = "Rich text, with each heading at its outline level, for Word, Pages, and TextEdit."

    /// Writes the RTF of `document` as a new file at `url`; a file already
    /// there is an error, and is left as it was.
    func write(
        _ document: ExportDocument,
        options: NoTextExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        let text = try Self.rtf(of: document, cancellation: cancellation)
        // The text is all ASCII, so UTF-8 is also its code page's bytes.
        // `.withoutOverwriting` makes a file that is already there an error.
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    // MARK: Sizes and Indents

    /// The body's size in half-points (RTF's `\fs`): 12 points.
    private static let bodySize = 24
    /// The sizes of headings of levels 1 to 6, in half-points: each larger
    /// than the body and than the next level, so a reader that ignores
    /// styles ranks them as levels 1 to 6. The style sheet and the heading
    /// paragraphs both read this one table.
    private static let headingSizes = [44, 38, 34, 30, 28, 26]
    /// The space a list adds for each level of nesting, and the width of an
    /// item's mark, in twips (a twentieth of a point).
    private static let listStep = 360
    /// The space a block quote adds, in twips.
    private static let quoteStep = 720
    /// The width of the text between the margins, in twips (6.5 inches).
    private static let textWidth = 9360
    /// The most columns Word accepts in a table.
    private static let mostTableColumns = 63

    /// How far in a block is set, in twips: the part from the block quotes
    /// that hold it and the part from the list item that holds it. They are
    /// kept apart because a list's depth already counts the lists holding
    /// it, so a list adds its own indent to the quotes' only.
    private struct Indent {
        /// The indent from block quotes.
        var quotes = 0
        /// The indent from the item of a list, 0 outside every list.
        var list = 0

        /// All of it.
        var total: Int { quotes + list }
    }

    // MARK: The Document

    /// The RTF of `document`, every line ended by a line feed (RTF ignores
    /// them; they keep the file readable). Calls `cancellation`'s
    /// `checkCancelled()` before each top-level block.
    static func rtf(of document: ExportDocument, cancellation: BookExportCancellation? = nil) throws -> String {
        var lines: [String] = []

        // The frame: the character set, the two fonts, and the style sheet.
        lines.append(#"{\rtf1\ansi\ansicpg1252\deff0\uc1"#)
        lines.append(#"{\fonttbl{\f0\fswiss\fcharset0 Helvetica;}{\f1\fmodern\fcharset0 Courier New;}}"#)
        lines.append(#"{\stylesheet"#)
        lines.append(#"{\s0\sa120\f0\fs\#(bodySize) Normal;}"#)
        for level in 1...headingSizes.count {
            lines.append(
                #"{\s\#(level)\sb240\sa120\keepn\outlinelevel\#(level - 1)\b\f0\fs\#(headingSizes[level - 1])"#
                    + #"\sbasedon0\snext0 heading \#(level);}"#
            )
        }
        lines.append("}")

        // The book's title and author.
        var info = #"{\info{\title "# + escaped(document.book.title) + "}"
        if let author = document.book.author {
            info += #"{\author "# + escaped(author) + "}"
        }
        lines.append(info + "}")

        // The title heading, then the text, stopping between top-level
        // blocks when asked to.
        if let titleHeading = document.titleHeading {
            lines.append(headingLine(titleHeading))
        }
        for block in document.blocks {
            try cancellation?.checkCancelled()
            lines.append(contentsOf: blockLines(block, indent: Indent()))
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Escaping

    /// `text` as RTF text, scalar by scalar:
    /// - a backslash, a left brace, and a right brace get a backslash before them;
    /// - a line feed is `\line ` and a tab `\tab `;
    /// - a vertical tab, a form feed, and a carriage return, white space all,
    ///   are a space;
    /// - every other character below U+0020, and U+007F, is left out;
    /// - U+0020 to U+007E stay as they are;
    /// - every character above is `\uN?` once for each of its UTF-16 code
    ///   units, with N the unit when it is at most 32767 and the unit minus
    ///   65536 when above (RTF's numbers are signed 16-bit), and `?` the one
    ///   character an old reader shows instead (the document's `\uc1`).
    ///
    /// Every text the writer puts in the file passes through here.
    static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5C, 0x7B, 0x7D:
                result += "\\" + String(scalar)
            case 0x0A:
                result += #"\line "#
            case 0x09:
                result += #"\tab "#
            case 0x0B, 0x0C, 0x0D:
                // Vertical tab, form feed, and carriage return are white
                // space RTF cannot hold: a space keeps the words they
                // kept apart apart ("page", a form feed, "Start" is "page Start").
                result += " "
            case 0x00..<0x20, 0x7F:
                continue
            case 0x20..<0x7F:
                result += String(scalar)
            default:
                for unit in String(scalar).utf16 {
                    result += #"\u\#(unit <= 32767 ? Int(unit) : Int(unit) - 65536)?"#
                }
            }
        }
        return result
    }

    // MARK: Blocks

    /// The lines of `block` set `indent` in, each paragraph on a line of its own.
    private static func blockLines(_ block: ExportBlock, indent: Indent) -> [String] {
        switch block {
        case .heading(let heading):
            return [headingLine(heading)]
        case .paragraph(let runs):
            return [paragraphLine(#"\s0\sa120"# + leftIndent(indent.total) + #"\f0\fs\#(bodySize)"#, runsText(runs))]
        case .list(let list):
            return listLines(list, indent: indent)
        case .blockQuote(let blocks):
            let quoted = Indent(quotes: indent.quotes + quoteStep, list: indent.list)
            return blocks.flatMap { blockLines($0, indent: quoted) }
        case .codeBlock(let code):
            // `escaped` turns the code's line feeds into `\line`s.
            return [paragraphLine(#"\s0\sa120"# + leftIndent(indent.total) + #"\f1\fs\#(bodySize)"#, escaped(code))]
        case .thematicBreak:
            // A paragraph with a line under it.
            return [#"\pard\plain\s0\sa120\brdrb\brdrs\brdrw10\brsp20\f0\fs\#(bodySize)\par"#]
        case .table(let table):
            return tableLines(table, indent: indent)
        case .pageBreak:
            // RTF has no page target; this writer's document never keeps them.
            return []
        }
    }

    /// A paragraph of `formatting`, its controls, holding `text`, which is
    /// already RTF. The space after the controls ends the last of them; one
    /// space only, so a text that begins with a space keeps it.
    private static func paragraphLine(_ formatting: String, _ text: String) -> String {
        #"\pard\plain"# + formatting + " " + text + #"\par"#
    }

    /// `\liN` for an indent of `twips`, nothing for none.
    private static func leftIndent(_ twips: Int) -> String {
        twips == 0 ? "" : #"\li\#(twips)"#
    }

    /// `heading` as a paragraph of its level's style, size, and outline
    /// level (kept within 1 to 6, since the writer trusts no caller).
    private static func headingLine(_ heading: ExportHeading) -> String {
        let level = min(max(heading.level, 1), headingSizes.count)
        let formatting = #"\s\#(level)\sb240\sa120\keepn\outlinelevel\#(level - 1)\b\f0\fs\#(headingSizes[level - 1])"#
        return paragraphLine(formatting, runsText(heading.runs))
    }

    // MARK: Lists

    /// `list` as a paragraph for each item's mark and first paragraph, and
    /// paragraphs for the rest of the item. An item is set 360 twips in for
    /// each list around it, its first line hanging back by the mark's width.
    private static func listLines(_ list: ExportList, indent: Indent) -> [String] {
        // A list's depth already counts the lists holding it.
        let depth = min(max(list.depth, 0), ExportDocument.maximumNesting)
        let itemIndent = Indent(quotes: indent.quotes, list: listStep * (depth + 1))
        let itemFormatting = #"\s0\sa60\li\#(itemIndent.total)"# + #"\f0\fs\#(bodySize)"#
        var lines: [String] = []

        for (place, item) in list.items.enumerated() {
            // "N." counts on from where the list starts (wrapping, never trapping, on a number from a file).
            let mark = list.isOrdered ? "\(list.start &+ place)." : "\u{2022}"
            var blocks = item.blocks[...]

            // The mark and a tab begin the item's first paragraph; an item
            // that does not begin with a paragraph has them alone.
            let markFormatting = #"\s0\sa60\li\#(itemIndent.total)\fi-\#(listStep)\f0\fs\#(bodySize)"#
            if case .paragraph(let runs)? = blocks.first {
                lines.append(paragraphLine(markFormatting, escaped(mark) + #"\tab "# + runsText(runs)))
                blocks = blocks.dropFirst()
            } else {
                lines.append(paragraphLine(markFormatting, escaped(mark) + #"\tab"#))
            }

            // The rest of the item: its paragraphs under the first, closer
            // together, and any other block, a list inside it too, as itself.
            for block in blocks {
                if case .paragraph(let runs) = block {
                    lines.append(paragraphLine(itemFormatting, runsText(runs)))
                } else {
                    lines.append(contentsOf: blockLines(block, indent: itemIndent))
                }
            }
        }
        return lines
    }

    // MARK: Tables

    /// `table` as Word's rows and cells, or, when it has more columns than
    /// Word accepts, a paragraph for each row with its cells apart by tabs.
    /// Its columns are the most cells any row has; a shorter row is padded
    /// with empty cells so every row fits the same grid.
    private static func tableLines(_ table: ExportTable, indent: Indent) -> [String] {
        let columns = table.rows.map(\.count).max() ?? 0
        guard columns > 0 else { return [] }

        // Too wide for Word: a paragraph a row.
        if columns > mostTableColumns {
            return table.rows.map { row in
                paragraphLine(
                    #"\s0\sa120"# + leftIndent(indent.total) + #"\f0\fs\#(bodySize)"#,
                    row.map(escaped).joined(separator: #"\tab "#)
                )
            }
        }

        // The columns share the width left of the indent; `\cellx` is each
        // column's right edge, counted from the margin.
        let width = max(1, (textWidth - indent.total) / columns)
        let edges = (1...columns).map { #"\cellx\#(indent.total + $0 * width)"# }.joined()

        return table.rows.enumerated().map { place, row in
            let isHeader = table.hasHeaderRow && place == 0
            var line = #"\trowd\trgaph108\trleft\#(indent.total)"# + (isHeader ? #"\trhdr"# : "") + edges
            for cell in row + [String](repeating: "", count: columns - row.count) {
                // The header row's cells are bold.
                let text = isHeader ? #"{\b "# + escaped(cell) + "}" : escaped(cell)
                line += #"\pard\plain\intbl\s0\f0\fs\#(bodySize) "# + text + #"\cell"#
            }
            return line + #"\row"#
        }
    }

    // MARK: Runs

    /// The RTF of `runs`, which every block that has runs shares.
    /// Neighbouring runs with the same link, when that link may be a link,
    /// are one field; any other run stands alone, and a link that may not be
    /// one (`ExportRun.isAllowedLinkAddress`) is written as plain text
    /// (`linkGroups`, which the HTML writer shares).
    private static func runsText(_ runs: [ExportRun]) -> String {
        runs.linkGroups.map { group in
            let inner = group.runs.map(styledText).joined()
            guard let address = group.link else { return inner }
            return linkText(address: address, inner: inner)
        }.joined()
    }

    /// `inner`, already RTF, as an underlined field that links to `address`.
    /// The address is written as text, with its quotes as `%22` (a quote
    /// would end the field's instruction) and its line breaks and tabs
    /// left out (an address has none).
    private static func linkText(address: String, inner: String) -> String {
        let flat = String(String.UnicodeScalarView(address.unicodeScalars.filter { $0.value >= 0x20 }))
        let safe = escaped(flat.replacingOccurrences(of: "\"", with: "%22"))
        return #"{\field{\*\fldinst{HYPERLINK "# + "\"" + safe + "\"" + #"}}{\fldrslt{\ul "# + inner + "}}}"
    }

    /// One run's text, escaped. A run in a style is a group that sets it:
    /// `\b` for strong, `\i` for emphasis, and `\f1`, the monospaced font,
    /// for code.
    private static func styledText(of run: ExportRun) -> String {
        let text = escaped(run.text)
        var controls = ""
        if run.isStrong { controls += #"\b"# }
        if run.isEmphasis { controls += #"\i"# }
        if run.isCode { controls += #"\f1"# }
        return controls.isEmpty ? text : "{" + controls + " " + text + "}"
    }
}
