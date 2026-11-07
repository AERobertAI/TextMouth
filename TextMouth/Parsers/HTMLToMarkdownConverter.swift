import Foundation
import SwiftSoup

/// Which elements of one HTML document begin the book's pages (PG05).
struct HTMLPageTargets {
    /// The pages a book's page list names in this document, by the id of the
    /// element each begins at (or the name of a legacy `a` element), looked up
    /// as heading targets are. The page list is the publisher's own, so its
    /// labels are used and the document's page-break elements are not.
    var markers: [String: MarkdownPageMarker]

    /// The labels of `markers` as the page list spelled them, by the same
    /// ids, before normalization took a leading "Page" off them
    /// (`MarkdownPageMarker`): an element's own text that is no more than
    /// either form is not read (ST02), so "Page 12" under the list's "Page
    /// 12" stays unread as it always was. An id whose entry gave no label of
    /// its own, and so has its ordinal, is not here.
    var sourceLabels: [String: String]

    /// Whether each page-break element is itself a page: true for standalone
    /// HTML and for a book without a page list, false once a page list names
    /// the book's pages (its page-break elements the list does not name are
    /// then not pages). A page-break element's own text is skipped, either way,
    /// only when it is no more than its page's own label (its number, or that
    /// number's twin in the other numbering); any other text is real words and
    /// is read (ST02, `MarkdownPageMarker.isNoMoreThanLabel`).
    var pageBreaksArePages: Bool

    /// Targets naming no page, with every page-break element a page.
    init(
        markers: [String: MarkdownPageMarker] = [:],
        sourceLabels: [String: String] = [:],
        pageBreaksArePages: Bool = true
    ) {
        self.markers = markers
        self.sourceLabels = sourceLabels
        self.pageBreaksArePages = pageBreaksArePages
    }
}

/// Converts HTML content to Markdown format.
/// Used during import to create cached Markdown representations of EPUB chapters and HTML files.
enum HTMLToMarkdownConverter {

    /// Convert an HTML string to Markdown, preserving headings, emphasis, links, and lists.
    /// `pages` says which elements begin the book's pages (see `HTMLPageTargets`);
    /// it is used only while `includesPages` is true.
    static func convert(
        _ html: String,
        stripDuplicateNavigation: Bool = false,
        headingTargets: [String: MarkdownHeadingAnnotation] = [:],
        pages: HTMLPageTargets = HTMLPageTargets(),
        includesPages: Bool = true
    ) throws -> String {
        try convert(
            document: SwiftSoup.parse(html),
            readingFlow: PublicationSemantics.ReadingFlow(source: html),
            stripDuplicateNavigation: stripDuplicateNavigation,
            headingTargets: headingTargets,
            pages: pages,
            includesPages: includesPages
        )
    }

    /// Convert `document`, already parsed from markup whose reading-flow
    /// rules are `readingFlow`, exactly as `convert(_:stripDuplicateNavigation:headingTargets:pages:includesPages:)`
    /// converts that markup, so a reader that has parsed a document for
    /// other reasons need not parse it again. Removing duplicate navigation
    /// changes `document`.
    static func convert(
        document: Document,
        readingFlow: PublicationSemantics.ReadingFlow,
        stripDuplicateNavigation: Bool = false,
        headingTargets: [String: MarkdownHeadingAnnotation] = [:],
        pages: HTMLPageTargets = HTMLPageTargets(),
        includesPages: Bool = true
    ) throws -> String {
        let body = document.body() ?? document
        if stripDuplicateNavigation {
            try removeDuplicateNavigation(from: body, readingFlow: readingFlow)
        }

        var result = ""
        convertNode(
            body, into: &result,
            context: Context(headingTargets: headingTargets, readingFlow: readingFlow, pages: pages, includesPages: includesPages)
        )
        return result.trimmingCharacters(in: writtenWhitespace)
    }

    /// Match EPUBParser's nav stripping: remove nav/TOC text only when the
    /// chapter has real heading elements outside nav, so nav-only headings
    /// remain available for sparse documents. `readingFlow` holds the rules
    /// of the document `body` belongs to, when its markup is known.
    static func removeDuplicateNavigation(
        from body: Element,
        readingFlow: PublicationSemantics.ReadingFlow = .unknownSource
    ) throws {
        var allHeadingCount = 0
        var navHeadingCount = 0
        var navigationElements: [Element] = []
        collectNavigationDetails(
            from: body,
            insideNavigation: false,
            readingFlow: readingFlow,
            allHeadingCount: &allHeadingCount,
            navHeadingCount: &navHeadingCount,
            navigationElements: &navigationElements
        )
        if allHeadingCount > navHeadingCount {
            for navigation in navigationElements {
                try navigation.remove()
            }
        }
    }

