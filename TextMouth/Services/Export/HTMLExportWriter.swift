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
        let markup = XHTMLMarkup(usesEPUBTypes: false)
        if let titleHeading = document.titleHeading {
            lines.append(contentsOf: markup.blockLines(.heading(titleHeading)))
        }
        let headings = document.headings
        if !headings.isEmpty {
            lines.append("<nav aria-label=\"Contents\">")
            lines.append(contentsOf: ExportContentsList.lines(of: headings.map {
                ExportContentsEntry(level: $0.level, title: $0.plainText, address: "#" + $0.id)
            }))
            lines.append("</nav>")
        }

        // The text, stopping between top-level blocks when asked to.
        for block in document.blocks {
            try cancellation?.checkCancelled()
            lines.append(contentsOf: markup.blockLines(block))
        }

        lines.append("</body>")
        lines.append("</html>")
        return lines.joined(separator: "\n") + "\n"
    }
}
