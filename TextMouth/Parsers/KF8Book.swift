import Foundation
import SwiftSoup

/// A KF8 book's text cut into the sections the shared reading path turns
/// into chapters: one for each XHTML document the book was made from, as
/// the EPUB reader makes a chapter of each document in a spine.
///
/// `KF8Layout` finds the book's documents and joins them. This gives each
/// its title and the headings the book's contents (its NCX) names inside it,
/// and writes a destination (`<a id="filepos-N"></a>`, N the place in the
/// text) at each place the contents names, as `MOBIBook` does for a MOBI 6
/// book, so the converter finds the headings by the same means.
///
/// Written from the format's specification (the MobileRead wiki's "KF8"
/// page) with foliate-js's `mobi.js` (MIT) read as a map: its `getNCX`, and
/// `kindle:pos:fid:XXXX:off:YYYY` links, whose two numbers (a fragment's
/// sequence number and a place in the fragment) are the contents'
/// destination there as here. No code is copied.
///
/// Links in the markup (`kindle:pos`, `kindle:flow`, and `kindle:embed`)
/// are left as the book wrote them. Nothing reads a link's destination
/// aloud, a picture is read by its description and not its file, and the
/// flows that `kindle:flow` names (style sheets and SVG) hold no words that
/// the markup does not.
enum KF8Book {

    /// One entry of the book's contents, resolved: the place in the text
    /// it names, the part that place is in, and how deep it lies.
    private struct Destination {
        var label: String
        var depth: Int
        /// The byte in the text the entry names.
        var position: Int
        /// The index in `KF8Layout.parts` of the part it lies in.
        var part: Int
        /// Whether the entry names the very start of its part's first
        /// fragment, which is where a contents entry for a whole document
        /// points. Such an entry titles the document; it is not a heading in it.
        var isWholeDocument: Bool
    }

    // MARK: Sections

    /// The sections of the KF8 book in `database`, whose record 0 `headers`
    /// was read from and whose decompressed text is `text`.
    /// - Parameters:
    ///   - bookTitle: The book's title, which a document's own `<title>` is
    ///     not taken as the document's title when it repeats.
    ///   - checkCancellation: Asked before each document is joined; throws
    ///     to stop the read. A test passes its own to prove the read stops
    ///     partway.
    /// - Throws: `MOBIError.damaged` for a book whose tables, contents, or
    ///   markup do not read (see `KF8Layout`), and `ImportCancelled` when the
    ///   import running this was cancelled, which is heard between documents.
    static func sections(
        of text: [UInt8], headers: MOBIHeaders, database: MOBIPalmDatabase, bookTitle: String,
        checkCancellation: () throws -> Void = { try ImportCancellation.throwIfCancelled() }
    ) throws -> [MOBIBook.Section] {
        let layout = try KF8Layout(database: database, headers: headers, textLength: text.count)
        let destinations = try self.destinations(of: layout, headers: headers, database: database)

        // A document that a contents entry names as a whole takes the
        // entry's label as its title; the first such entry names it.
        var titles: [Int: String] = [:]
        // The entries that name a place inside a document are headings
        // there, by the id of the destination written at the place.
        var headingTargets: [String: MarkdownHeadingAnnotation] = [:]
        var places: Set<Int> = []
        for destination in destinations {
            if destination.isWholeDocument {
                if titles[destination.part] == nil { titles[destination.part] = destination.label }
                continue
            }
            let id = MOBIMarkup.anchorID(forOffset: destination.position)
            if headingTargets[id] == nil {
                headingTargets[id] = MarkdownHeadingAnnotation(level: min(destination.depth + 1, 6), text: destination.label)
            }
            places.insert(destination.position)
        }
        let anchors = anchors(for: places, in: text, layout: layout)
        // A contents page that was made for the book (see `generatedContentsPart`)
        // is left out, unless the book's own contents names it.
        let generatedContents = try generatedContentsPart(of: layout, headers: headers, database: database)
            .flatMap { titles[$0] == nil ? $0 : nil }

        var sections: [MOBIBook.Section] = []
        sections.reserveCapacity(layout.parts.count)
        for (index, part) in layout.parts.enumerated() where index != generatedContents {
            // A very large book is cancelled between its documents.
            try checkCancellation()
            let joined = try layout.markup(of: part, in: text, anchors: anchors)
            try MOBIMarkup.requireShallowNesting(of: joined)
            let markup = restoringPageBreakTypes(in: joined)
            sections.append(MOBIBook.Section(
                title: titles[index] ?? documentTitle(in: text[part.skeleton], encoding: headers.encoding, differentFrom: bookTitle),
                html: withoutSoftHyphens(MOBIText.decode(markup, encoding: headers.encoding)),
                headingTargets: headingTargets,
                stripsDuplicateNavigation: true
            ))
        }
        return sections
    }

