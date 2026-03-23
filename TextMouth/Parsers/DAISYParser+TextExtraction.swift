import Foundation

// MARK: - DTBook XML → Markdown Converter

/// Converts DTBook XML (DAISY 3 text content) to Markdown.
/// Uses SAX parsing to walk the DTBook element tree and emit Markdown output.
class DTBookToMarkdownConverter: NSObject, XMLParserDelegate {
    private var markdown = ""
    private var elementStack: [String] = []

    // Track whether we're in a list and its type
    private var listTypeStack: [String] = [] // "ul" or "ol"
    private var listCounterStack: [Int] = []
    private var listDepth = 0

    // Inline formatting
    private var isInEmphasis = false
    private var isInStrong = false

    // Link state
    private var currentLinkHref = ""

    // Track block context for proper spacing
    private var lastOutputWasBlock = false

    // Skip elements (head, prodnote content, etc.)
    private var skipDepth = 0

    // Chapter marker state: capture h1 text inside level1 to emit chapter markers.
    // This lets MarkdownCacheService split the content into manageable chapters.
    private var pendingChapterTitle = false
    private var chapterTitleBuffer = ""
    private var level1Depth = 0

    /// Convert DTBook XML data to Markdown
    func convert(data: Data) -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        // Disable external entity resolution to prevent delays from DTD loading.
        // DTBook XML files reference dtbook-2005-3.dtd which isn't accessible
        // when parsing from in-memory data extracted from a ZIP archive.
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return normalizeWhitespace(markdown)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        elementStack.append(localName)

        // If we're inside a skipped element, just count depth
        if skipDepth > 0 { skipDepth += 1; return }

