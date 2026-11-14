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
/// What the book's markup says about the rest of the book is mostly left as
/// it was written. Links (`kindle:pos`) are never read aloud, so their
/// destinations are not followed, and a picture is read by its description
/// and not its file (`kindle:embed`). An SVG picture, which calibre and
/// kindlegen move out of the markup into a flow of its own and name with
/// `kindle:flow`, is put back where it stood, once for each flow, so the
/// words in it (its visible `<text>`, its title and description) are read
/// as they are in the EPUB. Style sheets are not read.
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

    /// What the book's contents (its NCX) says.
    private struct Contents {
        /// The entries that name a place in a document, in the order the contents lists them.
        var destinations: [Destination] = []
        /// The label of every entry, read, whether or not its place is found.
        var labels: Set<String> = []
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
    /// - Throws: `MOBIError.damaged` for a book whose tables or markup do not
    ///   read (see `KF8Layout`), `FileImportError.noTextToRead` for one
    ///   whose documents hold no words, and `ImportCancelled` when the
    ///   import running this was cancelled, which is heard between documents.
    ///   A contents or guide that does not read is not an error: the book is
    ///   read without it.
    static func sections(
        of text: [UInt8], headers: MOBIHeaders, database: MOBIPalmDatabase, bookTitle: String,
        checkCancellation: () throws -> Void = { try ImportCancellation.throwIfCancelled() }
    ) throws -> [MOBIBook.Section] {
        let layout = try KF8Layout(database: database, headers: headers, textLength: text.count)
        let contents = readContents(of: layout, headers: headers, database: database)

        // A document that a contents entry names as a whole takes the
        // entry's label as its title; the first such entry names it.
        var titles: [Int: String] = [:]
        var places: Set<Int> = []
        for destination in contents.destinations {
            if destination.isWholeDocument {
                if titles[destination.part] == nil { titles[destination.part] = destination.label }
            } else {
                places.insert(destination.position)
            }
        }
        // The entries that name a place inside a document are headings
        // there. Each place gets one anchor, and an anchor is named for the
        // place it is written at: all the places inside one tag (which an
        // anchor cannot go inside) share the anchor at its start, and the
        // first entry to name it names it.
        let snapped = MOBIMarkup.anchors(for: places.sortedStably(), in: text)
        var positionOfPlace: [Int: Int] = [:]
        for anchor in snapped { positionOfPlace[anchor.offset] = anchor.position }
        var headingTargets: [String: MarkdownHeadingAnnotation] = [:]
        for destination in contents.destinations where !destination.isWholeDocument {
            guard let position = positionOfPlace[destination.position] else { continue }
            let id = MOBIMarkup.anchorID(forOffset: position)
            if headingTargets[id] == nil {
                headingTargets[id] = MarkdownHeadingAnnotation(level: min(destination.depth + 1, 6), text: destination.label)
            }
        }
        let anchors = Set(positionOfPlace.values).sortedStably().map {
            KF8Layout.Anchor(position: $0, id: MOBIMarkup.anchorID(forOffset: $0))
        }
        // The last document may be a contents page a converter added (see `isGeneratedContents`).
        let contentsPageCandidate = generatedContentsCandidate(of: layout, headers: headers, database: database)
            .flatMap { titles[$0] == nil ? $0 : nil }

        var sections: [MOBIBook.Section] = []
        sections.reserveCapacity(layout.parts.count)
        // The SVG flows already put back; each is put back once.
        var inlinedFlows: Set<Int> = []
        var previousTitle: String?
        var previousContainer: Container?
        var previousEndsMidParagraph = false
        // Whether the piece before this one is the opening of this piece's section (see below).
        var previousOpensThisSection = false
        var anyWords = false
        for (index, part) in layout.parts.enumerated() {
            // A very large book is cancelled between its documents.
            try checkCancellation()
            let joined = try layout.markup(of: part, in: text, anchors: anchors)
            if index == contentsPageCandidate,
               isGeneratedContents(joined, labels: contents.labels, encoding: headers.encoding) {
                // Left out, so the piece after it is not the section the piece before it opened.
                previousOpensThisSection = false
                continue
            }
            let markup = rewritingTags(in: joined, layout: layout, text: text, inlinedFlows: &inlinedFlows)
            // Whether a piece with words came before this one: a chapter for this piece to go on with.
            let hasChapterBefore = anyWords
            anyWords = anyWords || MOBIMarkup.hasWords(markup)

            // A document of the EPUB that calibre cut into pieces: a piece that no contents entry names and
            // that opens with no heading of its own goes on with the chapter before it (and no heading is made
            // of its <title>) in two cases, and only these:
            // - its <title> is the title of the piece before it (the pieces of one file share the file's title),
            //   unless the piece before opens in a `header` or other section (not a footer) and this piece opens
            //   in no section: then the shared title is the book's, not a document's (Project Gutenberg's
            //   header page, and the essay after it in a `div`). A piece in another section is still taken for the
            //   second half of a document cut inside its second section, which the cut opens again;
            // - its <title> is the heading the next piece opens with: calibre gave the first piece of a file
            //   the file's title, but the piece holds the end of the chapter before, and the chapter the title
            //   names begins with the next piece's heading.
            // In that second case, when the piece and the next piece are inside one container (a `footer` that
            // calibre opened again in the second piece, as Project Gutenberg's license is: the words of the
            // license's opening, then its heading), the piece is not the end of the chapter before. It is the
            // opening of the next piece's section, which goes on with it.
            // Any other piece stands alone, titled as it always was. Only the book's first piece with words,
            // which has no chapter before it (a cover of pictures does not count), is never a continuation.
            let rawTitle = rawDocumentTitle(in: text[part.skeleton], encoding: headers.encoding)
            let start = documentOpening(of: markup)
            let container = openingContainer(of: markup)
            var continues = previousOpensThisSection
            // Whether the cut falls between two pieces of the chapter (so a paragraph may run across it).
            var cutsAChapter = false
            var opensNextSection = false
            if titles[index] == nil, !start.hasHeading, hasChapterBefore, let title = rawTitle {
                if title == previousTitle, !Container.endsBefore(previousContainer, piece: container) {
                    continues = true
                    cutsAChapter = true
                }
                if !continues, index + 1 < layout.parts.count {
                    let next = try layout.markup(of: layout.parts[index + 1], in: text, anchors: anchors)
                    if openingHeading(of: next, encoding: headers.encoding) == title {
                        if let container, container == openingContainer(of: next) {
                            opensNextSection = true
                        } else {
                            continues = true
                            cutsAChapter = true
                        }
                    }
                }
            }
            sections.append(MOBIBook.Section(
                title: titles[index] ?? displayTitle(of: rawTitle, differentFrom: bookTitle),
                html: ParserUtilities.removingSoftHyphens(MOBIText.decode(markup, encoding: headers.encoding)),
                headingTargets: headingTargets,
                stripsDuplicateNavigation: true,
                documentNumber: index + 1,
                continuesPrevious: continues,
                joinsParagraph: cutsAChapter && previousEndsMidParagraph && start.hasSplitMarker
            ))
            previousTitle = rawTitle
            previousContainer = container
            previousOpensThisSection = opensNextSection
            previousEndsMidParagraph = endsMidParagraph(markup)
        }
        guard anyWords else { throw FileImportError.noTextToRead }
        return sections
    }

    // MARK: The Contents

    /// What the book's contents (its NCX) names. A book without a contents
    /// names nothing, and so does one whose contents does not read: the
    /// contents only helps to find the chapters, and the book is read
    /// without it, as the EPUB reader reads an EPUB whose NCX is damaged.
    /// An entry without a label, or whose place is not in the book's
    /// documents, names nothing a reader can use and is passed over.
    private static func readContents(of layout: KF8Layout, headers: MOBIHeaders, database: MOBIPalmDatabase) -> Contents {
        guard let indexRecord = headers.indexRecord,
              let index = try? MOBIIndex.table(startingAt: indexRecord, in: database) else { return Contents() }
        var contents = Contents()
        // Each label is read once, however many rows name it.
        var readLabels: [Int: String] = [:]
        for row in index.rows {
            // Tag 3 is the label's place among the strings, tag 4 the depth,
            // and tag 6 the destination: a fragment's number and a place in it.
            guard let key = row.values[3]?.first, let raw = index.labels[key] else { continue }
            let label: String
            if let known = readLabels[key] {
                label = known
            } else {
                label = readableLabel(raw)
                readLabels[key] = label
            }
            guard !label.isEmpty else { continue }
            contents.labels.insert(label)
            guard let target = row.values[6], target.count >= 2,
                  let location = layout.locations[target[0]] else { continue }
            let fragment = layout.parts[location.part].fragments[location.fragment]
            // The place must be inside the fragment it names.
            guard target[1] < fragment.range.count else { continue }
            contents.destinations.append(Destination(
                label: label,
                depth: row.values[4]?.first ?? 0,
                position: fragment.range.lowerBound + target[1],
                part: location.part,
                isWholeDocument: location.fragment == 0 && target[1] == 0
            ))
        }
        return contents
    }

    /// A contents label as it is read: its character references (`Tom &amp; Jerry`,
    /// which a KF8 book's labels keep) read as characters, its soft hyphens left out, and its
    /// white space made single spaces, as the EPUB reader makes its labels. Empty
    /// when it holds nothing to read.
    private static func readableLabel(_ label: String) -> String {
        let unescaped = (try? Entities.unescape(label)) ?? label
        return ParserUtilities.removingSoftHyphens(unescaped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: A Contents Page Made for the Book

    /// The index of the last document when the book's guide names its start
    /// as the book's contents page (a guide entry of the type `toc` whose
    /// destination is the first fragment of the document, at place 0), else
    /// nil. A guide that does not read names nothing.
    private static func generatedContentsCandidate(
        of layout: KF8Layout, headers: MOBIHeaders, database: MOBIPalmDatabase
    ) -> Int? {
        guard let guideRecord = headers.guideIndexRecord, let last = layout.parts.indices.last,
              let guide = try? MOBIIndex.table(startingAt: guideRecord, in: database) else { return nil }
        for row in guide.rows where String(decoding: row.name, as: UTF8.self).lowercased() == "toc" {
            if let target = row.values[6], target.count >= 2, target[1] == 0,
               let location = layout.locations[target[0]], location.part == last, location.fragment == 0 {
                return last
            }
        }
        return nil
    }

    /// The most bytes of markup looked through to decide a contents page is made for the book. A page
    /// of links to a book's chapters is small.
    private static let maximumGeneratedContentsBytes = 1_000_000

    /// Whether the markup of the last document is a contents page that a
    /// converter added to the book (calibre writes one, headed "Table of
    /// Contents"): a page of links to the book's own chapters that is not in
    /// the book it was made from, and that reading aloud would repeat at the
    /// book's end. It is one only when all three hold (the guide has named
    /// its start already):
    /// - its only words outside its links are its own title;
    /// - every link goes to a place in the book (`kindle:pos`);
    /// - the words of each link are a label of the book's contents.
    /// An author's contents page with a note, or a last chapter that ends with
    /// a list of links, has other words and is read.
    private static func isGeneratedContents(_ markup: [UInt8], labels: Set<String>, encoding: Int) -> Bool {
        guard markup.count <= maximumGeneratedContentsBytes else { return false }
        var inHead = false
        var inTitle = false
        var skipping = false
        var inLink = false
        var holds = true
        var titleBytes: [UInt8] = []
        var linkBytes: [UInt8] = []
        var outsideBytes: [UInt8] = []
        var cursor = 0

        /// The text between tags, put where it belongs.
        func add(_ range: Range<Int>) {
            guard !range.isEmpty, !skipping else { return }
            if inTitle {
                titleBytes += markup[range]; titleBytes.append(0x20)
            } else if inHead {
                return
            } else if inLink {
                linkBytes += markup[range]; linkBytes.append(0x20)
            } else {
                outsideBytes += markup[range]; outsideBytes.append(0x20)
            }
        }
        MOBIMarkup.forEachTag(in: markup, within: 0..<markup.count) { tag in
            guard holds else { return }
            add(cursor..<tag.lowerBound)
            cursor = tag.upperBound
            guard let name = tagName(markup, tag) else { return }
            switch name {
            case "head": inHead = true
            case "/head": inHead = false
            case "title": inTitle = true
            case "/title": inTitle = false
            case "script", "style": skipping = true
            case "/script", "/style": skipping = false
            case "a":
                // An anchor with no href names a place and is no link.
                guard let href = attribute("href", in: markup, tag: tag) else { return }
                if markup[href.value].starts(with: Array("kindle:pos:".utf8)) {
                    inLink = true
                    linkBytes = []
                } else {
                    holds = false
                }
            case "/a":
                if inLink {
                    inLink = false
                    if !labels.contains(readableLabel(MOBIText.decode(linkBytes, encoding: encoding))) { holds = false }
                }
            default: break
            }
        }
        add(cursor..<markup.count)
        guard holds else { return false }
        // Its own words are its title's: every word outside its links is in the <title>.
        let title = Set(words(of: titleBytes, encoding: encoding))
        return words(of: outsideBytes, encoding: encoding).allSatisfy { title.contains($0) }
    }

    /// The words of `bytes`, read as text and folded to lower case.
    private static func words(of bytes: [UInt8], encoding: Int) -> [String] {
        readableLabel(MOBIText.decode(bytes, encoding: encoding)).lowercased().split(separator: " ").map(String.init)
    }

    // MARK: Tags

    /// The name of the tag at `tag` in `markup`, in lower case and with a
    /// leading "/" for an end tag; nil for a comment, a declaration, or a
    /// name longer than 16 bytes.
    private static func tagName(_ markup: [UInt8], _ tag: Range<Int>) -> String? {
        var position = tag.lowerBound + 1
        var name = ""
        if position < tag.upperBound, markup[position] == UInt8(ascii: "/") { name = "/"; position += 1 }
        let start = position
        while position < tag.upperBound, position - start < 16 {
            let byte = markup[position]
            guard (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: ":") else { break }
            name.append(Character(Unicode.Scalar(lower(byte))))
            position += 1
        }
        guard position > start else { return nil }
        // A name that goes on is not one of the names looked for.
        if position < tag.upperBound, position - start == 16 { return nil }
        return name
    }

    /// An attribute found in a tag: where its name starts and where its value is.
    private struct Attribute {
        var name: Int
        var value: Range<Int>
    }

    /// The longest attribute value looked at.
    private static let maximumAttributeBytes = 2_048

    /// The attribute `name` (lower case) of the tag at `tag`, whose name
    /// must follow a white space byte; nil when it has none. The value is
    /// taken up to its closing quote, or up to a space or the tag's end when it is not quoted.
    private static func attribute(_ name: String, in markup: [UInt8], tag: Range<Int>) -> Attribute? {
        let wanted = Array(name.utf8)
        var position = tag.lowerBound + 1
        while position + wanted.count < tag.upperBound {
            let before = markup[position - 1]
            guard before == 0x20 || before == 0x0A || before == 0x09 || before == 0x0D,
                  markup[position..<(position + wanted.count)].elementsEqual(wanted, by: { lower($0) == $1 }) else {
                position += 1
                continue
            }
            var cursor = position + wanted.count
            while cursor < tag.upperBound, markup[cursor] == 0x20 { cursor += 1 }
            guard cursor < tag.upperBound, markup[cursor] == UInt8(ascii: "=") else { position += 1; continue }
            cursor += 1
            while cursor < tag.upperBound, markup[cursor] == 0x20 { cursor += 1 }
            guard cursor < tag.upperBound else { return nil }
            var valueStart = cursor
            var end = cursor
            if markup[cursor] == UInt8(ascii: "\"") || markup[cursor] == UInt8(ascii: "'") {
                let quote = markup[cursor]
                valueStart = cursor + 1
                end = valueStart
                while end < tag.upperBound, end - valueStart < maximumAttributeBytes, markup[end] != quote { end += 1 }
            } else {
                while end < tag.upperBound, end - valueStart < maximumAttributeBytes,
                      markup[end] != 0x20, markup[end] != UInt8(ascii: ">") { end += 1 }
            }
            return Attribute(name: position, value: valueStart..<end)
        }
        return nil
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
    }

    // MARK: Putting Back What The Converters Took

    /// The `epub:type` tokens whose prefix calibre strips (`type="pagebreak"`),
    /// which the shared reading rules need: a page break is a page, and
    /// a page list, the landmarks, and a contents list are navigation,
    /// not words to be read aloud (`PublicationSemantics`).
    private static let navigationTypes: Set<String> = ["pagebreak", "page-list", "landmarks", "toc"]

    /// The largest SVG flow put back into the markup, in bytes.
    private static let maximumInlinedFlowBytes = 262_144

    /// `markup` with two things put back that the converters changed:
    /// - `epub:type` on a tag whose bare `type` lists one of
    ///   `navigationTypes` (`type="pagebreak bodymatter"` too), so the
    ///   converter takes the tag for what it was. The change is made inside
    ///   tags only, and no word of the book is touched.
    /// - an SVG picture, where an `<img>` names its flow
    ///   (`src="kindle:flow:0004?mime=image/svg+xml"`): the flow's `<svg>` is written in its place,
    ///   so the words in it are read as they are in the EPUB, where the
    ///   SVG stood in the markup. Each flow is put back once, in the first place
    ///   that names it (`inlinedFlows`), and no more than `maximumInlinedFlowBytes` of it.
    private static func rewritingTags(
        in markup: [UInt8], layout: KF8Layout, text: [UInt8], inlinedFlows: inout Set<Int>
    ) -> [UInt8] {
        var edits: [(range: Range<Int>, replacement: [UInt8])] = []
        MOBIMarkup.forEachTag(in: markup, within: 0..<markup.count) { tag in
            // Start tags only.
            guard tag.count > 2, lower(markup[tag.lowerBound + 1]) >= UInt8(ascii: "a"),
                  lower(markup[tag.lowerBound + 1]) <= UInt8(ascii: "z") else { return }
            if let src = attribute("src", in: markup, tag: tag),
               let svg = svgFlow(named: markup[src.value], layout: layout, text: text, inlinedFlows: &inlinedFlows) {
                edits.append((range: tag, replacement: svg))
                return
            }
            if let type = attribute("type", in: markup, tag: tag) {
                let tokens = String(decoding: markup[type.value], as: UTF8.self).lowercased().split(whereSeparator: \.isWhitespace)
                if tokens.contains(where: { navigationTypes.contains(String($0)) }) {
                    edits.append((range: type.name..<type.name, replacement: Array("epub:".utf8)))
                }
            }
        }
        guard !edits.isEmpty else { return markup }
        var result: [UInt8] = []
        result.reserveCapacity(markup.count + edits.reduce(0) { $0 + $1.replacement.count })
        var cursor = 0
        for edit in edits {
            result.append(contentsOf: markup[cursor..<edit.range.lowerBound])
            result.append(contentsOf: edit.replacement)
            cursor = edit.range.upperBound
        }
        result.append(contentsOf: markup[cursor...])
        return result
    }

    /// The `<svg>` markup of the flow `source` names, or nil when it names no
    /// SVG flow, names one already put back, or one that is too large or holds no `<svg>`.
    private static func svgFlow(
        named source: ArraySlice<UInt8>, layout: KF8Layout, text: [UInt8], inlinedFlows: inout Set<Int>
    ) -> [UInt8]? {
        let prefix = Array("kindle:flow:".utf8)
        guard source.starts(with: prefix) else { return nil }
        // The flow's number is base 32, up to the "?".
        var number = 0
        var digits = 0
        var cursor = source.startIndex + prefix.count
        while cursor < source.endIndex, digits < 6, let digit = base32Digit(source[cursor]) {
            number = number * 32 + digit
            digits += 1
            cursor += 1
        }
        guard digits > 0, String(decoding: source[cursor...], as: UTF8.self).lowercased().contains("svg"),
              number >= 1, number < layout.flows.count, !inlinedFlows.contains(number) else { return nil }
        let flow = layout.flows[number]
        guard flow.count <= maximumInlinedFlowBytes else { return nil }
        // The flow begins with an XML declaration, perhaps a doctype and comments, then the <svg>.
        let head = flow.lowerBound..<min(flow.upperBound, flow.lowerBound + 4_096)
        let marker = Array("<svg".utf8)
        var start = head.lowerBound
        while start + marker.count < head.upperBound,
              !(text[start] == UInt8(ascii: "<") && text[start..<(start + marker.count)].elementsEqual(marker, by: { lower($0) == $1 })
                && (text[start + marker.count] == 0x20 || text[start + marker.count] == UInt8(ascii: ">")
                    || text[start + marker.count] == UInt8(ascii: "/") || text[start + marker.count] == 0x0A)) {
            start += 1
        }
        guard start + marker.count < head.upperBound else { return nil }
        inlinedFlows.insert(number)
        return Array(text[start..<flow.upperBound])
    }

    /// The value of the digit `byte` in base 32 (0 to 9, then A to V), or nil.
    private static func base32Digit(_ byte: UInt8) -> Int? {
        switch lower(byte) {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "v"): return Int(lower(byte) - UInt8(ascii: "a")) + 10
        default: return nil
        }
    }

    // MARK: Where A Document Begins And Ends

    /// The first heading (`h1` to `h6`) a document opens with: whether one comes before any word, and the
    /// bytes between its start and end tag when the end tag is also within `length` bytes of where the
    /// words begin. Tags that are not headings (a `div`, an `img`, a comment) are passed over; a word before
    /// the first heading ends the search.
    private static func openingHeadingBounds(of markup: [UInt8], within length: Int) -> (found: Bool, text: Range<Int>?) {
        let start = bodyStart(of: markup)
        let window = start..<min(markup.count, start + length)
        var cursor = start
        var found = false
        var ended = false
        // Where the heading's text begins, the name of the end tag that ends it, and where it ends.
        var textStart = 0
        var endName = ""
        var textEnd: Int?
        MOBIMarkup.forEachTag(in: markup, within: window) { tag in
            guard !ended else { return }
            if !found {
                // Words before the first heading: the document does not open with one.
                if hasWord(markup[cursor..<tag.lowerBound]) { ended = true; return }
                cursor = tag.upperBound
                if let name = tagName(markup, tag), name.count == 2, name.first == "h",
                   let level = name.last?.wholeNumberValue, (1...6).contains(level) {
                    found = true
                    textStart = tag.upperBound
                    endName = "/" + name
                }
            } else if tagName(markup, tag) == endName {
                textEnd = tag.lowerBound
                ended = true
            }
        }
        guard found, let textEnd, textStart <= textEnd else { return (found, nil) }
        return (found, textStart..<textEnd)
    }

    /// How a document's markup begins: whether a heading comes before any word, and whether the first
    /// element is one calibre's cut left (its `id` begins `calibre_pb_`).
    private static func documentOpening(of markup: [UInt8]) -> (hasHeading: Bool, hasSplitMarker: Bool) {
        let start = bodyStart(of: markup)
        let marked = markup[start..<min(markup.count, start + 600)].indices.contains { index in
            markup[index] == UInt8(ascii: "c") && markup[index...].starts(with: Array("calibre_pb_".utf8))
        }
        return (openingHeadingBounds(of: markup, within: 4_096).found, marked)
    }

    /// The text of the heading a document opens with, read as a `<title>` is (`readableLabel`: character
    /// references read, soft hyphens left out, white space collapsed, case kept), so the two compare equal
    /// when they are the same words; nil when the document does not open with a heading, its end tag is not
    /// near, or it holds no letter or digit. Tags inside the heading add no words.
    private static func openingHeading(of markup: [UInt8], encoding: Int) -> String? {
        guard let text = openingHeadingBounds(of: markup, within: 8_192).text else { return nil }
        var words: [UInt8] = []
        var position = text.lowerBound
        MOBIMarkup.forEachTag(in: markup, within: text) { tag in
            words.append(contentsOf: markup[position..<tag.lowerBound])
            position = tag.upperBound
        }
        words.append(contentsOf: markup[position..<text.upperBound])
        let heading = readableLabel(MOBIText.decode(words, encoding: encoding))
        return heading.contains(where: { $0.isLetter || $0.isNumber }) ? heading : nil
    }

    /// A section the document's markup opens with: the first element under the `<body>` when it is a sectioning
    /// element with an `id`, as `<footer id="pg-footer">` and `<header id="pg-header">` are in Project Gutenberg's
    /// books. calibre opens the same element again at the start of the piece it cuts out of the middle of one
    /// (so the license's first piece and its second piece are both in `footer#pg-footer`), which is how two pieces
    /// are known to be halves of one element.
    private struct Container: Equatable {
        var name: String
        var id: String

        /// The elements that hold a section of their own, which a book's markup puts around a chapter, its
        /// header, or its footer.
        static let names: Set<String> = ["header", "footer", "section", "article", "aside", "nav", "main"]

        /// Whether a piece that opens in `piece` (nil when it opens in none) is not the second half of the piece
        /// before it, which opens in `previous`: the piece before opens in a section other than a `footer`, and
        /// this piece opens in no section at all. A piece that opens in another section may still be the second
        /// half of a document of two sections cut inside the second, which calibre and kindlegen open again, so
        /// only a piece in no section is taken for a document of its own (Project Gutenberg's essay, a `div`,
        /// after its header). What follows a footer is matter of the book's end, such as a back cover, and goes
        /// on with it.
        static func endsBefore(_ previous: Container?, piece: Container?) -> Bool {
            guard let previous, previous.name != "footer" else { return false }
            return piece == nil
        }
    }

    /// The most bytes of a document's body looked through for the element it opens with.
    private static let containerSearchLength = 2_048

    /// The section element `markup` opens with (see `Container`), nil when its body opens with words, with
    /// another element, or with a section that has no `id`. Anchors (`<a>` tags, which the reader writes
    /// where the contents names a place, and a book writes where it is linked to) and comments are passed over.
    private static func openingContainer(of markup: [UInt8]) -> Container? {
        let start = bodyStart(of: markup)
        var cursor = start
        var found: Container?
        var decided = false
        MOBIMarkup.forEachTag(in: markup, within: start..<min(markup.count, start + containerSearchLength)) { tag in
            guard !decided else { return }
            // Words before the tag: the document does not open with an element.
            if hasWord(markup[cursor..<max(cursor, tag.lowerBound)]) { decided = true; return }
            cursor = max(cursor, tag.upperBound)
            guard let name = tagName(markup, tag), name != "a", name != "/a" else { return }
            decided = true
            guard Container.names.contains(name), let id = attribute("id", in: markup, tag: tag) else { return }
            found = Container(name: name, id: String(decoding: markup[id.value], as: UTF8.self))
        }
        return found
    }

    /// Where the words of a document begin: after its `<body>` tag, else after its head, else at the start.
    private static func bodyStart(of markup: [UInt8]) -> Int {
        var body: Int?
        var headEnd: Int?
        MOBIMarkup.forEachTag(in: markup, within: 0..<min(markup.count, 16_384)) { tag in
            guard body == nil, let name = tagName(markup, tag) else { return }
            if name == "body" { body = tag.upperBound }
            if name == "/head" { headEnd = tag.upperBound }
        }
        return body ?? headEnd ?? 0
    }

    /// Whether `bytes` hold a letter or digit.
    private static func hasWord(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.contains { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 >= 0x80 }
    }

    /// Whether a document ends in the middle of a paragraph that calibre cut: its last text ends
    /// with a space inside a `</p>`, with only tags after.
    private static func endsMidParagraph(_ markup: [UInt8]) -> Bool {
        let tailStart = max(0, markup.count - 600)
        let closing = Array("</p".utf8)
        guard let end = (tailStart..<markup.count).last(where: { index in
            markup[index] == UInt8(ascii: "<") && markup[index...].prefix(closing.count).elementsEqual(closing, by: { lower($0) == $1 })
        }), end > tailStart else { return false }
        // The text before it ends with a space (or a no-break space).
        let before = markup[end - 1]
        let space = before == 0x20 || before == 0x0A || before == 0x09 || before == 0x0D
            || (end >= 2 && markup[end - 2] == 0xC2 && before == 0xA0)
        guard space else { return false }
        // Only tags and white space follow.
        var inTag = false
        for byte in markup[end...] {
            if byte == UInt8(ascii: "<") { inTag = true } else if byte == UInt8(ascii: ">") { inTag = false } else if !inTag, hasWord(ArraySlice([byte])) {
                return false
            }
        }
        return true
    }

    // MARK: A Document's Title

    /// The longest stretch of a skeleton looked through for its title, which
    /// is in its head, near the start.
    private static let titleSearchLength = 4096

    /// The text of the `<title>` element in the head of `skeleton`, with
    /// character references read and white space collapsed, or nil when it
    /// has none or none that holds a letter or digit.
    private static func rawDocumentTitle(in skeleton: ArraySlice<UInt8>, encoding: Int) -> String? {
        let head = skeleton.prefix(titleSearchLength)
        guard let open = find("<title", in: head, from: head.startIndex),
              let openEnd = head[open...].firstIndex(of: UInt8(ascii: ">")),
              let close = find("</title", in: head, from: openEnd) else { return nil }
        let raw = MOBIText.decode(Array(head[(openEnd + 1)..<close]), encoding: encoding)
        let title = readableLabel(raw)
        return title.contains(where: { $0.isLetter || $0.isNumber }) ? title : nil
    }

    /// A document's title as a chapter's: nil when it repeats the book's title (which names no
    /// chapter in particular) or is "Unknown", which calibre writes for a document whose title is blank.
    private static func displayTitle(of title: String?, differentFrom bookTitle: String) -> String? {
        guard let title, title.lowercased() != "unknown",
              title.caseInsensitiveCompare(bookTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")) != .orderedSame
        else { return nil }
        return title
    }

    /// The index of the first place in `bytes` at or after `start` where the
    /// ASCII `word` is spelled in any letter case and a name ends right after it
    /// (a white space, `/`, or `>`), or nil.
    private static func find(_ word: String, in bytes: ArraySlice<UInt8>, from start: Int) -> Int? {
        let wanted = Array(word.utf8)
        guard bytes.count >= wanted.count else { return nil }
        var position = start
        while position + wanted.count <= bytes.endIndex {
            var matches = true
            for (offset, expected) in wanted.enumerated() where lower(bytes[position + offset]) != expected {
                matches = false
                break
            }
            if matches {
                let after = position + wanted.count
                if after >= bytes.endIndex || bytes[after] == 0x20 || bytes[after] == UInt8(ascii: ">")
                    || bytes[after] == UInt8(ascii: "/") || bytes[after] == 0x0A { return position }
            }
            position += 1
        }
        return nil
    }
}
