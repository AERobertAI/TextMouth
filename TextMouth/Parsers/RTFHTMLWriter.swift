import Foundation

// MARK: - Writing the HTML

/// Writes the HTML document of a Rich Text Format document that was read
/// (FMT47), in the form `OwnDocumentReaders` describes: `h1` to `h6`, `p`,
/// `em` and `strong`, `ul`, `ol`, and `li`, `table`, `tr`, and `td`, every
/// text escaped, and, when pages are wanted, the empty page-break spans
/// `TextutilPageBreaks` writes into textutil's.
enum RTFHTMLWriter {

    /// The HTML document of `document`.
    /// - Parameter includesPages: whether page-break spans are written. They
    ///   are not written for a document with more breaks than
    ///   `TextutilPageBreaks.maximumPages` allows, nor, as for textutil's,
    ///   for one that holds no letter or digit.
    static func html(of document: RTFDocument, includesPages: Bool) -> String {
        var output = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
        if !document.title.isEmpty {
            output += "<title>\(XMLEscaping.text(document.title))</title>\n"
        }
        if !document.author.isEmpty {
            output += "<meta name=\"author\" content=\"\(XMLEscaping.attribute(document.author))\">\n"
        }
        output += "</head>\n<body>\n"

        // Page 1 begins at the start of the body of a document with words;
        // the later pages' spans are already among the paragraphs' content.
        let writesPages = includesPages && document.pageBreaks < TextutilPageBreaks.maximumPages
        if writesPages, hasLetterOrDigit(document.blocks) {
            output += pageBreakSpan(1)
        }
        var writer = BlockWriter(writesPages: writesPages)
        for block in document.blocks {
            writer.write(block, to: &output)
        }
        writer.closeLists(in: &output)
        output += "</body>\n</html>\n"
        return output
    }

    // MARK: Pages

    /// The empty element that begins page `number`.
    private static func pageBreakSpan(_ number: Int) -> String {
        "<span role=\"\(TextutilPageBreaks.pageBreakRole)\" aria-label=\"\(number)\"></span>"
    }

    /// Whether any paragraph of `blocks` holds a letter or a digit, as
    /// `TextutilPageBreaks` counts them.
    private static func hasLetterOrDigit(_ blocks: [RTFBlock]) -> Bool {
        paragraphs(of: blocks).contains { paragraph in
            paragraph.plainText.unicodeScalars.contains(where: TextutilPageBreaks.isCounted)
        }
    }

    /// Every paragraph of `blocks`, tables' cells included, in order.
    static func paragraphs(of blocks: [RTFBlock]) -> [RTFParagraph] {
        blocks.flatMap { block -> [RTFParagraph] in
            switch block {
            case .paragraph(let paragraph), .heading(let paragraph, _), .listItem(let paragraph, _, _):
                return [paragraph]
            case .table(let table):
                return table.rows.flatMap { $0.flatMap { $0 } }
            }
        }
    }

    // MARK: Blocks

    /// Writes blocks one after another, keeping track of the lists open
    /// between them: consecutive list items share their lists.
    private struct BlockWriter {
        /// Whether page-break spans are written.
        let writesPages: Bool
        /// The lists open now, outermost first: `true` for an `ol`. Each has
        /// an item open.
        private var openLists: [Bool] = []

        init(writesPages: Bool) {
            self.writesPages = writesPages
        }

        /// Writes `block`, first closing the lists it does not continue.
        mutating func write(_ block: RTFBlock, to output: inout String) {
            if case .listItem(let paragraph, let level, let numbered) = block {
                writeListItem(paragraph, level: level, numbered: numbered, to: &output)
                return
            }
            closeLists(in: &output)
            switch block {
            case .paragraph(let paragraph):
                output += "<p>\(inline(paragraph, emphasis: true))</p>\n"
            case .heading(let paragraph, let level):
                // A heading is already emphasized: its words carry none.
                let tag = "h\(min(max(level, 1), 6))"
                output += "<\(tag)>\(inline(paragraph, emphasis: false))</\(tag)>\n"
            case .table(let table):
                write(table, to: &output)
            case .listItem:
                break
            }
        }

        /// Writes a list item at `level`, opening, closing, or continuing
        /// lists so that the item is at that depth. A list cannot start
        /// deeper than one level below the open one, so a document that
        /// begins at level 3 gets a list at level 0.
        private mutating func writeListItem(_ paragraph: RTFParagraph, level: Int, numbered: Bool, to output: inout String) {
            let depth = min(max(level, 0), openLists.count)
            // Close the lists deeper than the item's.
            while openLists.count > depth + 1 {
                output += openLists.removeLast() ? "</li>\n</ol>\n" : "</li>\n</ul>\n"
            }
            if openLists.count == depth + 1 {
                if openLists[depth] == numbered {
                    // The next item of the same list.
                    output += "</li>\n"
                } else {
                    // The kind of list changed: a new list begins.
                    output += openLists.removeLast() ? "</li>\n</ol>\n" : "</li>\n</ul>\n"
                    output += numbered ? "<ol>\n" : "<ul>\n"
                    openLists.append(numbered)
                }
            } else {
                output += numbered ? "<ol>\n" : "<ul>\n"
                openLists.append(numbered)
            }
            output += "<li>\(inline(paragraph, emphasis: true))"
        }

        /// Closes every list open.
        mutating func closeLists(in output: inout String) {
            while let numbered = openLists.popLast() {
                output += numbered ? "</li>\n</ol>\n" : "</li>\n</ul>\n"
            }
        }

        /// Writes a table: a cell holds a paragraph for each of its own.
        private func write(_ table: RTFTable, to output: inout String) {
            output += "<table>\n"
            for row in table.rows {
                output += "<tr>"
                for cell in row {
                    output += "<td>" + cell.map { "<p>\(inline($0, emphasis: true))</p>" }.joined() + "</td>"
                }
                output += "</tr>\n"
            }
            output += "</table>\n"
        }

        /// The inline HTML of `paragraph`: its words escaped, bold as
        /// `strong` and italic as `em` when `emphasis` is true, line breaks
        /// as `br`, and the page breaks as spans when pages are written.
        private func inline(_ paragraph: RTFParagraph, emphasis: Bool) -> String {
            var html = ""
            for part in paragraph.inlines {
                switch part {
                case .text(let words, let bold, let italic, _):
                    let escaped = XMLEscaping.text(words)
                    // White space alone carries no emphasis: it would add a
                    // mark that holds nothing.
                    let hasWords = words.unicodeScalars.contains { !$0.properties.isWhitespace }
                    guard emphasis, hasWords, bold || italic else {
                        html += escaped
                        continue
                    }
                    var marked = escaped
                    if italic { marked = "<em>\(marked)</em>" }
                    if bold { marked = "<strong>\(marked)</strong>" }
                    html += marked
                case .lineBreak:
                    html += "<br>"
                case .pageBreak(let number):
                    if writesPages { html += RTFHTMLWriter.pageBreakSpan(number) }
                }
            }
            return html
        }
    }
}
