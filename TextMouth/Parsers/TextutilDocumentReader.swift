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
        case .epub, .txt, .markdown, .html, .webarchive, .ssml, .docx, .braille, .daisy, .pdf, .audio, .mobi, .kfx: return nil
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
        /// Whether pages were asked for and textutil's run for them failed
        /// or was stopped, so the Markdown has none (PG16): the book's page
        /// reader is then not recorded as done
        /// (`PageReaderVersions.stamp(for:pageRunFailed:previous:)`).
        var pageRunFailed = false

        /// `markdown` with the names its document's head holds
        /// (`metadata(in:)`), each nil when empty, and whether the run for
        /// its pages failed.
        fileprivate init(markdown: String, named: (title: String, author: String), pageRunFailed: Bool = false) {
            self.markdown = markdown
            title = named.title.isEmpty ? nil : named.title
            author = named.author.isEmpty ? nil : named.author
            self.pageRunFailed = pageRunFailed
        }
    }

    /// The Markdown of the book at `url`, read as `bookFormat`
    /// (`extractMarkdown(from:bookFormat:)`), with the title and author its
    /// HTML names. The document is converted once.
    /// - Parameter includesPages: whether page markers are written (PG11).
    ///   True runs textutil a second time for the page breaks its HTML loses
    ///   (`TextutilPageBreaks`), which also keeps the words either side of a
    ///   break apart (B13); false writes what cache format 3.0.7 wrote, from
    ///   one conversion.
    static func extract(from url: URL, bookFormat: BookFormat, includesPages: Bool = true) throws -> Extraction {
        let source = try htmlText(of: url, bookFormat: bookFormat, includesPages: includesPages)
        guard !source.isWebPage else {
            // A web page is converted as an .html file is, and names its
            // own title and author in its head.
            let named = metadata(in: try MarkupGuard.parse(headOf(source.html)))
            return Extraction(
                markdown: try HTMLToMarkdownConverter.convert(source.html, stripDuplicateNavigation: true),
                named: named
            )
        }
        let html = source.html
        // Cancel is heard between the steps of a very large document's reading
        try ImportCancellation.throwIfCancelled()
        let document = try MarkupGuard.parse(html)
        // The names are read before `markdown(from:source:fileName:includesPages:)`, which restores
        // the structure in the document and so changes it.
        let named = metadata(in: document)
        try ImportCancellation.throwIfCancelled()
        return Extraction(
            markdown: try markdown(from: document, source: source, fileName: url.lastPathComponent, includesPages: includesPages),
            named: named,
            pageRunFailed: source.pageRunFailed
        )
    }

    /// The book at `url`, read as `bookFormat`, for the direct reader. The
    /// document is converted once: its Markdown and its title and author
    /// both come from the same HTML. A document that names no title is
    /// titled by its file's name, and one that names no author has an
    /// unknown author.
    static func parse(url: URL, bookFormat: BookFormat) throws -> DocumentContent {
        let source = try htmlText(of: url, bookFormat: bookFormat, includesPages: true)
        let fileName = url.deletingPathExtension().lastPathComponent
        if source.isWebPage {
            // A web page is read as an .html file is.
            return try HTMLParser.parse(html: source.html, title: fileName)
        }
        let html = source.html
        let document = try MarkupGuard.parse(html)
        let named = metadata(in: document)
        // The metadata is read before `markdown(from:source:fileName:includesPages:)`, which restores
        // the structure in the document and so changes it.
        let title = named.title.isEmpty ? fileName : named.title
        let author = named.author.isEmpty ? Book.unknownAuthor : named.author

        let text = try markdown(from: document, source: source, fileName: url.lastPathComponent, includesPages: true)
        let content = try MarkdownDocParser.parse(markdown: text, title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// The title and author the document at `url` names, each empty when it
    /// names none. They come from the head of textutil's HTML alone: the
    /// text before `</head>` is parsed, so a large document's body is never
    /// parsed for its title.
    static func readMetadata(from url: URL, bookFormat: BookFormat) throws -> (title: String, author: String) {
        // The names are in the HTML alone: no plain-text run for pages.
        let html = try htmlText(of: url, bookFormat: bookFormat, includesPages: false).html
        return metadata(in: try MarkupGuard.parse(headOf(html)))
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
        /// textutil's plain text of the same document, which keeps each page
        /// break as a form feed (PG11); nil when pages were not asked for or
        /// the plain-text run failed, and for a web page.
        var plainText: String?
        /// Whether pages were asked for and the plain-text run failed or was
        /// stopped (PG16).
        var pageRunFailed = false
        /// True for HTML that TextMouth's own reader made
        /// (`OwnDocumentReaders`), whose headings, lists, and page breaks
        /// are in its markup already, so nothing is restored or lined up.
        var isOwnReading = false
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
    /// textutil writes and convert (twice, with `includesPages`: the second
    /// run is the plain text that holds the page breaks).
    private static func htmlText(of url: URL, bookFormat: BookFormat, includesPages: Bool) throws -> Source {
        let format: TextutilInputFormat
        switch try reading(of: url, bookFormat: bookFormat) {
        case .webPage:
            // The page's bytes are held to the same limit as a document's.
            let bytes = try DocumentByteLimit.contents(of: url)
            // The old evidence, as the web archive reader reads: a .doc keeps its
            // version, so what it reads does not change (`TextFileDecoder.Evidence.legacy`).
            let page = try TextFileDecoder.decode(
                bytes, fileName: url.lastPathComponent, format: .html, evidence: .legacy
            )
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

        // A format this platform reads with TextMouth's own reader never
        // reaches textutil (`OwnDocumentReaders`).
        if let own = try OwnDocumentReaders.html(of: url, as: format, includesPages: includesPages) {
            return Source(html: own, isOwnReading: true)
        }

        #if os(iOS)
        // iOS has no textutil: a Word document TextMouth's own reader leaves
        // to it is a Word 6 or Word 95 one, refused in the phone's words.
        if format == .doc { throw PhoneImportRefusal.wordSixOrNinetyFive }
        #endif

        return try withWorkingFolder(for: url) { folder in
            let html = try TextutilConverter.html(of: url, as: format, workingIn: folder)
            guard includesPages else { return Source(html: html) }
            let plainText = try pageText(of: url, as: format, workingIn: folder)
            // A failed run is noted, so the book's pages are not recorded as
            // read (PG16).
            return Source(html: html, plainText: plainText, pageRunFailed: plainText == nil)
        }
    }

    /// textutil's plain text of the document at `url`, for its page breaks
    /// (PG11), or nil when that run fails or is stopped: the document is then
    /// read without pages, never refused for it. One line is logged. An
    /// import's cancellation still ends the import.
    private static func pageText(of url: URL, as format: TextutilInputFormat, workingIn folder: URL) throws -> String? {
        do {
            return try TextutilConverter.plainText(of: url, as: format, workingIn: folder)
        } catch let cancelled as ImportCancelled {
            // Not a failure of the run: the reader cancelled the import.
            throw cancelled
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            DiagnosticLog.event(
                .import,
                TextutilPageBreaks.failedLogLine(fileName: url.lastPathComponent, why: error.localizedDescription)
            )
            return nil
        }
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
    ///
    /// The braille reader (`BrailleBookReader`) uses this too, for the hidden
    /// files the braille helper reads and writes.
    static func withWorkingFolder<Output>(for url: URL, _ body: (URL) throws -> Output) throws -> Output {
        let parent = url.deletingLastPathComponent()
        if ImportStaging.isStagedPackageName(parent.lastPathComponent) {
            return try body(parent)
        }
        return try withTemporaryWorkingFolder(body)
    }

    /// Runs `body` with a new folder in `temporaryRoot` (the temporary
    /// directory), removed afterwards: the working folder of a conversion
    /// outside a staged package, and of work with no file of its own, such
    /// as the check of one of this Mac's braille tables chosen in Settings
    /// (`MacBrailleTableCheck`).
    static func withTemporaryWorkingFolder<Output>(_ body: (URL) throws -> Output) throws -> Output {
        let folder = temporaryRoot
            .appendingPathComponent("TextMouth-textutil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    // MARK: Markdown

    /// The Markdown of `document`, parsed from `source`'s HTML. The document
    /// is changed: its structure is restored first. textutil writes no
    /// navigation, so none is stripped. With `source`'s plain text, each page
    /// break in it is written into the document as a page-break element
    /// (`TextutilPageBreaks`) before the shared converter reads it, and one
    /// line is logged for each break that could not be lined up.
    private static func markdown(
        from document: Document,
        source: Source,
        fileName: String,
        includesPages: Bool
    ) throws -> String {
        // TextMouth's own reader wrote its structure and its pages into its
        // markup, so its HTML goes to the shared converter as it is.
        guard !source.isOwnReading else {
            return try HTMLToMarkdownConverter.convert(
                document: document,
                readingFlow: PublicationSemantics.ReadingFlow(source: source.html),
                includesPages: includesPages
            )
        }
        // The page breaks go in while the field instructions are still in the
        // text, as the plain text holds them too (ST10); see
        // `TextutilHTMLStructure.restore(in:beforeFieldRemoval:)`.
        var outcome: TextutilPageBreaks.Outcome?
        try TextutilHTMLStructure.restore(in: document) { restoring in
            if let plainText = source.plainText {
                outcome = try TextutilPageBreaks.insertPageBreaks(fromPlainText: plainText, into: restoring)
            }
        }
        var readingFlow = PublicationSemantics.ReadingFlow(source: source.html)
        if let outcome {
            for page in outcome.unaligned {
                DiagnosticLog.event(.import, TextutilPageBreaks.unalignedLogLine(fileName: fileName, page: page))
            }
            if !outcome.placed.isEmpty {
                // The reading flow learns from the markup whether to look for
                // page-break elements at all, and the spans are not in the
                // markup it was told of, so it is told of the word they hold.
                readingFlow = PublicationSemantics.ReadingFlow(source: source.html + TextutilPageBreaks.pageBreakRole)
            }
        }
        return try HTMLToMarkdownConverter.convert(
            document: document,
            readingFlow: readingFlow,
            includesPages: includesPages
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
