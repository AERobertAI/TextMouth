import Foundation

// MARK: - The Markup of an Exported Document's Blocks (FMT18, FMT28)

/// Writes the blocks of an `ExportDocument` as lines of XHTML, which both
/// writers of XHTML share: the HTML writer's page and the EPUB writer's
/// chapters. One block, or one line of a list, is a line, so a braille display
/// or a text editor reads it line by line.
///
/// It reads the model and never parses Markdown, and everything it puts in
/// the markup passes through `XMLEscaping`, so the markup parses whatever the
/// book's text holds. It holds no image: the model already holds an image as
/// its alternative text.
struct XHTMLMarkup {
    /// Whether the markup uses EPUB's `epub:type` attribute, which needs the
    /// document to declare the `epub` prefix (EPUB's chapters do, the HTML
    /// writer's page does not).
    let usesEPUBTypes: Bool

    // MARK: Blocks

    /// The lines of `block`, each block starting on a line of its own.
    func blockLines(_ block: ExportBlock) -> [String] {
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
        case .pageBreak(let page):
            return [pageBreakMarkup(page)]
        }
    }

    /// `heading` as one line: its level (kept within HTML's 1 to 6, since
    /// the writer trusts no caller), its id, and its runs.
    private func headingLine(_ heading: ExportHeading) -> String {
        let level = min(max(heading.level, 1), 6)
        return "<h\(level) id=\"\(XMLEscaping.attribute(heading.id))\">\(runsMarkup(heading.runs))</h\(level)>"
    }

    /// `list` as a line opening it, a few lines per item, and a line closing it.
    private func listLines(_ list: ExportList) -> [String] {
        let tag = list.isOrdered ? "ol" : "ul"
        // Only an ordered list that does not begin at 1 says where it does.
        let start = list.isOrdered && list.start != 1 ? " start=\"\(list.start)\"" : ""
        return ["<\(tag)\(start)>"] + list.items.flatMap(itemLines) + ["</\(tag)>"]
    }

    /// `item` as lines: its first block, when a paragraph, on the `<li>`
    /// line; its other blocks on lines of their own; and `</li>` on the last
    /// line when nothing follows the first line, on a line of its own when
    /// something does.
    private func itemLines(_ item: ExportListItem) -> [String] {
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
    private func tableLines(_ table: ExportTable) -> [String] {
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
    private func rowLine(_ cells: [String], cellTag: String) -> String {
        let markup = cells.map { "<\(cellTag)>\(XMLEscaping.text($0))</\(cellTag)>" }.joined()
        return "<tr>\(markup)</tr>"
    }

    // MARK: Pages

    /// The start of `page`: an empty element that a reading system's page
    /// navigation finds by its role (`doc-pagebreak`, and in EPUB its
    /// `epub:type` too), named by its label for a screen reader and for a
    /// pointer's tooltip. Its id is what a page list links to.
    func pageBreakMarkup(_ page: ExportPageBreak) -> String {
        let label = XMLEscaping.attribute(page.label)
        let type = usesEPUBTypes ? " epub:type=\"pagebreak\"" : ""
        return "<span\(type) role=\"doc-pagebreak\" id=\"\(XMLEscaping.attribute(page.id))\" "
            + "aria-label=\"\(label)\" title=\"\(label)\"></span>"
    }

    // MARK: Runs

    /// The markup of `runs`, which every block that has runs shares.
    /// Neighbouring runs with the same link, when that link may be a link,
    /// are one `<a>`; any other run stands alone, and a link that may not be
    /// one (`ExportRun.isAllowedLinkAddress`) is written as plain text
    /// (`linkGroups`, which the RTF writer shares).
    private func runsMarkup(_ runs: [ExportRun]) -> String {
        runs.linkGroups.map { group in
            let inner = group.runs.map(styledMarkup).joined()
            guard let address = group.link else { return inner }
            return "<a href=\"\(XMLEscaping.attribute(address))\">\(inner)</a>"
        }.joined()
    }

    /// One run's text, escaped, each line feed a `<br/>`, wrapped from the
    /// inside out in `<code>`, `<em>`, and `<strong>`; or, for a run that
    /// starts a page, that page's element.
    private func styledMarkup(of run: ExportRun) -> String {
        if let page = run.pageBreak {
            return pageBreakMarkup(page)
        }
        var markup = XMLEscaping.text(run.text).components(separatedBy: "\n").joined(separator: "<br/>")
        if run.isCode { markup = "<code>\(markup)</code>" }
        if run.isEmphasis { markup = "<em>\(markup)</em>" }
        if run.isStrong { markup = "<strong>\(markup)</strong>" }
        return markup
    }
}

// MARK: - A Contents List

/// One entry of a contents list: a heading, or a chapter, that the list links.
struct ExportContentsEntry: Equatable, Sendable {
    /// The entry's level, 1 to 6.
    var level: Int
    /// The entry's words, as plain text (the list escapes them).
    var title: String
    /// Where the entry links to: "#id" in the page, or a file and an id.
    var address: String
}

/// Writes the nested ordered lists of a contents list, which the HTML page's
/// contents and the EPUB's navigation document share.
enum ExportContentsList {
    /// The lines of the nested ordered lists that link `entries`, from the
    /// opening `<ol>` to the closing `</ol>`; none for no entries. A stack
    /// holds the level of each open list; an entry deeper than the top opens
    /// a list inside the open item, and a shallower one closes lists down to
    /// the first whose level it does not go below (never past the outermost,
    /// so a first entry of level 2 followed by one of level 1 stays one flat
    /// list, and a skipped level opens only one list).
    static func lines(of entries: [ExportContentsEntry]) -> [String] {
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

        for (index, entry) in entries.enumerated() {
            if index == 0 {
                lines.append("<ol>")
                levels = [entry.level]
            } else {
                // Close the lists the entry rises out of.
                while levels.count > 1, let top = levels.last, entry.level < top {
                    closeItem()
                    lines.append("</ol>")
                    levels.removeLast()
                }
                if let top = levels.last, entry.level > top {
                    // A deeper entry: a list inside the open item.
                    lines.append("<ol>")
                    levels.append(entry.level)
                } else {
                    closeItem()
                }
            }
            let address = XMLEscaping.attribute(entry.address)
            lines.append("<li><a href=\"\(address)\">\(XMLEscaping.text(entry.title))</a>")
        }
        guard !entries.isEmpty else { return [] }

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
}
