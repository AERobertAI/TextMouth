import Foundation
import ZIPFoundation

// MARK: - Error Types

/// Errors that can occur when parsing a DOCX file
enum DOCXParserError: LocalizedError {
    case fileNotFound(String)
    case invalidArchive
    case missingDocumentXML
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "DOCX file not found at: \(path)"
        case .invalidArchive: return "The DOCX file could not be opened as a ZIP archive."
        case .missingDocumentXML: return "The DOCX file is missing word/document.xml."
        case .parseError(let msg): return "DOCX parse error: \(msg)"
        }
    }
}

// MARK: - DOCX Parser

/// Parses .docx files (Office Open XML) by extracting and converting the XML content
/// to Markdown. A .docx file is a ZIP archive containing XML files; the main content
/// lives in word/document.xml with styles defined in word/styles.xml and list
/// numbering in word/numbering.xml.
enum DOCXParser {

    /// Parse a DOCX file into DocumentContent for reading/playback
    static func parse(url: URL) throws -> DocumentContent {
        let markdown = try extractMarkdown(from: url)
        let title = url.deletingPathExtension().lastPathComponent
        let metadata = try? readMetadata(from: url)

        // Parse the generated Markdown using the shared Markdown parser
        let docTitle = metadata?.title ?? title
        let docAuthor = metadata?.author ?? "Unknown"

        let content = try MarkdownDocParser.parse(markdown: markdown, title: docTitle)
        return DocumentContent(
            title: docTitle,
            author: docAuthor,
            chapters: content.chapters
        )
    }

    /// Extract Markdown text from a DOCX file. This is the main conversion entry point
    /// used by MarkdownCacheService for generating the content.md cache.
    static func extractMarkdown(from url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DOCXParserError.fileNotFound(url.path)
        }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw DOCXParserError.invalidArchive
        }

        // Parse styles first so we can identify heading paragraph styles
        let styles = parseStyles(from: archive)

        // Parse numbering definitions for bullet and numbered lists
        let numbering = parseNumbering(from: archive)

        // Parse the main document content
        let documentXML = try extractData(from: archive, path: "word/document.xml")
        guard let xmlString = String(data: documentXML, encoding: .utf8) else {
            throw DOCXParserError.missingDocumentXML
        }

        // Parse relationships for hyperlink targets
        let relationships = parseRelationships(from: archive)

        let converter = DOCXToMarkdownConverter(
            styles: styles,
            numbering: numbering,
            relationships: relationships
        )
        return converter.convert(xmlString: xmlString)
    }

    /// Read basic metadata (title, author) from the DOCX core properties
    static func readMetadata(from url: URL) throws -> DOCXMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }

        // Core properties live in docProps/core.xml
        guard let coreData = try? extractData(from: archive, path: "docProps/core.xml"),
              let coreXML = String(data: coreData, encoding: .utf8) else {
            return nil
        }

        let parser = DOCXMetadataParser(xml: coreXML)
        return parser.parse()
    }

    // MARK: - ZIP Extraction Helpers

    /// Extract raw data from a ZIP archive entry
    private static func extractData(from archive: Archive, path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw DOCXParserError.missingDocumentXML
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return data
    }

    /// Extract and parse the styles.xml to build a map of style IDs to heading levels
    private static func parseStyles(from archive: Archive) -> DOCXStyles {
        guard let data = try? extractData(from: archive, path: "word/styles.xml"),
              let xml = String(data: data, encoding: .utf8) else {
            return DOCXStyles()
        }
        let parser = DOCXStylesParser(xml: xml)
        return parser.parse()
    }

    /// Extract and parse numbering.xml for list definitions
    private static func parseNumbering(from archive: Archive) -> DOCXNumbering {
        guard let data = try? extractData(from: archive, path: "word/numbering.xml"),
              let xml = String(data: data, encoding: .utf8) else {
            return DOCXNumbering()
        }
        let parser = DOCXNumberingParser(xml: xml)
        return parser.parse()
    }

    /// Extract and parse document relationships for hyperlink targets
    private static func parseRelationships(from archive: Archive) -> [String: String] {
        guard let data = try? extractData(from: archive, path: "word/_rels/document.xml.rels"),
              let xml = String(data: data, encoding: .utf8) else {
            return [:]
        }
        let parser = DOCXRelationshipsParser(xml: xml)
        return parser.parse()
    }
}

// MARK: - Metadata

/// Basic metadata extracted from docProps/core.xml
struct DOCXMetadata {
    var title: String
    var author: String
}

