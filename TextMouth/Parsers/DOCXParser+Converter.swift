import Foundation

// MARK: - DOCX to Markdown Converter

/// Markdown converted from a document's text part.
struct DOCXConversion {
    /// The document text: everything read from the part, up to any damage.
    let markdown: String
    /// Set when the part broke off or stopped being well-formed after some
    /// of its text had been read. That text is kept in `markdown`; this
    /// describes the damage so callers can report the document as
    /// incomplete. It never becomes part of the text.
    let diagnostic: DOCXParserError?
}

/// Converts the XML content of word/document.xml into Markdown text.
/// Uses XMLParser (SAX-style) to walk through the document structure,
/// tracking paragraph styles, run formatting, and list context to emit
/// properly formatted Markdown.
class DOCXToMarkdownConverter: DOCXSAXParser {
    private let styles: DOCXStyles
    private let relationships: [String: String]

    // Output accumulation
    private var markdown = ""

    // Element stack for tracking nesting context
    private var elementStack: [String] = []

    /// How many records of tracked formatting changes (`w:pPrChange`,
    /// `w:rPrChange`, and the like) enclose the element being read. Inside
    /// one, properties are the formatting from before the change.
    private var trackedChangeDepth = 0

    // Paragraph-level state (reset at each <w:p>)
    private var currentParagraphStyle = ""
    private var currentParagraphText = ""
    private var paragraphHasContent = false
    private var isInParagraph = false
    private var listNumId: String?
    private var listLevel: Int = 0
    /// The paragraph's own outline level (`w:outlineLvl` in its
    /// properties), which wins over its style's heading level.
    private var paragraphOutlineLevel: DOCXOutlineLevel?

    // Run-level state (reset at each <w:r>)
    private var isInRun = false
    private var runIsBold = false
    private var runIsItalic = false
    private var runIsStrikethrough = false
    private var runText = ""

    // Hyperlink state
    private var isInHyperlink = false
    private var hyperlinkRelId = ""
    private var hyperlinkText = ""

    // Table state
    private var isInTable = false
    private var isInTableRow = false
    private var isInTableCell = false
    private var tableRows: [[String]] = []
    private var currentRowCells: [String] = []
    private var currentCellText = ""

    /// Numbers the list paragraphs from the package's list definitions.
    /// Its counts start again when a non-list paragraph interrupts a list.
    private var listCounter: DOCXListCounter
    private var previousParagraphWasList = false

    /// The list items open in the Markdown list being written, outermost
    /// first. A heading, paragraph, or table ends the list and empties it.
    private var openListItems: [OpenListItem] = []

    /// Whether any readable text has been read. Damage after this point
    /// leaves text worth keeping; damage before it leaves none.
    private var producedText = false

    /// Prepare to convert the text part `data`, read from `file`, with the
    /// package's paragraph styles, list numbering, and hyperlink targets.
    init(
        data: Data,
        file: String = DOCXParser.Part.document,
        styles: DOCXStyles,
        numbering: DOCXNumbering,
        relationships: [String: String]
    ) {
        self.styles = styles
        self.listCounter = DOCXListCounter(numbering: numbering)
        self.relationships = relationships
        super.init(data: data, file: file)
    }

