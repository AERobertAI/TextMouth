import Foundation
import SwiftSoup

// MARK: - Page Breaks in textutil's Documents

/// Finds the page breaks of a document textutil read (PG11, fixing B13) and
/// writes them into the HTML textutil wrote for it.
///
/// textutil's HTML keeps no page break, and joins the words on either side of
/// one ("runs on andcontinues here"). Its plain text (`-convert txt`) keeps
/// each break as a form feed (U+000C) at exactly its place. So the plain text
/// is read a second time, and each form feed is put into the HTML as an empty
/// `<span role="doc-pagebreak" aria-label="N">`, which `HTMLToMarkdownConverter`
/// writes as a page marker (PG05) and never reads aloud.
///
/// The two texts are lined up by their **letters and digits**: the same
/// words in both, whatever each does with white space, punctuation, bullets,
/// and pictures. A form feed that follows the n-th letter or digit of the
/// plain text begins its page right before the n-th letter or digit of the
/// HTML's text. Because a wrong count would put a page in the wrong place and
/// every saved place after it would be wrong with it, each break is checked:
/// the 16 letters and digits on each side must be the same in both texts, or
/// the break is dropped (`Outcome.unaligned`) and never placed wrongly.
///
/// Everything here is pure apart from the `Document` it changes, so tests
/// drive it with strings.
enum TextutilPageBreaks {

    // MARK: Constants

    /// The form feed that textutil's plain text writes at each page break.
    static let formFeed: Unicode.Scalar = "\u{000C}"

    /// How many letters and digits on each side of a break the two texts must
    /// agree on (fewer at a document's ends).
    static let contextLength = 16

    /// The most page breaks one document may hold: the limit every page
    /// reader shares (`MarkdownPageMarker.maximumPagesPerBook`). A document
    /// with more is taken as hostile (a plain text that is almost all form
    /// feeds would otherwise cost one insertion each), and is read without
    /// pages.
    static let maximumPages = MarkdownPageMarker.maximumPagesPerBook

    /// The value of the `role` attribute of the element that stands for a page
    /// break; the converter's page-break test (`PublicationSemantics.isPageBreak`).
    static let pageBreakRole = "doc-pagebreak"

    // MARK: Letters and Digits