/// SAX parser for docProps/core.xml to extract title and author
private class DOCXMetadataParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var title = ""
    private var author = ""
    private var currentElement = ""
    private var currentText = ""

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> DOCXMetadata {
        guard let data = xml.data(using: .utf8) else {
            return DOCXMetadata(title: "", author: "")
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return DOCXMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // Strip namespace prefix (e.g. "dc:title" → "title", "cp:lastModifiedBy" → "lastModifiedBy")
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        switch localName {
        case "title":
            if title.isEmpty { title = currentText }
        case "creator":
            if author.isEmpty { author = currentText }
        default:
            break
        }
    }
}

// MARK: - Styles

/// Parsed style definitions mapping style IDs to their semantic roles
struct DOCXStyles {
    /// Maps style ID → heading level (1-6), empty if no heading styles found
    var headingLevels: [String: Int] = [:]

    /// Style IDs that represent bullet list paragraphs
    var bulletListStyles: Set<String> = []

    /// Style IDs that represent numbered list paragraphs
    var numberedListStyles: Set<String> = []
}

/// SAX parser for word/styles.xml to identify which style IDs correspond to headings
private class DOCXStylesParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var styles = DOCXStyles()

    // Tracking state during parsing
    private var currentStyleId = ""
    private var currentStyleName = ""
    private var inStyle = false
    private var currentOutlineLevel: Int?

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> DOCXStyles {
        guard let data = xml.data(using: .utf8) else { return styles }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return styles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "style":
            // Start of a style definition — capture its ID
            currentStyleId = attributes["w:styleId"] ?? ""
            currentStyleName = ""
            currentOutlineLevel = nil
            inStyle = true
        case "name" where inStyle:
            // The human-readable style name (e.g. "heading 1", "Heading 2")
            currentStyleName = attributes["w:val"] ?? ""
        case "outlineLvl" where inStyle:
            // Explicit outline level — most reliable indicator of heading level
            if let val = attributes["w:val"], let level = Int(val) {
                currentOutlineLevel = level + 1 // outline levels are 0-based
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        if localName == "style" && inStyle {
            // Determine if this style is a heading
            let headingLevel = resolveHeadingLevel()
            if let level = headingLevel, level >= 1 && level <= 6 {
                styles.headingLevels[currentStyleId] = level
            }

            // Detect list styles by name pattern (e.g. "ListBullet", "List Number")
            let nameLower = currentStyleName.lowercased()
            let idLower = currentStyleId.lowercased()
            if nameLower.contains("list bullet") || idLower.contains("listbullet") {
                styles.bulletListStyles.insert(currentStyleId)
            } else if nameLower.contains("list number") || idLower.contains("listnumber") {
                styles.numberedListStyles.insert(currentStyleId)
            }

            inStyle = false
        }
    }

    /// Determine heading level from style name and/or outline level
    private func resolveHeadingLevel() -> Int? {
        // Prefer explicit outline level
        if let level = currentOutlineLevel {
            return min(level, 6)
        }

        // Fall back to style name pattern matching (works for "heading 1", "Heading1", etc.)
        let nameLower = currentStyleName.lowercased()
        if nameLower.hasPrefix("heading") {
            let rest = nameLower.dropFirst("heading".count)
                .trimmingCharacters(in: .whitespaces)
            if let level = Int(rest) {
                return min(level, 6)
            }
        }

        // Check style ID as last resort (Word uses "Heading1", "Heading2", etc.)
        let idLower = currentStyleId.lowercased()
        if idLower.hasPrefix("heading") {
            let rest = idLower.dropFirst("heading".count)
            if let level = Int(rest) {
                return min(level, 6)
            }
        }

        // "Title" style maps to heading level 1
        if nameLower == "title" || idLower == "title" {
            return 1
        }

        // "Subtitle" maps to heading level 2
        if nameLower == "subtitle" || idLower == "subtitle" {
            return 2
        }

        return nil
    }
}

// MARK: - Numbering

/// Parsed numbering definitions for bullet and numbered lists
struct DOCXNumbering {
    /// Maps abstract numbering ID → array of level formats.
    /// Each level has a format type (bullet, decimal, etc.)
    var abstractNums: [String: [ListLevelFormat]] = [:]

    /// Maps numbering ID (numId) → abstract numbering ID
    var numIdToAbstractId: [String: String] = [:]

    /// Determine whether a given numId + indent level is a bullet or numbered list
    func listType(numId: String, level: Int) -> ListType {
        guard let abstractId = numIdToAbstractId[numId],
              let levels = abstractNums[abstractId],
              level < levels.count else {
            return .bullet // default to bullet if we can't determine
        }
        return levels[level].listType
    }
}