    /// Convert the part to Markdown.
    ///
    /// When the part breaks off or becomes malformed after some of its text
    /// was read, that text is kept: a document missing its last pages is
    /// more use read than refused. Elements still open at the damage are
    /// closed as though the part ended there, so the paragraph, link, or
    /// table in progress is written out with its emphasis and link syntax
    /// complete, none of it read aloud as symbols, and the damage is
    /// returned as the diagnostic.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   damaged before any text.
    func convert() throws -> DOCXConversion {
        do {
            try parseDocument()
            return DOCXConversion(markdown: normalizeWhitespace(markdown), diagnostic: nil)
        } catch let damage as DOCXParserError where producedText {
            closeOpenElements()
            return DOCXConversion(markdown: normalizeWhitespace(markdown), diagnostic: damage)
        }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        elementStack.append(localName)

        // Formatting from before a tracked change says nothing about the
        // text as it now stands: read as current, it would undo the change.
        if Self.recordsTrackedChange(localName) {
            trackedChangeDepth += 1
        }
        guard trackedChangeDepth == 0 else { return }

        switch localName {
        case "p":
            // Start of a paragraph -- reset paragraph state
            startParagraph()
        case "pPr":
            // Paragraph properties container -- handled via child elements
            break
        case "pStyle":
            // Paragraph style reference (e.g. "Heading1", "ListParagraph")
            currentParagraphStyle = attributes["w:val"] ?? ""
        case "numPr":
            // List numbering properties -- handled via child elements
            break
        case "ilvl":
            // Word lists support nine levels. Malformed values must not reach
            // a level lookup or a potentially enormous indentation allocation.
            if let val = attributes["w:val"], let level = Int(val) {
                listLevel = DOCXNumbering.levelIndexes.contains(level) ? level : 0
            }
        case "numId":
            // List numbering definition ID
            let val = attributes["w:val"] ?? "0"
            if val != "0" {
                listNumId = val
            }
        case "outlineLvl":
            // The paragraph's own outline level: a heading level, or body text
            if let outline = DOCXOutlineLevel(attributes["w:val"]) {
                paragraphOutlineLevel = outline
            }
        case "r":
            // Start of a text run -- reset run formatting state
            startRun()
        case "rPr":
            // Run properties container
            break
        case "b" where isInRun:
            // Bold formatting. Check for w:val="0" which means explicitly NOT bold.
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" {
                runIsBold = true
            }
        case "i" where isInRun:
            // Italic formatting
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" {
                runIsItalic = true
            }
        case "strike" where isInRun:
            // Strikethrough
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" {
                runIsStrikethrough = true
            }
        case "br" where isInRun:
            // Keep breaks in their run; the paragraph has not received the
            // preceding run text yet, so appending there reverses their order.
            runText += "\n"
        case "tab" where isInRun:
            runText += "\t"
        case "hyperlink":
            // Start of a hyperlink -- capture the relationship ID for the URL
            isInHyperlink = true
            hyperlinkRelId = attributes["r:id"] ?? ""
            hyperlinkText = ""
        case "tbl":
            // Start of a table
            isInTable = true
            tableRows = []
        case "tr":
            // Table row
            isInTableRow = true
            currentRowCells = []
        case "tc":
            // Table cell
            isInTableCell = true
            currentCellText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Only capture text inside <w:t> elements (handled by element context)
        if let lastElement = elementStack.last, lastElement == "t" {
            runText += string
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                producedText = true
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        endElement(ParserUtilities.stripNamespacePrefix(elementName))
    }

    /// Close every element the damage left open, innermost first, exactly as
    /// their end tags would have: the run, any link, the paragraph, and any
    /// table around it are finished and written out.
    ///
    /// The run in progress first loses the whitespace at its cut end. That
    /// whitespace separated the last word read from one that never arrived,
    /// and before a closing `**` it would stop the emphasis from closing, so
    /// the asterisks would be read aloud.
    private func closeOpenElements() {
        if isInRun {
            while runText.last?.isWhitespace == true {
                runText.removeLast()
            }
        }
        while let innermost = elementStack.last {
            endElement(innermost)
        }
    }

    /// Emit the Markdown that ends the element named `localName` (without
    /// its namespace prefix) and pop it from the element stack.
    private func endElement(_ localName: String) {
        defer {
            if !elementStack.isEmpty {
                elementStack.removeLast()
            }
        }

        // Inside a tracked change's record nothing started as content, so
        // nothing ends as content either; only the record itself closes.
        if trackedChangeDepth > 0 {
            if Self.recordsTrackedChange(localName) {
                trackedChangeDepth -= 1
            }
            return
        }

        switch localName {
        case "r":
            // End of a text run -- apply formatting and append to paragraph text
            endRun()
        case "p":
            // End of a paragraph -- emit the accumulated text with proper formatting
            endParagraph()
        case "hyperlink":
            // End of hyperlink -- emit Markdown link
            endHyperlink()
        case "tbl":
            // End of table -- emit as Markdown table
            endTable()
        case "tr":
            // End of table row
            if isInTableRow {
                tableRows.append(currentRowCells)
                isInTableRow = false
            }
        case "tc":
            // End of table cell
            if isInTableCell {
                currentRowCells.append(currentCellText.trimmingCharacters(in: .whitespacesAndNewlines))
                isInTableCell = false
            }
        default:
            break
        }
    }

    /// Whether the element named `localName` records a tracked formatting
    /// change: `w:pPrChange`, `w:rPrChange`, `w:sectPrChange`, the table
    /// property changes, and `w:numberingChange`. Each holds the properties
    /// as they were before the change, and never any text.
    private static func recordsTrackedChange(_ localName: String) -> Bool {
        localName.hasSuffix("Change")
    }

    // MARK: - Paragraph Processing

    /// Reset state for a new paragraph
    private func startParagraph() {
        isInParagraph = true
        currentParagraphStyle = ""
        currentParagraphText = ""
        paragraphHasContent = false
        listNumId = nil
        listLevel = 0
        paragraphOutlineLevel = nil
    }

    /// The heading level of the paragraph being read: its own outline
    /// level when it declares one, which wins over its style's as direct
    /// formatting does in Word, so a paragraph marked as body text is no
    /// heading whatever its style; otherwise its style's heading level.
    private var paragraphHeadingLevel: Int? {
        if let paragraphOutlineLevel {
            return paragraphOutlineLevel.headingLevel
        }
        return styles.headingLevels[currentParagraphStyle]
    }

    /// Emit the completed paragraph as Markdown
    private func endParagraph() {
        let text = currentParagraphText.trimmingCharacters(in: .whitespaces)

        // If we're inside a table cell, append to cell text instead of main output
        if isInTableCell {
            if !currentCellText.isEmpty && !text.isEmpty {
                currentCellText += " "
            }
            currentCellText += text
            isInParagraph = false
            return
        }

        // Handle empty paragraphs (just add a blank line)
        guard !text.isEmpty else {
            markdown += "\n"
            isInParagraph = false
            return
        }

        // Determine if this paragraph is a list item
        let isListParagraph = listNumId != nil
            || styles.bulletListStyles.contains(currentParagraphStyle)
            || styles.numberedListStyles.contains(currentParagraphStyle)

        // TextMouth's policy for a list interrupted by other text: every
        // list starts again from its start value afterwards. (Word would
        // continue the list's count; DOCXEdgeCaseTests pins this policy.)
        if !isListParagraph && previousParagraphWasList {
            listCounter.restartAll()
        }
        previousParagraphWasList = isListParagraph

        // Check if this paragraph is a heading
        if let headingLevel = paragraphHeadingLevel {
            let prefix = String(repeating: "#", count: headingLevel)
            openListItems.removeAll()
            markdown += "\n\(prefix) \(text)\n\n"
        }
        // Check if this paragraph is a list item (via numPr or list style)
        else if let numId = listNumId {
            writeListItem(text, level: listLevel, marker: listCounter.marker(numId: numId, level: listLevel))
        }
        // Style-based list detection (e.g. "ListBullet", "ListNumber" styles)
        else if styles.bulletListStyles.contains(currentParagraphStyle) {
            writeListItem(text, level: 0, marker: .bullet)
        }
        else if styles.numberedListStyles.contains(currentParagraphStyle) {
            writeListItem(text, level: 0, marker: listCounter.marker(numberedStyle: currentParagraphStyle))
        }
        // Regular paragraph
        else {
            openListItems.removeAll()
            markdown += "\n\(text)\n"
        }

        isInParagraph = false
    }

    // MARK: - List Items

    /// A list item open in the Markdown being written: the items after it
    /// nest inside it or continue its list.
    private struct OpenListItem {
        /// The level (`w:ilvl`) of the paragraph it holds.
        let level: Int
        /// The spaces before its marker.
        let indent: Int
        /// The column where its text begins, which a nested item must reach.
        let contentColumn: Int
        /// Whether it is numbered: an item at its depth continues its
        /// Markdown list only when the two are both numbered or both bulleted.
        let isNumbered: Bool
    }

    /// Write a list item reading `text` at list level `level` after `marker`.
    ///
    /// The item nests one step inside the nearest open item of a shallower
    /// level, so a list that skips a level (an item at level 2 straight
    /// after one at level 0), or begins below level 0, still reads as a list
    /// rather than drifting far enough right to become a code block or a line
    /// of the paragraph above, whose words would then include its bullet or
    /// number. It is indented four spaces past its parent's marker, or to
    /// the parent's text when that marker is wider, which keeps it inside
    /// the parent's text (CommonMark §5.2).
    ///
    /// A numbered item that begins a new list at a number other than 1 is
    /// written after a blank line: CommonMark lets only a list starting at 1
    /// interrupt a paragraph, so otherwise its number would be read aloud as
    /// words of the paragraph before it.
    private func writeListItem(_ text: String, level: Int, marker: DOCXListMarker) {
        // Items at this level or deeper are finished. The last of them to
        // close stood at this item's depth, in the list this item continues
        // when both are numbered or both bulleted.
        var previousAtDepth: OpenListItem?
        while let innermost = openListItems.last, innermost.level >= level {
            previousAtDepth = openListItems.removeLast()
        }
        let parent = openListItems.last
        let indent = parent.map { max($0.indent + 4, $0.contentColumn) } ?? 0

        let markerText: String
        switch marker {
        case .bullet:
            markerText = "- "
        case .number(let number):
            markerText = "\(number). "
            if number != 1 && previousAtDepth?.isNumbered != true {
                ensureBlankLine()
            }
        }
        markdown += String(repeating: " ", count: indent) + markerText + text + "\n"
        openListItems.append(OpenListItem(
            level: level,
            indent: indent,
            contentColumn: indent + markerText.count,
            isNumbered: marker != .bullet
        ))
    }

    /// End the Markdown with a blank line, so the next block cannot be read
    /// as part of the block before it. Nothing is written at the start, or
    /// when the Markdown already ends with a blank line. Unicode scalars
    /// decide, because a carriage return before a line feed forms a single
    /// Character that a Character comparison with "\n" would not match.
    private func ensureBlankLine() {
        guard !markdown.isEmpty else { return }
        let ending = markdown.unicodeScalars.suffix(2)
        guard !ending.elementsEqual(["\n", "\n"]) else { return }
        markdown += ending.last == "\n" ? "\n" : "\n\n"
    }

    // MARK: - Run Processing

    /// Reset state for a new text run
    private func startRun() {
        isInRun = true
        runIsBold = false
        runIsItalic = false
        runIsStrikethrough = false
        runText = ""
    }

    /// Apply formatting to the run text and append to paragraph
    private func endRun() {
        guard isInRun else { return }
        isInRun = false

        let text = runText
        guard !text.isEmpty else { return }

        var formatted = text

        // Apply inline formatting markers.
        // Order matters: strikethrough wraps emphasis wraps bold.
        if runIsBold && runIsItalic {
            formatted = "***\(formatted)***"
        } else if runIsBold {
            formatted = "**\(formatted)**"
        } else if runIsItalic {
            formatted = "*\(formatted)*"
        }

        if runIsStrikethrough {
            formatted = "~~\(formatted)~~"
        }

        // Hyperlink runs belong to the link label until </w:hyperlink> emits
        // it once. Appending here and at link end duplicates the spoken text.
        if isInHyperlink {
            hyperlinkText += formatted
        } else {
            currentParagraphText += formatted
        }
        paragraphHasContent = true
    }

    // MARK: - Hyperlink Processing

    /// Emit a completed hyperlink as Markdown
    private func endHyperlink() {
        guard isInHyperlink else { return }
        isInHyperlink = false

        let text = hyperlinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let target = relationships[hyperlinkRelId], !target.isEmpty {
            // Escape parentheses in URLs to avoid breaking markdown link syntax
            let escapedTarget = target
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            currentParagraphText += "[\(text)](\(escapedTarget))"
        } else {
            // No URL found -- just emit the text
            currentParagraphText += text
        }
        paragraphHasContent = true
    }

    // MARK: - Table Processing

    /// Emit a completed table as a Markdown table
    private func endTable() {
        isInTable = false

        guard !tableRows.isEmpty else { return }

        // Determine column count from the widest row
        let colCount = tableRows.map { $0.count }.max() ?? 0
        guard colCount > 0 else { return }

        // The table ends any list before it.
        openListItems.removeAll()
        markdown += "\n"

        for (rowIndex, row) in tableRows.enumerated() {
            // Pad rows to consistent column count
            var cells = row
            while cells.count < colCount {
                cells.append("")
            }

            markdown += "| " + cells.joined(separator: " | ") + " |\n"

            // Add header separator after first row
            if rowIndex == 0 {
                let separator = cells.map { _ in "---" }.joined(separator: " | ")
                markdown += "| \(separator) |\n"
            }
        }

        markdown += "\n"
    }

    // MARK: - Whitespace Normalization

    /// Clean up the generated Markdown: collapse excessive blank lines,
    /// trim trailing whitespace from lines
    private func normalizeWhitespace(_ text: String) -> String {
        ParserUtilities.normalizeMarkdownWhitespace(text)
    }
}
