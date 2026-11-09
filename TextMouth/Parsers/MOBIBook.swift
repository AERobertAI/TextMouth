import Foundation
import SwiftSoup

/// A Kindle (MOBI) book opened for reading: what it says about itself, and
/// its text cut into sections of HTML. This is everything the book holds
/// before the shared HTML converter turns it into the reading text
/// (`MOBIParser`).
///
/// It reads MOBI 6 books and KF8 books (an .azw3, or a KF8 file named .mobi
/// or .azw; the header's version decides, not the name). A hybrid file holds
/// both: a MOBI 6 book first and, after the boundary EXTH 121 names, the same
/// book in KF8 (`HybridChoice` says which is read).
///
/// It refuses what TextMouth does not read, in this order: a book that is
/// encrypted or carries DRM (never removed, and checked in both halves of a
/// hybrid), and a text compressed in a way not read.
struct MOBIBook {

    /// What the book says about itself.
    struct Metadata: Equatable {
        /// The title: EXTH 503, else the full name in the header, else the
        /// database name; empty when the book names none.
        var title: String
        /// The authors (EXTH 100) joined with commas; empty when it names none.
        var author: String
        /// The language (EXTH 524), such as "en"; nil when it names none.
        var language: String?
    }

    /// One part of the book's text, as HTML.
    struct Section {
        /// The title the book's contents gives the part, nil when it gives
        /// none (the part before the first entry, or a part cut at a page
        /// break).
        var title: String?
        /// The part's HTML: the book's own markup with an anchor
        /// (`<a id="filepos-N"></a>`) at every place it names, and the
        /// Mobipocket tags taken out.
        var html: String
        /// The contents entries that name places in the book, by the id of
        /// their anchor; the converter writes each as a heading annotation.
        var headingTargets: [String: MarkdownHeadingAnnotation]
        /// The pages the book's own page list begins at elements of the
        /// HTML, by the element's id; none for a MOBI book, which has no
        /// print pages, and for a KFX book that has no page list.
        var pages = HTMLPageTargets()
        /// Whether a chapter that nothing titles takes the book's own title
        /// (a KFX book's only such chapter is its first, or the whole of a
        /// book with no contents and no headings) rather than "Chapter" and
        /// its number, which a MOBI book's does.
        var untitledTakesBookTitle = false
        /// Whether the converter takes out the text of a navigation list the
        /// section repeats, as it does for an EPUB's documents (a KF8 book's
        /// documents are an EPUB's, a MOBI 6 book's are not).
        var stripsDuplicateNavigation = false
        /// For a KF8 book: the number of the document the section is, from 1
        /// in the book's reading order, counting every document as the EPUB
        /// reader counts a spine's. A chapter nothing titles is "Chapter" and
        /// this number. Nil for a section that is numbered by the chapters
        /// that hold text before it, as a MOBI 6 book's is.
        var documentNumber: Int?
        /// Whether the section continues the chapter before it: calibre cut
        /// one document of the EPUB into several, and this is a later piece
        /// of it. Its words are read in the chapter before it, with no heading
        /// of its own (`KF8Book`).
        var continuesPrevious = false
        /// For a section that continues the chapter before it: whether the
        /// cut fell in the middle of a paragraph, so the two halves are read
        /// as one paragraph, with no break between them.
        var joinsParagraph = false
    }

    /// Which half of a hybrid file is read.
    enum HybridChoice: Equatable {
        /// The KF8 half, which keeps the book's structure; the MOBI 6 half
        /// when the KF8 half does not read.
        case kf8
        /// The MOBI 6 half, which is what TextMouth read before KF8 was read.
        case mobi6
    }

    /// The half of a hybrid file `init(bytes:)` reads: the KF8 half. On the
    /// real hybrids read both ways (kindlegen's and calibre's, among them
    /// 15 hybrids made by kindlegen from Project Gutenberg's EPUBs, and the
    /// edge books of the review), the KF8 half had the same words as the MOBI 6
    /// half, except that the MOBI 6 half also read a contents page a converter
    /// added at the end and the KF8 half also read a picture's description,
    /// the words in an SVG picture, and a title page that MOBI 6 had dropped;
    /// and it had at least as many headings, at the levels the book's author
    /// gave them (the MOBI 6 half of a calibre hybrid has every heading at
    /// level 1). A KF8 half that fails to read, in any way but protection
    /// and a cancel, leaves the MOBI 6 half.
    static let hybridChoice = HybridChoice.kf8

    var metadata: Metadata
    var sections: [Section]
    /// Whether the book's print pages (the page-break elements of its
    /// markup) are written: for a KF8 book, whose documents keep them as an
    /// EPUB's do; a MOBI 6 book has none.
    private(set) var includesPages = false

