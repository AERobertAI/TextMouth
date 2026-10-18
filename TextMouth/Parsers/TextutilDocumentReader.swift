import Foundation
import SwiftSoup

// MARK: - From Book Format to textutil's Format

extension TextutilInputFormat {
    /// The format textutil reads a book of `format` as: the five formats
    /// TextMouth hands to textutil (rich text, rich text with attachments,
    /// Word 97-2003, OpenDocument text, and Word 2003 XML), and nil for
    /// every other format.
    init?(_ format: BookFormat) {
        switch format {
        case .rtf: self = .rtf
        case .rtfd: self = .rtfd
        case .doc: self = .doc
        case .odt: self = .odt
        case .wordml: self = .wordml
        case .epub, .txt, .markdown, .html, .webarchive, .ssml, .docx, .daisy, .pdf, .audio: return nil
        }
    }
}

// MARK: - The Reader

/// Reads the books textutil reads (FMT13) into Markdown, a parsed book, and
/// a title and author, the way `DOCXParser` does for a Word document.
///
/// textutil runs in a child process under the watchdog
/// (`TextutilConverter`); everything here works on the HTML it writes. All
/// of these functions block while the child runs, so they are called only
/// where the DOCX reader is called: the import queue, startup maintenance,
/// Redo Text Extraction, and the reader's background load.
enum TextutilDocumentReader {

    // MARK: Public entry points

    /// The Markdown of the book at `url`, read as `bookFormat`. Headings,
    /// lists, and pictures are restored in textutil's HTML
    /// (`TextutilHTMLStructure`) before the shared converter reads it.
    /// - Throws: `FileImportError.unsupportedFormat` for a format that is
    ///   not textutil's (it never happens: the callers switch on the
    ///   format), `PasswordProtectedDocument`, and what
    ///   `TextutilConverter.html(of:as:workingIn:using:)` throws.
    static func extractMarkdown(from url: URL, bookFormat: BookFormat) throws -> String {
        let html = try htmlText(of: url, bookFormat: bookFormat)
        return try markdown(from: SwiftSoup.parse(html), html: html)
    }

    /// The book at `url`, read as `bookFormat`, for the direct reader. The
    /// document is converted once: its Markdown and its title and author
    /// both come from the same HTML. A document that names no title is
    /// titled by its file's name, and one that names no author has an
    /// unknown author.
    static func parse(url: URL, bookFormat: BookFormat) throws -> DocumentContent {
        let html = try htmlText(of: url, bookFormat: bookFormat)
        let document = try SwiftSoup.parse(html)
        let named = metadata(in: document)
        // The metadata is read before `markdown(from:html:)`, which restores
        // the structure in the document and so changes it.
        let title = named.title.isEmpty ? url.deletingPathExtension().lastPathComponent : named.title
        let author = named.author.isEmpty ? Book.unknownAuthor : named.author

        let content = try MarkdownDocParser.parse(markdown: try markdown(from: document, html: html), title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// The title and author the document at `url` names, each empty when it
    /// names none. They come from the head of textutil's HTML alone: the
    /// text before `</head>` is parsed, so a large document's body is never
    /// parsed for its title.
    static func readMetadata(from url: URL, bookFormat: BookFormat) throws -> (title: String, author: String) {
        let html = try htmlText(of: url, bookFormat: bookFormat)
        return metadata(in: try SwiftSoup.parse(headOf(html)))
    }

    // MARK: HTML

    /// textutil's HTML for the book at `url`. The steps, in order: choose
    /// the format textutil is told, refuse a document protected by a
    /// password, choose where textutil writes, and convert.
    private static func htmlText(of url: URL, bookFormat: BookFormat) throws -> String {
        guard let declared = TextutilInputFormat(bookFormat) else {
            throw FileImportError.unsupportedFormat(bookFormat.rawValue)
        }
        // A file that begins as RTF is read as RTF whatever its name (Word's
        // "Save as RTF" keeps the .doc). An .rtfd is a folder, never RTF.
        let format: TextutilInputFormat = declared != .rtfd && TextutilSourceCheck.beginsAsRTF(url) ? .rtf : declared

        // textutil would fail on a document with a password as on a damaged
        // one, which tells the listener nothing to do.
        switch format {
        case .doc where TextutilSourceCheck.isEncryptedWordDocument(url),
             .odt where TextutilSourceCheck.isEncryptedOpenDocument(url):
            throw PasswordProtectedDocument()
        case .rtf, .rtfd, .doc, .odt, .wordml:
            break
        }

        return try withWorkingFolder(for: url) { folder in
            try TextutilConverter.html(of: url, as: format, workingIn: folder)
        }
    }

    /// Runs `body` with the folder textutil writes its hidden output in.
    /// When the book's file is in a staged package (an import in progress)
    /// that is the package, so the output goes with it should the import
    /// fail or be cancelled. Otherwise it is a new folder in the temporary
    /// directory, removed afterwards: neither a library package (perhaps in
    /// a cloud folder) nor the folder of a file being imported ever
    /// receives one.
    private static func withWorkingFolder<Output>(for url: URL, _ body: (URL) throws -> Output) throws -> Output {
        let parent = url.deletingLastPathComponent()
        if ImportStaging.isStagedPackageName(parent.lastPathComponent) {
            return try body(parent)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouth-textutil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    // MARK: Markdown

    /// The Markdown of `document`, parsed from `html`. The document is
    /// changed: its structure is restored first. textutil writes no
    /// navigation, so none is stripped.
    private static func markdown(from document: Document, html: String) throws -> String {
        try TextutilHTMLStructure.restore(in: document)
        return try HTMLToMarkdownConverter.convert(
            document: document,
            readingFlow: PublicationSemantics.ReadingFlow(source: html)
        )
    }

    // MARK: Title and author

    /// The most of a head's text parsed when the HTML never closes its head.
    private static let unclosedHeadLimit = 64 * 1024

    /// The text of `html` before `</head>` (found case-insensitively), or
    /// its first `unclosedHeadLimit` characters when it has no head's end.
    private static func headOf(_ html: String) -> String {
        if let end = html.range(of: "</head>", options: .caseInsensitive) {
            return String(html[..<end.lowerBound])
        }
        return String(html.prefix(unclosedHeadLimit))
    }

    /// The title and author `document` names: its `<title>` text and the
    /// `content` of its `<meta name="Author">` (the name compared
    /// case-insensitively), each with white space collapsed and trimmed and
    /// control characters removed (`collapsed(_:)`), and empty when absent.
    private static func metadata(in document: Document) -> (title: String, author: String) {
        let title = (try? document.title()) ?? ""
        var author = ""
        for meta in (try? document.select("meta").array()) ?? [] {
            guard let name = try? meta.attr("name"), name.lowercased() == "author" else { continue }
            author = (try? meta.attr("content")) ?? ""
            break
        }
        return (collapsed(title), collapsed(author))
    }

    /// `text` with every run of white space, every other control character,
    /// and every replacement character as one space, trimmed at both ends.
    /// textutil writes the title and author of some Word documents as NUL
    /// characters (the sample `libreoffice-tdf120761_zOrder.dot` has a title
    /// of three), which the HTML parser turns into replacement characters,
    /// and a listener must never meet either as a book's name.
    private static func collapsed(_ text: String) -> String {
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0 == "\u{FFFD}" ? " " : $0
        }))
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
