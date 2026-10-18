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
        try extract(from: url, bookFormat: bookFormat).markdown
    }

    /// What reading a document for the Markdown cache produced: its Markdown,
    /// and the title and author its own HTML head names, each nil when the
    /// document names none. They come from the one conversion that made the
    /// Markdown, so an import that adopts them converts the document once.
    struct Extraction: Equatable {
        var markdown: String
        var title: String?
        var author: String?

        /// `markdown` with the names its document's head holds
        /// (`metadata(in:)`), each nil when empty.
        fileprivate init(markdown: String, named: (title: String, author: String)) {
            self.markdown = markdown
            title = named.title.isEmpty ? nil : named.title
            author = named.author.isEmpty ? nil : named.author
        }
    }

    /// The Markdown of the book at `url`, read as `bookFormat`
    /// (`extractMarkdown(from:bookFormat:)`), with the title and author its
    /// HTML names. The document is converted once.
    static func extract(from url: URL, bookFormat: BookFormat) throws -> Extraction {
        let source = try htmlText(of: url, bookFormat: bookFormat)
        guard !source.isWebPage else {
            // A web page is converted as an .html file is, and names its
            // own title and author in its head.
            let named = metadata(in: try SwiftSoup.parse(headOf(source.html)))
            return Extraction(
                markdown: try HTMLToMarkdownConverter.convert(source.html, stripDuplicateNavigation: true),
                named: named
            )
        }
        let html = source.html
        let document = try SwiftSoup.parse(html)
        // The names are read before `markdown(from:html:)`, which restores
        // the structure in the document and so changes it.
        let named = metadata(in: document)
        return Extraction(markdown: try markdown(from: document, html: html), named: named)
    }

    /// The book at `url`, read as `bookFormat`, for the direct reader. The
    /// document is converted once: its Markdown and its title and author
    /// both come from the same HTML. A document that names no title is
    /// titled by its file's name, and one that names no author has an
    /// unknown author.
    static func parse(url: URL, bookFormat: BookFormat) throws -> DocumentContent {
        let source = try htmlText(of: url, bookFormat: bookFormat)
        let fileName = url.deletingPathExtension().lastPathComponent
        if source.isWebPage {
            // A web page is read as an .html file is.
            return try HTMLParser.parse(html: source.html, title: fileName)
        }
        let html = source.html
        let document = try SwiftSoup.parse(html)
        let named = metadata(in: document)
        // The metadata is read before `markdown(from:html:)`, which restores
        // the structure in the document and so changes it.
        let title = named.title.isEmpty ? fileName : named.title
        let author = named.author.isEmpty ? Book.unknownAuthor : named.author

        let content = try MarkdownDocParser.parse(markdown: try markdown(from: document, html: html), title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// The title and author the document at `url` names, each empty when it
    /// names none. They come from the head of textutil's HTML alone: the
    /// text before `</head>` is parsed, so a large document's body is never
    /// parsed for its title.
    static func readMetadata(from url: URL, bookFormat: BookFormat) throws -> (title: String, author: String) {
        let html = try htmlText(of: url, bookFormat: bookFormat).html
        return metadata(in: try SwiftSoup.parse(headOf(html)))
    }

    // MARK: HTML

    /// The HTML a document is read from, and whether it is a web page that
    /// was never converted (`htmlText(of:bookFormat:)`).
    private struct Source {
        var html: String
        /// True for a page that was HTML to begin with, which TextMouth's
        /// HTML reader reads as it reads an .html file; false for textutil's
        /// HTML, whose structure `TextutilHTMLStructure` restores.
        var isWebPage = false
    }

    /// How a document is read, decided from its first bytes
    /// (`reading(of:bookFormat:)`).
    private enum Reading: Equatable {
        /// By textutil, told this format.
        case textutil(TextutilInputFormat)
        /// By TextMouth's own HTML reader: the file is a web page whatever
        /// its name.
        case webPage
    }

    /// How the document at `url` is read, as a book of `bookFormat`. A
    /// file's name or extension can say .doc, .rtf, or .odt while its bytes
    /// say otherwise, so the first bytes decide, in this order:
    /// - an .rtfd is a folder and is read as one;
    /// - a file that begins as RTF is read as RTF (Word's "Save as RTF"
    ///   keeps the .doc);
    /// - a file that begins as an HTML page (Word's "Web Page") is read as
    ///   a web page, never by textutil, which refuses it as damaged;
    /// - a file whose root element is Word 2003 XML is read as WordML;
    /// - any other file is read as the format its book says.
    /// - Throws: `FileImportError.unsupportedFormat` for a format that is not
    ///   textutil's.
    private static func reading(of url: URL, bookFormat: BookFormat) throws -> Reading {
        guard let declared = TextutilInputFormat(bookFormat) else {
            throw FileImportError.unsupportedFormat(bookFormat.rawValue)
        }
        guard declared != .rtfd else { return .textutil(.rtfd) }
        if TextutilSourceCheck.beginsAsRTF(url) { return .textutil(.rtf) }
        if TextutilSourceCheck.beginsAsHTML(url) { return .webPage }
        if declared != .wordml, XMLDocumentSniffer.rootKind(ofFileAt: url) == .wordML { return .textutil(.wordml) }
        return .textutil(declared)
    }

    /// The HTML for the book at `url`: textutil's, or the page's own. The
    /// steps, in order: decide how the document is read, refuse a document
    /// protected by a password, and either read the page or choose where
    /// textutil writes and convert.
    private static func htmlText(of url: URL, bookFormat: BookFormat) throws -> Source {
        let format: TextutilInputFormat
        switch try reading(of: url, bookFormat: bookFormat) {
        case .webPage:
            // The page's bytes are held to the same limit as a document's.
            let bytes = try DocumentByteLimit.contents(of: url)
            let page = try TextFileDecoder.decode(bytes, fileName: url.lastPathComponent, format: .html)
            return Source(html: page.text, isWebPage: true)
        case let .textutil(chosen):
            format = chosen
        }

        // textutil would fail on a document with a password as on a damaged
        // one, which tells the listener nothing to do.
        switch format {
        case .doc where TextutilSourceCheck.isEncryptedWordDocument(url),
             .odt where TextutilSourceCheck.isEncryptedOpenDocument(url):
            throw PasswordProtectedDocument()
        case .rtf, .rtfd, .doc, .odt, .wordml:
            break
        }

        let html = try withWorkingFolder(for: url) { folder in
            try TextutilConverter.html(of: url, as: format, workingIn: folder)
        }
        return Source(html: html)
    }

    /// The folder the working folders of conversions outside a staged
    /// package are made in: the temporary directory, unless a test binds a
    /// folder of its own with `TextutilDocumentReader.$temporaryRoot
    /// .withValue(_:operation:)`, so that its scan for leftovers never meets
    /// the files of another build's textutil in the shared temporary
    /// directory. Like `DocumentByteLimit.current`, it is read on the
    /// caller's thread (`withWorkingFolder(for:_:)`), before any hop.
    @TaskLocal static var temporaryRoot: URL = FileManager.default.temporaryDirectory

    /// Runs `body` with the folder textutil writes its hidden output in.
    /// When the book's file is in a staged package (an import in progress)
    /// that is the package, so the output goes with it should the import
    /// fail or be cancelled. Otherwise it is a new folder in `temporaryRoot`
    /// (the temporary directory), removed afterwards: neither a library
    /// package (perhaps in a cloud folder) nor the folder of a file being
    /// imported ever receives one.
    private static func withWorkingFolder<Output>(for url: URL, _ body: (URL) throws -> Output) throws -> Output {
        let parent = url.deletingLastPathComponent()
        if ImportStaging.isStagedPackageName(parent.lastPathComponent) {
            return try body(parent)
        }
        let folder = temporaryRoot
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
