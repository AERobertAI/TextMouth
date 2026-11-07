import Foundation
import ZIPFoundation

// MARK: - Building the Package (FMT28)

/// One file of an EPUB's package that is a document of the book: where it is
/// in the ZIP and in the package document.
struct EPUBChapterFile {
    /// The file's name, inside the package's folder.
    var name: String
}

/// Makes one EPUB: adds its files to the archive one at a time, and keeps what
/// the navigation document and the package document need to know of them.
/// `EPUBExportWriter` is the one that makes it and checks what it made.
struct EPUBPackageBuilder {
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
    /// The first subtags of the languages written from right to left.
    static let rightToLeftLanguages: Set<String> = [
        "ar", "arc", "ckb", "dv", "fa", "he", "iw", "ks", "ku", "ps", "sd", "ug", "ur", "yi",
    ]

    let archive: Archive
    let document: ExportDocument
    /// The export's date, and the date of every file in the ZIP.
    let date: Date
    let maximumFileBytes: Int
    let cancellation: BookExportCancellation
    /// The writer's `afterEachFile`.
    let afterEachFile: (@Sendable (String) throws -> Void)?
    /// The book's language when it is a well-formed tag, else nil: a tag that
    /// is not one is no language (`ExportBookDetails.languageTag`).
    let language: String?
    /// Whether the book's language is written from right to left.
    let isRightToLeft: Bool