    /// Whether `scalar` is counted when the two texts are lined up: a letter
    /// or a number. This is `Character.isLetter || Character.isNumber`
    /// applied to scalars, so a combining mark (which `Character` would fold
    /// into its letter) never counts, and a page can never begin between a
    /// letter and its mark.
    static func isCounted(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return scalar.properties.numericType != nil
        }
    }

    // MARK: Context

    /// The letters and digits on each side of one place in a text.
    struct Context: Equatable {
        /// The (at most `contextLength`) counted scalars before the place,
        /// the nearest last.
        var before: [Unicode.Scalar] = []
        /// The (at most `contextLength`) counted scalars from the place on.
        var after: [Unicode.Scalar] = []
    }

    /// Reads a text's counted scalars in order and keeps the context of the
    /// places marked on the way, in memory proportional to the places, never
    /// to the text. The plain text marks each form feed; the HTML marks each
    /// place the plain text wants.
    struct ContextCollector {
        /// How many counted scalars have been fed.
        private(set) var count = 0
        /// The most recent `contextLength` counted scalars.
        private var recent: [Unicode.Scalar] = []
        /// The context of each place marked, in the order marked.
        private(set) var contexts: [Context] = []
        /// The first context still short of its `after` scalars. Contexts
        /// are marked in order and each wants the same number, so the ones
        /// still collecting are always the contexts from here on.
        private var firstIncomplete = 0

        /// Whether every marked context has all its `after` scalars.
        var isComplete: Bool { firstIncomplete == contexts.count }

        /// Marks the place just before the next counted scalar, and returns
        /// the index of its context.
        @discardableResult
        mutating func mark() -> Int {
            contexts.append(Context(before: recent, after: []))
            return contexts.count - 1
        }

        /// Feeds the next counted scalar.
        mutating func feed(_ scalar: Unicode.Scalar) {
            // The scalar follows every place still collecting.
            for index in firstIncomplete..<contexts.count {
                contexts[index].after.append(scalar)
            }
            while firstIncomplete < contexts.count, contexts[firstIncomplete].after.count >= contextLength {
                firstIncomplete += 1
            }
            recent.append(scalar)
            if recent.count > contextLength { recent.removeFirst() }
            count += 1
        }
    }

    // MARK: The Plain Text

    /// One form feed of the plain text.
    struct PlainBreak: Equatable {
        /// The number of the page the form feed begins: 2 for the first
        /// form feed (page 1 begins at the document's start).
        var page: Int
        /// How many letters and digits come before the form feed.
        var lettersBefore: Int
        /// The letters and digits on each side of it.
        var context: Context
    }

    /// The form feeds of `text`, in order, each with its context; nil when
    /// there are more than `maximumPages` of them. Also the count of letters
    /// and digits in all, so a caller can tell a document with no text.
    static func formFeeds(in text: String) -> (breaks: [PlainBreak], letters: Int)? {
        var collector = ContextCollector()
        // The collector's context index of each form feed and its count.
        var marks: [(context: Int, lettersBefore: Int)] = []
        for scalar in text.unicodeScalars {
            if scalar == formFeed {
                guard marks.count < maximumPages - 1 else { return nil }
                marks.append((collector.mark(), collector.count))
            } else if isCounted(scalar) {
                collector.feed(scalar)
            }
        }
        let breaks = marks.enumerated().map { number, mark in
            PlainBreak(page: number + 2, lettersBefore: mark.lettersBefore, context: collector.contexts[mark.context])
        }
        return (breaks, collector.count)
    }

    // MARK: The HTML

    /// Where in the HTML a page begins: right before one scalar of one text node.
    private struct Place {
        var node: TextNode
        /// How many Unicode scalars of the node's text come before the place.
        var scalarOffset: Int
    }

    /// What the HTML's walk found for the places asked for.
    private struct Found {
        /// The place of each wanted count, by count; a count the HTML never
        /// reaches has none.
        var places: [Int: Place] = [:]
        /// The context at each wanted count, by count.
        var contexts: [Int: Context] = [:]
    }

    /// Whether the walk skips `element` and everything in it: exactly what
    /// the converter reads nothing of (`script`, `style`, and what
    /// `PublicationSemantics.isExcludedFromReadingFlow` leaves out).
    private static func isSkipped(_ element: Element) -> Bool {
        let tag = element.tagName().lowercased()
        return tag == "script" || tag == "style" || PublicationSemantics.isExcludedFromReadingFlow(element)
    }

    /// Walks the text nodes of `root` in document order, as the converter
    /// reads them, counting letters and digits, and finds the place and the
    /// context at each of `wanted` (ascending counts). Stops once every
    /// wanted place has its full context.
    private static func walk(_ root: Node, wanted: [Int]) -> Found {
        var found = Found()
        var collector = ContextCollector()
        // The collector's context index of each wanted count.
        var contextIndexes: [Int: Int] = [:]
        var nextWanted = 0
        // An explicit stack, so a deeply nested document cannot exhaust the call stack.
        var pending: [Node] = [root]
        while let node = pending.popLast() {
            if let element = node as? Element, isSkipped(element) { continue }
            guard let textNode = node as? TextNode else {
                pending.append(contentsOf: node.getChildNodes().reversed())
                continue
            }
            var scalarOffset = 0
            for scalar in textNode.getWholeText().unicodeScalars {
                defer { scalarOffset += 1 }
                guard isCounted(scalar) else { continue }
                // Every wanted count reached here begins at this scalar.
                while nextWanted < wanted.count, wanted[nextWanted] == collector.count {
                    contextIndexes[wanted[nextWanted]] = collector.mark()
                    found.places[wanted[nextWanted]] = Place(node: textNode, scalarOffset: scalarOffset)
                    nextWanted += 1
                }
                collector.feed(scalar)
            }
            if nextWanted == wanted.count, collector.isComplete { break }
        }
        // A wanted count the HTML never reaches (its text has fewer letters
        // and digits) was never marked, so it has neither place nor context,
        // and its break will be dropped.
        for (count, index) in contextIndexes {
            found.contexts[count] = collector.contexts[index]
        }
        return found
    }

    // MARK: Putting the Pages In

    /// What `insertPageBreaks(fromPlainText:into:)` did.
    struct Outcome: Equatable {
        /// The pages written into the document, by page number, in order.
        /// Page 1 is always among them when there are any.
        var placed: [Int] = []
        /// The pages whose break was dropped because the two texts did not
        /// agree around it (`TextutilPageBreaks`), in order.
        var unaligned: [Int] = []
    }

    /// Writes the page breaks of the plain text `plainText` into `document`
    /// (textutil's HTML, after its pictures are removed and before its field
    /// instructions are: both texts hold those as bare text, ST10) as empty
    /// `<span role="doc-pagebreak" aria-label="N">` elements: page 1 at the
    /// start of the body, and each later page right before its first letter
    /// or digit. Where textutil joined the words on either side of a break,
    /// one space goes in too, so the words stay apart (B13).
    ///
    /// Writes nothing when the plain text holds no letter or digit, or has
    /// more than `maximumPages` breaks.
    @discardableResult
    static func insertPageBreaks(fromPlainText plainText: String, into document: Document) throws -> Outcome {
        guard let plain = formFeeds(in: plainText), plain.letters > 0 else { return Outcome() }

        // A break with no letter or digit after it ends a page that holds no
        // words (a blank last page): there is nothing to place it before.
        let candidates = plain.breaks.filter { !$0.context.after.isEmpty }
        let wanted = Array(Set(candidates.map(\.lettersBefore))).sortedStably()
        let body: Element = document.body() ?? document
        let found = walk(body, wanted: wanted)

        var outcome = Outcome()
        // The places to write, by node, then by offset in the node, with the
        // pages that begin there in order.
        var pagesAt: [ObjectIdentifier: (node: TextNode, offsets: [Int: [Int]])] = [:]
        for candidate in candidates {
            guard let place = found.places[candidate.lettersBefore],
                  found.contexts[candidate.lettersBefore] == candidate.context else {
                outcome.unaligned.append(candidate.page)
                continue
            }
            let key = ObjectIdentifier(place.node)
            var entry = pagesAt[key] ?? (place.node, [:])
            entry.offsets[place.scalarOffset, default: []].append(candidate.page)
            pagesAt[key] = entry
            outcome.placed.append(candidate.page)
        }

        // Page 1 begins at the start of the body.
        try body.prependChild(pageBreakElement(page: 1))
        outcome.placed.insert(1, at: 0)
        for entry in pagesAt.values {
            try insert(pagesAtOffset: entry.offsets, into: entry.node)
        }
        return outcome
    }

    /// An empty element standing for the break that begins page `page`.
    private static func pageBreakElement(page: Int) throws -> Element {
        let element = try Element(Tag.valueOf("span"), "")
        try element.attr("role", pageBreakRole)
        try element.attr("aria-label", String(page))
        return element
    }

    /// Splits `node` at each offset of `pagesAtOffset` (in Unicode scalars)
    /// and puts the spans of the pages that begin there between the pieces,
    /// in page order. The node keeps the text before the first break (which
    /// is nothing when the break is at its start) and the rest follows it as
    /// new siblings. A break that comes with no white space before it in the
    /// node gets one space first, so the words textutil joined are apart
    /// again (B13); a break at the start of a node gets none, as the node
    /// before it ends a block or an inline run of its own.
    private static func insert(pagesAtOffset: [Int: [Int]], into node: TextNode) throws {
        let scalars = Array(node.getWholeText().unicodeScalars)
        // Offsets past the text cannot happen (the walk read this text), but
        // are dropped rather than trusted.
        let offsets = pagesAtOffset.keys.filter { $0 < scalars.count }.sortedStably()
        guard let first = offsets.first else { return }

        // The nodes that follow the original, in order.
        var following: [Node] = []
        for (position, offset) in offsets.enumerated() {
            if offset > 0, !scalars[offset - 1].properties.isWhitespace {
                following.append(TextNode(" ", nil))
            }
            for page in pagesAtOffset[offset] ?? [] {
                following.append(try pageBreakElement(page: page))
            }
            // The text from this break to the next, or to the end.
            let end = position + 1 < offsets.count ? offsets[position + 1] : scalars.count
            following.append(TextNode(String(String.UnicodeScalarView(scalars[offset..<end])), nil))
        }

        node.text(String(String.UnicodeScalarView(scalars[0..<first])))
        var last: Node = node
        for next in following {
            try last.after(next)
            last = next
        }
    }

    // MARK: Log Lines

    /// The line logged for a document whose plain-text run failed or was
    /// stopped (`why` in words); the document is read without pages.
    static func failedLogLine(fileName: String, why: String) -> String {
        "TEXTUTIL_PAGES_FAILED: \(fileName): \(why)"
    }

    /// The line logged for a page break dropped because the plain text and
    /// the HTML did not agree around it.
    static func unalignedLogLine(fileName: String, page: Int) -> String {
        "TEXTUTIL_PAGE_UNALIGNED: \(fileName): page \(page)"
    }
}