/// Format information for a single list level
struct ListLevelFormat {
    var numFmt: String // "bullet", "decimal", "lowerLetter", etc.

    var listType: ListType {
        numFmt == "bullet" ? .bullet : .numbered
    }
}

/// Whether a list item is bulleted or numbered
enum ListType {
    case bullet
    case numbered
}

/// SAX parser for word/numbering.xml
private class DOCXNumberingParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var numbering = DOCXNumbering()

    // Parsing state
    private var currentAbstractNumId = ""
    private var inAbstractNum = false
    private var currentLevels: [ListLevelFormat] = []
    // Track the current <w:num> element's numId so we can link it to abstractNumId
    private var currentNumId: String?
    private var inNum = false

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> DOCXNumbering {
        guard let data = xml.data(using: .utf8) else { return numbering }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return numbering
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "abstractNum":
            currentAbstractNumId = attributes["w:abstractNumId"] ?? ""
            currentLevels = []
            inAbstractNum = true
        case "lvl" where inAbstractNum:
            // Each level definition — we'll fill in the format when we see numFmt
            break
        case "numFmt" where inAbstractNum:
            let fmt = attributes["w:val"] ?? "bullet"
            currentLevels.append(ListLevelFormat(numFmt: fmt))
        case "num":
            // Start of a <w:num> element — track its numId
            currentNumId = attributes["w:numId"]
            inNum = true
        case "abstractNumId" where inNum:
            // Inside a <w:num>, links numId to its abstract numbering definition
            if let val = attributes["w:val"], let numId = currentNumId {
                numbering.numIdToAbstractId[numId] = val
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "abstractNum" && inAbstractNum {
            numbering.abstractNums[currentAbstractNumId] = currentLevels
            inAbstractNum = false
        } else if localName == "num" && inNum {
            inNum = false
            currentNumId = nil
        }
    }
}

// MARK: - Relationships

/// SAX parser for word/_rels/document.xml.rels to extract hyperlink targets
private class DOCXRelationshipsParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var relationships: [String: String] = [:]

    init(xml: String) {
        self.xml = xml
    }

    func parse() -> [String: String] {
        guard let data = xml.data(using: .utf8) else { return relationships }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return relationships
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "Relationship" {
            if let id = attributes["Id"], let target = attributes["Target"] {
                relationships[id] = target
            }
        }
    }
}

// MARK: - DOCX to Markdown Converter

/// Converts the XML content of word/document.xml into Markdown text.
/// Uses XMLParser (SAX-style) to walk through the document structure,
/// tracking paragraph styles, run formatting, and list context to emit
/// properly formatted Markdown.
private class DOCXToMarkdownConverter: NSObject, XMLParserDelegate {
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

    // List counter tracking (for numbered lists)
    private var listCounters: [String: [Int: Int]] = [:] // numId → [level: count]

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
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        elementStack.append(localName)

        switch localName {
        case "p":
            // Start of a paragraph — reset paragraph state
            startParagraph()
        case "pPr":
            // Paragraph properties container — handled via child elements
            break
        case "pStyle":
            // Paragraph style reference (e.g. "Heading1", "ListParagraph")
            currentParagraphStyle = attributes["w:val"] ?? ""
        case "numPr":
            // List numbering properties — handled via child elements
            break
        case "ilvl":
            // List indent level (0-based)
            if let val = attributes["w:val"], let level = Int(val) {
                listLevel = level
            }
        case "numId":
            // List numbering definition ID
            let val = attributes["w:val"] ?? "0"
            if val != "0" {
                listNumId = val
            }
        case "r":
            // Start of a text run — reset run formatting state
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
        case "br":
            // Line break within a paragraph
            currentParagraphText += "\n"
        case "hyperlink":
            // Start of a hyperlink — capture the relationship ID for the URL
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
            if isInHyperlink {
                hyperlinkText += string
            }
            runText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "r":
            // End of a text run — apply formatting and append to paragraph text
            endRun()
        case "p":
            // End of a paragraph — emit the accumulated text with proper formatting
            endParagraph()
        case "hyperlink":
            // End of hyperlink — emit Markdown link
            endHyperlink()
        case "tbl":
            // End of table — emit as Markdown table
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

        currentParagraphText += formatted
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
            currentParagraphText += "[\(text)](\(target))"
        } else {
            // No URL found — just emit the text
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
        var lines = text.components(separatedBy: "\n")

        // Trim trailing whitespace from each line
        lines = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // Collapse 3+ consecutive blank lines to 2
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 {
                    result.append(line)
                }
            } else {
                blankCount = 0
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
