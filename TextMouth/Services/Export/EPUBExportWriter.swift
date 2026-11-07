import CryptoKit
import Foundation
import ZIPFoundation

// MARK: - The EPUB 3 Writer (FMT28)

/// Writes a text book as an EPUB 3 file: its chapters, its headings nested in
/// a navigation document, and its pages, so a blind reader's headings,
/// pages, and contents go with the book to any reading system.
///
/// It reads the `ExportDocument` that `ExportWalkOptions.bookStructure` asks
/// for, and never parses Markdown. The chapters' markup is `XHTMLMarkup`'s,
/// the HTML writer's too, so a heading, a list, or a table is written once.
///
/// The package, in the order the ZIP holds it:
/// - `mimetype`, first and stored, as EPUB requires;
/// - `META-INF/container.xml`, which names the package document;
/// - `OEBPS/chapter-N.xhtml`, a file for each chapter, a long chapter
///   continued in another file when it passes `maximumFileBytes`, so no file
///   (and no string held at once) is the whole book;
/// - `OEBPS/nav.xhtml`, the contents from the headings and the page list
///   from the pages;
/// - `OEBPS/content.opf`, the package document: identifier, title, creator,
///   language, the modified date, and accessibility metadata that says only
///   what is true of the file.
///
/// What it leaves out: pictures (the book's text holds their alternative
/// text), styles, and the book's cover. Every string it writes is escaped for
/// XML, and a character XML 1.0 forbids is dropped (`XMLEscaping`).
struct EPUBExportWriter: TextExportWriter {
    let id = "epub"
    let name = "EPUB"
    let fileExtension = "epub"
    let hint = "An e-book with the book's headings, contents, and page numbers where it has them, for Apple Books and other reading apps. It holds no pictures."

    /// The book's chapters and pages are kept as well as its words.
    var walkOptions: ExportWalkOptions { .bookStructure }

    /// The date the export says it was made on: the clock's, or a fixed one
    /// in a test, so that the bytes written are the same every time.
    let modified: @Sendable () -> Date
    /// How many bytes of markup a chapter's file holds before the chapter
    /// goes on in another: a file is not ended inside a block, so it may pass
    /// this by the last block's size.
    let maximumFileBytes: Int
    /// Called with the path of each file of the package once it is in the
    /// ZIP, and free to throw: a test's way to stop, or fail, the export
    /// exactly after a given file. The export itself sets none.
    let afterEachFile: (@Sendable (String) throws -> Void)?

    /// The file size EPUB reading systems handle comfortably: they load a
    /// whole file to lay it out.
    static let defaultMaximumFileBytes = 256_000

    /// A writer that dates the export by the clock.
    init(
        modified: @escaping @Sendable () -> Date = { Date() },
        maximumFileBytes: Int = defaultMaximumFileBytes,
        afterEachFile: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.modified = modified
        self.maximumFileBytes = maximumFileBytes
        self.afterEachFile = afterEachFile
    }

    /// Writes the EPUB of `document` as a new file at `url`; a file already
    /// there is an error, and is left as it was. A stopped or failed write
    /// removes the file it began.
    func write(
        _ document: ExportDocument,
        options: NoTextExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url])
        }
        do {
            let archive = try Archive(url: url, accessMode: .create)
            var builder = EPUBPackageBuilder(
                archive: archive,
                document: document,
                date: modified(),
                maximumFileBytes: max(maximumFileBytes, 1),
                cancellation: cancellation,
                afterEachFile: afterEachFile
            )
            try builder.writePackage()
        } catch {
            // Whatever began the file is not an EPUB: remove it, and say why.
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || error is TextExportError {
                throw error
            }
            throw TextExportError("The EPUB file could not be written.")
        }
    }

    // MARK: Identity

    /// The book's identifier as the package gives it: "urn:uuid:" and the
    /// book's identity in the library, in lower case, so exporting the same
    /// book twice gives the same one. A book made without an identity
    /// (a test's details) gets a UUID derived from its title and author, by
    /// the way a name-based UUID is (version 5 layout), so that is stable
    /// too.
    static func identifier(of book: ExportBookDetails) -> String {
        if let identifier = book.identifier {
            return "urn:uuid:" + identifier.uuidString.lowercased()
        }
        var bytes = Array(SHA256.hash(data: Data("\(book.title)\n\(book.author ?? "")".utf8)).prefix(16))
        // The version (5) and variant bits a name-based UUID carries.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return "urn:uuid:" + uuid.uuidString.lowercased()
    }

    /// `date` as the package's modified date: UTC, to the second, "Z" at the
    /// end, as EPUB requires ("2026-11-06T17:30:00Z").
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Building the Package