    // MARK: Opening

    /// Reads the book in `bytes`.
    /// - Parameters:
    ///   - hybrid: Which half of a hybrid file is read.
    ///   - checkCancellation: Asked between the documents of a KF8 book; the
    ///     read stops when it throws. By default it hears the import running
    ///     on this thread being cancelled.
    /// - Throws: see `init(data:hybrid:checkCancellation:)`.
    init(
        bytes: [UInt8], hybrid: HybridChoice = MOBIBook.hybridChoice,
        checkCancellation: () throws -> Void = { try ImportCancellation.throwIfCancelled() }
    ) throws {
        try self.init(data: Data(bytes), hybrid: hybrid, checkCancellation: checkCancellation)
    }

    /// Reads the book in `data`, which may be a file mapped into memory, so that a book of
    /// pictures costs no memory of its size.
    /// - Parameters: as for `init(bytes:hybrid:checkCancellation:)`.
    /// - Throws: `MOBIError` for a file that is not a readable Kindle book
    ///   (see the type's comment for the refusals), `DocumentTooLargeError`
    ///   for a text past `DocumentByteLimit`, `FileImportError.noTextToRead`
    ///   for a book without text, and what `checkCancellation` throws.
    init(
        data: Data, hybrid: HybridChoice = MOBIBook.hybridChoice,
        checkCancellation: () throws -> Void = { try ImportCancellation.throwIfCancelled() }
    ) throws {
        let database = try MOBIPalmDatabase(data: data)
        let headers = try MOBIHeaders(
            record0: try database.record(0, "Record 0"),
            requiresMOBIHeader: database.type == MOBIPalmDatabase.mobiSignature.type
        )
        try Self.refuseProtected(headers)

        // The KF8 half of a hybrid, when the file is one. Its protection is
        // looked at whether or not it is the half read: a file that is
        // protected in either half is a protected book.
        let second = Self.secondHalf(of: database, firstHeaders: headers)
        if let second { try Self.refuseProtected(second.headers) }

        if let second, hybrid == .kf8 {
            do {
                self = try Self.kf8Book(
                    database: second.database, headers: second.headers, firstHeaders: headers,
                    checkCancellation: checkCancellation)
                return
            } catch MOBIError.copyProtected {
                throw MOBIError.copyProtected
            } catch let cancelled as ImportCancelled {
                throw cancelled
            } catch {
                // A KF8 half that does not read, for whatever reason (damaged tables, a
                // compression no one defined, a text too large, no words at all), leaves
                // the MOBI 6 half, which the file opens as and which holds the same book.
                // Only protection and a cancel are the book's, not the half's.
            }
        }
        if headers.version >= 8 {
            self = try Self.kf8Book(
                database: database, headers: headers, firstHeaders: nil, checkCancellation: checkCancellation)
            return
        }

        metadata = Self.metadata(of: [headers], database: database)
        let text = try MOBIText.bytes(of: database, headers: headers)
        // A plain PalmDOC book is plain text, unless the text is HTML.
        if headers.hasMOBIHeader || MOBIMarkup.looksLikeHTML(text) {
            sections = try Self.sections(of: text, headers: headers, database: database)
        } else {
            sections = [Self.plainSection(of: text)]
        }
    }

    /// A book made of the KF8 book in `database`. For the KF8 half of a
    /// hybrid, `firstHeaders` holds the MOBI 6 half's, which names the book
    /// where the KF8 half does not.
    private static func kf8Book(
        database: MOBIPalmDatabase, headers: MOBIHeaders, firstHeaders: MOBIHeaders?,
        checkCancellation: () throws -> Void
    ) throws -> MOBIBook {
        // The KF8 half names the book; where it names nothing, the MOBI 6 half does.
        let metadata = Self.metadata(of: [headers] + (firstHeaders.map { [$0] } ?? []), database: database)
        let text = try MOBIText.bytes(
            of: database, headers: headers, through: KF8Layout.flowTableEnd(database: database, headers: headers))
        return MOBIBook(
            metadata: metadata,
            sections: try KF8Book.sections(
                of: text, headers: headers, database: database, bookTitle: metadata.title,
                checkCancellation: checkCancellation),
            includesPages: true
        )
    }

    /// A book made of its parts.
    private init(metadata: Metadata, sections: [Section], includesPages: Bool) {
        self.metadata = metadata
        self.sections = sections
        self.includesPages = includesPages
    }

    /// What the book says about itself, read without its text. A book that
    /// is protected or compressed in a way not read still names its title
    /// and author. A hybrid file is named as it is read: from its KF8 half
    /// first, and from its MOBI 6 half where that names nothing.
    /// - Throws: `MOBIError` for a file that is not a Kindle book.
    static func metadata(in bytes: [UInt8], hybrid: HybridChoice = MOBIBook.hybridChoice) throws -> Metadata {
        try metadata(in: Data(bytes), hybrid: hybrid)
    }

