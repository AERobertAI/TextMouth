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
                // Emit text content, collapsing runs of whitespace
                let text = textNode.getWholeText()
                let collapsed = collapseWhitespace(text)
                result += collapsed
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
        // Most chapters have no fragment destinations. Avoid attribute lookups
        // at every node when there is no possible navigation match.
        if !headingTargets.isEmpty, tag != "script", tag != "style" {
            let id = (try? element.attr("id")) ?? ""
            let legacyName = tag == "a" ? ((try? element.attr("name")) ?? "") : ""
            if let annotation = headingTargets[id] ?? headingTargets[legacyName] {
                if element.isBlock() {
                    ensureBlankLine(&result)
                    result += annotation.markdown + "\n\n"
                } else {
                    result += annotation.markdown
                }
            }
        }

        switch tag {
        // Non-content elements are ignored without running selector queries.
        case "script", "style":
            return

        // Headings
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last!)) ?? 1
            let prefix = String(repeating: "#", count: level)
            ensureBlankLine(&result)
            result += "\(prefix) "
            convertNode(element, into: &result, headingTargets: headingTargets)
            result += "\n\n"

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

        // Images — emit alt text for accessibility
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = (try? element.attr("src")) ?? ""
            result += "![\(alt)](\(src))"

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

        // Inline code
        case "code":
            // If parent is <pre>, skip the inline backticks
            if element.parent()?.tagName().lowercased() == "pre" {
                convertNode(element, into: &result, headingTargets: headingTargets)
            } else {
                result += "`"
                convertNode(element, into: &result, headingTargets: headingTargets)
                result += "`"
            }

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

    /// Collapse runs of whitespace (spaces, tabs, newlines) into a single space.
    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
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