/// One file of an EPUB's package that is a document of the book: where it is
/// in the ZIP and in the package document.
private struct EPUBChapterFile {
    /// The file's name, inside the package's folder.
    var name: String
}

/// Makes one EPUB: adds its files to the archive one at a time, and keeps what
/// the navigation document and the package document need to know of them.
private struct EPUBPackageBuilder {
    /// The folder of the package inside the ZIP.
    static let packageFolder = "OEBPS"
    /// The name of the package document, inside that folder.
    static let packageDocumentName = "content.opf"
    /// The name of the navigation document, inside that folder.
    static let navigationDocumentName = "nav.xhtml"
    /// What an untitled heading, chapter, or page list entry is called where
    /// a name must have words.
    static let untitled = "Untitled"
    /// The language of the words this file writes itself (the contents'
    /// headings), whatever the book's.
    static let ownLanguage = "en"

    let archive: Archive
    let document: ExportDocument
    /// The export's date, and the date of every file in the ZIP.
    let date: Date
    let maximumFileBytes: Int
    let cancellation: BookExportCancellation
    /// The writer's `afterEachFile`.
    let afterEachFile: (@Sendable (String) throws -> Void)?

    /// The markup of the book's blocks.
    private let markup = XHTMLMarkup(usesEPUBTypes: true)
    /// The chapter files written so far, in reading order.
    private var files: [EPUBChapterFile] = []
    /// The contents: every heading, in reading order, linking its file.
    private var contents: [ExportContentsEntry] = []
    /// Whether any chapter holds a heading of the book's own.
    private var hasHeadings = false
    /// The page list: every page, in reading order, linking its file.
    private var pages: [ExportContentsEntry] = []

    init(
        archive: Archive,
        document: ExportDocument,
        date: Date,
        maximumFileBytes: Int,
        cancellation: BookExportCancellation,
        afterEachFile: (@Sendable (String) throws -> Void)?
    ) {
        self.archive = archive
        self.document = document
        self.date = date
        self.maximumFileBytes = maximumFileBytes
        self.cancellation = cancellation
        self.afterEachFile = afterEachFile
    }

    /// Writes every file of the package: the fixed ones first, then the
    /// chapters, then the two documents that list them.
    mutating func writePackage() throws {
        // `mimetype` first and stored; no file before it, no extra field.
        try add("mimetype", "application/epub+zip", compressed: false)
        try add("META-INF/container.xml", Self.containerDocument(), compressed: true)
        for chapter in chapters() {
            try writeChapter(chapter)
        }
        try add("\(Self.packageFolder)/\(Self.navigationDocumentName)", navigationDocument(), compressed: true)
        let packageDocument = Self.packageDocument(
            for: document, files: files, hasHeadings: hasHeadings,
            hasPages: !pages.isEmpty, modified: date
        )
        try add("\(Self.packageFolder)/\(Self.packageDocumentName)", packageDocument, compressed: true)
    }