    /// `metadata(in:hybrid:)` for a file that may be mapped into memory.
    static func metadata(in data: Data, hybrid: HybridChoice = MOBIBook.hybridChoice) throws -> Metadata {
        let database = try MOBIPalmDatabase(data: data)
        let headers = try MOBIHeaders(
            record0: try database.record(0, "Record 0"),
            requiresMOBIHeader: database.type == MOBIPalmDatabase.mobiSignature.type
        )
        if hybrid == .kf8, let second = secondHalf(of: database, firstHeaders: headers) {
            return metadata(of: [second.headers, headers], database: database)
        }
        return metadata(of: [headers], database: database)
    }

    // MARK: Refusals

    /// Throws for a book that is protected, before any of its text is
    /// touched. Copy protection comes first: TextMouth never removes it,
    /// and says so rather than naming the book's other faults.
    private static func refuseProtected(_ headers: MOBIHeaders) throws {
        // The encryption field is not 0, or the DRM offset is not
        // 0xFFFFFFFF: the book is protected.
        if headers.encryption != 0 || headers.hasDRM { throw MOBIError.copyProtected }
    }

    // MARK: The Halves of a Hybrid

    /// The KF8 half of a hybrid file: the database seen from the boundary
    /// that EXTH 121 of the MOBI 6 half names, and the headers of the record
    /// the boundary names. Nil for a book that is not a hybrid: one that is
    /// KF8 throughout, one without a boundary, or one whose boundary does
    /// not name a KF8 header (then the file is the MOBI 6 book it opens as).
    private static func secondHalf(
        of database: MOBIPalmDatabase, firstHeaders: MOBIHeaders
    ) -> (database: MOBIPalmDatabase, headers: MOBIHeaders)? {
        guard firstHeaders.version < 8, let boundary = firstHeaders.kf8BoundaryRecord, boundary > 0,
              let half = try? database.starting(atRecord: boundary),
              let record0 = try? half.record(0, "The second part's record 0"),
              let headers = try? MOBIHeaders(record0: record0, requiresMOBIHeader: true),
              headers.version >= 8 else { return nil }
        return (half, headers)
    }

    // MARK: Metadata

    /// The metadata the headers hold, those first in `headersInOrder` first
    /// (a hybrid's KF8 half before its MOBI 6 half), with the database name
    /// as the last resort for a title. Each field is the first header's that
    /// names it.
    private static func metadata(of headersInOrder: [MOBIHeaders], database: MOBIPalmDatabase) -> Metadata {
        let title = firstNonEmpty(
            headersInOrder.map { $0.exthText(MOBIHeaders.EXTHType.title) }
                + headersInOrder.map { $0.fullName }
                // The database name spells spaces as underscores.
                + [database.name.replacingOccurrences(of: "_", with: " ")]
        )
        let authors = headersInOrder.lazy
            .map { $0.exthTexts(MOBIHeaders.EXTHType.author).map(cleaned).filter { !$0.isEmpty } }
            .first { !$0.isEmpty } ?? []
        let language = headersInOrder.lazy
            .map { cleaned($0.exthText(MOBIHeaders.EXTHType.language) ?? "") }
            .first { !$0.isEmpty } ?? ""
        return Metadata(
            title: title,
            author: authors.joined(separator: ", "),
            language: language.isEmpty ? nil : language
        )
    }

    /// The first of `candidates` that holds a letter or digit, cleaned, or "".
    private static func firstNonEmpty(_ candidates: [String?]) -> String {
        candidates.compactMap { $0.map(cleaned) }.first { !$0.isEmpty } ?? ""
    }

