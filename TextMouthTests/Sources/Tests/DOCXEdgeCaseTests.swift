import Foundation
import ZIPFoundation

#if canImport(TextMouth)
@testable import TextMouth

private func legacyListLevel(_ format: String) -> ListLevelFormat {
    ListLevelFormat(numFmt: format)
}
#else
private func legacyListLevel(_ format: String) -> String { format }
#endif

@MainActor
func runDOCXEdgeCaseTests() {
print("\n--- DOCX Edge Case Tests ---")

// Test the DOCX-to-Markdown converter directly with synthetic XML

/// Helper: wrap DOCX XML content in a minimal document.xml structure
func wrapDocumentXML(_ bodyContent: String) -> String {
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <w:body>
    \(bodyContent)
    </w:body>
    </w:document>
    """
}

/// Convert a synthetic document.xml to Markdown using DOCX converter logic
func convertDOCXSnippet(_ bodyXML: String, styles: DOCXStyles = DOCXStyles(),
                         numbering: DOCXNumbering = DOCXNumbering(),
                         relationships: [String: String] = [:]) throws -> String {
    let xml = wrapDocumentXML(bodyXML)
#if canImport(TextMouth)
    return try DOCXToMarkdownConverter(
        data: Data(xml.utf8),
        styles: styles,
        numbering: numbering,
        relationships: relationships
    ).convert().markdown
#else
    let converter = TestDOCXConverter(styles: styles, numbering: numbering,
                                      relationships: relationships)
    return converter.convert(xmlString: xml)
#endif
}

// Empty document
test("DOCX empty document produces empty output") {
    let result = try convertDOCXSnippet("")
    try assertTrue(result.isEmpty || result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   "Empty body should produce empty output")
}

// Simple paragraph
test("DOCX simple paragraph converts correctly") {
    let xml = """
    <w:p>
    <w:r><w:t>Hello world</w:t></w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("Hello world"), "Should contain paragraph text")
}

// Bold text
test("DOCX bold text wraps in double asterisks") {
    let xml = """
    <w:p>
    <w:r>
    <w:rPr><w:b/></w:rPr>
    <w:t>bold text</w:t>
    </w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("**bold text**"), "Should wrap bold text, got: \(result)")
}

// Italic text
test("DOCX italic text wraps in single asterisks") {
    let xml = """
    <w:p>
    <w:r>
    <w:rPr><w:i/></w:rPr>
    <w:t>italic text</w:t>
    </w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("*italic text*"), "Should wrap italic text, got: \(result)")
}

// Bold + italic combined
test("DOCX bold-italic wraps in triple asterisks") {
    let xml = """
    <w:p>
    <w:r>
    <w:rPr><w:b/><w:i/></w:rPr>
    <w:t>bold italic</w:t>
    </w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("***bold italic***"), "Should wrap bold-italic text, got: \(result)")
}

// Strikethrough
test("DOCX strikethrough wraps in tildes") {
    let xml = """
    <w:p>
    <w:r>
    <w:rPr><w:strike/></w:rPr>
    <w:t>deleted</w:t>
    </w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("~~deleted~~"), "Should wrap strikethrough text, got: \(result)")
}

// Bold explicitly disabled with val="0"
test("DOCX bold val=0 means not bold") {
    let xml = """
    <w:p>
    <w:r>
    <w:rPr><w:b w:val="0"/></w:rPr>
    <w:t>not bold</w:t>
    </w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(!result.contains("**not bold**"), "val=0 should mean not bold, got: \(result)")
    try assertTrue(result.contains("not bold"), "Should still contain text")
}

// Bold explicitly disabled with val="false"
test("DOCX bold val=false means not bold") {
    let xml = """
    <w:p>
    <w:r>
    <w:rPr><w:b w:val="false"/></w:rPr>
    <w:t>plain text</w:t>
    </w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(!result.contains("**plain text**"), "val=false should mean not bold")
}

