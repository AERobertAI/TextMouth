import Foundation
import SwiftSoup

/// Converts HTML content to Markdown format.
/// Used during import to create cached Markdown representations of EPUB chapters and HTML files.
enum HTMLToMarkdownConverter {

    /// Convert an HTML string to Markdown, preserving headings, emphasis, links, and lists.
    static func convert(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)

        // Remove script and style elements — they shouldn't appear in Markdown output
        try doc.select("script, style").remove()

        let body = doc.body() ?? doc
        var result = ""
        convertNode(body, into: &result)

        // Clean up excessive blank lines (collapse 3+ newlines to 2)
        result = collapseBlankLines(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Node Conversion

    /// Recursively walk the DOM tree and emit Markdown for each element.
    private static func convertNode(_ node: Node, into result: inout String) {
        for child in node.getChildNodes() {
            if let textNode = child as? TextNode {
                // Emit text content, collapsing runs of whitespace
                let text = textNode.getWholeText()
                let collapsed = collapseWhitespace(text)
                result += collapsed
            } else if let element = child as? Element {
                convertElement(element, into: &result)
            }
        }
    }

    /// Convert a single HTML element to its Markdown equivalent.
    private static func convertElement(_ element: Element, into result: inout String) {
        let tag = element.tagName().lowercased()

        switch tag {
        // Headings
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last!)) ?? 1
            let prefix = String(repeating: "#", count: level)
            ensureBlankLine(&result)
            result += "\(prefix) "
            convertNode(element, into: &result)
            result += "\n\n"

        // Paragraphs
        case "p":
            ensureBlankLine(&result)
            convertNode(element, into: &result)
            result += "\n\n"

        // Line breaks
        case "br":
            result += "  \n"

        // Emphasis
        case "em", "i":
            result += "*"
            convertNode(element, into: &result)
            result += "*"

        // Strong
        case "strong", "b":
            result += "**"
            convertNode(element, into: &result)
            result += "**"

        // Links
        case "a":
            let href = (try? element.attr("href")) ?? ""
            result += "["
            convertNode(element, into: &result)
            result += "]"
            if !href.isEmpty {
                result += "(\(href))"
            }

        // Images — emit alt text for accessibility
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = (try? element.attr("src")) ?? ""
            result += "![\(alt)](\(src))"

        // Unordered lists
        case "ul":
            ensureBlankLine(&result)
            convertListItems(element, ordered: false, into: &result)
            result += "\n"

        // Ordered lists
        case "ol":
            ensureBlankLine(&result)
            convertListItems(element, ordered: true, into: &result)
            result += "\n"

        // List items (handled by convertListItems, but just in case)
        case "li":
            convertNode(element, into: &result)

        // Blockquotes
        case "blockquote":
            ensureBlankLine(&result)
            var inner = ""
            convertNode(element, into: &inner)
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
                convertNode(element, into: &result)
            } else {
                result += "`"
                convertNode(element, into: &result)
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
            convertNode(element, into: &result)

        // Unknown elements — just emit their text children
        default:
            convertNode(element, into: &result)
        }
    }

    // MARK: - List Conversion

    /// Convert list item children of a <ul> or <ol> to Markdown.
    private static func convertListItems(_ listElement: Element, ordered: Bool, into result: inout String) {
        let items = (try? listElement.select(":root > li")) ?? Elements()
        for (index, item) in items.array().enumerated() {
            let bullet = ordered ? "\(index + 1). " : "- "
            result += bullet
            var itemContent = ""
            convertNode(item, into: &itemContent)
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
