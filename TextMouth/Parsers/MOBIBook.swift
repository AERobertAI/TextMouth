import Foundation
import SwiftSoup

/// A Kindle (MOBI) book opened for reading: what it says about itself, and
/// its text cut into sections of HTML. This is everything the book holds
/// before the shared HTML converter turns it into the reading text
/// (`MOBIParser`).
///
/// It refuses what TextMouth does not read, in this order: a book that is
/// encrypted or carries DRM (never removed), a KF8 book (the next format,
/// FMT48), and a text compressed in a way not yet read.
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
    }

    var metadata: Metadata
    var sections: [Section]

    // MARK: Opening

    /// Reads the book in `bytes`.
    /// - Throws: `MOBIError` for a file that is not a readable Kindle book
    ///   (see the type's comment for the refusals), `DocumentTooLargeError`
    ///   for a text past `DocumentByteLimit`, and `FileImportError.noTextToRead`
    ///   for a book without text.
    init(bytes: [UInt8]) throws {
        let database = try MOBIPalmDatabase(bytes: bytes)
        let headers = try MOBIHeaders(
            record0: try database.record(0, "Record 0"),
            requiresMOBIHeader: database.type == MOBIPalmDatabase.mobiSignature.type
        )
        try Self.refuseWhatIsNotRead(headers)
        metadata = Self.metadata(of: headers, database: database)

        let text = try MOBIText.bytes(of: database, headers: headers)
        // A plain PalmDOC book is plain text, unless the text is HTML.
        if headers.hasMOBIHeader || MOBIMarkup.looksLikeHTML(text) {
            sections = try Self.sections(of: text, headers: headers, database: database)
        } else {
            sections = [Self.plainSection(of: text)]
        }
    }

    /// What the book says about itself, read without its text. A book that
    /// is protected, in KF8, or compressed in a way not read still names its
    /// title and author.
    /// - Throws: `MOBIError` for a file that is not a Kindle book.
    static func metadata(in bytes: [UInt8]) throws -> Metadata {
        let database = try MOBIPalmDatabase(bytes: bytes)
        let headers = try MOBIHeaders(
            record0: try database.record(0, "Record 0"),
            requiresMOBIHeader: database.type == MOBIPalmDatabase.mobiSignature.type
        )
        return metadata(of: headers, database: database)
    }

    // MARK: Refusals

    /// Throws for a book this reader does not read, before any of its text
    /// is touched. Copy protection comes first: TextMouth never removes it,
    /// and says so rather than naming the book's other faults.
    private static func refuseWhatIsNotRead(_ headers: MOBIHeaders) throws {
        // The encryption field is not 0, or the DRM offset is not
        // 0xFFFFFFFF: the book is protected.
        if headers.encryption != 0 || headers.hasDRM { throw MOBIError.copyProtected }
        // Version 8 and later is KF8. A hybrid file's record 0 is its MOBI 6
        // part (version 6, with an EXTH record 121 naming where the KF8 part
        // begins), which is read; only a book that is all KF8 is refused.
        if headers.version >= 8 { throw MOBIError.kf8Only }
    }

    // MARK: Metadata

    /// The metadata `headers` hold, with the database name as the last
    /// resort for a title.
    private static func metadata(of headers: MOBIHeaders, database: MOBIPalmDatabase) -> Metadata {
        let title = firstNonEmpty([
            headers.exthText(MOBIHeaders.EXTHType.title),
            headers.fullName,
            // The database name spells spaces as underscores.
            database.name.replacingOccurrences(of: "_", with: " "),
        ])
        let authors = headers.exthTexts(MOBIHeaders.EXTHType.author).map(cleaned).filter { !$0.isEmpty }
        let language = cleaned(headers.exthText(MOBIHeaders.EXTHType.language) ?? "")
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
                html: MOBIText.decode(bytes, encoding: headers.encoding),
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
        return Section(title: nil, html: "<html><body>\(paragraphs.joined())</body></html>", headingTargets: [:])
    }
}
