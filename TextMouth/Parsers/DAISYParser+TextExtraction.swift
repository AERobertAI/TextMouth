import Foundation

// MARK: - DTBook XML → Markdown Converter

/// Markdown converted from one DTBook file.
struct DTBookConversion {
    /// The book text: everything read from the file, up to any damage.
    let markdown: String
    /// Set when the file broke off or stopped being well-formed after some
    /// of its text had been read. That text is kept in `markdown`; this
    /// describes the damage so callers can report the file as incomplete.
    /// It never becomes part of the text.
    let diagnostic: DAISYParserError?
    /// How many pages the book has had up to the end of this file: the pages
    /// the converter was told came before it, and the ones it wrote. The next
    /// file of the book begins its ordinals after this one.
    let pagesRead: Int
}

/// Converts DTBook XML (DAISY 3 text content) to Markdown.
/// Uses SAX parsing to walk the DTBook element tree and emit Markdown output.
class DTBookToMarkdownConverter: DAISYSAXParser {
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

    /// How many tables enclose the text being read. Text inside a table is
    /// written as the table's paragraphs hold it (see `tableText(_:)`).
    private var tableDepth = 0

    /// Whether any readable character data has been written. Damage after
    /// this point leaves text worth keeping; damage before it leaves none.
    private var producedText = false

    // MARK: Pages (PG08)

    /// Whether a `pagenum` becomes a page marker (`<!-- page: N -->`, never
    /// read) instead of the "[Page N]" line that cache format 3.0.7 wrote.
    private let includesPages: Bool

    /// How deep inside a `pagenum` the reading is: 0 outside one, 1 inside
    /// it, more inside elements it holds. Everything inside goes to the label.
    private var pageLabelDepth = 0

    /// The text of the `pagenum` being read: the page's label. It is never
    /// written to the Markdown while pages are included.
    private var pageLabel = ""

    /// How many `pagenum` elements the book has had up to now: those of the
    /// files before this one (`pagesBefore`) and those this converter has
    /// finished reading. The next one's ordinal, the label of one that holds
    /// no words, is this plus one.
    private var pagesRead: Int

    /// Whether the next text loses the whitespace it begins with: set after a
    /// marker written inside running text, which has already kept the words
    /// on either side apart (see `writePageMarker()`).
    private var dropsLeadingSpace = false

    /// Where the last page marker went, for a run of them after a line break
    /// (`MarkdownMarkerWriter.RunMemo`): each is placed at the end of the line
    /// before, which a line of megabytes made slow for every one.
    private var markerRun = MarkdownMarkerWriter.RunMemo()

    /// How many parser events (elements started and ended, and runs of text)
    /// have been heard, to ask now and then whether the import was cancelled.
    private var eventsRead = 0

    /// Whether the import running this conversion was cancelled, so the parse
    /// was stopped for it.
    private var wasCancelled = false

    /// How many events pass between asks. A page marker after a line of
    /// megabytes can take milliseconds, so the ask is often.
    private static let eventsBetweenCancellationChecks = 256

    /// Prepare to convert `data`, reporting problems under the name `file`.
    /// With `includesPages` false the Markdown is what it was before pages.
    /// A book of several files numbers its pages through all of them: `pagesBefore`
    /// is how many pages the files before this one had, so that a page here
    /// with no words is labelled by its place in the whole book, not in this file.
    init(data: Data, file: String, includesPages: Bool = true, pagesBefore: Int = 0) {
        self.includesPages = includesPages
        self.pagesRead = pagesBefore
        super.init(data: data, file: file)
    }

    /// Read `path` from `provider` and prepare to convert it under that name.
    /// - Throws: the provider's error when the file cannot be read.
    convenience init(path: String, in provider: DAISYFileProvider, includesPages: Bool = true, pagesBefore: Int = 0) throws {
        self.init(data: try provider.readFile(at: path), file: path, includesPages: includesPages, pagesBefore: pagesBefore)
    }

