import Foundation

// MARK: - The HTML Writer (FMT18)

/// Writes a text book as one XHTML page that an XML parser accepts: its
/// title, a contents list linking each heading, and its text block by block.
///
/// It reads the `ExportDocument` and never parses Markdown. It writes its
/// own markup, because swift-markdown's `HTMLFormatter` puts text in
/// unescaped and drops heading ids. Everything it puts in the page passes
/// through `XMLEscaping`, so the page parses whatever the book's text holds.
///
/// The page is a few lines of frame, then the title heading, the contents
/// `<nav>`, and the blocks, one block (or one line of a list) to a line, so
/// a braille display or a text editor reads it line by line. It holds no
/// image: the model already holds an image as its alternative text.
struct HTMLExportWriter: TextExportWriter {
    let id = "html"
    let name = "HTML"
    let fileExtension = "html"
    let hint = "A web page of the book's text, with a contents list linking each heading."

    /// Writes the page of `document` as UTF-8 to a new file at `url`; a file
    /// already there is an error, and is left as it was.
    func write(
        _ document: ExportDocument,
        options: NoTextExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        let page = try Self.page(of: document, cancellation: cancellation)
        // `.withoutOverwriting` makes a file that is already there an error.
        try Data(page.utf8).write(to: url, options: .withoutOverwriting)
    }

    // MARK: The Page