    /// The markup of the book's blocks: with the text direction guessed from
    /// the words (`dir="auto"`) when the book names no language, and a link
    /// only where its address is a URL.
    private let markup: XHTMLMarkup
    /// The path of each entry added to the ZIP so far, in order.
    private(set) var writtenPaths: [String] = []
    /// The chapter files written so far, in reading order.
    private var files: [EPUBChapterFile] = []
    /// The contents: every heading, chapter, and target, in reading order,
    /// linking its file.
    private var contents: [ExportContentsEntry] = []
    /// The page list: every page, in reading order, linking its file.
    private var pages: [ExportContentsEntry] = []
    /// Whether any chapter holds a heading of the book's own.
    private var hasHeadings = false

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
        let language = document.book.language.flatMap(ExportBookDetails.languageTag)
        self.language = language
        let primary = language?.split(separator: "-").first.map { String($0).lowercased() }
        isRightToLeft = primary.map(Self.rightToLeftLanguages.contains) ?? false
        markup = XHTMLMarkup(
            usesEPUBTypes: true,
            blockAttributes: language == nil ? " dir=\"auto\"" : "",
            writesEmptyHeadingsAsTargets: true,
            linkAddress: { EPUBLinkAddress.url(from: $0) }
        )
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
        // A contents list needs an entry: a book with none (it has no text
        // at all) names itself.
        if contents.isEmpty, let first = files.first {
            contents.append(ExportContentsEntry(level: 1, title: bookName, address: first.name))
        }
        try add("\(Self.packageFolder)/\(Self.navigationDocumentName)", navigationDocument(), compressed: true)
        try add("\(Self.packageFolder)/\(Self.packageDocumentName)", packageDocument(), compressed: true)
    }

    /// Adds the file `path` holding `text` as UTF-8, stored or deflated.
    private mutating func add(_ path: String, _ text: String, compressed: Bool) throws {
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
        writtenPaths.append(path)
        try afterEachFile?(path)
    }

    /// The book's name as the contents and the documents give it.
    private var bookName: String {
        Self.name(document.book.title) ?? Self.untitled
    }

    // MARK: Chapters

    /// A chapter of the book: its title and its blocks.
    private struct Chapter {
        var title: String
        var blocks: ArraySlice<ExportBlock>
        /// The titles of the chapters before it that held nothing but the
        /// starts of pages, which it took in so the pages land at its words.
        var absorbedTitles: [String] = []
    }

    /// Whether `block` is the start of a page.
    private static func isPage(_ block: ExportBlock) -> Bool {
        if case .pageBreak = block { return true }
        return false
    }

    /// The document's chapters in order, each with the blocks between its
    /// start and the next. A document that names none is one chapter, and a
    /// chapter with no block is left out: it has nothing to read. A chapter of
    /// nothing but the starts of pages joins the chapter after it (a file of
    /// only pages has no words, which the reader takes as a blank chapter and
    /// drops with its pages), or the one before it at the end. A book with no
    /// text at all is still one (empty) chapter, so the package has a spine.
    private func chapters() -> [Chapter] {
        let blocks = document.blocks
        let starts = document.chapterStarts.isEmpty
            ? [ExportChapterStart(blockIndex: 0, title: "")]
            : document.chapterStarts
        var result: [Chapter] = []
        var pendingLower: Int?
        var pendingTitles: [String] = []
        for (index, start) in starts.enumerated() {
            let lower = min(max(start.blockIndex, 0), blocks.count)
            let upper = index + 1 < starts.count ? min(max(starts[index + 1].blockIndex, lower), blocks.count) : blocks.count
            guard lower < upper else { continue }
            if blocks[lower..<upper].allSatisfy(Self.isPage) {
                pendingLower = pendingLower ?? lower
                pendingTitles.append(start.title)
                continue
            }
            result.append(Chapter(
                title: start.title, blocks: blocks[(pendingLower ?? lower)..<upper], absorbedTitles: pendingTitles
            ))
            pendingLower = nil
            pendingTitles = []
        }
        if let lower = pendingLower {
            if let last = result.indices.last {
                result[last].blocks = blocks[result[last].blocks.startIndex..<blocks.count]
            } else {
                result.append(Chapter(title: pendingTitles.first ?? "", blocks: blocks[lower..<blocks.count],
                                      absorbedTitles: Array(pendingTitles.dropFirst())))
            }
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
    /// limit when a heading comes next (past the starts of pages, which then
    /// begin the next file), so a heading begins each file that follows (the
    /// reader gives a file that begins with other text an entry of its own);
    /// a chapter with no heading to end a file at goes on until
    /// `hardLimitFactor` times the limit.
    ///
    /// The contents get an entry for a chapter that does not open at a heading
    /// or a target: the chapter's title, or the book's, linking its first
    /// file (S7), so the opening words can be reached from the contents; and
    /// one for each chapter of only pages that this one took in.
    private mutating func writeChapter(_ chapter: Chapter) throws {
        let all = Array(chapter.blocks)
        if !all.isEmpty {
            for title in chapter.absorbedTitles {
                if let name = Self.name(title) {
                    contents.append(ExportContentsEntry(level: 1, title: name, address: nextFileName))
                }
            }
            if !Self.opensAtAPlace(all) {
                contents.append(ExportContentsEntry(
                    level: 1, title: Self.name(chapter.title) ?? bookName, address: nextFileName
                ))
            }
        }

        var lines: [String] = []
        var byteCount = 0
        // What the lines so far hold, for the contents and the page list.
        var items: [ExportContentsItem] = []
        var pageBreaks: [ExportPageBreak] = []

        let following = Self.followingText(in: chapter.blocks)
        for (offset, block) in chapter.blocks.enumerated() {
            try cancellation.checkCancelled()
            let blockLines = markup.blockLines(block)
            lines += blockLines
            byteCount += blockLines.reduce(0) { $0 + $1.utf8.count + 1 }
            items += ExportBlock.contentsItems(in: [block])
            pageBreaks += ExportBlock.pageBreaks(in: [block])
            let upcoming = following[offset]
            let mustEnd = byteCount >= maximumFileBytes * Self.hardLimitFactor
            // Not after a start of a page that a heading's page follows: the
            // file ends before the pages, so they begin the next one.
            let endsAtHeading = byteCount >= maximumFileBytes && upcoming == .heading && !Self.isPage(block)
            if upcoming != .nothing, endsAtHeading || mustEnd {
                try writeChapterFile(titled: chapter.title, lines: lines, items: items, pages: pageBreaks)
                lines = []
                byteCount = 0
                items = []
                pageBreaks = []
            }
        }
        try writeChapterFile(titled: chapter.title, lines: lines, items: items, pages: pageBreaks)
    }

    /// Whether the first block of `blocks` that is not the start of a page is
    /// a heading or a target: the chapter opens at a place the contents link.
    private static func opensAtAPlace(_ blocks: [ExportBlock]) -> Bool {
        switch blocks.first(where: { !isPage($0) }) {
        case .heading?, .navigationTarget?: return true
        default: return false
        }
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

    /// Writes one file of `lines`, and notes its contents and pages for the
    /// navigation document.
    private mutating func writeChapterFile(
        titled title: String,
        lines: [String],
        items: [ExportContentsItem],
        pages pageBreaks: [ExportPageBreak]
    ) throws {
        let name = nextFileName
        let text = Self.xhtmlDocument(
            title: Self.name(title) ?? bookName,
            language: language,
            isRightToLeft: isRightToLeft,
            body: lines
        )
        try add("\(Self.packageFolder)/\(name)", text, compressed: true)
        files.append(EPUBChapterFile(name: name))
        if items.contains(where: \.isHeading) { hasHeadings = true }
        contents += items.map {
            ExportContentsEntry(level: $0.level, title: Self.name($0.text) ?? Self.untitled, address: "\(name)#\($0.id)")
        }
        // A page whose label has no word is the page's number among the pages.
        let before = pages.count
        pages += pageBreaks.enumerated().map { offset, page in
            ExportContentsEntry(
                level: 1, title: Self.name(page.label) ?? String(before + offset + 1), address: "\(name)#\(page.id)"
            )
        }
    }

    // MARK: Documents

    /// The XHTML document that holds `body` (lines of markup), titled
    /// `title`, in `language` when the book names one: with `lang` and
    /// `xml:lang`, which EPUB's XHTML and HTML's readers read respectively,
    /// and `dir="rtl"` for a language written from right to left.
    /// Reading systems read XML, so the declaration and the namespaces are
    /// there; `epub` is what `epub:type` needs.
    private static func xhtmlDocument(title: String, language: String?, isRightToLeft: Bool, body: [String]) -> String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE html>",
        ]
        var root = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\""
        if let language {
            let escaped = XMLEscaping.attribute(language)
            root += " lang=\"\(escaped)\" xml:lang=\"\(escaped)\""
        }
        if isRightToLeft {
            root += " dir=\"rtl\""
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

    /// The navigation document: the contents nested by level, and the page
    /// list when the book has pages. The page list is `hidden`, as EPUB
    /// intends: it is for the reading system's page navigation, not for the
    /// page. The headings of the two lists are English (this file's own
    /// words, marked as such); their entries are the book's.
    private func navigationDocument() -> String {
        let direction = language == nil ? " dir=\"auto\"" : ""
        let own = "lang=\"\(Self.ownLanguage)\" xml:lang=\"\(Self.ownLanguage)\""
        var body = [
            "<nav epub:type=\"toc\" role=\"doc-toc\" id=\"toc\"\(direction)>",
            "<h1 \(own)>Contents</h1>",
        ]
        body += ExportContentsList.lines(of: contents)
        body.append("</nav>")
        if !pages.isEmpty {
            body.append("<nav epub:type=\"page-list\" role=\"doc-pagelist\" id=\"page-list\" hidden=\"hidden\"\(direction)>")
            body.append("<h1 \(own)>Pages</h1>")
            body += Self.pageListLines(of: pages)
            body.append("</nav>")
        }
        return Self.xhtmlDocument(title: bookName, language: language, isRightToLeft: isRightToLeft, body: body)
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
    ///   headings, `pageNavigation` and `pageBreakMarkers` only when it has
    ///   pages;
    /// - no claim of conformance to any standard, because nothing here
    ///   checks the book against one.
    private func packageDocument() -> String {
        let book = document.book
        // The book's language where it names one; "und", which is how a
        // language tag says "undetermined", where it does not. The chapters
        // then carry no `lang`, rather than a language they may not be in.
        let languageTag = XMLEscaping.attribute(language ?? "und")
        var features = ["tableOfContents", "readingOrder"]
        if hasHeadings { features.append("structuralNavigation") }
        if !pages.isEmpty { features += ["pageNavigation", "pageBreakMarkers"] }
        let summary = Self.accessibilitySummary(
            hasHeadings: hasHeadings, entryCount: contents.count, hasPages: !pages.isEmpty
        )

        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">",
            "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
            "<dc:identifier id=\"book-id\">\(XMLEscaping.text(EPUBExportWriter.identifier(of: book)))</dc:identifier>",
            "<dc:title>\(XMLEscaping.text(bookName))</dc:title>",
        ]
        if let author = book.author, let creator = Self.name(author) {
            lines.append("<dc:creator>\(XMLEscaping.text(creator))</dc:creator>")
        }
        lines.append("<dc:language>\(languageTag)</dc:language>")
        lines.append("<meta property=\"dcterms:modified\">\(EPUBExportWriter.timestamp(date))</meta>")
        lines.append("<meta property=\"schema:accessMode\">textual</meta>")
        lines.append("<meta property=\"schema:accessModeSufficient\">textual</meta>")
        lines += features.map { "<meta property=\"schema:accessibilityFeature\">\($0)</meta>" }
        lines.append("<meta property=\"schema:accessibilityHazard\">none</meta>")
        lines.append("<meta property=\"schema:accessibilitySummary\" xml:lang=\"\(Self.ownLanguage)\">\(XMLEscaping.text(summary))</meta>")
        lines.append("</metadata>")

        lines.append("<manifest>")
        lines.append("<item id=\"nav\" href=\"\(Self.navigationDocumentName)\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        for (index, file) in files.enumerated() {
            lines.append("<item id=\"chapter-\(index + 1)\" href=\"\(XMLEscaping.attribute(file.name))\" media-type=\"application/xhtml+xml\"/>")
        }
        lines.append("</manifest>")
        lines.append(isRightToLeft ? "<spine page-progression-direction=\"rtl\">" : "<spine>")
        for index in files.indices {
            lines.append("<itemref idref=\"chapter-\(index + 1)\"/>")
        }
        lines.append("</spine>")
        lines.append("</package>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The accessibility summary, a plain statement of what the book holds
    /// and does not, for a person choosing whether it suits them. What it says
    /// of the contents follows the entries really written: `entryCount` of
    /// them, and whether any is a heading of the book's own.
    static func accessibilitySummary(hasHeadings: Bool, entryCount: Int, hasPages: Bool) -> String {
        var sentences = ["This book was exported from TextMouth as text only."]
        if hasHeadings {
            sentences.append("Its headings are real headings, and the contents list links them.")
        } else if entryCount == 1 {
            sentences.append("It has no headings, so the contents list has one entry for the whole book.")
        } else {
            sentences.append("It has no headings, so the contents list has \(entryCount) entries for its chapters and the places it marks.")
        }
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