    /// Avoid SwiftSoup's selector-result cache for one-shot conversion walks.
    /// Cached `Elements` strongly reference their root and form a cycle for
    /// every parsed EPUB chapter, which is catastrophic during library-wide
    /// migrations. A direct DOM walk is both sufficient and leak-free here.
    private static func collectNavigationDetails(
        from node: Node,
        insideNavigation: Bool,
        readingFlow: PublicationSemantics.ReadingFlow,
        allHeadingCount: inout Int,
        navHeadingCount: inout Int,
        navigationElements: inout [Element]
    ) {
        for child in node.getChildNodes() {
            // Hidden content, page lists, and landmarks are never converted,
            // so they neither count as headings nor need removing as navigation.
            guard let element = child as? Element,
                  !readingFlow.excludes(element) else { continue }
            let tag = element.tagName().lowercased()
            let isNavigation = insideNavigation || tag == "nav"
            if tag == "nav" {
                navigationElements.append(element)
            }
            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                allHeadingCount += 1
                if isNavigation {
                    navHeadingCount += 1
                }
            default:
                break
            }
            collectNavigationDetails(
                from: element,
                insideNavigation: isNavigation,
                readingFlow: readingFlow,
                allHeadingCount: &allHeadingCount,
                navHeadingCount: &navHeadingCount,
                navigationElements: &navigationElements
            )
        }
    }

    // MARK: - Node Conversion

    /// The page ids a conversion has written a marker for, shared by every
    /// copy of the `Context` of one conversion (PG05): an id that two
    /// elements carry names a page once, at the first.
    private final class WrittenPageIDs {
        var ids: Set<String> = []
    }

    /// Where the page markers that end one Markdown buffer begin, remembered
    /// between questions (`beforeTrailingPageMarkers(of:context:)`): asking
    /// walked back over every marker of the run each time, so a book of N
    /// empty page anchors in a row took N squared steps (5,000 took 24 s).
    /// There is one for each buffer the conversion writes (the result, a
    /// quote's lines, a list item's content, the content between items),
    /// shared by the copies of the `Context` that write into it, and it holds
    /// only what a buffer of its own length would give: it is used only while
    /// the buffer's length is the one it was made for, and every writer of the
    /// buffer that is not one of its two updaters (`emit`, `dropSpace…`) changes
    /// the length, which forgets it.
    private final class TrailingMarkers {
        /// The buffer's length in UTF-8 bytes when this was made; -1 when it
        /// holds nothing.
        var length = -1
        /// The UTF-8 offset at which the markers that end the buffer begin
        /// (the length itself when none does).
        var start = 0
    }

    /// What conversion knows about the position of the node it converts.
    private struct Context {
        /// TOC destinations, keyed by the id (or legacy anchor name) marking them.
        var headingTargets: [String: MarkdownHeadingAnnotation]
        /// Which elements of the document are outside its reading flow.
        var readingFlow: PublicationSemantics.ReadingFlow
        /// Which elements of the document begin pages (PG05).
        var pages: HTMLPageTargets
        /// Whether page markers are written (PG05); false converts as cache
        /// format 3.0.7 did: no marker, and a page-break element's text is read.
        /// True skips a page-break element's text only when it is no more than
        /// its page's label (ST02).
        var includesPages: Bool
        /// The ids whose pages are written already (PG05).
        let writtenPageIDs = WrittenPageIDs()
        /// Where the page markers that end the buffer being written begin; a
        /// buffer of its own has a `TrailingMarkers` of its own.
        var trailing = TrailingMarkers()
        /// Inside a link. Markdown cannot nest links, so a link here keeps
        /// only its words.
        var insideLink = false
        /// Inside emphasis, whose words are marked once, by the outermost.
        var insideEmphasis = false

        /// Whether any page marker may be written: pages are included and the
        /// document names a page or can hold a page-break element (PG05).
        var mayHoldPages: Bool {
            includesPages && (!pages.markers.isEmpty || readingFlow.mayHoldPageBreaks)
        }
    }

    /// Recursively walk the DOM tree and emit Markdown for each element.
    private static func convertNode(_ node: Node, into result: inout String, context: Context) {
        for child in node.getChildNodes() {
            convertChild(child, into: &result, context: context)
        }
    }

    /// Convert one child node: text as Markdown literals, an element as its
    /// Markdown. Comments and the data of scripts and styles write nothing.
    private static func convertChild(_ child: Node, into result: inout String, context: Context) {
        if let textNode = child as? TextNode {
            appendText(textNode.getWholeText(), to: &result, context: context)
        } else if let element = child as? Element {
            convertElement(element, into: &result, context: context)
        }
    }

    /// Convert a single HTML element to its Markdown equivalent.
    private static func convertElement(_ element: Element, into result: inout String, context: Context) {
        let tag = element.tagName().lowercased()
        // Non-content elements are ignored without running selector queries.
        // Content outside the rendered reading flow (the hidden attribute, page
        // lists, and landmarks) contributes no words, headings, or destinations.
        guard tag != "script", tag != "style",
              !context.readingFlow.excludes(element) else { return }

        // Keep the element's words apart from its neighbors' exactly where the
        // direct reader does (HTMLReadingBoundary): a block is a paragraph of
        // its own, and a table cell, ins, del, or s is at least a word of its
        // own. A line break is its own boundary, the hard break it writes.
        let boundary: HTMLReadingBoundary = tag == "br" ? .none : .of(element, tag: tag)
        separate(at: boundary, in: &result, context: context)

        // Preserve a TOC target, and the page an element begins (PG05), in the
        // Markdown stream at its actual DOM position. Inline targets stay
        // inline; block targets precede their block. A marker never
        // contributes words to speech.
        let isBreak = isPageBreakElement(element, context: context)
        // The page is computed once: a page the page list names is recorded as
        // written by the lookup, so a second lookup would lose it.
        let page = pageMarker(for: element, tag: tag, isPageBreak: isBreak, context: context)
        for marker in destinationMarkers(for: element, tag: tag, page: page, context: context) {
            emit(marker, inline: boundary != .paragraph, into: &result, context: context)
        }
        // A page-break element's own text that is no more than its page's
        // own label (the page's number, or its twin in the other numbering),
        // named or not, is not read, so its children are not converted. Any
        // other text is real words and is converted like any element's (ST02).
        if isBreak && !readsOwnText(ofPageBreak: element, page: page) {
            separate(at: boundary, in: &result, context: context)
            return
        }

        switch tag {
        // Headings
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = HTMLReadingText.headingLevel(of: tag) ?? 1
            // A destination inside a heading (such as an anchor before its
            // words) names that heading. Emit it as its own block immediately
            // before the heading line, never inside the label: the Markdown
            // parser gives both the same offset and keeps the visible heading,
            // and a heading without visible text still keeps its destination.
            // A page that begins inside the heading is written there too.
            let enclosed = destinationMarkers(inside: element, context: context)
            for marker in enclosed.markers {
                emit(marker, inline: false, into: &result, context: context)
            }
            // The heading line holds the label the direct reader gives it,
            // as literal text: one line even when the heading contains a line
            // break or a block, and no link, emphasis, or code syntax, whose
            // markers the parser would otherwise have to keep out of the label.
            // A page-break element inside the heading whose text is only its
            // page's number keeps that number out of the label, as it keeps it
            // out of the body text: "Part <page 9>Two" is the heading "Part
            // Two", and the page is the marker written above.
            let label = HTMLReadingText.label(of: element, leavingOut: enclosed.unreadPageBreaks)
            result += String(repeating: "#", count: level) + " " + MarkdownLiteral.escaped(label) + "\n\n"

        // Line breaks
        case "br":
            dropSpaceBeforeTrailingPageMarkers(in: &result, context: context)
            result += "  \n"

        // Emphasis and strong emphasis. Only the outermost is marked: emphasis
        // inside emphasis adds nothing a listener hears, and nested or
        // touching delimiter runs are where CommonMark stops matching pairs.
        case "em", "i", "strong", "b":
            var inner = context
            inner.insideEmphasis = true
            let start = result.utf8.count
            convertNode(element, into: &result, context: inner)
            if !context.insideEmphasis {
                emphasize(from: start, in: &result, delimiter: tag == "em" || tag == "i" ? "*" : "**")
            }

        // Links
        case "a":
            let href = (try? element.attr("href")) ?? ""
            if href.isEmpty || context.insideLink {
                // A named anchor such as <a id="page_12"/> marks a destination;
                // it is not a link. Markdown would keep bare brackets as literal
                // text in speech and in heading labels ("[]2"), so emit only
                // whatever the anchor encloses. A link inside a link, which
                // Markdown cannot nest, likewise keeps only its words.
                convertNode(element, into: &result, context: context)
            } else {
                var inner = context
                inner.insideLink = true
                let start = result.utf8.count
                convertNode(element, into: &result, context: inner)
                wrap(from: start, in: &result, opener: "[", closer: "](" + destination(href) + ")")
            }

        // Images — emit alt text for accessibility, read like any other text.
        // Whitespace at the ends of the alt text is read around the image, as
        // the direct reader reads it, rather than inside the brackets.
        case "img":
            let alt = HTMLReadingText.collapsingWhitespace((try? element.attr("alt")) ?? "")
            let src = (try? element.attr("src")) ?? ""
            appendSpaced(alt, to: &result, context: context) { core, _ in
                "![" + MarkdownLiteral.escaped(core) + "](" + destination(src) + ")"
            }

        // Lists
        case "ul", "ol":
            convertListItems(element, ordered: tag == "ol", into: &result, context: context)

        // Blockquotes
        case "blockquote":
            var inner = ""
            var quoted = context
            quoted.trailing = TrailingMarkers()
            convertNode(element, into: &inner, context: quoted)
            // Prefix each line with >
            let lines = inner.trimmingCharacters(in: writtenWhitespace)
                .components(separatedBy: "\n")
            for line in lines {
                result += "> \(line)\n"
            }

        // Preformatted text becomes a fenced code block holding its lines
        // exactly, which the reader reads verbatim. The fence is longer than
        // any run of backticks inside, so no line of the text can close it,
        // and it always stands on a line of its own. Destinations inside the
        // block precede it rather than becoming words of the code.
        case "pre":
            for marker in destinationMarkers(inside: element, context: context).markers {
                emit(marker, inline: false, into: &result, context: context)
            }
            let code = HTMLReadingText.preformattedText(of: element)
            // Whitespace alone holds nothing to read.
            guard code.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { break }
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
            let lineEnd = code.unicodeScalars.last == "\n" ? "" : "\n"
            result += fence + "\n" + code + lineEnd + fence + "\n"

        // Inline code. A code span is read verbatim, so destinations inside
        // it precede it rather than becoming words of the code.
        case "code":
            for marker in destinationMarkers(inside: element, context: context).markers {
                emit(marker, inline: true, into: &result, context: context)
            }
            appendSpaced(HTMLReadingText.inlineText(of: element), to: &result, context: context, codeSpan(_:after:))

        // Horizontal rules
        case "hr":
            result += "---\n\n"

        // Paragraphs, containers, and table and definition list parts, whose
        // boundaries were written above, and phrasing or unknown elements:
        // their children say what they hold. A table row is therefore one
        // paragraph of its cells, each a word or more of its own.
        default:
            convertNode(element, into: &result, context: context)
        }

        separate(at: boundary, in: &result, context: context)
    }

    // MARK: - Navigation Annotations

    /// Write a destination (a heading annotation or a page marker, as
    /// Markdown) without changing the words around it; see
    /// `MarkdownMarkerWriter.write`, which places every marker alike. The
    /// conversion writes a list item's or quote's content apart from its
    /// opening and indents each of its lines itself, so a marker is placed by
    /// indentation alone (`continuationAtMargin`), which keeps the heading
    /// annotations exactly where cache format 3.0.7 wrote them.
    private static func emit(_ marker: String, inline: Bool, into result: inout String, context: Context) {
        let trailing = context.trailing
        let before = result.utf8.count
        let wasKnown = trailing.length == before
        let startedAt = trailing.start
        MarkdownMarkerWriter.write(marker, inline: inline, continuationAtMargin: true, into: &result)
        // A page marker written at the end of the buffer, with nothing else
        // added or moved (the length grew by the marker's own), extends the
        // run of markers that ends it, or begins one where the buffer ended.
        let grown = result.utf8.count - before
        if wasKnown, grown == marker.utf8.count, result.hasSuffix(marker), MarkdownPageMarker.decode(marker) != nil {
            trailing.length = result.utf8.count
            trailing.start = startedAt
        } else {
            trailing.length = -1
        }
    }

    /// The TOC destination an element carries through its id, or through the
    /// name of a legacy anchor.
    private static func headingAnnotation(
        for element: Element,
        tag: String,
        headingTargets: [String: MarkdownHeadingAnnotation]
    ) -> MarkdownHeadingAnnotation? {
        // Most chapters have no fragment destinations. Avoid attribute lookups
        // at every node when there is no possible navigation match.
        guard !headingTargets.isEmpty, tag != "script", tag != "style" else { return nil }
        let id = (try? element.attr("id")) ?? ""
        let legacyName = tag == "a" ? ((try? element.attr("name")) ?? "") : ""
        return headingTargets[id] ?? headingTargets[legacyName]
    }

    /// The Markdown of the destinations `element` itself carries (PG05): the
    /// page it begins, then its TOC annotation, so an element that is both
    /// gets the page marker first. `page` is the page `element` begins, from
    /// `pageMarker`, which the caller computes once because looking up a page
    /// the page list names records it as written.
    private static func destinationMarkers(
        for element: Element,
        tag: String,
        page: PageStart?,
        context: Context
    ) -> [String] {
        var markers: [String] = []
        if let page {
            markers.append(page.marker.markdown)
        }
        if let annotation = headingAnnotation(for: element, tag: tag, headingTargets: context.headingTargets) {
            markers.append(annotation.markdown)
        }
        return markers
    }

    /// What a heading, `pre`, or `code` element holds besides its words: the
    /// destinations its descendants carry, and the page-break elements among
    /// them whose text is not read.
    private struct EnclosedDestinations {
        /// The Markdown of the destinations, in document order, which are
        /// written before the element instead of inside it.
        var markers: [String] = []
        /// The descendant page-break elements whose text conversion does not
        /// read (`readsOwnText`), which are no more than their markers: a
        /// reading of the element's words leaves them out, as the body text's
        /// does.
        var unreadPageBreaks: [Element] = []
    }

    /// Destinations carried by the descendants of a heading, `pre`, or `code`,
    /// in document order, where they are written before that element instead
    /// of inside it. Content outside the reading flow is skipped exactly as
    /// conversion skips it, and so are the children of a page-break element
    /// whose text conversion does not read (`readsOwnText`), which are
    /// returned so the element's own words can leave them out. Each page-break
    /// element is looked at once, here: looking up a page the page list names
    /// records it as written (`pageMarker`), so a second lookup would find none.
    private static func destinationMarkers(inside container: Element, context: Context) -> EnclosedDestinations {
        var enclosed = EnclosedDestinations()
        guard !context.headingTargets.isEmpty || context.mayHoldPages else { return enclosed }
        for child in container.getChildNodes() {
            guard let element = child as? Element,
                  !context.readingFlow.excludes(element) else { continue }
            let tag = element.tagName().lowercased()
            guard tag != "script", tag != "style" else { continue }
            let isBreak = isPageBreakElement(element, context: context)
            let page = pageMarker(for: element, tag: tag, isPageBreak: isBreak, context: context)
            enclosed.markers += destinationMarkers(for: element, tag: tag, page: page, context: context)
            if !isBreak || readsOwnText(ofPageBreak: element, page: page) {
                let inner = destinationMarkers(inside: element, context: context)
                enclosed.markers += inner.markers
                enclosed.unreadPageBreaks += inner.unreadPageBreaks
            } else {
                enclosed.unreadPageBreaks.append(element)
            }
        }
        return enclosed
    }

    // MARK: - Pages

    /// Whether `element` is a page-break element whose number is not read
    /// (PG05): only while pages are included, and only in a document whose
    /// markup can hold one (an attribute scan costs every element, so a
    /// document that never spells "pagebreak" skips it). Its text is still read
    /// when it is anything but the page's own label (`readsOwnText`).
    private static func isPageBreakElement(_ element: Element, context: Context) -> Bool {
        context.includesPages && context.readingFlow.mayHoldPageBreaks && PublicationSemantics.isPageBreak(element)
    }

    /// Whether the text of the page-break element `element` is real words, to
    /// be read like any element's (ST02): true when it is anything but its
    /// page's own label (`MarkdownPageMarker.isNoMoreThanLabel`), such as a
    /// heading "IV" or a word "Mix" under the page "5". The label is that of
    /// `page` (the page the element begins), in either of its forms: as
    /// normalized ("12") and as its source spelled it ("Page 12"), so text
    /// that is either is not read. Without a page it is the element's
    /// `aria-label` or `title`, else empty, which any text up to
    /// `maximumLabelLength` Characters is no more than. Conversion and
    /// `destinationMarkers(inside:context:)` both ask this, so they agree.
    private static func readsOwnText(ofPageBreak element: Element, page: PageStart?) -> Bool {
        let text = HTMLReadingText.inlineText(of: element)
        guard let page else {
            return !MarkdownPageMarker.isNoMoreThanLabel(text, label: attributeText(of: element) ?? "")
        }
        return !MarkdownPageMarker.isNoMoreThanLabel(text, label: page.marker.label)
            && !MarkdownPageMarker.isNoMoreThanLabel(text, label: page.sourceLabel)
    }

    /// A page an element begins (PG05): its marker, and its label as the
    /// source spelled it, which `readsOwnText` compares the element's text
    /// with besides the marker's own.
    private struct PageStart {
        /// The page's marker, whose label is normalized: a leading "Page"
        /// is taken off it ("Page 12" is the page "12").
        let marker: MarkdownPageMarker
        /// The label as the page list, the element's attribute, or its text
        /// gave it ("Page 12"); the marker's own label when the source gave
        /// none or a blank one, so the comparison never takes an empty label,
        /// which any short text would be no more than.
        let sourceLabel: String

        /// The page `marker` names, which its source called `sourceLabel`.
        init(marker: MarkdownPageMarker, sourceLabel: String?) {
            self.marker = marker
            if let sourceLabel, sourceLabel.contains(where: { !$0.isWhitespace }) {
                self.sourceLabel = sourceLabel
            } else {
                self.sourceLabel = marker.label
            }
        }

        /// The page a source labelled `label` (never blank here, so the
        /// ordinal is never used).
        init(label: String) {
            self.init(marker: MarkdownPageMarker(label: label, ordinal: 0), sourceLabel: label)
        }
    }

    /// The attributes a page-break element names its page in, in the order
    /// they are asked.
    private static let pageLabelAttributes = ["aria-label", "title"]

    /// The first of an element's `aria-label` and `title` that is not blank,
    /// or nil when it has neither. This is what `readsOwnText` compares the
    /// element's text with when it begins no page, so its words are read
    /// whenever they are more than these attributes say.
    private static func attributeText(of element: Element) -> String? {
        for name in pageLabelAttributes {
            let value = (try? element.attr(name)) ?? ""
            if value.contains(where: { !$0.isWhitespace }) { return value }
        }
        return nil
    }

    /// The first of an element's `aria-label` and `title` that names a page,
    /// or nil when neither does. A blank one, or one that is only the word
    /// "Page" (`MarkdownPageMarker.namesNoPage`), names none: a generator
    /// that has no number for a page writes `aria-label="Page "`, and the
    /// element's `title` is then asked.
    private static func attributeLabel(of element: Element) -> String? {
        for name in pageLabelAttributes {
            let value = (try? element.attr(name)) ?? ""
            if !MarkdownPageMarker.namesNoPage(value) { return value }
        }
        return nil
    }

    /// The page `element` begins, or nil (PG05). A page the book's page list
    /// names at this element's id is that page, written once however many
    /// elements share the id. Otherwise a page-break element is a page of its
    /// own when the book has no page list, labelled by its `aria-label`, its
    /// `title`, or its text, and is no page when it has no label at all (a
    /// label that is only the word "Page" is none,
    /// `MarkdownPageMarker.namesNoPage`). Its
    /// text is a label only when it could be one (not longer than
    /// `maximumLabelLength`): a page-break element holding a paragraph begins
    /// no page, so the paragraph's first words are not read out by Go to Page.
    private static func pageMarker(
        for element: Element,
        tag: String,
        isPageBreak: Bool,
        context: Context
    ) -> PageStart? {
        guard context.includesPages else { return nil }
        if let named = namedPageMarker(for: element, tag: tag, context: context) {
            return named
        }
        guard isPageBreak, context.pages.pageBreaksArePages else { return nil }
        // Every label here names a page, so no marker takes its ordinal.
        if let label = attributeLabel(of: element) {
            return PageStart(label: label)
        }
        let text = HTMLReadingText.inlineText(of: element)
        // An element whose attributes say "Page" and give no number names
        // its page by its text only when the text is a page number. Words
        // beside such an attribute ("Page " over "Chapter One") stay words,
        // which `readsOwnText` reads.
        if attributeText(of: element) != nil {
            return MarkdownPageMarker.isPageNumber(text) ? PageStart(label: text) : nil
        }
        // Without an attribute the element's text names the page, when it
        // names one at all and is short enough to be a label.
        if !MarkdownPageMarker.namesNoPage(text),
           MarkdownPageMarker.isNoMoreThanLabel(text, label: "") {
            return PageStart(label: text)
        }
        return nil
    }

    /// The page the page list gives `element` through its id, or through the
    /// name of a legacy anchor, when no earlier element took that id, with
    /// the label as the list spelled it (`HTMLPageTargets.sourceLabels`).
    private static func namedPageMarker(for element: Element, tag: String, context: Context) -> PageStart? {
        // Most documents name no page. Avoid attribute lookups at every node.
        guard !context.pages.markers.isEmpty else { return nil }
        let id = (try? element.attr("id")) ?? ""
        let legacyName = tag == "a" ? ((try? element.attr("name")) ?? "") : ""
        for key in [id, legacyName] {
            if let marker = context.pages.markers[key], context.writtenPageIDs.ids.insert(key).inserted {
                return PageStart(marker: marker, sourceLabel: context.pages.sourceLabels[key])
            }
        }
        return nil
    }

    // MARK: - List Conversion

    /// Convert the children of a <ul> or <ol> to Markdown: each list item
    /// after its bullet, and anything else the list holds (text, or a list
    /// nested directly inside the list) where it stands between the items,
    /// as the direct reader reads it, so none of its words are lost.
    private static func convertListItems(_ listElement: Element, ordered: Bool, into result: inout String, context: Context) {
        var itemCount = 0
        // Content between two items, collected until the next item begins.
        var between = ""
        // Each buffer written apart has a memory of its own for its markers.
        var betweenContext = context
        betweenContext.trailing = TrailingMarkers()
        for child in listElement.getChildNodes() {
            guard let item = child as? Element, item.tagName().lowercased() == "li" else {
                convertChild(child, into: &between, context: betweenContext)
                continue
            }
            // A hidden item is not rendered: it must neither leave an empty
            // bullet nor take a number from the visible items that follow it.
            guard !context.readingFlow.excludes(item) else { continue }
            appendBlock(between, to: &result)
            between = ""
            betweenContext.trailing = TrailingMarkers()
            itemCount += 1
            let bullet = ordered ? "\(itemCount). " : "- "
            result += bullet
            var itemContent = ""
            var itemContext = context
            itemContext.trailing = TrailingMarkers()
            // Go through the element entry point so an id on the li itself
            // receives its annotation as well as targets inside the item.
            convertElement(item, into: &itemContent, context: itemContext)
            // Trim the item content and indent continuation lines
            let trimmed = itemContent.trimmingCharacters(in: writtenWhitespace)
            let lines = trimmed.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                if lineIndex == 0 {
                    result += line + "\n"
                } else {
                    // Indent continuation lines to align with content after bullet
                    let indent = String(repeating: " ", count: bullet.count)
                    result += indent + line + "\n"
                }
            }
        }
        appendBlock(between, to: &result)
    }

    /// Write Markdown converted apart from its surroundings (the content a
    /// list holds between its items) as blocks of its own, with a blank line
    /// on either side, or nothing when it holds no words. Written straight
    /// after an item it would run into that item's paragraph, and the next
    /// item, if numbered other than 1, could not interrupt it: its number
    /// would be read aloud. Converted from an empty buffer, the content
    /// already begins as a block would.
    private static func appendBlock(_ markdown: String, to result: inout String) {
        let trimmed = markdown.trimmingCharacters(in: writtenWhitespace)
        guard !trimmed.isEmpty else { return }
        MarkdownMarkerWriter.ensureBlankLine(&result)
        result += trimmed
        MarkdownMarkerWriter.ensureBlankLine(&result)
    }

    // MARK: - Whitespace Helpers

    /// Keep the words on either side of a boundary apart: a blank line
    /// around a paragraph, at least a space around a word. Both are written
    /// only when missing, so nested and empty blocks never pile up blank
    /// lines, and nothing is written at the start of the Markdown.
    private static func separate(at boundary: HTMLReadingBoundary, in result: inout String, context: Context) {
        switch boundary {
        case .none:
            break
        case .word:
            if !isAtWordStart(result, context: context) {
                result += " "
            }
        case .paragraph:
            dropSpaceBeforeTrailingPageMarkers(in: &result, context: context)
            MarkdownMarkerWriter.ensureBlankLine(&result)
        }
    }

    /// The whitespace conversion writes between words and blocks: spaces and
    /// line feeds. Converted Markdown is trimmed of these alone, because
    /// `CharacterSet.whitespacesAndNewlines` also holds characters such as
    /// U+200B that are words of the reading.
    private static let writtenWhitespace = CharacterSet(charactersIn: " \n")

    /// Whether the next text begins a word: at the start of the Markdown, of
    /// a line, or after a space, with any page markers that end the Markdown
    /// passed over. Were a marker taken for a word's end, the space after an
    /// empty page anchor between two words would be kept beside the one
    /// before it, and "One <span id="p2"/> two" would read "One  two".
    private static func isAtWordStart(_ result: String, context: Context) -> Bool {
        guard let last = beforeTrailingPageMarkers(of: result, context: context).unicodeScalars.last else { return true }
        return last == " " || last == "\n"
    }

    // MARK: - Page Markers Between Words

    /// `result` without the page markers that end it, if any. A page marker
    /// is never read, so the words before it decide where the next words
    /// begin (`isAtWordStart(_:)`) and whether a line ends with a space
    /// (`dropSpaceBeforeTrailingPageMarkers(in:)`), and the book reads the
    /// same with pages as without. A heading annotation is not passed over:
    /// the Markdown without pages, which holds annotations, stays as cache
    /// format 3.0.7 wrote it.
    ///
    /// Where the markers begin is remembered in `context.trailing` for the
    /// buffer's length, so a long run of them is walked once.
    private static func beforeTrailingPageMarkers(of result: String, context: Context) -> Substring {
        let trailing = context.trailing
        let bytes = result.utf8
        if trailing.length == bytes.count, trailing.start <= trailing.length {
            return Substring(result)[..<bytes.index(bytes.startIndex, offsetBy: trailing.start)]
        }
        var text = Substring(result)
        while text.hasSuffix("-->"), let open = lastCommentOpening(in: text),
              MarkdownPageMarker.decode(String(text[open...])) != nil {
            text = text[..<open]
        }
        trailing.length = bytes.count
        trailing.start = bytes.distance(from: bytes.startIndex, to: text.endIndex)
        return text
    }

    /// Where the last "<!--" in `text` begins, searched for from the end, so
    /// finding the opening of a marker that ends the Markdown reads only the
    /// marker. A marker's label never holds "<!--" (`MarkdownPageMarker`).
    private static func lastCommentOpening(in text: Substring) -> String.Index? {
        let bytes = text.utf8
        var index = bytes.endIndex
        while index > bytes.startIndex {
            index = bytes.index(before: index)
            if bytes[index...].starts(with: "<!--".utf8) { return index }
        }
        return nil
    }

    /// Where a line ends, at a paragraph boundary or a line break, drop the
    /// space before page markers that end `result`. Without the markers the
    /// parser trims that space from the end of the line; before them it was
    /// kept, and "Words <!-- page: 6 -->" read "Words " where the book
    /// without pages reads "Words". The page still begins at the next word
    /// (`PageBreak.firstWordStart`). An inline wrapper still open, whose
    /// start this may move, holds the line's end, so it is never written
    /// (`wrapSpan`, `emphasisSpan`).
    private static func dropSpaceBeforeTrailingPageMarkers(in result: inout String, context: Context) {
        let words = beforeTrailingPageMarkers(of: result, context: context)
        guard words.endIndex < result.endIndex, words.unicodeScalars.last == " " else { return }
        result.unicodeScalars.remove(at: result.unicodeScalars.index(before: words.endIndex))
        // The space was one byte before the markers: they begin one earlier.
        context.trailing.length = result.utf8.count
        context.trailing.start -= 1
    }

    // MARK: - Literal Text

    /// Write the words of a text node as Markdown literals, so every
    /// character is read as written. Whitespace collapses exactly as the
    /// direct reader collapses it (HTMLReadingText). A space is dropped at the
    /// start of a word, where it would be two spaces or begin a line; four
    /// spaces there would even begin a code block.
    private static func appendText(_ raw: String, to result: inout String, context: Context) {
        var text = HTMLReadingText.collapsingWhitespace(raw)
        // Scalars decide: a combining mark after a space joins it into one
        // Character, which `hasPrefix(" ")` would not match.
        if text.unicodeScalars.first == " ", isAtWordStart(result, context: context) {
            text.unicodeScalars.removeFirst()
        }
        result += MarkdownLiteral.escaped(text)
    }

    /// Write inline words (`text`, with whitespace collapsed) as `render`
    /// writes them after the Markdown's last scalar. The space collapsing
    /// leaves at either end is written outside, as an ordinary space, so the
    /// rendered syntax never begins or ends with one (a code span would drop
    /// it and run the words around it together). Any other character, a
    /// no-break space included, is words.
    private static func appendSpaced(
        _ text: String,
        to result: inout String,
        context: Context,
        _ render: (_ words: String, _ previous: Unicode.Scalar?) -> String
    ) {
        // Scalars decide where the words begin and end: a combining mark
        // after a space joins it into one Character with the space.
        let scalars = text.unicodeScalars
        let start = scalars.firstIndex { $0 != " " } ?? scalars.endIndex
        let end = scalars.lastIndex { $0 != " " }.map { scalars.index(after: $0) } ?? start
        let core = String(String.UnicodeScalarView(scalars[start..<end]))
        if start > scalars.startIndex {
            appendText(" ", to: &result, context: context)
        }
        result += render(core, result.unicodeScalars.last)
        if !core.isEmpty, end < scalars.endIndex {
            appendText(" ", to: &result, context: context)
        }
    }

    /// A code span holding `code` (one line with no whitespace at either
    /// end), whose text the reader reads verbatim; nothing for empty code.
    /// The fence is one backtick longer than the longest run of backticks
    /// inside, so none of them can close it, and CommonMark's padding space
    /// separates a backtick at either end from the fence. Code ending in a
    /// backslash is padded too, so a backslash never stands before a closing
    /// backtick, where `emphasize` would take it for an escape. Straight
    /// after a backtick (another span's closing fence) an opening fence would
    /// merge with it into one run, and neither span would close, so the code
    /// is written as literal text, which reads the same.
    private static func codeSpan(_ code: String, after previous: Unicode.Scalar?) -> String {
        guard !code.isEmpty else { return "" }
        guard previous != "`" else { return MarkdownLiteral.escaped(code) }
        let fence = String(repeating: "`", count: longestRun(of: "`", in: code) + 1)
        let scalars = code.unicodeScalars
        let padding = scalars.first == "`" || scalars.last == "`" || scalars.last == "\\" ? " " : ""
        return fence + padding + code + padding + fence
    }

    /// A link or image destination in angle brackets, which may hold spaces
    /// and parentheses. Its whitespace is collapsed, because a destination
    /// cannot span lines, and each `<`, `>`, and backslash is escaped, so
    /// nothing in the URL can end it early. Nothing reads a destination
    /// aloud; it is kept only so the link or image stays one.
    private static func destination(_ url: String) -> String {
        var escaped = String.UnicodeScalarView()
        let collapsed = HTMLReadingText.collapsingWhitespace(url).trimmingCharacters(in: .whitespaces)
        for scalar in collapsed.unicodeScalars {
            if scalar == "<" || scalar == ">" || scalar == "\\" {
                escaped.append("\\")
            }
            escaped.append(scalar)
        }
        return "<" + String(escaped) + ">"
    }

    // MARK: - Inline Wrappers

    /// Where an inline wrapper goes in the Markdown being built: the stretch
    /// from `contentStart` to the end of the Markdown is the element's own
    /// content, and the opener goes before `lower` and the closer before
    /// `upper`, both within that stretch.
    private struct InlineSpan {
        var contentStart: String.Index
        var lower: String.Index
        var upper: String.Index
    }

    /// Wrap the Markdown written since `start` (a UTF-8 offset into `result`)
    /// in `opener` and `closer`, leaving whitespace at either end outside.
    /// Words spanning lines (a block or line break inside the element) cannot
    /// form one inline span, and empty content needs no wrapper: both are
    /// left unwrapped, so only the words remain.
    private static func wrap(from start: Int, in result: inout String, opener: String, closer: String) {
        guard let span = wrapSpan(from: start, in: result) else { return }
        insert(opener, closer, around: span, in: &result)
    }

    /// Where `wrap` puts its opener and closer around the Markdown written
    /// since `start`, or nil when it leaves the words unwrapped. Found here,
    /// apart from the insertion, for the reason `insert` gives.
    private static func wrapSpan(from start: Int, in result: String) -> InlineSpan? {
        let scalars = result.unicodeScalars
        let contentStart = result.utf8.index(result.utf8.startIndex, offsetBy: start)
        guard !scalars[contentStart...].contains("\n") else { return nil }
        var lower = contentStart
        var upper = scalars.endIndex
        while lower < upper, scalars[lower] == " " {
            lower = scalars.index(after: lower)
        }
        while upper > lower, scalars[scalars.index(before: upper)] == " " {
            upper = scalars.index(before: upper)
        }
        guard lower < upper else { return nil }
        return InlineSpan(contentStart: contentStart, lower: lower, upper: upper)
    }

    /// Mark the Markdown written since `start` as emphasis with `delimiter`,
    /// but only where CommonMark will read the pair as emphasis. A pair it
    /// does not match is read aloud as asterisks, while emphasis changes
    /// nothing a listener hears, so otherwise the words are left unmarked.
    ///
    /// Whitespace, punctuation, and symbols at either end of the words stay
    /// outside the pair ("*Titanic*." rather than "*Titanic.*"), so each
    /// delimiter normally touches a letter, digit, or mark, which makes it
    /// flanking whatever stands on its other side. Where the words begin
    /// with syntax that cannot move (a link, image, code span, or
    /// destination), the opener must follow whitespace, punctuation, or a
    /// line start. Where they end with such syntax they stay unmarked, since
    /// what will follow the closer is not yet written. Nor is an opener
    /// written right after a delimiter, with which it would merge into one
    /// run: this is what keeps emphasis beside emphasis apart.
    private static func emphasize(from start: Int, in result: inout String, delimiter: String) {
        guard let span = emphasisSpan(from: start, in: result) else { return }
        insert(delimiter, delimiter, around: span, in: &result)
    }

    /// Where `emphasize` puts its delimiters around the Markdown written
    /// since `start`, or nil where CommonMark would not read them as a pair.
    /// Found here, apart from the insertion, for the reason `insert` gives.
    private static func emphasisSpan(from start: Int, in result: String) -> InlineSpan? {
        let scalars = result.unicodeScalars
        let contentStart = result.utf8.index(result.utf8.startIndex, offsetBy: start)
        guard !scalars[contentStart...].contains("\n") else { return nil }
        var lower = contentStart
        var upper = scalars.endIndex
        // Leave whitespace, escapes (a backslash and the ASCII punctuation it
        // makes literal), and other punctuation or symbols before the pair.
        while lower < upper {
            let scalar = scalars[lower]
            if scalar == "\\" {
                lower = scalars.index(lower, offsetBy: 2, limitedBy: upper) ?? upper
            } else if scalar == " " || (!scalar.isASCII && !MarkdownLiteral.isFlankingSafe(scalar)) {
                lower = scalars.index(after: lower)
            } else {
                break
            }
        }
        // And the same after it.
        while upper > lower {
            let last = scalars.index(before: upper)
            let scalar = scalars[last]
            if scalar == " " || (!scalar.isASCII && !MarkdownLiteral.isFlankingSafe(scalar)) {
                upper = last
            } else if MarkdownLiteral.isASCIIPunctuation(scalar), isEscaped(last, in: scalars, notBefore: lower) {
                upper = scalars.index(before: last)
            } else {
                break
            }
        }
        guard lower < upper else { return nil }
        let previous = lower > scalars.startIndex ? scalars[scalars.index(before: lower)] : nil
        let followsBoundary = previous.map { $0 == " " || $0 == "\n" || MarkdownLiteral.isASCIIPunctuation($0) } ?? true
        guard previous != "*",
              MarkdownLiteral.isFlankingSafe(scalars[lower]) || followsBoundary,
              MarkdownLiteral.isFlankingSafe(scalars[scalars.index(before: upper)]) else { return nil }
        return InlineSpan(contentStart: contentStart, lower: lower, upper: upper)
    }

    /// Whether the ASCII punctuation at `index` is escaped: an odd number of
    /// backslashes, counted back no further than `lower`, stands before it.
    /// Outside code spans every backslash the converter writes belongs to an
    /// escape, and a code span never ends with one (see `codeSpan`), so a
    /// closing backtick or bracket is never mistaken for escaped text.
    private static func isEscaped(
        _ index: String.Index,
        in scalars: String.UnicodeScalarView,
        notBefore lower: String.Index
    ) -> Bool {
        var backslashes = 0
        var position = index
        while position > lower {
            position = scalars.index(before: position)
            guard scalars[position] == "\\" else { break }
            backslashes += 1
        }
        return backslashes % 2 == 1
    }

    /// Rewrite the Markdown from `span.contentStart` to the end of `result`
    /// with `opener` inserted before `span.lower` and `closer` before
    /// `span.upper`. All three indexes lie in that final stretch, so the
    /// work is proportional to the wrapped content rather than to the
    /// chapter, but only while `result` is the one reference to its storage
    /// when the stretch is replaced. A view of `result` alive at that moment
    /// (a `unicodeScalars` constant in this function or in its caller, as
    /// there once were) shares the storage, so the standard library cannot
    /// replace the stretch in place: it copies the whole Markdown converted
    /// so far, scalar by scalar, and every emphasis and link then cost as
    /// much as everything before it (PERF18). So the span is found by a
    /// function that has returned, and the new stretch is built by another.
    private static func insert(_ opener: String, _ closer: String, around span: InlineSpan, in result: inout String) {
        let stretch = rewrapped(result, around: span, opener: opener, closer: closer)
        result.unicodeScalars.replaceSubrange(span.contentStart..., with: stretch)
    }

    /// The stretch of `markdown` from `span.contentStart` to its end, with
    /// `opener` before `span.lower` and `closer` before `span.upper`.
    private static func rewrapped(
        _ markdown: String,
        around span: InlineSpan,
        opener: String,
        closer: String
    ) -> String.UnicodeScalarView {
        let scalars = markdown.unicodeScalars
        var stretch = String.UnicodeScalarView()
        stretch.append(contentsOf: scalars[span.contentStart..<span.lower])
        stretch.append(contentsOf: opener.unicodeScalars)
        stretch.append(contentsOf: scalars[span.lower..<span.upper])
        stretch.append(contentsOf: closer.unicodeScalars)
        stretch.append(contentsOf: scalars[span.upper...])
        return stretch
    }

    /// The length of the longest run of `scalar` in `text`.
    private static func longestRun(of scalar: Unicode.Scalar, in text: String) -> Int {
        var longest = 0
        var current = 0
        for candidate in text.unicodeScalars {
            current = candidate == scalar ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