// Heading with style
test("DOCX heading style maps to markdown heading") {
    var styles = DOCXStyles()
    styles.headingLevels["Heading1"] = 1
    styles.headingLevels["Heading2"] = 2

    let xml = """
    <w:p>
    <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
    <w:r><w:t>Chapter Title</w:t></w:r>
    </w:p>
    <w:p>
    <w:pPr><w:pStyle w:val="Heading2"/></w:pPr>
    <w:r><w:t>Section Title</w:t></w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml, styles: styles)
    try assertTrue(result.contains("# Chapter Title"), "Should have h1, got: \(result)")
    try assertTrue(result.contains("## Section Title"), "Should have h2, got: \(result)")
}

// Numbered list with counter reset
test("DOCX numbered lists restart after non-list paragraph") {
    var numbering = DOCXNumbering()
    numbering.abstractNums["1"] = [0: legacyListLevel("decimal")]
    numbering.numIdToAbstractId["1"] = "1"

    let xml = """
    <w:p>
    <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    <w:r><w:t>First item</w:t></w:r>
    </w:p>
    <w:p>
    <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    <w:r><w:t>Second item</w:t></w:r>
    </w:p>
    <w:p>
    <w:r><w:t>A regular paragraph.</w:t></w:r>
    </w:p>
    <w:p>
    <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    <w:r><w:t>Restarted item</w:t></w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml, numbering: numbering)
    try assertTrue(result.contains("1. First item"), "First list should start at 1")
    try assertTrue(result.contains("2. Second item"), "First list should continue to 2")
    // After the intervening paragraph, the counter should reset
    try assertTrue(result.contains("1. Restarted item"),
                   "Second list should restart at 1, got: \(result)")
}

// Bullet list
test("DOCX bullet list uses dash prefix") {
    var numbering = DOCXNumbering()
    numbering.abstractNums["2"] = [0: legacyListLevel("bullet")]
    numbering.numIdToAbstractId["2"] = "2"

    let xml = """
    <w:p>
    <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>
    <w:r><w:t>Bullet A</w:t></w:r>
    </w:p>
    <w:p>
    <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>
    <w:r><w:t>Bullet B</w:t></w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml, numbering: numbering)
    try assertTrue(result.contains("- Bullet A"), "Should have bullet A")
    try assertTrue(result.contains("- Bullet B"), "Should have bullet B")
}

// Hyperlink with URL
test("DOCX hyperlink produces markdown link") {
    let rels = ["rId1": "http://example.com"]
    let xml = """
    <w:p>
    <w:hyperlink r:id="rId1">
    <w:r><w:t>click here</w:t></w:r>
    </w:hyperlink>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml, relationships: rels)
    try assertTrue(result.contains("[click here](http://example.com)"),
                   "Should produce markdown link, got: \(result)")
}

// Hyperlink with parentheses in URL (escaping test)
test("DOCX hyperlink escapes parentheses in URL") {
    let rels = ["rId1": "http://example.com/path(1)/file"]
    let xml = """
    <w:p>
    <w:hyperlink r:id="rId1">
    <w:r><w:t>link</w:t></w:r>
    </w:hyperlink>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml, relationships: rels)
    try assertTrue(result.contains("%28") && result.contains("%29"),
                   "Should escape parentheses in URL, got: \(result)")
}

// Hyperlink without matching relationship falls back to text only
test("DOCX hyperlink without relationship shows plain text") {
    let xml = """
    <w:p>
    <w:hyperlink r:id="rId999">
    <w:r><w:t>orphan link</w:t></w:r>
    </w:hyperlink>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("orphan link"), "Should fall back to plain text")
    try assertTrue(!result.contains("[orphan link]"), "Should not have bracket notation")
}

