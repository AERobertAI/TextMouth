import Foundation

// MARK: - DOCX to Markdown Converter

/// Converts the XML content of word/document.xml into Markdown text.
/// Uses XMLParser (SAX-style) to walk through the document structure,
/// tracking paragraph styles, run formatting, and list context to emit
/// properly formatted Markdown.
class DOCXToMarkdownConverter: NSObject, XMLParserDelegate {
    private let styles: DOCXStyles
    private let numbering: DOCXNumbering
    private let relationships: [String: String]

    // Output accumulation
    private var markdown = ""

    // Element stack for tracking nesting context
    private var elementStack: [String] = []

    // Paragraph-level state (reset at each <w:p>)
    private var currentParagraphStyle = ""
    private var currentParagraphText = ""
    private var paragraphHasContent = false
    private var isInParagraph = false
    private var listNumId: String?
    private var listLevel: Int = 0

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

    // List counter tracking (for numbered lists).
    // Counters reset when a non-list paragraph interrupts a list sequence.
    private var listCounters: [String: [Int: Int]] = [:] // numId -> [level: count]
    private var previousParagraphWasList = false

    init(styles: DOCXStyles, numbering: DOCXNumbering, relationships: [String: String]) {
        self.styles = styles
        self.numbering = numbering
        self.relationships = relationships
    }

    /// Convert the document.xml content to Markdown
    func convert(xmlString: String) -> String {
        guard let data = xmlString.data(using: .utf8) else { return "" }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()

        // Clean up trailing whitespace and excessive blank lines
        return normalizeWhitespace(markdown)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        elementStack.append(localName)

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
            // an array index or a potentially enormous indentation allocation.
            if let val = attributes["w:val"], let level = Int(val) {
                listLevel = (0...8).contains(level) ? level : 0
            }
        case "numId":
            // List numbering definition ID
            let val = attributes["w:val"] ?? "0"
            if val != "0" {
                listNumId = val
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
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)

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

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
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

        // Reset all list counters when transitioning from list to non-list,
        // so that subsequent numbered lists restart at 1
        if !isListParagraph && previousParagraphWasList {
            listCounters.removeAll()
        }
        previousParagraphWasList = isListParagraph

        // Check if this paragraph is a heading
        if let headingLevel = styles.headingLevels[currentParagraphStyle] {
            let prefix = String(repeating: "#", count: headingLevel)
            markdown += "\n\(prefix) \(text)\n\n"
        }
        // Check if this paragraph is a list item (via numPr or list style)
        else if let numId = listNumId {
            let listType = numbering.listType(numId: numId, level: listLevel)
            let indent = String(repeating: "    ", count: listLevel)

            switch listType {
            case .bullet:
                markdown += "\(indent)- \(text)\n"
            case .numbered:
                // Track counter for this list
                var counter = listCounters[numId] ?? [:]
                let current = (counter[listLevel] ?? 0) + 1
                counter[listLevel] = current
                listCounters[numId] = counter
                markdown += "\(indent)\(current). \(text)\n"
            }
        }
        // Style-based list detection (e.g. "ListBullet", "ListNumber" styles)
        else if styles.bulletListStyles.contains(currentParagraphStyle) {
            markdown += "- \(text)\n"
        }
        else if styles.numberedListStyles.contains(currentParagraphStyle) {
            let key = "style-\(currentParagraphStyle)"
            var counter = listCounters[key] ?? [:]
            let current = (counter[0] ?? 0) + 1
            counter[0] = current
            listCounters[key] = counter
            markdown += "\(current). \(text)\n"
        }
        // Regular paragraph
        else {
            markdown += "\n\(text)\n"
        }

        isInParagraph = false
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