    // MARK: The Contents

    /// The entries of the book's contents (its NCX) that name a place in a
    /// document, in the order the contents lists them. An entry without a
    /// label, or whose place is not in the book's documents, names nothing
    /// a reader can use and is passed over, as the EPUB reader passes over
    /// an entry it cannot place. A book without a contents has none.
    /// - Throws: `MOBIError.damaged` for a contents that does not read.
    private static func destinations(
        of layout: KF8Layout, headers: MOBIHeaders, database: MOBIPalmDatabase
    ) throws -> [Destination] {
        guard let indexRecord = headers.indexRecord else { return [] }
        let index = try MOBIIndex.table(startingAt: indexRecord, in: database)
        var destinations: [Destination] = []
        for row in index.rows {
            // Tag 3 is the label's place among the strings, tag 4 the depth,
            // and tag 6 the destination: a fragment's number and a place in it.
            guard let label = row.values[3]?.first.flatMap({ index.labels[$0] }), !label.isEmpty,
                  let target = row.values[6], target.count >= 2,
                  let location = layout.locations[target[0]] else { continue }
            let part = layout.parts[location.part]
            let fragment = part.fragments[location.fragment]
            // The place must be inside the fragment it names.
            guard target[1] < fragment.range.count else { continue }
            destinations.append(Destination(
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                depth: row.values[4]?.first ?? 0,
                position: fragment.range.lowerBound + target[1],
                part: location.part,
                isWholeDocument: location.fragment == 0 && target[1] == 0
            ))
        }
        return destinations
    }

    /// The anchors to write for the contents' `places`, ascending: each at
    /// its place, moved back to the start of the tag the place lies in (an
    /// anchor cannot go inside a tag), and no further back than the start of
    /// the fragment that holds it.
    private static func anchors(for places: Set<Int>, in text: [UInt8], layout: KF8Layout) -> [KF8Layout.Anchor] {
        let snapped = MOBIMarkup.anchors(for: places.sorted(), in: text)
        // Where each fragment starts, to keep an anchor from going back into
        // the fragment before (or the skeleton) when a tag straddles them.
        var fragmentStarts: [Int] = []
        for part in layout.parts { fragmentStarts.append(contentsOf: part.fragments.map(\.range.lowerBound)) }
        fragmentStarts.sort()
        return snapped.map { anchor in
            // The last fragment start at or before the place.
            var low = 0
            var high = fragmentStarts.count
            while low < high {
                let middle = (low + high) / 2
                if fragmentStarts[middle] <= anchor.offset { low = middle + 1 } else { high = middle }
            }
            let start = low > 0 ? fragmentStarts[low - 1] : 0
            return KF8Layout.Anchor(position: max(anchor.position, start), id: anchor.id)
        }.sorted { $0.position < $1.position }
    }

    // MARK: A Contents Page Made for the Book

    /// The index in `layout.parts` of a contents page that a converter added
    /// to the end of the book, or nil. Such a page (calibre writes one, with
    /// the heading "Table of Contents") repeats the book's own contents as
    /// links and is not in the book it was made from, so reading it would
    /// read the contents aloud at the book's end. It is the last document,
    /// and the book's guide names it as its contents page (a guide entry of
    /// the type `toc`, whose destination is a fragment's number and a place
    /// in it, as the book's own contents' are). A contents page that comes
    /// earlier in the book is the author's, and is read as an EPUB's is.
    private static func generatedContentsPart(
        of layout: KF8Layout, headers: MOBIHeaders, database: MOBIPalmDatabase
    ) throws -> Int? {
        guard let guideRecord = headers.guideIndexRecord, let last = layout.parts.indices.last else { return nil }
        let guide = try MOBIIndex.table(startingAt: guideRecord, in: database)
        for row in guide.rows where String(decoding: row.name, as: UTF8.self).lowercased() == "toc" {
            if let fragment = row.values[6]?.first, layout.locations[fragment]?.part == last { return last }
        }
        return nil
    }

    // MARK: Page Breaks