    /// `text` with the character references EXTH strings carry
    /// (`Tom &amp; Jerry`) read as characters, and white space at its ends
    /// and any NUL padding removed.
    private static func cleaned(_ text: String) -> String {
        let unescaped = (try? Entities.unescape(text)) ?? text
        return unescaped
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Sections

    /// The book's text cut into sections. With a contents (the NCX index),
    /// a section for each top-level entry, from its offset to the next, and
    /// the deeper entries become headings inside them; without one, a
    /// section for each `<mbp:pagebreak>`. A page break is a layout break,
    /// not a print page, so it is a chapter boundary at most.
    private static func sections(of text: [UInt8], headers: MOBIHeaders, database: MOBIPalmDatabase) throws -> [Section] {
        let scan = MOBIMarkup.scan(text)

        // The contents, when the book has one. An entry past the end of the
        // text names nothing, so it is passed over.
        var entries: [MOBIIndexEntry] = []
        if let indexRecord = headers.indexRecord {
            entries = try MOBIIndex.entries(startingAt: indexRecord, in: database).filter { $0.offset < text.count }
            // A label is read, searched, and shown in braille as it is written: without a soft hyphen in it.
            for index in entries.indices {
                entries[index].label = ParserUtilities.removingSoftHyphens(entries[index].label)
            }
        }

        // Every place the book names gets an anchor: the places its links
        // name and the places its contents name.
        let offsets = scan.fileposTargets.union(entries.map(\.offset)).sorted()
        let anchors = MOBIMarkup.anchors(for: offsets, in: text)

        // Where each section starts, with its title when the contents gives one.
        // The head of the book (its metadata and guide) is not read, so no section begins before the body.
        let starts = sectionStarts(
            entries: entries, anchors: anchors, pageBreaks: scan.pageBreakOffsets, bodyStart: scan.bodyStart
        )

        // Each entry that has a label is a heading at its anchor. The first
        // entry to name a place names it.
        var headingTargets: [String: MarkdownHeadingAnnotation] = [:]
        for entry in entries where !entry.label.isEmpty {
            let id = MOBIMarkup.anchorID(forOffset: entry.offset)
            if headingTargets[id] == nil {
                headingTargets[id] = MarkdownHeadingAnnotation(level: min(entry.depth + 1, 6), text: entry.label)
            }
        }

        var sections: [Section] = []
        var nextAnchor = 0
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].position : text.count
            // The anchors of this section: those placed in its range.
            while nextAnchor < anchors.count, anchors[nextAnchor].position < start.position { nextAnchor += 1 }
            var lastAnchor = nextAnchor
            while lastAnchor < anchors.count, anchors[lastAnchor].position < end { lastAnchor += 1 }
            let bytes = MOBIMarkup.html(of: text, range: start.position..<end, anchors: anchors[nextAnchor..<lastAnchor])
            nextAnchor = lastAnchor
            sections.append(Section(
                title: start.title,
                // Without the soft hyphens a publisher put inside words (see `ParserUtilities.removingSoftHyphens`).
                html: ParserUtilities.removingSoftHyphens(MOBIText.decode(bytes, encoding: headers.encoding)),
                headingTargets: headingTargets
            ))
        }
        return sections
    }

    /// Where each section starts (an offset into the text, snapped to a tag's
    /// start) and the title the contents gives it, in order, the first at 0.
    private static func sectionStarts(
        entries: [MOBIIndexEntry], anchors: [MOBIMarkup.Anchor], pageBreaks: [Int], bodyStart: Int
    ) -> [(position: Int, title: String?)] {
        var starts: [(position: Int, title: String?)] = []
        let chapters = entries.filter { $0.depth == 0 }
        if chapters.isEmpty {
            // No contents: a section at each page break.
            starts = pageBreaks.map { (position: $0, title: nil) }
        } else {
            // Where an entry's offset is anchored; the anchors are sorted by offset.
            let positions = Dictionary(anchors.map { ($0.offset, $0.position) }, uniquingKeysWith: { first, _ in first })
            starts = chapters.compactMap { entry in
                positions[entry.offset].map { (position: $0, title: entry.label.isEmpty ? nil : entry.label) }
            }
        }
        // A section that would begin in the head begins where the body does.
        starts = starts.map { (position: max($0.position, bodyStart), title: $0.title) }
        // In order of place; of two sections at one place, the first one stays.
        starts = starts.enumerated().sorted {
            $0.element.position != $1.element.position ? $0.element.position < $1.element.position : $0.offset < $1.offset
        }.map(\.element)
        var unique: [(position: Int, title: String?)] = []
        for start in starts where start.position != unique.last?.position {
            unique.append(start)
        }
        // The first section starts where the body does, whether or not the
        // contents does: the words before it are a section of their own.
        if unique.first?.position != bodyStart { unique.insert((position: bodyStart, title: nil), at: 0) }
        return unique
    }

    // MARK: A PalmDOC Book

    /// The one section of a plain PalmDOC book (`TEXtREAd`): its text is
    /// plain, not HTML, a paragraph to a line.
    private static func plainSection(of text: [UInt8]) -> Section {
        let decoded = MOBIText.decode(text, encoding: 1252)
        let paragraphs = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                // Only the three characters that would read as markup.
                let escaped = line
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<p>\(escaped)</p>"
            }
        // The soft hyphens (U+00AD, which Windows-1252 has at 0xAD) are left out, as they are of a book of markup.
        // Run after the escaping above, so that the text "&shy;" (now "&amp;shy;") stays as the author typed it.
        return Section(
            title: nil, html: ParserUtilities.removingSoftHyphens("<html><body>\(paragraphs.joined())</body></html>"),
            headingTargets: [:])
    }
}
