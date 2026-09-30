import Foundation
import SwiftSoup

/// Converts HTML content to Markdown format.
/// Used during import to create cached Markdown representations of EPUB chapters and HTML files.
enum HTMLToMarkdownConverter {

    /// Convert an HTML string to Markdown, preserving headings, emphasis, links, and lists.
    static func convert(
        _ html: String,
        stripDuplicateNavigation: Bool = false,
        headingTargets: [String: MarkdownHeadingAnnotation] = [:]
    ) throws -> String {
        let doc = try SwiftSoup.parse(html)

        let body = doc.body() ?? doc
        if stripDuplicateNavigation {
            try removeDuplicateNavigation(from: body)
        }

        var result = ""
        convertNode(body, into: &result, context: Context(headingTargets: headingTargets))
        return result.trimmingCharacters(in: writtenWhitespace)
    }

    /// Match EPUBParser's nav stripping: remove nav/TOC text only when the
    /// chapter has real heading elements outside nav, so nav-only headings
    /// remain available for sparse documents.
    static func removeDuplicateNavigation(from body: Element) throws {
        var allHeadingCount = 0
        var navHeadingCount = 0
        var navigationElements: [Element] = []
        collectNavigationDetails(
            from: body,
            insideNavigation: false,
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
        allHeadingCount: inout Int,
        navHeadingCount: inout Int,
        navigationElements: inout [Element]
    ) {
        for child in node.getChildNodes() {
            // Hidden content, page lists, and landmarks are never converted,
            // so they neither count as headings nor need removing as navigation.
            guard let element = child as? Element,
                  !PublicationSemantics.isExcludedFromReadingFlow(element) else { continue }
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
                allHeadingCount: &allHeadingCount,
                navHeadingCount: &navHeadingCount,
                navigationElements: &navigationElements
            )
        }
    }

    // MARK: - Node Conversion

