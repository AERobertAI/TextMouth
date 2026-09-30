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
        convertNode(body, into: &result, headingTargets: headingTargets)

        // Clean up excessive blank lines (collapse 3+ newlines to 2)
        result = collapseBlankLines(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Recursively walk the DOM tree and emit Markdown for each element.
    private static func convertNode(_ node: Node, into result: inout String, headingTargets: [String: MarkdownHeadingAnnotation]) {
        for child in node.getChildNodes() {
            if let textNode = child as? TextNode {
                appendText(textNode.getWholeText(), to: &result)
            } else if let element = child as? Element {
                convertElement(element, into: &result, headingTargets: headingTargets)
            }
        }
    }

    /// Convert a single HTML element to its Markdown equivalent.
    private static func convertElement(_ element: Element, into result: inout String, headingTargets: [String: MarkdownHeadingAnnotation]) {
        // Content outside the rendered reading flow (the hidden attribute, page
        // lists, and landmarks) contributes no words, headings, or destinations.
        guard !PublicationSemantics.isExcludedFromReadingFlow(element) else { return }
        let tag = element.tagName().lowercased()

        // Preserve a TOC target in the Markdown stream at its actual DOM
        // position. Inline targets stay inline; block targets precede their
        // block. The annotation never contributes words to speech.
        if let annotation = headingAnnotation(for: element, tag: tag, headingTargets: headingTargets) {
            emit(annotation, inline: !element.isBlock(), into: &result)
        }

        switch tag {
        // Non-content elements are ignored without running selector queries.
        case "script", "style":
            return

        // Headings
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = HTMLReadingText.headingLevel(of: tag) ?? 1
            ensureBlankLine(&result)
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

        // Paragraphs
        case "p":
            ensureBlankLine(&result)
            convertNode(element, into: &result, headingTargets: headingTargets)
            result += "\n\n"

        // Line breaks
        case "br":
            result += "  \n"

        // Emphasis
        case "em", "i":
            result += "*"
            convertNode(element, into: &result, headingTargets: headingTargets)
            result += "*"

        // Strong
        case "strong", "b":
            result += "**"
            convertNode(element, into: &result, headingTargets: headingTargets)
            result += "**"

        // Links
        case "a":
            let href = (try? element.attr("href")) ?? ""
            if href.isEmpty {
                // A named anchor such as <a id="page_12"/> marks a destination;
                // it is not a link. Markdown would keep bare brackets as literal
                // text in speech and in heading labels ("[]2"), so emit only
                // whatever the anchor encloses.
                convertNode(element, into: &result, headingTargets: headingTargets)
            } else {
                result += "["
                convertNode(element, into: &result, headingTargets: headingTargets)
                result += "](\(href))"
            }

        // Images — emit alt text for accessibility, read like any other text
        case "img":
            let alt = HTMLReadingText.collapsingWhitespace((try? element.attr("alt")) ?? "")
            let src = (try? element.attr("src")) ?? ""
            result += "![\(MarkdownLiteral.escaped(alt))](\(src))"

        // Unordered lists
        case "ul":
            ensureBlankLine(&result)
            convertListItems(element, ordered: false, into: &result, headingTargets: headingTargets)
            result += "\n"

        // Ordered lists
        case "ol":
            ensureBlankLine(&result)
            convertListItems(element, ordered: true, into: &result, headingTargets: headingTargets)
            result += "\n"

        // List items (handled by convertListItems, but just in case)
        case "li":
            convertNode(element, into: &result, headingTargets: headingTargets)

        // Blockquotes
        case "blockquote":
            ensureBlankLine(&result)
            var inner = ""
            convertNode(element, into: &inner, headingTargets: headingTargets)
            // Prefix each line with >
            let lines = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            for line in lines {
                result += "> \(line)\n"
            }
            result += "\n"

        // Preformatted / code blocks
        case "pre":
            ensureBlankLine(&result)
            result += "```\n"
            // Get raw text content without further processing
            let text = (try? element.text()) ?? ""
            result += text
            if !text.hasSuffix("\n") { result += "\n" }
            result += "```\n\n"

        // Inline code. A code span is read verbatim, so destinations inside
        // it precede it rather than becoming words of the code.
        case "code":
            for annotation in headingAnnotations(inside: element, headingTargets: headingTargets) {
                emit(annotation, inline: true, into: &result)
            }
            appendCodeSpan(HTMLReadingText.inlineText(of: element), to: &result)

        // Horizontal rules
        case "hr":
            ensureBlankLine(&result)
            result += "---\n\n"

        // Block-level containers — just recurse into children
        case "div", "section", "article", "main", "header", "footer", "nav",
             "aside", "figure", "figcaption", "details", "summary",
             "body", "html", "span", "sup", "sub", "small", "mark",
             "abbr", "cite", "dfn", "time", "var", "samp", "kbd",
             "ruby", "rt", "rp", "bdi", "bdo", "wbr",
             "table", "thead", "tbody", "tfoot", "tr", "td", "th",
             "caption", "colgroup", "col",
             "dl", "dt", "dd":
            convertNode(element, into: &result, headingTargets: headingTargets)

        // Unknown elements — just emit their text children
        default:
            convertNode(element, into: &result, headingTargets: headingTargets)
        }
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

    /// Convert list item children of a <ul> or <ol> to Markdown.
    private static func convertListItems(_ listElement: Element, ordered: Bool, into result: inout String, headingTargets: [String: MarkdownHeadingAnnotation]) {
        // A hidden item is not rendered: it must neither leave an empty bullet
        // nor take a number from the visible items that follow it.
        let items = listElement.getChildNodes().compactMap { node -> Element? in
            guard let element = node as? Element,
                  element.tagName().lowercased() == "li",
                  !PublicationSemantics.isExcludedFromReadingFlow(element) else { return nil }
            return element
        }
        for (index, item) in items.enumerated() {
            let bullet = ordered ? "\(index + 1). " : "- "
            result += bullet
            var itemContent = ""
            // Go through the element entry point so an id on the li itself
            // receives its annotation as well as targets inside the item.
            convertElement(item, into: &itemContent, headingTargets: headingTargets)
            // Trim the item content and indent continuation lines
            let trimmed = itemContent.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    // MARK: - Whitespace Helpers

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
        if text.hasPrefix(" "), isAtWordStart(result) {
            text.removeFirst()
        }
        result += MarkdownLiteral.escaped(text)
    }

    /// Write inline code (`code`, its words with whitespace collapsed) as a
    /// code span, whose text the reader reads verbatim. The fence is one
    /// backtick longer than the longest run of backticks inside, so none of
    /// them can close it, and CommonMark's padding space separates a
    /// backtick at either end from the fence. Whitespace at either end is
    /// written outside the span as an ordinary space, so the span never
    /// begins or ends with one.
    private static func appendCodeSpan(_ code: String, to result: inout String) {
        let core = code.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix(" ") {
            appendText(" ", to: &result)
        }
        guard !core.isEmpty else { return }
        let fence = String(repeating: "`", count: longestRun(of: "`", in: core) + 1)
        let scalars = core.unicodeScalars
        let padding = scalars.first == "`" || scalars.last == "`" ? " " : ""
        result += fence + padding + core + padding + fence
        if code.hasSuffix(" ") {
            appendText(" ", to: &result)
        }
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

    /// Collapse three or more consecutive newlines into exactly two.
    private static func collapseBlankLines(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
    }
}
