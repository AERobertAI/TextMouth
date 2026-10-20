import Foundation

/// Reads a braille book (FMT20, FMT21) into the Markdown the library keeps
/// and into a parsed book, the way `PlainTextParser` does for a text file.
///
/// A braille book is a BRF, a BRL, or a PEF file. The reader puts the
/// pieces the braille types provide in a row: `BrailleFileReader` reads the
/// file's pages, `BraillePageAnalyzer` finds the headings and paragraphs,
/// and `BrailleTranslator` turns each block's cells into print through
/// liblouis in the braille helper, with the table the book was imported
/// with. Both reading paths, the direct parse and the Markdown cache, call
/// `markdown(of:table:)`, so they read the same text.
enum BrailleBookReader {

    /// Separates the blocks of the Markdown, a blank line, as
    /// `PlainTextParser.markdown(text:)` separates its blocks.
    private static let blockSeparator = "\n\n"

    // MARK: - The kind of file

    /// The kind of braille file at `url`, by its extension: `.brl` for
    /// "brl", `.pef` for "pef" and for "xml" (a PEF is XML, and the import
    /// sends a loose .xml file here only when its root is a PEF's, see
    /// `XMLDocumentSniffer`), and `.brf` for "brf" and anything else. A
    /// braille book's file always has one of these extensions, so the last
    /// case is only a safe answer.
    static func kind(of url: URL) -> BrailleFileKind {
        switch url.pathExtension.lowercased() {
        case "brl": return .brl
        case "pef", "xml": return .pef
        default: return .brf
        }
    }

    // MARK: - Reading

    /// The Markdown of the braille book at `url`, translated to print with
    /// `table`: a heading as an ATX heading of its level, a paragraph or a
    /// list item as a paragraph, every one written as a Markdown literal so
    /// text that merely looks like Markdown is read as written.
    /// - Parameters:
    ///   - url: The book's file.
    ///   - table: A bare file name in the bundle's tables folder.
    /// - Throws: `BrailleFileError` for a file that is not braille,
    ///   `FileImportError.noTextToRead` when the book has no blocks or no
    ///   print text, `BrailleTranslator.Failure` for a table that is unknown
    ///   or a translation that fails, and what the file's reading throws.
    static func markdown(of url: URL, table: String) throws -> String {
        // The file's pages, then the blocks the pages hold (a BRL file has
        // no layout to read, so its analysis is not "formatted").
        let fileKind = kind(of: url)
        let pages = try BrailleFileReader.read(url, as: fileKind)
        let blocks = BraillePageAnalyzer.structure(of: pages.pages, formatted: fileKind != .brl).blocks
        guard !blocks.isEmpty else { throw FileImportError.noTextToRead }

        // One run of the helper translates every block, in a working folder
        // beside the staged package during an import and a temporary one
        // otherwise.
        let printed = try TextutilDocumentReader.withWorkingFolder(for: url) { folder in
            try BrailleTranslator.translate(blocks.map(\.text), table: table, direction: .brailleToPrint, workingIn: folder)
        }

        // Each block's print, trimmed at both ends, as Markdown; a block with
        // no print left is dropped. `zip` stops at the shorter list, so a
        // translation that answered short could not be indexed past its end.
        var pieces: [String] = []
        for (block, text) in zip(blocks, printed) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let literal = MarkdownLiteral.escaped(trimmed)
            if case let .heading(level, _) = block {
                pieces.append(String(repeating: "#", count: level) + " " + literal)
            } else {
                pieces.append(literal)
            }
        }
        guard !pieces.isEmpty else { throw FileImportError.noTextToRead }
        return pieces.joined(separator: blockSeparator)
    }

    /// The parsed content of the braille book at `url`, from the Markdown
    /// `markdown(of:table:)` reads, so the direct reading and the cache's
    /// read the same text.
    /// - Parameters:
    ///   - title: The book's title.
    ///   - table: The table the book was imported with.
    static func parse(url: URL, title: String, table: String) throws -> DocumentContent {
        try MarkdownDocParser.parse(markdown: markdown(of: url, table: table), title: title)
    }
}