    /// The page of `document`, every line ended by a line feed. Calls
    /// `cancellation`'s `checkCancelled()` before each top-level block.
    static func page(of document: ExportDocument, cancellation: BookExportCancellation? = nil) throws -> String {
        var lines: [String] = []

        // The frame: the language goes in both attributes that XHTML and HTML read.
        lines.append("<!DOCTYPE html>")
        if let language = document.book.language {
            let escaped = XMLEscaping.attribute(language)
            lines.append("<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"\(escaped)\" xml:lang=\"\(escaped)\">")
        } else {
            lines.append("<html xmlns=\"http://www.w3.org/1999/xhtml\">")
        }
        lines.append("<head>")
        lines.append("<meta charset=\"utf-8\"/>")
        lines.append("<title>\(XMLEscaping.text(document.book.title))</title>")
        if let author = document.book.author {
            lines.append("<meta name=\"author\" content=\"\(XMLEscaping.attribute(author))\"/>")
        }
        lines.append("</head>")
        lines.append("<body>")

        // The page's own title, then the contents of the book's headings.
        if let titleHeading = document.titleHeading {
            lines.append(headingLine(titleHeading))
        }
        let headings = document.headings
        if !headings.isEmpty {
            lines.append("<nav aria-label=\"Contents\">")
            lines.append(contentsOf: contentsLines(of: headings))
            lines.append("</nav>")
        }

        // The text, stopping between top-level blocks when asked to.
        for block in document.blocks {
            try cancellation?.checkCancelled()
            lines.append(contentsOf: blockLines(block))
        }

        lines.append("</body>")
        lines.append("</html>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: The Contents List

    /// The lines of the nested ordered lists that link `headings`, from the
    /// opening `<ol>` to the closing `</ol>`. A stack holds the level of
    /// each open list; a heading deeper than the top opens a list inside the
    /// open item, and a heading shallower closes lists down to the first
    /// whose level it does not go below (never past the outermost, so a
    /// first heading of level 2 followed by one of level 1 stays one flat
    /// list, and a skipped level opens only one list).
    private static func contentsLines(of headings: [ExportHeading]) -> [String] {
        var lines: [String] = []
        var levels: [Int] = []

        /// Ends the open item: `</li>` joins the last line when that line is
        /// the item's own `<li>` line, and takes a line of its own after a
        /// nested list.
        func closeItem() {
            if let last = lines.last, last.hasPrefix("<li>") {
                lines[lines.count - 1] = last + "</li>"
            } else {
                lines.append("</li>")
            }
        }

        for (index, heading) in headings.enumerated() {
            if index == 0 {
                lines.append("<ol>")
                levels = [heading.level]
            } else {
                // Close the lists the heading rises out of.
                while levels.count > 1, let top = levels.last, heading.level < top {
                    closeItem()
                    lines.append("</ol>")
                    levels.removeLast()
                }
                if let top = levels.last, heading.level > top {
                    // A deeper heading: a list inside the open item.
                    lines.append("<ol>")
                    levels.append(heading.level)
                } else {
                    closeItem()
                }
            }
            let id = XMLEscaping.attribute(heading.id)
            lines.append("<li><a href=\"#\(id)\">\(XMLEscaping.text(heading.plainText))</a>")
        }

        // Close the last item and every list still open.
        closeItem()
        while levels.count > 1 {
            lines.append("</ol>")
            closeItem()
            levels.removeLast()
        }
        lines.append("</ol>")
        return lines
    }

    // MARK: Blocks

    /// The lines of `block`, each block starting on a line of its own.
    private static func blockLines(_ block: ExportBlock) -> [String] {
        switch block {
        case .heading(let heading):
            return [headingLine(heading)]
        case .paragraph(let runs):
            return ["<p>\(runsMarkup(runs))</p>"]
        case .list(let list):
            return listLines(list)
        case .blockQuote(let blocks):
            return ["<blockquote>"] + blocks.flatMap(blockLines) + ["</blockquote>"]
        case .codeBlock(let code):
            // Line feeds stay in the text, which `<pre>` keeps.
            return ["<pre><code>\(XMLEscaping.text(code))</code></pre>"]
        case .thematicBreak:
            return ["<hr/>"]
        case .table(let table):
            return tableLines(table)
        }
    }

    /// `heading` as one line: its level (kept within HTML's 1 to 6, since
    /// the writer trusts no caller), its id, and its runs.
    private static func headingLine(_ heading: ExportHeading) -> String {
        let level = min(max(heading.level, 1), 6)
        return "<h\(level) id=\"\(XMLEscaping.attribute(heading.id))\">\(runsMarkup(heading.runs))</h\(level)>"
    }

    /// `list` as a line opening it, a few lines per item, and a line closing it.
    private static func listLines(_ list: ExportList) -> [String] {
        let tag = list.isOrdered ? "ol" : "ul"
        // Only an ordered list that does not begin at 1 says where it does.
        let start = list.isOrdered && list.start != 1 ? " start=\"\(list.start)\"" : ""
        return ["<\(tag)\(start)>"] + list.items.flatMap(itemLines) + ["</\(tag)>"]
    }

    /// `item` as lines: its first block, when a paragraph, on the `<li>`
    /// line; its other blocks on lines of their own; and `</li>` on the last
    /// line when nothing follows the first line, on a line of its own when
    /// something does.
    private static func itemLines(_ item: ExportListItem) -> [String] {
        var blocks = item.blocks[...]
        var opening = "<li>"
        if case .paragraph(let runs)? = blocks.first {
            opening += runsMarkup(runs)
            blocks = blocks.dropFirst()
        }
        if blocks.isEmpty {
            return [opening + "</li>"]
        }
        return [opening] + blocks.flatMap(blockLines) + ["</li>"]
    }

    /// `table` as lines: the header row inside `<thead>` when it has one,
    /// every other row inside `<tbody>` (left out when there is none).
    private static func tableLines(_ table: ExportTable) -> [String] {
        var rows = table.rows[...]
        var lines = ["<table>"]
        if table.hasHeaderRow, let header = rows.popFirst() {
            lines += ["<thead>", rowLine(header, cellTag: "th"), "</thead>"]
        }
        if !rows.isEmpty {
            lines += ["<tbody>"] + rows.map { rowLine($0, cellTag: "td") } + ["</tbody>"]
        }
        lines.append("</table>")
        return lines
    }

    /// One table row as a line, with the cells it has, each in `cellTag`.
    private static func rowLine(_ cells: [String], cellTag: String) -> String {
        let markup = cells.map { "<\(cellTag)>\(XMLEscaping.text($0))</\(cellTag)>" }.joined()
        return "<tr>\(markup)</tr>"
    }

    // MARK: Runs

    /// The markup of `runs`, which every block that has runs shares.
    /// Neighbouring runs with the same link, when that link may be a link,
    /// are one `<a>`; any other run stands alone, and a link that may not be
    /// one (`ExportRun.isAllowedLinkAddress`) is written as plain text
    /// (`linkGroups`, which the RTF writer shares).
    private static func runsMarkup(_ runs: [ExportRun]) -> String {
        runs.linkGroups.map { group in
            let inner = group.runs.map(styledMarkup).joined()
            guard let address = group.link else { return inner }
            return "<a href=\"\(XMLEscaping.attribute(address))\">\(inner)</a>"
        }.joined()
    }

    /// One run's text, escaped, each line feed a `<br/>`, wrapped from the
    /// inside out in `<code>`, `<em>`, and `<strong>`.
    private static func styledMarkup(of run: ExportRun) -> String {
        var markup = XMLEscaping.text(run.text).components(separatedBy: "\n").joined(separator: "<br/>")
        if run.isCode { markup = "<code>\(markup)</code>" }
        if run.isEmphasis { markup = "<em>\(markup)</em>" }
        if run.isStrong { markup = "<strong>\(markup)</strong>" }
        return markup
    }
}