// Table conversion
test("DOCX table converts to markdown table with header separator") {
    let xml = """
    <w:tbl>
    <w:tr>
    <w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>Value</w:t></w:r></w:p></w:tc>
    </w:tr>
    <w:tr>
    <w:tc><w:p><w:r><w:t>Alpha</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>100</w:t></w:r></w:p></w:tc>
    </w:tr>
    </w:tbl>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("| Name | Value |"), "Should have header row, got: \(result)")
    try assertTrue(result.contains("| --- | --- |"), "Should have separator row")
    try assertTrue(result.contains("| Alpha | 100 |"), "Should have data row")
}

// Table with uneven row widths
test("DOCX table pads shorter rows") {
    let xml = """
    <w:tbl>
    <w:tr>
    <w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc>
    </w:tr>
    <w:tr>
    <w:tc><w:p><w:r><w:t>Only two</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>cells</w:t></w:r></w:p></w:tc>
    </w:tr>
    </w:tbl>
    """
    let result = try convertDOCXSnippet(xml)
    let lines = result.components(separatedBy: "\n").filter { $0.contains("|") }
    try assertGreater(lines.count, 2, "Should have header, separator, and data rows")
}

// Line break within paragraph
test("DOCX line break emits newline") {
    let xml = """
    <w:p>
    <w:r><w:t>Line one</w:t></w:r>
    <w:r><w:br/></w:r>
    <w:r><w:t>Line two</w:t></w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(result.contains("Line one"), "Should have first line")
    try assertTrue(result.contains("Line two"), "Should have second line")
}

// Multiple empty paragraphs collapse
test("DOCX excessive blank lines are collapsed") {
    let xml = """
    <w:p><w:r><w:t>Text</w:t></w:r></w:p>
    <w:p></w:p>
    <w:p></w:p>
    <w:p></w:p>
    <w:p></w:p>
    <w:p><w:r><w:t>More text</w:t></w:r></w:p>
    """
    let result = try convertDOCXSnippet(xml)
    try assertTrue(!result.contains("\n\n\n\n"), "Should collapse excessive blank lines")
    try assertTrue(result.contains("Text"), "Should have first text")
    try assertTrue(result.contains("More text"), "Should have second text")
}

// Mixed content: heading, paragraph, list
test("DOCX mixed content converts in order") {
    var styles = DOCXStyles()
    styles.headingLevels["Heading1"] = 1
    var numbering = DOCXNumbering()
    numbering.abstractNums["1"] = [0: legacyListLevel("bullet")]
    numbering.numIdToAbstractId["1"] = "1"

    let xml = """
    <w:p>
    <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
    <w:r><w:t>My Chapter</w:t></w:r>
    </w:p>
    <w:p>
    <w:r><w:t>Introductory paragraph.</w:t></w:r>
    </w:p>
    <w:p>
    <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    <w:r><w:t>Item one</w:t></w:r>
    </w:p>
    """
    let result = try convertDOCXSnippet(xml, styles: styles, numbering: numbering)
    let headingPos = result.range(of: "# My Chapter")?.lowerBound
    let paraPos = result.range(of: "Introductory paragraph")?.lowerBound
    let listPos = result.range(of: "- Item one")?.lowerBound

    try assertTrue(headingPos != nil, "Should have heading")
    try assertTrue(paraPos != nil, "Should have paragraph")
    try assertTrue(listPos != nil, "Should have list item")

    if let h = headingPos, let p = paraPos, let l = listPos {
        try assertTrue(h < p, "Heading should come before paragraph")
        try assertTrue(p < l, "Paragraph should come before list")
    }
}