    /// What conversion knows about the position of the node it converts.
    private struct Context {
        /// TOC destinations, keyed by the id (or legacy anchor name) marking them.
        var headingTargets: [String: MarkdownHeadingAnnotation]
        /// Inside a link. Markdown cannot nest links, so a link here keeps
        /// only its words.
        var insideLink = false
        /// Inside emphasis, whose words are marked once, by the outermost.
        var insideEmphasis = false
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
            appendText(textNode.getWholeText(), to: &result)
        } else if let element = child as? Element {
            convertElement(element, into: &result, context: context)
        }
    }

    /// Convert a single HTML element to its Markdown equivalent.
    private static func convertElement(_ element: Element, into result: inout String, context: Context) {
        let headingTargets = context.headingTargets
        let tag = element.tagName().lowercased()
        // Non-content elements are ignored without running selector queries.
        // Content outside the rendered reading flow (the hidden attribute, page
        // lists, and landmarks) contributes no words, headings, or destinations.
        guard tag != "script", tag != "style",
              !PublicationSemantics.isExcludedFromReadingFlow(element) else { return }

        // Keep the element's words apart from its neighbors' exactly where the
        // direct reader does (HTMLReadingBoundary): a block is a paragraph of
        // its own, and a table cell, ins, del, or s is at least a word of its
        // own. A line break is its own boundary, the hard break it writes.
        let boundary: HTMLReadingBoundary = tag == "br" ? .none : .of(element, tag: tag)
        separate(at: boundary, in: &result)

        // Preserve a TOC target in the Markdown stream at its actual DOM
        // position. Inline targets stay inline; block targets precede their
        // block. The annotation never contributes words to speech.
        if let annotation = headingAnnotation(for: element, tag: tag, headingTargets: headingTargets) {
            emit(annotation, inline: boundary != .paragraph, into: &result)
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
            for annotation in headingAnnotations(inside: element, headingTargets: headingTargets) {
                emit(annotation, inline: false, into: &result)
            }
            // The heading line holds the label the direct reader gives it,
            // as literal text: one line even when the heading contains a line
            // break or a block, and no link, emphasis, or code syntax, whose
            // markers the parser would otherwise have to keep out of the label.
            let label = HTMLReadingText.label(of: element)
            result += String(repeating: "#", count: level) + " " + MarkdownLiteral.escaped(label) + "\n\n"

        // Line breaks
        case "br":
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
            appendSpaced(alt, to: &result) { core, _ in
                "![" + MarkdownLiteral.escaped(core) + "](" + destination(src) + ")"
            }

        // Lists
        case "ul", "ol":
            convertListItems(element, ordered: tag == "ol", into: &result, context: context)

        // Blockquotes
        case "blockquote":
            var inner = ""
            convertNode(element, into: &inner, context: context)
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
            for annotation in headingAnnotations(inside: element, headingTargets: headingTargets) {
                emit(annotation, inline: false, into: &result)
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
            for annotation in headingAnnotations(inside: element, headingTargets: headingTargets) {
                emit(annotation, inline: true, into: &result)
            }
            appendSpaced(HTMLReadingText.inlineText(of: element), to: &result, codeSpan(_:after:))

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

        separate(at: boundary, in: &result)
    }

    // MARK: - Navigation Annotations

    /// Where the next output lands in the Markdown being built.
    private enum LinePosition {
        /// After visible content on the current line.
        case withinLine
        /// At the start of a line that continues a paragraph (after a hard break).
        case continuationLine
        /// At the start of a new block: the beginning, or after a blank line.
        case blockStart
    }

    /// Classify the end of `result` from its last two lines only, so the cost
    /// does not grow with the chapter. Spaces and tabs are indentation, not
    /// content, as in CommonMark. Scalars keep "\r\n" from hiding a newline.
    private static func linePosition(of result: String) -> LinePosition {
        let scalars = result.unicodeScalars
        let isIndentation: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" }
        guard let lineBreak = scalars.lastIndex(of: "\n") else {
            return scalars.allSatisfy(isIndentation) ? .blockStart : .withinLine
        }
        guard scalars[scalars.index(after: lineBreak)...].allSatisfy(isIndentation) else { return .withinLine }
        let earlierLines = scalars[..<lineBreak]
        let previousLineStart = earlierLines.lastIndex(of: "\n").map { earlierLines.index(after: $0) }
            ?? earlierLines.startIndex
        return earlierLines[previousLineStart...].allSatisfy(isIndentation) ? .blockStart : .continuationLine
    }

    /// Write a destination without changing the words around it. CommonMark
    /// opens an HTML block at any line that begins with "<!--", and that block
    /// swallows the rest of the line: an anchor at the start of a paragraph
    /// used to delete the paragraph's words from speech. An annotation therefore
    /// never begins a line. At a block boundary it becomes a block of its own,
    /// which names the same position as the block that follows. After a hard
    /// line break, four spaces keep it inside the paragraph, because an HTML
    /// block may be indented by at most three and a continuation line's
    /// indentation is not part of its text.
    private static func emit(_ annotation: MarkdownHeadingAnnotation, inline: Bool, into result: inout String) {
        switch inline ? linePosition(of: result) : .blockStart {
        case .withinLine:
            result += annotation.markdown
        case .continuationLine:
            result += "    " + annotation.markdown
        case .blockStart:
            ensureBlankLine(&result)
            result += annotation.markdown + "\n\n"
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

    /// Destinations carried by a heading's descendants, in document order.
    /// Content outside the reading flow is skipped exactly as conversion skips it.
    private static func headingAnnotations(
        inside heading: Element,
        headingTargets: [String: MarkdownHeadingAnnotation]
    ) -> [MarkdownHeadingAnnotation] {
        guard !headingTargets.isEmpty else { return [] }
        var annotations: [MarkdownHeadingAnnotation] = []
        for child in heading.getChildNodes() {
            guard let element = child as? Element,
                  !PublicationSemantics.isExcludedFromReadingFlow(element) else { continue }
            let tag = element.tagName().lowercased()
            if let annotation = headingAnnotation(for: element, tag: tag, headingTargets: headingTargets) {
                annotations.append(annotation)
            }
            annotations += headingAnnotations(inside: element, headingTargets: headingTargets)
        }
        return annotations
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
        for child in listElement.getChildNodes() {
            guard let item = child as? Element, item.tagName().lowercased() == "li" else {
                convertChild(child, into: &between, context: context)
                continue
            }
            // A hidden item is not rendered: it must neither leave an empty
            // bullet nor take a number from the visible items that follow it.
            guard !PublicationSemantics.isExcludedFromReadingFlow(item) else { continue }
            appendBlock(between, to: &result)
            between = ""
            itemCount += 1
            let bullet = ordered ? "\(itemCount). " : "- "
            result += bullet
            var itemContent = ""
            // Go through the element entry point so an id on the li itself
            // receives its annotation as well as targets inside the item.
            convertElement(item, into: &itemContent, context: context)
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
        ensureBlankLine(&result)
        result += trimmed
        ensureBlankLine(&result)
    }

    // MARK: - Whitespace Helpers

    /// Keep the words on either side of a boundary apart: a blank line
    /// around a paragraph, at least a space around a word. Both are written
    /// only when missing, so nested and empty blocks never pile up blank
    /// lines, and nothing is written at the start of the Markdown.
    private static func separate(at boundary: HTMLReadingBoundary, in result: inout String) {
        switch boundary {
        case .none:
            break
        case .word:
            if !isAtWordStart(result) {
                result += " "
            }
        case .paragraph:
            ensureBlankLine(&result)
        }
    }

    /// Ensure the result ends with a blank line (two newlines).
    private static func ensureBlankLine(_ result: inout String) {
        if result.isEmpty { return }
        if !result.hasSuffix("\n\n") {
            if result.hasSuffix("\n") {
                result += "\n"
            } else {
                result += "\n\n"
            }
        }
    }

    /// The whitespace conversion writes between words and blocks: spaces and
    /// line feeds. Converted Markdown is trimmed of these alone, because
    /// `CharacterSet.whitespacesAndNewlines` also holds characters such as
    /// U+200B that are words of the reading.
    private static let writtenWhitespace = CharacterSet(charactersIn: " \n")

    /// Whether the next text begins a word: at the start of the Markdown, of
    /// a line, or after a space.
    private static func isAtWordStart(_ result: String) -> Bool {
        guard let last = result.unicodeScalars.last else { return true }
        return last == " " || last == "\n"
    }

    // MARK: - Literal Text

    /// Write the words of a text node as Markdown literals, so every
    /// character is read as written. Whitespace collapses exactly as the
    /// direct reader collapses it (HTMLReadingText). A space is dropped at the
    /// start of a word, where it would be two spaces or begin a line; four
    /// spaces there would even begin a code block.
    private static func appendText(_ raw: String, to result: inout String) {
        var text = HTMLReadingText.collapsingWhitespace(raw)
        // Scalars decide: a combining mark after a space joins it into one
        // Character, which `hasPrefix(" ")` would not match.
        if text.unicodeScalars.first == " ", isAtWordStart(result) {
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
        _ render: (_ words: String, _ previous: Unicode.Scalar?) -> String
    ) {
        // Scalars decide where the words begin and end: a combining mark
        // after a space joins it into one Character with the space.
        let scalars = text.unicodeScalars
        let start = scalars.firstIndex { $0 != " " } ?? scalars.endIndex
        let end = scalars.lastIndex { $0 != " " }.map { scalars.index(after: $0) } ?? start
        let core = String(String.UnicodeScalarView(scalars[start..<end]))
        if start > scalars.startIndex {
            appendText(" ", to: &result)
        }
        result += render(core, result.unicodeScalars.last)
        if !core.isEmpty, end < scalars.endIndex {
            appendText(" ", to: &result)
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

    /// Wrap the Markdown written since `start` (a UTF-8 offset into `result`)
    /// in `opener` and `closer`, leaving whitespace at either end outside.
    /// Words spanning lines (a block or line break inside the element) cannot
    /// form one inline span, and empty content needs no wrapper: both are
    /// left unwrapped, so only the words remain.
    private static func wrap(from start: Int, in result: inout String, opener: String, closer: String) {
        let scalars = result.unicodeScalars
        let contentStart = result.utf8.index(result.utf8.startIndex, offsetBy: start)
        guard !scalars[contentStart...].contains("\n") else { return }
        var lower = contentStart
        var upper = scalars.endIndex
        while lower < upper, scalars[lower] == " " {
            lower = scalars.index(after: lower)
        }
        while upper > lower, scalars[scalars.index(before: upper)] == " " {
            upper = scalars.index(before: upper)
        }
        guard lower < upper else { return }
        insert(opener, at: lower, closer, at: upper, afterContentStart: contentStart, in: &result)
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
        let scalars = result.unicodeScalars
        let contentStart = result.utf8.index(result.utf8.startIndex, offsetBy: start)
        guard !scalars[contentStart...].contains("\n") else { return }
        var lower = contentStart
        var upper = scalars.endIndex
        // Leave whitespace, escapes (a backslash and the ASCII punctuation it
        // makes literal), and other punctuation or symbols before the pair.
        while lower < upper {
            let scalar = scalars[lower]
            if scalar == "\\" {
                lower = scalars.index(lower, offsetBy: 2, limitedBy: upper) ?? upper
            } else if scalar == " " || (!scalar.isASCII && !isFlankingSafe(scalar)) {
                lower = scalars.index(after: lower)
            } else {
                break
            }
        }
        // And the same after it.
        while upper > lower {
            let last = scalars.index(before: upper)
            let scalar = scalars[last]
            if scalar == " " || (!scalar.isASCII && !isFlankingSafe(scalar)) {
                upper = last
            } else if MarkdownLiteral.isASCIIPunctuation(scalar), isEscaped(last, in: scalars, notBefore: lower) {
                upper = scalars.index(before: last)
            } else {
                break
            }
        }
        guard lower < upper else { return }
        let previous = lower > scalars.startIndex ? scalars[scalars.index(before: lower)] : nil
        let followsBoundary = previous.map { $0 == " " || $0 == "\n" || MarkdownLiteral.isASCIIPunctuation($0) } ?? true
        guard previous != "*",
              isFlankingSafe(scalars[lower]) || followsBoundary,
              isFlankingSafe(scalars[scalars.index(before: upper)]) else { return }
        insert(delimiter, at: lower, delimiter, at: upper, afterContentStart: contentStart, in: &result)
    }

    /// Letters, digits, and marks. CommonMark counts none of them as
    /// whitespace or punctuation, so a delimiter beside one is flanking on
    /// that side whatever stands on its other side.
    private static func isFlankingSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
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

    /// Rewrite the Markdown from `contentStart` to the end of `result` with
    /// `opener` inserted at `lower` and `closer` at `upper`. All three
    /// indexes lie in that final stretch, so the work is proportional to the
    /// wrapped content rather than to the chapter.
    private static func insert(
        _ opener: String, at lower: String.Index,
        _ closer: String, at upper: String.Index,
        afterContentStart contentStart: String.Index,
        in result: inout String
    ) {
        let scalars = result.unicodeScalars
        var wrapped = String.UnicodeScalarView()
        wrapped.append(contentsOf: scalars[contentStart..<lower])
        wrapped.append(contentsOf: opener.unicodeScalars)
        wrapped.append(contentsOf: scalars[lower..<upper])
        wrapped.append(contentsOf: closer.unicodeScalars)
        wrapped.append(contentsOf: scalars[upper...])
        result.unicodeScalars.replaceSubrange(contentStart..., with: wrapped)
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
