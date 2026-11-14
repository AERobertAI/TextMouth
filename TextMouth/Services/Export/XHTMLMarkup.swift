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
    /// An attribute written on the start tag of each block that has words,
    /// such as ` dir="auto"` for a book whose language is unknown, so a
    /// right-to-left paragraph is set right to left; empty for none.
    let blockAttributes: String
    /// Whether a heading with no word left once the characters XML forbids are
    /// gone is written as a target only, so no screen reader meets an empty
    /// heading. The HTML writer's page keeps its heading as it always was.
    let writesEmptyHeadingsAsTargets: Bool
    /// How the address of a link is written, or nil to write it as it is. The
    /// closure answers nil for an address that cannot be a URL, which then
    /// leaves the link's words without the link.
    let linkAddress: (@Sendable (String) -> String?)?

    /// Markup for `usesEPUBTypes`, with nothing else asked for: what the HTML
    /// writer's page uses (but for the first flag).
    init(
        usesEPUBTypes: Bool,
        blockAttributes: String = "",
        writesEmptyHeadingsAsTargets: Bool = false,
        linkAddress: (@Sendable (String) -> String?)? = nil
    ) {
        self.usesEPUBTypes = usesEPUBTypes
        self.blockAttributes = blockAttributes
        self.writesEmptyHeadingsAsTargets = writesEmptyHeadingsAsTargets
        self.linkAddress = linkAddress
    }

    // MARK: Blocks

    /// The lines of `block`, each block starting on a line of its own.
    func blockLines(_ block: ExportBlock) -> [String] {
        switch block {
        case .heading(let heading):
            return [headingLine(heading)]
        case .paragraph(let runs):
            return ["<p\(blockAttributes)>\(runsMarkup(runs))</p>"]
        case .list(let list):
            return listLines(list)
        case .blockQuote(let blocks):
            return ["<blockquote\(blockAttributes)>"] + blocks.flatMap(blockLines) + ["</blockquote>"]
        case .codeBlock(let code):
            // Line feeds stay in the text, which `<pre>` keeps.
            return ["<pre\(blockAttributes)><code>\(XMLEscaping.text(code))</code></pre>"]
        case .thematicBreak:
            return ["<hr/>"]
        case .table(let table):
            return tableLines(table)
        case .pageBreak(let page):
            return [pageBreakMarkup(page)]
        case .navigationTarget(let target):
            return [targetMarkup(target)]
        }
    }

    /// `heading` as one line: its level (kept within HTML's 1 to 6, since
    /// the writer trusts no caller), its id, and its runs. A heading with no
    /// word to show is, where asked, an empty target of its id instead.
    private func headingLine(_ heading: ExportHeading) -> String {
        let id = XMLEscaping.attribute(heading.id)
        if writesEmptyHeadingsAsTargets, !XMLEscaping.hasVisibleText(heading.plainText) {
            return "<span id=\"\(id)\"></span>"
        }
        let level = min(max(heading.level, 1), 6)
        return "<h\(level) id=\"\(id)\"\(blockAttributes)>\(runsMarkup(heading.runs))</h\(level)>"
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
        var opening = "<li\(blockAttributes)>"
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
        var lines = ["<table\(blockAttributes)>"]
        var body: [String] = []
        for (index, cells) in table.rows.enumerated() {
            let isHeader = table.hasHeaderRow && index == 0
            let pages = table.cellPages.filter { $0.row == index }
            let line = rowLine(cells, cellTag: isHeader ? "th" : "td", pages: pages)
            if isHeader {
                lines += ["<thead>", line, "</thead>"]
            } else {
                body.append(line)
            }
        }
        if !body.isEmpty {
            lines += ["<tbody>"] + body + ["</tbody>"]
        }
        lines.append("</table>")
        return lines
    }

    /// One table row as a line, with the cells it has, each in `cellTag`;
    /// `pages` are the pages that start in the row's cells.
    private func rowLine(_ cells: [String], cellTag: String, pages: [ExportCellPage]) -> String {
        let markup = cells.enumerated().map { column, text in
            "<\(cellTag)\(blockAttributes)>\(cellMarkup(text, pages: pages.filter { $0.column == column }))</\(cellTag)>"
        }.joined()
        return "<tr>\(markup)</tr>"
    }

    /// A cell's `text`, escaped, with the element of each of `pages` where its
    /// page starts in it, that many Characters in.
    private func cellMarkup(_ text: String, pages: [ExportCellPage]) -> String {
        guard !pages.isEmpty else { return XMLEscaping.text(text) }
        let characters = Array(text)
        var markup = ""
        var written = 0
        for cellPage in pages.sortedStably(by: { $0.offset < $1.offset }) {
            let offset = min(max(cellPage.offset, written), characters.count)
            markup += XMLEscaping.text(String(characters[written..<offset])) + pageBreakMarkup(cellPage.page)
            written = offset
        }
        return markup + XMLEscaping.text(String(characters[written...]))
    }

    // MARK: Places

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

    /// A place the contents point at that is no heading: an empty element with
    /// the id the contents link to, and nothing for a screen reader to meet.
    func targetMarkup(_ target: ExportNavigationTarget) -> String {
        "<span id=\"\(XMLEscaping.attribute(target.id))\"></span>"
    }

    // MARK: Runs

    /// The markup of `runs`, which every block that has runs shares.
    /// Neighbouring runs with the same link, when that link may be a link,
    /// are one `<a>`; any other run stands alone, and a link that may not be
    /// one (`ExportRun.isAllowedLinkAddress`, and `linkAddress`) is written as
    /// plain text (`linkGroups`, which the RTF writer shares).
    private func runsMarkup(_ runs: [ExportRun]) -> String {
        runs.linkGroups.map { group in
            let inner = group.runs.map(styledMarkup).joined()
            guard let address = group.link else { return inner }
            guard let written = linkAddress.map({ $0(address) }) ?? address else { return inner }
            return "<a href=\"\(XMLEscaping.attribute(written))\">\(inner)</a>"
        }.joined()
    }

    /// One run's text, escaped, each line feed a `<br/>`, wrapped from the
    /// inside out in `<code>`, `<em>`, and `<strong>`; or, for a run that
    /// marks a place, that place's element.
    private func styledMarkup(of run: ExportRun) -> String {
        if let page = run.pageBreak {
            return pageBreakMarkup(page)
        }
        if let target = run.navigationTarget {
            return targetMarkup(target)
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
    /// opening `<ol>` to the closing `</ol>`; none for no entries.
    ///
    /// Every item holds at most one list (EPUB 3.3, section 7.3). A stack
    /// holds the level of each open list, and an entry is placed by it:
    /// - deeper than the innermost list: a list inside the open item;
    /// - the same level: the next item of that list;
    /// - shallower, but deeper than the list around that one (a heading that
    ///   rises out of a skipped level: 1, 3, 2): it joins the innermost list,
    ///   whose level becomes the entry's, rather than opening a second list
    ///   in the same item;
    /// - shallower than the outermost list: that list's level lowers to the
    ///   entry's, so a first entry deeper than the rest does not keep every
    ///   later entry flat (3, 1, 2, 1, 2 nests the 2s under the 1s);
    /// - otherwise the innermost list is closed and the entry is placed in
    ///   the list around it.
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

        for entry in entries {
            if levels.isEmpty {
                lines.append("<ol>")
                levels = [entry.level]
            } else {
                var isPlaced = false
                while !isPlaced {
                    let innermost = levels.count - 1
                    if entry.level > levels[innermost] {
                        // A deeper entry: a list inside the open item.
                        lines.append("<ol>")
                        levels.append(entry.level)
                        isPlaced = true
                    } else if entry.level == levels[innermost] {
                        closeItem()
                        isPlaced = true
                    } else if innermost == 0 || entry.level > levels[innermost - 1] {
                        // The entry joins this list: it was opened for a
                        // deeper level that the entry rose out of, or it is
                        // the outermost, which lowers to the entry's level.
                        levels[innermost] = entry.level
                        closeItem()
                        isPlaced = true
                    } else {
                        // The entry rises above this list: close it, and
                        // place the entry in the list around it.
                        closeItem()
                        lines.append("</ol>")
                        levels.removeLast()
                    }
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
