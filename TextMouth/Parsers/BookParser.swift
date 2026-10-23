import Foundation

/// Unified interface for parsing all supported book formats
enum BookParser {

    /// Parse the book at `url` directly from its source file. HTML,
    /// Markdown, and plain-text sources are decoded by `TextFileDecoder`,
    /// exactly as the Markdown cache decodes them, so both readings start
    /// from the same text whatever the file's encoding and line endings.
    /// - Parameter brailleTable: For a braille book (FMT21), the table its
    ///   text is read with, by its stored value: the one it was imported with
    ///   (`Book.brailleTable`), a bundled table or one of this Mac's. Nil
    ///   reads with `BrailleTableCatalog.defaultTableID`; every other format
    ///   ignores it.
    /// - Parameter brailleTableVersion: For a braille book of one of this
    ///   Mac's tables, the Mac's liblouis version it was read with
    ///   (`Book.brailleTableVersion`); another version refuses the reading
    ///   (review R2).
    static func parse(
        url: URL,
        format: BookFormat,
        brailleTable: String? = nil,
        brailleTableVersion: String? = nil
    ) throws -> DocumentContent {
        switch format {
        case .epub:
            return try EPUBParser.parse(url: url)
        case .html:
            let html = try TextFileDecoder.readText(at: url, format: format)
            return try HTMLParser.parse(html: html, title: url.deletingPathExtension().lastPathComponent)
        case .webarchive:
            // The archive's main page, as an HTML or a text book is read.
            return try WebArchiveReader.mainPage(of: url).parsed(title: url.deletingPathExtension().lastPathComponent)
        case .ssml:
            // An SSML file is read as text, its markup removed (FMT07): it is
            // never handed to the speech engine as SSML
            // (`AVSpeechUtterance(ssmlRepresentation:)` crashed on an
            // `emphasis` element), nor as text with its tags.
            return try HTMLParser.parse(html: SSMLReader.html(from: url), title: url.deletingPathExtension().lastPathComponent)
        case .markdown:
            let text = try TextFileDecoder.readText(at: url, format: format)
            return try MarkdownDocParser.parse(markdown: text, title: url.deletingPathExtension().lastPathComponent)
        case .txt:
            let text = try TextFileDecoder.readText(at: url, format: format)
            return PlainTextParser.parse(text: text, title: url.deletingPathExtension().lastPathComponent)
        case .docx:
            return try DOCXParser.parse(url: url)
        case .rtf, .rtfd, .doc, .odt, .wordml:
            // textutil's formats, read through a child process (FMT13).
            return try TextutilDocumentReader.parse(url: url, bookFormat: format)
        case .braille:
            // Read through liblouis in the braille helper (FMT20, FMT21), as
            // the Markdown cache reads it.
            return try BrailleBookReader.parse(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                table: brailleTable ?? BrailleTableCatalog.defaultTableID,
                recordedVersion: brailleTableVersion
            )
        case .daisy:
            return try DAISYParser.parse(url: url)
        case .pdf:
            return try PDFTextParser.parse(url: url)
        case .audio:
            // Audio parsing is async, so wait for it through the shared bridge.
            return try AsyncBridge.waitForResult(timeLimit: AsyncBridge.audioAnalysisTimeLimit) {
                try await AudioBookParser.parse(url: url)
            }
        }
    }
}

// MARK: - Web Archive Pages

extension WebArchiveReader.MainPage {
    /// The page as a book's content: an HTML page through the HTML parser, a
    /// text page through the plain-text parser, as an `.html` and a `.txt`
    /// file are read. This is the one place the choice between the two is made
    /// for a direct reading; `markdown()` makes it for the cache.
    func parsed(title: String) throws -> DocumentContent {
        isHTML ? try HTMLParser.parse(html: text, title: title) : PlainTextParser.parse(text: text, title: title)
    }

    /// The page as the Markdown cache holds it, converted exactly as an
    /// `.html` file (with its duplicate navigation stripped) or a `.txt` file is.
    func markdown() throws -> String {
        isHTML
            ? try HTMLToMarkdownConverter.convert(text, stripDuplicateNavigation: true)
            : PlainTextParser.markdown(text: text)
    }
}