    /// Convert the file to Markdown.
    ///
    /// When the file breaks off or becomes malformed after some of its text
    /// was read, that text is kept: a book missing its last pages is more
    /// use read than refused. Elements still open at the damage are closed
    /// as though the file ended there, so no stray `*`, `[`, or `[Page`
    /// reaches speech, and the damage is returned as the diagnostic.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   damaged before any text.
    func convert() throws -> DTBookConversion {
        do {
            try parseDocument()
            return DTBookConversion(markdown: normalizeWhitespace(markdown), diagnostic: nil, pagesRead: pagesRead)
        } catch where wasCancelled {
            // The import was cancelled and the parse stopped for it.
            throw ImportCancelled()
        } catch let damage as DAISYParserError where producedText {
            closeOpenElements()
            return DTBookConversion(markdown: normalizeWhitespace(markdown), diagnostic: damage, pagesRead: pagesRead)
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if stopIfCancelled(parser) { return }
        let localName = ParserUtilities.stripNamespacePrefix(elementName).lowercased()
        elementStack.append(localName)

        // If we're inside a skipped element, just count depth
        if skipDepth > 0 { skipDepth += 1; return }

        // Inside a page number only its words matter: they name the page.
        if pageLabelDepth > 0 { pageLabelDepth += 1; return }
        dropsLeadingSpace = false

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

        // Headings
        case "h1": ensureBlankLine(); markdown += "# "
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

        // Page numbers: a page marker named by the element's words (its end
        // tag writes it), or, without pages, "[Page N]" on a line of its own.
        case "pagenum":
            if includesPages {
                pageLabelDepth = 1
                pageLabel = ""
            } else {
                ensureNewline()
                markdown += "[Page "
            }

        // Tables read as HTML tables are read (TODO T03), with no Markdown
        // table syntax: each row is a paragraph of its own, and each cell
        // at least a word of its own, so two cells' words never run
        // together. A caption, which comes before the rows, is therefore a
        // paragraph of its own too, and a table in a cell is a block between
        // the words of the row holding it. The end tags write the same
        // boundaries (`endElement(_:)`).
        case "table":
            ensureBlankLine()
            tableDepth += 1
        case "tr":
            ensureBlankLine()
        case "th", "td":
            separateWords()

        // Structural containers — just pass through
        case "dtbook", "book", "frontmatter", "bodymatter", "rearmatter",
             "level1", "level2", "level3", "level4", "level5", "level6", "level",
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
        if pageLabelDepth > 0 {
            pageLabel += string
            return
        }
        var text = string
        if dropsLeadingSpace {
            // A marker written inline already keeps the words around it apart,
            // so the whitespace the source put after the page number would
            // double the space. Whitespace alone leaves the flag set.
            text = String(text.drop(while: { $0.isWhitespace }))
            guard !text.isEmpty else { return }
            dropsLeadingSpace = false
        }
        markdown += tableDepth > 0 ? tableText(text) : text
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastOutputWasBlock = false
            producedText = true
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if stopIfCancelled(parser) { return }
        endElement(ParserUtilities.stripNamespacePrefix(elementName).lowercased())
    }

    /// Close every element the damage left open, innermost first, exactly as
    /// their end tags would have: emphasis, links, and page markers are
    /// finished rather than left dangling in the text.
    private func closeOpenElements() {
        while let innermost = elementStack.last {
            endElement(innermost)
        }
    }

    /// Emit the Markdown that ends the element named `localName` (a lowercase
    /// name without prefix) and pop it from the element stack.
    private func endElement(_ localName: String) {
        // Handle skip depth tracking
        if skipDepth > 0 {
            skipDepth -= 1
            if !elementStack.isEmpty { elementStack.removeLast() }
            return
        }

        // An element inside a page number ends without writing anything.
        if pageLabelDepth > 1 {
            pageLabelDepth -= 1
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

        case "h1", "h2", "h3", "h4", "h5", "h6", "hd":
            markdown += "\n\n"
            lastOutputWasBlock = true

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
            if includesPages {
                writePageMarker()
            } else {
                markdown += "]\n"
            }

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

        // A table, and each of its rows, ends its paragraph; a cell's words
        // stay apart from whatever follows them in the row.
        case "table":
            tableDepth = max(0, tableDepth - 1)
            ensureBlankLine()

        case "tr":
            ensureBlankLine()

        case "th", "td":
            separateWords()

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

    // MARK: - Pages (PG08)

    /// Write the page marker for the `pagenum` that just ended, labelled by
    /// the words it held (or its ordinal when it held none), and leave the
    /// page number itself unwritten.
    ///
    /// At a block boundary (nothing yet, or the Markdown ends with a line
    /// break) the marker is a block of its own, which names the same place as
    /// the block after it. Anywhere else the shared writer places it
    /// (`MarkdownMarkerWriter.write`): inline in running text, with a space
    /// first when none is there, so "before<pagenum>12</pagenum>after" reads
    /// "before after"; at the opening of a list item, quote, or heading
    /// (`- `, `3. `, `> `, `## `), even with the source's whitespace after
    /// it, inside it before its words; after a line break, at the end of the
    /// line before. A marker written after an opening would make an HTML
    /// block of the item's whole first line.
    private func writePageMarker() {
        pagesRead += 1
        let marker = MarkdownPageMarker(label: pageLabel, ordinal: pagesRead).markdown
        pageLabel = ""
        pageLabelDepth = 0

        let atBlockBoundary = markdown.unicodeScalars.last.map { $0 == "\n" } ?? true
        MarkdownMarkerWriter.write(
            marker, inline: !atBlockBoundary, keepingWordsApart: true, remembering: &markerRun, into: &markdown)
        dropsLeadingSpace = !atBlockBoundary
    }

    /// Counts the event and, every `eventsBetweenCancellationChecks`, ends the
    /// parse if the import running on this thread was cancelled (as the DOCX
    /// converter does), so `convert()` throws `ImportCancelled`. A conversion
    /// outside an import is never stopped. True when the parse was stopped.
    private func stopIfCancelled(_ parser: XMLParser) -> Bool {
        eventsRead += 1
        guard eventsRead % Self.eventsBetweenCancellationChecks == 0,
              ImportCancellation.current?.isCancelled == true else { return wasCancelled }
        wasCancelled = true
        parser.abortParsing()
        return true
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

    /// Whether the next text begins a word: at the start of the Markdown, of
    /// a line, or after a space. Unicode scalars decide, since a combining
    /// mark after a space makes one `Character` with it.
    private var isAtWordStart: Bool {
        guard let last = markdown.unicodeScalars.last else { return true }
        return last == " " || last == "\n"
    }

    /// Keep the words on either side of a table cell's edge apart, with a
    /// space unless one is already there: so an empty cell adds no doubled
    /// space, and a row's first cell no space before its words.
    private func separateWords() {
        if !isAtWordStart {
            markdown += " "
        }
    }

    /// `text` from inside a table, as the table's paragraphs hold it. Each
    /// run of whitespace is one space, as HTML reads a table's text, and
    /// none is written where a word begins, so the line breaks and
    /// indentation a file puts between its rows and cells never split a
    /// row or double a space. Every character is written as a Markdown
    /// literal (`MarkdownLiteral`): a row begins its own line, where words
    /// such as "# of copies" or "1. Introduction" would otherwise be read
    /// as a heading or a list.
    private func tableText(_ text: String) -> String {
        var words = HTMLReadingText.collapsingWhitespace(text)
        if words.unicodeScalars.first == " ", isAtWordStart {
            words.unicodeScalars.removeFirst()
        }
        return MarkdownLiteral.escaped(words)
    }

    /// Clean up excessive blank lines and trailing whitespace
    private func normalizeWhitespace(_ text: String) -> String {
        ParserUtilities.normalizeMarkdownWhitespace(text)
    }
}