// Metadata extraction
test("DOCX readMetadata returns title even without author") {
    let coreXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                       xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Only Title</dc:title>
    </cp:coreProperties>
    """
    let metadata = try parseMetadataXML(coreXML)
    try assertEqual(metadata.title, "Only Title", "Should extract title")
    try assertTrue(metadata.author.isEmpty, "Author should be empty")
}

}

#if !canImport(TextMouth)
// MARK: - Test DOCX Converter (mirrors app converter for direct XML testing)

/// Minimal DOCX to Markdown converter for tests.
/// Uses the test target's DOCXStyles and DOCXNumbering types.
class TestDOCXConverter: NSObject, XMLParserDelegate {
    private let styles: DOCXStyles
    private let numbering: DOCXNumbering
    private let relationships: [String: String]

    private var markdown = ""
    private var elementStack: [String] = []
    private var currentParagraphStyle = ""
    private var currentParagraphText = ""
    private var paragraphHasContent = false
    private var isInParagraph = false
    private var listNumId: String?
    private var listLevel: Int = 0
    private var isInRun = false
    private var runIsBold = false
    private var runIsItalic = false
    private var runIsStrikethrough = false
    private var runText = ""
    private var isInHyperlink = false
    private var hyperlinkRelId = ""
    private var hyperlinkText = ""
    private var isInTable = false
    private var isInTableRow = false
    private var isInTableCell = false
    private var tableRows: [[String]] = []
    private var currentRowCells: [String] = []
    private var currentCellText = ""
    private var listCounters: [String: [Int: Int]] = [:]
    private var previousParagraphWasList = false

    init(styles: DOCXStyles, numbering: DOCXNumbering, relationships: [String: String]) {
        self.styles = styles
        self.numbering = numbering
        self.relationships = relationships
    }

    func convert(xmlString: String) -> String {
        guard let data = xmlString.data(using: .utf8) else { return "" }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()
        return normalizeWhitespace(markdown)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        elementStack.append(localName)
        switch localName {
        case "p": startParagraph()
        case "pStyle": currentParagraphStyle = attributes["w:val"] ?? ""
        case "ilvl":
            if let val = attributes["w:val"], let level = Int(val) { listLevel = level }
        case "numId":
            let val = attributes["w:val"] ?? "0"
            if val != "0" { listNumId = val }
        case "r": startRun()
        case "b" where isInRun:
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" { runIsBold = true }
        case "i" where isInRun:
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" { runIsItalic = true }
        case "strike" where isInRun:
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" { runIsStrikethrough = true }
        case "br": currentParagraphText += "\n"
        case "hyperlink":
            isInHyperlink = true
            hyperlinkRelId = attributes["r:id"] ?? ""
            hyperlinkText = ""
        case "tbl": isInTable = true; tableRows = []
        case "tr": isInTableRow = true; currentRowCells = []
        case "tc": isInTableCell = true; currentCellText = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let lastElement = elementStack.last, lastElement == "t" {
            if isInHyperlink { hyperlinkText += string }
            runText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        switch localName {
        case "r": endRun()
        case "p": endParagraph()
        case "hyperlink": endHyperlink()
        case "tbl": endTable()
        case "tr":
            if isInTableRow { tableRows.append(currentRowCells); isInTableRow = false }
        case "tc":
            if isInTableCell {
                currentRowCells.append(currentCellText.trimmingCharacters(in: .whitespacesAndNewlines))
                isInTableCell = false
            }
        default: break
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    private func startParagraph() {
        isInParagraph = true; currentParagraphStyle = ""; currentParagraphText = ""
        paragraphHasContent = false; listNumId = nil; listLevel = 0
    }

    private func endParagraph() {
        let text = currentParagraphText.trimmingCharacters(in: .whitespaces)
        if isInTableCell {
            if !currentCellText.isEmpty && !text.isEmpty { currentCellText += " " }
            currentCellText += text; isInParagraph = false; return
        }
        guard !text.isEmpty else { markdown += "\n"; isInParagraph = false; return }

        let isListParagraph = listNumId != nil
            || styles.bulletListStyles.contains(currentParagraphStyle)
            || styles.numberedListStyles.contains(currentParagraphStyle)
        if !isListParagraph && previousParagraphWasList { listCounters.removeAll() }
        previousParagraphWasList = isListParagraph

        if let headingLevel = styles.headingLevels[currentParagraphStyle] {
            let prefix = String(repeating: "#", count: headingLevel)
            markdown += "\n\(prefix) \(text)\n\n"
        } else if let numId = listNumId {
            // Use the test target's string-based listType
            let listType = numbering.listType(numId: numId, level: listLevel)
            let indent = String(repeating: "    ", count: listLevel)
            if listType == "bullet" {
                markdown += "\(indent)- \(text)\n"
            } else {
                var counter = listCounters[numId] ?? [:]
                let current = (counter[listLevel] ?? 0) + 1
                counter[listLevel] = current; listCounters[numId] = counter
                markdown += "\(indent)\(current). \(text)\n"
            }
        } else if styles.bulletListStyles.contains(currentParagraphStyle) {
            markdown += "- \(text)\n"
        } else if styles.numberedListStyles.contains(currentParagraphStyle) {
            let key = "style-\(currentParagraphStyle)"
            var counter = listCounters[key] ?? [:]
            let current = (counter[0] ?? 0) + 1
            counter[0] = current; listCounters[key] = counter
            markdown += "\(current). \(text)\n"
        } else {
            markdown += "\n\(text)\n"
        }
        isInParagraph = false
    }

    private func startRun() {
        isInRun = true; runIsBold = false; runIsItalic = false
        runIsStrikethrough = false; runText = ""
    }

    private func endRun() {
        guard isInRun else { return }; isInRun = false
        let text = runText; guard !text.isEmpty else { return }
        var formatted = text
        if runIsBold && runIsItalic { formatted = "***\(formatted)***" }
        else if runIsBold { formatted = "**\(formatted)**" }
        else if runIsItalic { formatted = "*\(formatted)*" }
        if runIsStrikethrough { formatted = "~~\(formatted)~~" }
        currentParagraphText += formatted; paragraphHasContent = true
    }

    private func endHyperlink() {
        guard isInHyperlink else { return }; isInHyperlink = false
        let text = hyperlinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let target = relationships[hyperlinkRelId], !target.isEmpty {
            let escaped = target
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            currentParagraphText += "[\(text)](\(escaped))"
        } else {
            currentParagraphText += text
        }
        paragraphHasContent = true
    }

    private func endTable() {
        isInTable = false; guard !tableRows.isEmpty else { return }
        let colCount = tableRows.map { $0.count }.max() ?? 0
        guard colCount > 0 else { return }
        markdown += "\n"
        for (rowIndex, row) in tableRows.enumerated() {
            var cells = row
            while cells.count < colCount { cells.append("") }
            markdown += "| " + cells.joined(separator: " | ") + " |\n"
            if rowIndex == 0 {
                let sep = cells.map { _ in "---" }.joined(separator: " | ")
                markdown += "| \(sep) |\n"
            }
        }
        markdown += "\n"
    }

    private func normalizeWhitespace(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        var result: [String] = []; var blankCount = 0
        for line in lines {
            if line.isEmpty { blankCount += 1; if blankCount <= 2 { result.append(line) } }
            else { blankCount = 0; result.append(line) }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Parse metadata from a core.xml string (test helper)
func parseMetadataXML(_ xml: String) -> DOCXMetadata {
    let parser = TestMetadataParser(xml: xml)
    return parser.parse()
}

private class TestMetadataParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var title = ""
    private var author = ""
    private var currentElement = ""
    private var currentText = ""

    init(xml: String) { self.xml = xml }

    func parse() -> DOCXMetadata {
        guard let data = xml.data(using: .utf8) else { return DOCXMetadata(title: "", author: "") }
        let parser = XMLParser(data: data)
        parser.delegate = self; parser.parse()
        return DOCXMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = local; currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        switch local {
        case "title": if title.isEmpty { title = currentText }
        case "creator": if author.isEmpty { author = currentText }
        default: break
        }
    }
}
#else
/// Parse core properties through the production metadata parser.
func parseMetadataXML(_ xml: String) throws -> DOCXMetadata {
    try DOCXMetadataParser(data: Data(xml.utf8), file: DOCXParser.Part.coreProperties).parse()
}
#endif