    /// The attribute calibre leaves a page-break element with: it takes the
    /// namespace prefix off `epub:type`, so `epub:type="pagebreak"` of the
    /// EPUB the book was made from is `type="pagebreak"` in the KF8 book.
    /// (`role="doc-pagebreak"` is kept as it was.) The spellings with each
    /// kind of quote.
    private static let unprefixedPageBreakTypes = [
        Array("type=\"pagebreak\"".utf8), Array("type='pagebreak'".utf8),
    ]

    /// `markup` with `epub:type` put back on each tag that has a bare
    /// `type="pagebreak"`, which the converter then takes for the page-break
    /// element it was (`PublicationSemantics.isPageBreak`). The change is
    /// made inside tags only, so no word of the book is touched. Markup with
    /// no such attribute is returned as it is, after a scan for the word.
    private static func restoringPageBreakTypes(in markup: [UInt8]) -> [UInt8] {
        // The places an `epub:` goes: just before a `type` that starts an attribute.
        var places: [Int] = []
        MOBIMarkup.forEachTag(in: markup, within: 0..<markup.count) { tag in
            for pattern in unprefixedPageBreakTypes {
                var position = tag.lowerBound + 1
                while position + pattern.count <= tag.upperBound {
                    if markup[position] == pattern[0], markup[position - 1] == 0x20 || markup[position - 1] == 0x0A
                        || markup[position - 1] == 0x09, markup[position..<(position + pattern.count)].elementsEqual(pattern) {
                        places.append(position)
                        position += pattern.count
                    } else {
                        position += 1
                    }
                }
            }
        }
        guard !places.isEmpty else { return markup }
        places.sort()
        var result: [UInt8] = []
        result.reserveCapacity(markup.count + places.count * 5)
        var cursor = 0
        for place in places {
            result.append(contentsOf: markup[cursor..<place])
            result.append(contentsOf: "epub:".utf8)
            cursor = place
        }
        result.append(contentsOf: markup[cursor...])
        return result
    }

    // MARK: Soft Hyphens

    /// The soft hyphen (U+00AD) and the three other ways markup spells it.
    private static let softHyphenSpellings = ["\u{AD}", "&shy;", "&#173;", "&#xAD;", "&#xad;"]

    /// `markup` without its soft hyphens, which a book's publisher puts
    /// inside words to say where a line may break. A person reading sees
    /// none in the middle of a line, and a speech engine or a braille
    /// display should not meet one in the middle of a word.
    private static func withoutSoftHyphens(_ markup: String) -> String {
        var result = markup
        for spelling in softHyphenSpellings where result.contains(spelling) {
            result = result.replacingOccurrences(of: spelling, with: "")
        }
        return result
    }

    // MARK: A Document's Title

    /// The longest stretch of a skeleton looked through for its title, which
    /// is in its head, near the start.
    private static let titleSearchLength = 4096

    /// The text of the `<title>` element in the head of `skeleton`, with
    /// character references read and white space collapsed, or nil when it
    /// has none, none that holds a letter or digit, or one that repeats
    /// `bookTitle` (which names no chapter in particular).
    private static func documentTitle(in skeleton: ArraySlice<UInt8>, encoding: Int, differentFrom bookTitle: String) -> String? {
        let head = skeleton.prefix(titleSearchLength)
        guard let open = find("<title", in: head, from: head.startIndex),
              let openEnd = head[open...].firstIndex(of: UInt8(ascii: ">")),
              let close = find("</title", in: head, from: openEnd) else { return nil }
        let raw = MOBIText.decode(Array(head[(openEnd + 1)..<close]), encoding: encoding)
        let unescaped = (try? Entities.unescape(raw)) ?? raw
        let title = unescaped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard title.contains(where: { $0.isLetter || $0.isNumber }),
              title.caseInsensitiveCompare(bookTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")) != .orderedSame
        else { return nil }
        return title
    }

    /// The index of the first place in `bytes` at or after `start` where the
    /// ASCII `word` is spelled in any letter case, or nil.
    private static func find(_ word: String, in bytes: ArraySlice<UInt8>, from start: Int) -> Int? {
        let wanted = Array(word.utf8)
        guard bytes.count >= wanted.count else { return nil }
        var position = start
        while position + wanted.count <= bytes.endIndex {
            var matches = true
            for (offset, expected) in wanted.enumerated() {
                var byte = bytes[position + offset]
                if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
                if byte != expected { matches = false; break }
            }
            if matches { return position }
            position += 1
        }
        return nil
    }
}