    /// Adds the file `path` holding `text` as UTF-8, stored or deflated.
    private func add(_ path: String, _ text: String, compressed: Bool) throws {
        try cancellation.checkCancelled()
        let data = Data(text.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: date,
            compressionMethod: compressed ? .deflate : .none,
            provider: { position, size in
                // The archive asks for chunks; the data is in memory whole.
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        )
        try afterEachFile?(path)
    }

    // MARK: Chapters

    /// A chapter of the book: its title and its blocks.
    private struct Chapter {
        var title: String
        var blocks: ArraySlice<ExportBlock>
    }

    /// The document's chapters in order, each with the blocks between its
    /// start and the next. A document that names none is one chapter, and a
    /// chapter with no block is left out: it has nothing to read. A book with
    /// no text at all is still one (empty) chapter, so the package has a
    /// spine.
    private func chapters() -> [Chapter] {
        let blocks = document.blocks
        let starts = document.chapterStarts.isEmpty
            ? [ExportChapterStart(blockIndex: 0, title: "")]
            : document.chapterStarts
        var result: [Chapter] = []
        for (index, start) in starts.enumerated() {
            let lower = min(max(start.blockIndex, 0), blocks.count)
            let upper = index + 1 < starts.count ? min(max(starts[index + 1].blockIndex, lower), blocks.count) : blocks.count
            guard lower < upper else { continue }
            result.append(Chapter(title: start.title, blocks: blocks[lower..<upper]))
        }
        return result.isEmpty ? [Chapter(title: "", blocks: [])] : result
    }

    /// How many times `maximumFileBytes` a file may grow while no heading
    /// comes to end it at.
    private static let hardLimitFactor = 4

    /// The name of the next chapter file.
    private var nextFileName: String {
        "chapter-\(files.count + 1).xhtml"
    }

    /// Writes `chapter` as one file, or more when it passes
    /// `maximumFileBytes`. A file is ended after the block that passes the
    /// limit when a heading comes next, so a heading begins each file that
    /// follows (the reader gives a file that begins with other text a start
    /// entry of its own); a chapter with no heading to end a file at goes on
    /// until `hardLimitFactor` times the limit. A chapter with a title and
    /// no heading is named in the contents, linking its first file.
    private mutating func writeChapter(_ chapter: Chapter) throws {
        if !ExportBlock.headings(in: Array(chapter.blocks)).isEmpty {
            hasHeadings = true
        } else if let title = Self.name(chapter.title) {
            contents.append(ExportContentsEntry(level: 1, title: title, address: nextFileName))
        }
        var lines: [String] = []
        var byteCount = 0
        // What the lines so far hold, for the contents and the page list.
        var headings: [ExportHeading] = []
        var pageBreaks: [ExportPageBreak] = []

        let following = Self.followingText(in: chapter.blocks)
        for (offset, block) in chapter.blocks.enumerated() {
            try cancellation.checkCancelled()
            let blockLines = markup.blockLines(block)
            lines += blockLines
            byteCount += blockLines.reduce(0) { $0 + $1.utf8.count + 1 }
            headings += ExportBlock.headings(in: [block])
            pageBreaks += ExportBlock.pageBreaks(in: [block])
            let upcoming = following[offset]
            let mustEnd = byteCount >= maximumFileBytes * Self.hardLimitFactor
            // Not after a start of a page that a heading's page follows: the
            // file ends before the pages, so they begin the next one.
            var isPage = false
            if case .pageBreak = block { isPage = true }
            let endsAtHeading = byteCount >= maximumFileBytes && upcoming == .heading && !isPage
            if upcoming != .nothing, endsAtHeading || mustEnd {
                try writeChapterFile(titled: chapter.title, lines: lines, headings: headings, pages: pageBreaks)
                lines = []
                byteCount = 0
                headings = []
                pageBreaks = []
            }
        }
        try writeChapterFile(titled: chapter.title, lines: lines, headings: headings, pages: pageBreaks)
    }

    /// What comes after a block, past the starts of pages.
    private enum Following {
        /// Nothing but, at most, starts of pages.
        case nothing
        /// A heading.
        case heading
        /// Any other text.
        case other
    }

    /// For each block of `blocks`, what follows it past the starts of pages,
    /// found in one pass from the end so a long run of pages costs nothing
    /// more than any other run.
    private static func followingText(in blocks: ArraySlice<ExportBlock>) -> [Following] {
        var result = [Following](repeating: .nothing, count: blocks.count)
        var next = Following.nothing
        for (index, block) in blocks.enumerated().reversed() {
            result[index] = next
            switch block {
            case .pageBreak: break
            case .heading: next = .heading
            default: next = .other
            }
        }
        return result
    }

    /// Writes one file of `lines`, and notes its headings and pages for the
    /// navigation document.
    private mutating func writeChapterFile(
        titled title: String,
        lines: [String],
        headings: [ExportHeading],
        pages pageBreaks: [ExportPageBreak]
    ) throws {
        let name = nextFileName
        let documentTitle = Self.name(title) ?? Self.name(document.book.title)
        let text = Self.xhtmlDocument(
            title: documentTitle ?? Self.untitled,
            language: document.book.language,
            body: lines
        )
        try add("\(Self.packageFolder)/\(name)", text, compressed: true)
        files.append(EPUBChapterFile(name: name))
        contents += headings.map {
            ExportContentsEntry(
                level: $0.level,
                title: Self.name($0.plainText) ?? Self.untitled,
                address: "\(name)#\($0.id)"
            )
        }
        pages += pageBreaks.map { ExportContentsEntry(level: 1, title: $0.label, address: "\(name)#\($0.id)") }
    }

    // MARK: Documents

    /// The XHTML document that holds `body` (lines of markup), titled
    /// `title`, in `language` when the book names one: with `lang` and
    /// `xml:lang`, which EPUB's XHTML and HTML's readers read respectively.
    /// Reading systems read XML, so the declaration and the namespaces are
    /// there; `epub` is what `epub:type` needs.
    private static func xhtmlDocument(title: String, language: String?, body: [String]) -> String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE html>",
        ]
        var root = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\""
        if let language {
            let escaped = XMLEscaping.attribute(language)
            root += " lang=\"\(escaped)\" xml:lang=\"\(escaped)\""
        }
        lines.append(root + ">")
        lines.append("<head>")
        lines.append("<title>\(XMLEscaping.text(title))</title>")
        lines.append("</head>")
        lines.append("<body>")
        lines += body
        lines.append("</body>")
        lines.append("</html>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `META-INF/container.xml`: where the package document is.
    private static func containerDocument() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
        <rootfile full-path="\(packageFolder)/\(packageDocumentName)" media-type="application/oebps-package+xml"/>
        </rootfiles>
        </container>

        """
    }

    /// The navigation document: the contents nested by heading level, and the
    /// page list when the book has pages. A book with no heading has one
    /// entry, its title, linking its first file, because a contents list
    /// needs an entry. The page list is `hidden`, as EPUB intends: it is for
    /// the reading system's page navigation, not for the page.
    private func navigationDocument() -> String {
        var entries = contents
        if entries.isEmpty, let first = files.first {
            let title = Self.name(document.book.title) ?? Self.untitled
            entries = [ExportContentsEntry(level: 1, title: title, address: first.name)]
        }
        var body = [
            "<nav epub:type=\"toc\" role=\"doc-toc\" id=\"toc\">",
            "<h1 lang=\"\(Self.ownLanguage)\" xml:lang=\"\(Self.ownLanguage)\">Contents</h1>",
        ]
        body += ExportContentsList.lines(of: entries)
        body.append("</nav>")
        if !pages.isEmpty {
            body.append("<nav epub:type=\"page-list\" role=\"doc-pagelist\" id=\"page-list\" hidden=\"hidden\">")
            body.append("<h1 lang=\"\(Self.ownLanguage)\" xml:lang=\"\(Self.ownLanguage)\">Pages</h1>")
            body += Self.pageListLines(of: pages)
            body.append("</nav>")
        }
        let title = Self.name(document.book.title) ?? Self.untitled
        return Self.xhtmlDocument(title: title, language: document.book.language, body: body)
    }

    /// The page list's `<ol>`: one flat item for each page, linking its
    /// target and named by its label.
    private static func pageListLines(of pages: [ExportContentsEntry]) -> [String] {
        ["<ol>"]
            + pages.map { "<li><a href=\"\(XMLEscaping.attribute($0.address))\">\(XMLEscaping.text($0.title))</a></li>" }
            + ["</ol>"]
    }

    /// The package document: the metadata, the manifest of every file, and
    /// the spine in reading order.
    ///
    /// The accessibility metadata says only what is true of the file:
    /// - the text is the only way in (`accessMode` and `accessModeSufficient`
    ///   are textual), with no image, sound, or flashing (`accessibilityHazard`
    ///   none);
    /// - `tableOfContents` and `readingOrder` always (the navigation document
    ///   and the spine), `structuralNavigation` only when the book has
    ///   headings, `pageNavigation` only when it has pages;
    /// - no claim of conformance to any standard, because nothing here
    ///   checks the book against one.
    private static func packageDocument(
        for document: ExportDocument,
        files: [EPUBChapterFile],
        hasHeadings: Bool,
        hasPages: Bool,
        modified: Date
    ) -> String {
        let book = document.book
        let title = name(book.title) ?? untitled
        // The book's language where it names one; "und", which is how a
        // language tag says "undetermined", where it does not. The chapters
        // then carry no `lang`, rather than a language they may not be in.
        let language = XMLEscaping.attribute(book.language ?? "und")
        var features = ["tableOfContents", "readingOrder"]
        if hasHeadings { features.append("structuralNavigation") }
        if hasPages { features.append("pageNavigation") }

        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">",
            "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
            "<dc:identifier id=\"book-id\">\(XMLEscaping.text(EPUBExportWriter.identifier(of: book)))</dc:identifier>",
            "<dc:title>\(XMLEscaping.text(title))</dc:title>",
        ]
        if let author = book.author, let creator = name(author) {
            lines.append("<dc:creator>\(XMLEscaping.text(creator))</dc:creator>")
        }
        lines.append("<dc:language>\(language)</dc:language>")
        lines.append("<meta property=\"dcterms:modified\">\(EPUBExportWriter.timestamp(modified))</meta>")
        lines.append("<meta property=\"schema:accessMode\">textual</meta>")
        lines.append("<meta property=\"schema:accessModeSufficient\">textual</meta>")
        lines += features.map { "<meta property=\"schema:accessibilityFeature\">\($0)</meta>" }
        lines.append("<meta property=\"schema:accessibilityHazard\">none</meta>")
        lines.append("<meta property=\"schema:accessibilitySummary\">\(XMLEscaping.text(accessibilitySummary(hasHeadings: hasHeadings, hasPages: hasPages)))</meta>")
        lines.append("</metadata>")

        lines.append("<manifest>")
        lines.append("<item id=\"nav\" href=\"\(navigationDocumentName)\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        for (index, file) in files.enumerated() {
            lines.append("<item id=\"chapter-\(index + 1)\" href=\"\(XMLEscaping.attribute(file.name))\" media-type=\"application/xhtml+xml\"/>")
        }
        lines.append("</manifest>")
        lines.append("<spine>")
        for index in files.indices {
            lines.append("<itemref idref=\"chapter-\(index + 1)\"/>")
        }
        lines.append("</spine>")
        lines.append("</package>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The accessibility summary, a plain statement of what the book holds
    /// and does not, for a person choosing whether it suits them.
    private static func accessibilitySummary(hasHeadings: Bool, hasPages: Bool) -> String {
        var sentences = ["This book was exported from TextMouth as text only."]
        sentences.append(hasHeadings
            ? "Its headings are real headings, and the contents list links them."
            : "It has no headings, so the contents list has one entry for the whole book.")
        if hasPages {
            sentences.append("It has a page list, and the start of each page is marked in the text.")
        }
        sentences.append("It has no pictures, sound, or video, and the text of a picture's description is kept as text.")
        return sentences.joined(separator: " ")
    }

    // MARK: Text

    /// `text` as a name on one line: the characters XML forbids dropped (a
    /// forbidden white space character is a space), each run of white space,
    /// line feeds included, one space, and none at either end; nil when no
    /// word is left, so a name that has no words in the file is never
    /// written empty.
    private static func name(_ text: String) -> String? {
        let words = XMLEscaping.cleaned(text).split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