        switch localName {
        // Skip the head element and its children
        case "head":
            skipDepth = 1

        // Book title → h1
        case "doctitle":
            ensureBlankLine()
            markdown += "# "

        // Book author → italic paragraph
        case "docauthor":
            ensureBlankLine()
            markdown += "*"

        // Headings — h1 inside level1 triggers chapter marker emission
        case "h1":
            ensureBlankLine()
            if level1Depth > 0 {
                pendingChapterTitle = true
                chapterTitleBuffer = ""
            }
            markdown += "# "
        case "h2": ensureBlankLine(); markdown += "## "
        case "h3": ensureBlankLine(); markdown += "### "
        case "h4": ensureBlankLine(); markdown += "#### "
        case "h5": ensureBlankLine(); markdown += "##### "
        case "h6": ensureBlankLine(); markdown += "###### "
        case "hd": ensureBlankLine(); markdown += "## "  // sidebar/note heading

        // Paragraphs
        case "p":
            ensureBlankLine()

        // Emphasis and strong
        case "em":
            isInEmphasis = true
            markdown += "*"
        case "strong":
            isInStrong = true
            markdown += "**"

        // Lists
        case "list":
            let listType = attributes["type"]?.lowercased() ?? "ul"
            let type = (listType == "ol") ? "ol" : "ul"
            listTypeStack.append(type)
            listCounterStack.append(0)
            listDepth += 1
            ensureNewline()

        case "li":
            let indent = String(repeating: "    ", count: max(0, listDepth - 1))
            if let currentType = listTypeStack.last {
                if currentType == "ol" {
                    let count = (listCounterStack.last ?? 0) + 1
                    if !listCounterStack.isEmpty {
                        listCounterStack[listCounterStack.count - 1] = count
                    }
                    markdown += "\(indent)\(count). "
                } else {
                    markdown += "\(indent)- "
                }
            } else {
                markdown += "- "
            }

        // Blockquote
        case "blockquote":
            ensureBlankLine()
            markdown += "> "

        // Links
        case "a":
            currentLinkHref = attributes["href"] ?? ""
            markdown += "["

        // Images
        case "img":
            let alt = attributes["alt"] ?? ""
            let src = attributes["src"] ?? ""
            markdown += "![" + alt + "](" + src + ")"

        // Line break
        case "br":
            markdown += "\n"

        // Horizontal rule
        case "hr":
            ensureBlankLine()
            markdown += "---\n"
            lastOutputWasBlock = true

        // Page numbers — emit as inline marker for navigation reference
        case "pagenum":
            ensureNewline()
            markdown += "[Page "

        // Table elements
        case "table":
            ensureBlankLine()
        case "tr":
            markdown += "| "
        case "th", "td":
            break // text will be captured

        // level1 containers — emit chapter markers so the cache service can
        // split the book into manageable chapters for SwiftUI rendering
        case "level1":
            level1Depth += 1

        // Structural containers — just pass through
        case "dtbook", "book", "frontmatter", "bodymatter", "rearmatter",
             "level2", "level3", "level4", "level5", "level6", "level",
             "div", "span", "sent", "w":
            break

        // Poetry
        case "poem":
            ensureBlankLine()
        case "line":
            ensureNewline()

        // Notes/sidebars — skip producer notes, keep user-facing content
        case "prodnote":
            skipDepth = 1

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        markdown += string
        // Capture heading text for chapter marker when inside level1 > h1
        if pendingChapterTitle {
            chapterTitleBuffer += string
        }
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastOutputWasBlock = false
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()

        // Handle skip depth tracking
        if skipDepth > 0 {
            skipDepth -= 1
            if !elementStack.isEmpty { elementStack.removeLast() }
            return
        }

        switch localName {
        case "doctitle":
            markdown += "\n\n"
            lastOutputWasBlock = true

        case "docauthor":
            markdown += "*\n\n"
            lastOutputWasBlock = true

        case "h1":
            // When closing an h1 inside level1, insert a chapter marker BEFORE
            // the heading we just emitted. We find the last "# " and prepend the marker.
            if pendingChapterTitle {
                let title = chapterTitleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    // Find where the "# " heading started and insert marker before it.
                    // The heading is the last "# " line in the markdown.
                    if let headingRange = markdown.range(of: "\n# ", options: .backwards) {
                        let insertPos = markdown.index(after: headingRange.lowerBound)
                        markdown.insert(contentsOf: "<!-- chapter: \(title) -->\n", at: insertPos)
                    } else if markdown.hasPrefix("# ") {
                        // Heading is at the very start
                        markdown.insert(contentsOf: "<!-- chapter: \(title) -->\n", at: markdown.startIndex)
                    }
                }
                pendingChapterTitle = false
                chapterTitleBuffer = ""
            }
            markdown += "\n\n"
            lastOutputWasBlock = true

        case "h2", "h3", "h4", "h5", "h6", "hd":
            markdown += "\n\n"
            lastOutputWasBlock = true

        case "level1":
            level1Depth = max(0, level1Depth - 1)

        case "p":
            markdown += "\n\n"
            lastOutputWasBlock = true

        case "em":
            markdown += "*"
            isInEmphasis = false

        case "strong":
            markdown += "**"
            isInStrong = false

        case "list":
            if !listTypeStack.isEmpty { listTypeStack.removeLast() }
            if !listCounterStack.isEmpty { listCounterStack.removeLast() }
            listDepth = max(0, listDepth - 1)
            ensureNewline()

        case "li":
            ensureNewline()

        case "pagenum":
            markdown += "]\n"

        case "blockquote":
            markdown += "\n\n"
            lastOutputWasBlock = true

        case "a":
            // Close link with href if available
            if !currentLinkHref.isEmpty {
                markdown += "](\(currentLinkHref))"
            } else {
                markdown += "]"
            }
            currentLinkHref = ""

        case "tr":
            markdown += "\n"

        case "th", "td":
            markdown += " | "

        case "line":
            markdown += "\n"

        case "poem":
            markdown += "\n\n"
            lastOutputWasBlock = true

        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    // MARK: - Helpers

    /// Ensure the output ends with at least one blank line (two newlines)
    private func ensureBlankLine() {
        if markdown.isEmpty { return }
        if !markdown.hasSuffix("\n\n") {
            if markdown.hasSuffix("\n") {
                markdown += "\n"
            } else {
                markdown += "\n\n"
            }
        }
        lastOutputWasBlock = true
    }

    /// Ensure the output ends with at least one newline
    private func ensureNewline() {
        if markdown.isEmpty { return }
        if !markdown.hasSuffix("\n") {
            markdown += "\n"
        }
    }

    /// Clean up excessive blank lines and trailing whitespace
    private func normalizeWhitespace(_ text: String) -> String {
        ParserUtilities.normalizeMarkdownWhitespace(text)
    }
}
