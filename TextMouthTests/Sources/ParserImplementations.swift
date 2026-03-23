import Foundation
import ZIPFoundation
import SwiftSoup
import Markdown
import CryptoKit

// MARK: - EPUB Parser (copied from app)

enum EPUBParserError: LocalizedError {
    case invalidArchive, missingContainer, missingOPF, invalidOPF, missingSpine
    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "Invalid ZIP archive"
        case .missingContainer: return "Missing container.xml"
        case .missingOPF: return "Missing OPF"
        case .invalidOPF: return "Invalid OPF"
        case .missingSpine: return "Missing spine"
        }
    }
}

struct ManifestItem {
    var href: String
    var mediaType: String
}

struct OPFData {
    var title: String
    var author: String
    var manifest: [String: ManifestItem]
    var spineItemRefs: [String]
}

func extractStringFromArchive(_ archive: Archive, path: String) throws -> String {
    guard let entry = archive[path] else {
        throw EPUBParserError.missingContainer
    }
    var data = Data()
    _ = try archive.extract(entry) { chunk in data.append(chunk) }
    guard let string = String(data: data, encoding: .utf8) else {
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        throw EPUBParserError.invalidOPF
    }
    return string
}

func parseContainerForOPFPath(_ xml: String) throws -> String {
    let doc = try XMLDocument(xmlString: xml)
    let rootfiles = try doc.nodes(forXPath: "//*[local-name()='rootfile']")
    guard let rootfile = rootfiles.first,
          let element = rootfile as? XMLElement,
          let fullPath = element.attribute(forName: "full-path")?.stringValue else {
        throw EPUBParserError.missingOPF
    }
    return fullPath
}

func parseOPF(_ xml: String) throws -> OPFData {
    let doc = try XMLDocument(xmlString: xml)
    let titles = try doc.nodes(forXPath: "//*[local-name()='title']")
    let title = titles.first?.stringValue ?? "Untitled"
    let creators = try doc.nodes(forXPath: "//*[local-name()='creator']")
    let author = creators.first?.stringValue ?? "Unknown"
    let manifestNodes = try doc.nodes(forXPath: "//*[local-name()='item']")
    var manifest: [String: ManifestItem] = [:]
    for node in manifestNodes {
        guard let element = node as? XMLElement,
              let id = element.attribute(forName: "id")?.stringValue,
              let href = element.attribute(forName: "href")?.stringValue,
              let mediaType = element.attribute(forName: "media-type")?.stringValue else { continue }
        manifest[id] = ManifestItem(href: href, mediaType: mediaType)
    }
    let spineNodes = try doc.nodes(forXPath: "//*[local-name()='itemref']")
    let spineItemRefs = spineNodes.compactMap { ($0 as? XMLElement)?.attribute(forName: "idref")?.stringValue }
    guard !spineItemRefs.isEmpty else { throw EPUBParserError.missingSpine }
    return OPFData(title: title, author: author, manifest: manifest, spineItemRefs: spineItemRefs)
}

func parseChapterHTML(_ html: String) throws -> Chapter {
    let doc = try SwiftSoup.parse(html)
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    let allText = try body.text()
    var headings: [Heading] = []
    let headingElements = try doc.select("h1, h2, h3, h4, h5, h6")
    for element in headingElements.array() {
        let tag = element.tagName()
        let level = tag.last.flatMap({ Int(String($0)) }) ?? 1
        let headingText = try element.text()
        let offset: Int
        if let range = allText.range(of: headingText) {
            offset = allText.distance(from: allText.startIndex, to: range.lowerBound)
        } else {
            offset = 0
        }
        headings.append(Heading(level: level, text: headingText, characterOffset: offset))
    }
    let chapterTitle = headings.first?.text ?? ""
    return Chapter(title: chapterTitle, text: allText, headings: headings)
}

func parseEPUB(url: URL) throws -> DocumentContent {
    let archive: Archive
    do {
        archive = try Archive(url: url, accessMode: .read)
    } catch {
        throw EPUBParserError.invalidArchive
    }
    let containerXML = try extractStringFromArchive(archive, path: "META-INF/container.xml")
    let opfPath = try parseContainerForOPFPath(containerXML)
    let opfXML = try extractStringFromArchive(archive, path: opfPath)
    let opfDirectory = (opfPath as NSString).deletingLastPathComponent
    let opfData = try parseOPF(opfXML)

    var chapters: [Chapter] = []
    for itemRef in opfData.spineItemRefs {
        guard let manifestItem = opfData.manifest[itemRef],
              manifestItem.mediaType.contains("html") || manifestItem.mediaType.contains("xml") else { continue }
        let chapterPath: String
        if opfDirectory.isEmpty {
            chapterPath = manifestItem.href
        } else {
            chapterPath = "\(opfDirectory)/\(manifestItem.href)"
        }
        let decodedPath = chapterPath.removingPercentEncoding ?? chapterPath
        guard let chapterHTML = try? extractStringFromArchive(archive, path: decodedPath) else { continue }
        let chapter = try parseChapterHTML(chapterHTML)
        chapters.append(chapter)
    }
    return DocumentContent(title: opfData.title, author: opfData.author, chapters: chapters)
}

// MARK: - HTML Parser

func parseHTML(html: String, title: String = "Untitled") throws -> DocumentContent {
    let doc = try SwiftSoup.parse(html)
    let docTitle = (try? doc.title()).flatMap({ $0.isEmpty ? nil : $0 }) ?? title
    try doc.select("script, style").remove()
    let body = doc.body() ?? doc
    let fullText = try body.text()
    var headings: [Heading] = []
    let headingElements = try doc.select("h1, h2, h3, h4, h5, h6")
    var searchStart = fullText.startIndex
    for element in headingElements.array() {
        let tag = element.tagName()
        let level = tag.last.flatMap({ Int(String($0)) }) ?? 1
        let headingText = try element.text()
        let offset: Int
        if let range = fullText.range(of: headingText, range: searchStart..<fullText.endIndex) {
            offset = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
            searchStart = range.upperBound
        } else {
            offset = fullText.distance(from: fullText.startIndex, to: searchStart)
        }
        headings.append(Heading(level: level, text: headingText, characterOffset: offset))
    }
    // Extract author from meta tag
    let metaAuthor: String?
    if let meta = try? doc.select("meta[name=author]").first() {
        metaAuthor = try? meta.attr("content")
    } else {
        metaAuthor = nil
    }
    let chapter = Chapter(title: docTitle, text: fullText, headings: headings)
    return DocumentContent(title: docTitle, author: metaAuthor ?? "Unknown", chapters: [chapter])
}

// MARK: - Markdown Parser

struct HeadingCollector: MarkupWalker {
    var headings: [(level: Int, text: String)] = []
    mutating func visitHeading(_ heading: Markdown.Heading) {
        headings.append((level: heading.level, text: heading.plainText))
        descendInto(heading)
    }
}

struct PlainTextExtractor: MarkupWalker {
    var result = ""
    mutating func visitText(_ text: Markdown.Text) { result += text.string }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) { result += " " }
    mutating func visitLineBreak(_ lineBreak: LineBreak) { result += "\n" }
    mutating func visitParagraph(_ paragraph: Markdown.Paragraph) {
        if !result.isEmpty && !result.hasSuffix("\n\n") { result += "\n\n" }
        descendInto(paragraph)
    }
    mutating func visitHeading(_ heading: Markdown.Heading) {
        if !result.isEmpty && !result.hasSuffix("\n\n") { result += "\n\n" }
        descendInto(heading)
        result += "\n\n"
    }
}

func parseMarkdown(markdown: String, title: String = "Untitled") throws -> DocumentContent {
    let document = Document(parsing: markdown)
    var collector = HeadingCollector()
    collector.visit(document)
    var textExtractor = PlainTextExtractor()
    textExtractor.visit(document)
    let plainText = textExtractor.result.trimmingCharacters(in: .whitespacesAndNewlines)
    var headings: [Heading] = []
    var searchStart = plainText.startIndex
    for (level, headingText) in collector.headings {
        let offset: Int
        if let range = plainText.range(of: headingText, range: searchStart..<plainText.endIndex) {
            offset = plainText.distance(from: plainText.startIndex, to: range.lowerBound)
            searchStart = range.upperBound
        } else {
            offset = plainText.distance(from: plainText.startIndex, to: searchStart)
        }
        headings.append(Heading(level: level, text: headingText, characterOffset: offset))
    }
    let docTitle = headings.first?.text ?? title
    let chapter = Chapter(title: docTitle, text: plainText, headings: headings)
    return DocumentContent(title: docTitle, author: "Unknown", chapters: [chapter])
}

// MARK: - Plain Text Parser

func parsePlainText(text: String, title: String = "Untitled") -> DocumentContent {
    var headings: [Heading] = []
    let lines = text.components(separatedBy: .newlines)
    var currentOffset = 0

    // Pre-identify setext underline lines
    var setextLines: Set<Int> = []
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 3 && (trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" })) {
            setextLines.insert(index)
        }
    }

    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var matched = false

        if setextLines.contains(index) {
            currentOffset += line.count + 1
            continue
        }

        // 1. Markdown-style
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if level >= 1 && level <= 6 {
                let headingText = String(trimmed.dropFirst(level))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    .trimmingCharacters(in: .whitespaces)
                if !headingText.isEmpty {
                    headings.append(Heading(level: min(level, 6), text: headingText, characterOffset: currentOffset))
                    matched = true
                }
            }
        }

        // 2. Setext-style
        if !matched && !trimmed.isEmpty && index + 1 < lines.count && setextLines.contains(index + 1) {
            let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if nextLine.allSatisfy({ $0 == "=" }) {
                headings.append(Heading(level: 1, text: trimmed, characterOffset: currentOffset))
                matched = true
            } else if nextLine.allSatisfy({ $0 == "-" }) {
                headings.append(Heading(level: 2, text: trimmed, characterOffset: currentOffset))
                matched = true
            }
        }

        // 3. All-caps (mutually exclusive)
        if !matched && trimmed.count >= 3 && trimmed.count <= 80
            && trimmed.uppercased() == trimmed
            && trimmed.rangeOfCharacter(from: .letters) != nil {
            let letters = trimmed.filter { $0.isLetter }
            if letters.count >= 3 {
                headings.append(Heading(level: 2, text: trimmed, characterOffset: currentOffset))
            }
        }
        currentOffset += line.count + 1
    }
    let chapter = Chapter(title: title, text: text, headings: headings)
    return DocumentContent(title: title, author: "Unknown", chapters: [chapter])
}

// MARK: - DOCX Parser

/// Metadata from docProps/core.xml
struct DOCXMetadata {
    var title: String
    var author: String
}

/// Parsed style information from word/styles.xml
struct DOCXStyles {
    var headingLevels: [String: Int] = [:]
    var bulletListStyles: Set<String> = []
    var numberedListStyles: Set<String> = []
}

/// Numbering definitions for lists
struct DOCXNumbering {
    var abstractNums: [String: [String]] = [:]  // abstractNumId → [numFmt per level]
    var numIdToAbstractId: [String: String] = [:]

    func listType(numId: String, level: Int) -> String {
        guard let abstractId = numIdToAbstractId[numId],
              let levels = abstractNums[abstractId],
              level < levels.count else {
            return "bullet"
        }
        return levels[level]
    }
}

/// Extract raw data from a ZIP archive entry
func extractDOCXData(from archive: Archive, path: String) throws -> Data {
    guard let entry = archive[path] else {
        throw TestError.fileNotFound(path)
    }
    var data = Data()
    _ = try archive.extract(entry) { chunk in data.append(chunk) }
    return data
}

/// Parse metadata from docProps/core.xml
func parseDOCXMetadata(from url: URL) throws -> DOCXMetadata {
    let archive = try Archive(url: url, accessMode: .read)
    let data = try extractDOCXData(from: archive, path: "docProps/core.xml")
    guard let xml = String(data: data, encoding: .utf8) else {
        throw TestError.assertionFailed("Cannot decode core.xml as UTF-8")
    }
    let parser = DOCXMetadataXMLParser(xml: xml)
    return parser.parse()
}

/// SAX parser for docProps/core.xml
private class DOCXMetadataXMLParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var title = ""
    private var author = ""
    private var currentElement = ""
    private var currentText = ""

    init(xml: String) { self.xml = xml }

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
        case "title": if title.isEmpty { title = currentText }
        case "creator": if author.isEmpty { author = currentText }
        default: break
        }
    }
}

/// Parse styles from word/styles.xml
func parseDOCXStyles(from url: URL) throws -> DOCXStyles {
    let archive = try Archive(url: url, accessMode: .read)
    let data = try extractDOCXData(from: archive, path: "word/styles.xml")
    guard let xml = String(data: data, encoding: .utf8) else {
        throw TestError.assertionFailed("Cannot decode styles.xml as UTF-8")
    }
    let parser = DOCXStylesXMLParser(xml: xml)
    return parser.parse()
}

/// SAX parser for word/styles.xml
private class DOCXStylesXMLParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var styles = DOCXStyles()
    private var currentStyleId = ""
    private var currentStyleName = ""
    private var inStyle = false
    private var currentOutlineLevel: Int?

    init(xml: String) { self.xml = xml }

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
            currentStyleId = attributes["w:styleId"] ?? ""
            currentStyleName = ""
            currentOutlineLevel = nil
            inStyle = true
        case "name" where inStyle:
            currentStyleName = attributes["w:val"] ?? ""
        case "outlineLvl" where inStyle:
            if let val = attributes["w:val"], let level = Int(val) {
                currentOutlineLevel = level + 1
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "style" && inStyle {
            // Heading detection
            if let level = resolveHeadingLevel(), level >= 1, level <= 6 {
                styles.headingLevels[currentStyleId] = level
            }
            // List style detection
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

    private func resolveHeadingLevel() -> Int? {
        if let level = currentOutlineLevel { return min(level, 6) }
        let nameLower = currentStyleName.lowercased()
        if nameLower.hasPrefix("heading") {
            let rest = nameLower.dropFirst("heading".count).trimmingCharacters(in: .whitespaces)
            if let level = Int(rest) { return min(level, 6) }
        }
        let idLower = currentStyleId.lowercased()
        if idLower.hasPrefix("heading") {
            let rest = idLower.dropFirst("heading".count)
            if let level = Int(rest) { return min(level, 6) }
        }
        if nameLower == "title" || idLower == "title" { return 1 }
        if nameLower == "subtitle" || idLower == "subtitle" { return 2 }
        return nil
    }
}

/// Convert DOCX to Markdown
func parseDOCXToMarkdown(from url: URL) throws -> String {
    let archive = try Archive(url: url, accessMode: .read)

    // Parse styles
    let styles: DOCXStyles
    if let stylesData = try? extractDOCXData(from: archive, path: "word/styles.xml"),
       let stylesXML = String(data: stylesData, encoding: .utf8) {
        styles = DOCXStylesXMLParser(xml: stylesXML).parse()
    } else {
        styles = DOCXStyles()
    }

    // Parse numbering
    let numbering: DOCXNumbering
    if let numData = try? extractDOCXData(from: archive, path: "word/numbering.xml"),
       let numXML = String(data: numData, encoding: .utf8) {
        numbering = DOCXNumberingXMLParser(xml: numXML).parse()
    } else {
        numbering = DOCXNumbering()
    }

    // Parse relationships
    let relationships: [String: String]
    if let relData = try? extractDOCXData(from: archive, path: "word/_rels/document.xml.rels"),
       let relXML = String(data: relData, encoding: .utf8) {
        relationships = DOCXRelationshipsXMLParser(xml: relXML).parse()
    } else {
        relationships = [:]
    }

    // Parse document.xml
    let docData = try extractDOCXData(from: archive, path: "word/document.xml")
    guard let docXML = String(data: docData, encoding: .utf8) else {
        throw TestError.assertionFailed("Cannot decode document.xml as UTF-8")
    }

    let converter = DOCXToMarkdownXMLConverter(
        styles: styles, numbering: numbering, relationships: relationships
    )
    return converter.convert(xmlString: docXML)
}

/// SAX parser for numbering.xml
private class DOCXNumberingXMLParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var numbering = DOCXNumbering()
    private var currentAbstractNumId = ""
    private var inAbstractNum = false
    private var currentLevels: [String] = []
    private var currentNumId: String?
    private var inNum = false

    init(xml: String) { self.xml = xml }

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
        case "numFmt" where inAbstractNum:
            currentLevels.append(attributes["w:val"] ?? "bullet")
        case "num":
            currentNumId = attributes["w:numId"]
            inNum = true
        case "abstractNumId" where inNum:
            if let val = attributes["w:val"], let numId = currentNumId {
                numbering.numIdToAbstractId[numId] = val
            }
        default: break
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

/// SAX parser for relationships
private class DOCXRelationshipsXMLParser: NSObject, XMLParserDelegate {
    private let xml: String
    private var relationships: [String: String] = [:]

    init(xml: String) { self.xml = xml }

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

/// Main DOCX-to-Markdown converter using SAX parsing
private class DOCXToMarkdownXMLConverter: NSObject, XMLParserDelegate {
    private let styles: DOCXStyles
    private let numbering: DOCXNumbering
    private let relationships: [String: String]

    private var markdown = ""
    private var elementStack: [String] = []

    // Paragraph state
    private var currentParagraphStyle = ""
    private var currentParagraphText = ""
    private var isInParagraph = false
    private var listNumId: String?
    private var listLevel: Int = 0

    // Run state
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

    // List counters
    private var listCounters: [String: [Int: Int]] = [:]

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
        case "p":
            isInParagraph = true
            currentParagraphStyle = ""
            currentParagraphText = ""
            listNumId = nil
            listLevel = 0
        case "pStyle":
            currentParagraphStyle = attributes["w:val"] ?? ""
        case "ilvl":
            if let val = attributes["w:val"], let level = Int(val) { listLevel = level }
        case "numId":
            let val = attributes["w:val"] ?? "0"
            if val != "0" { listNumId = val }
        case "r":
            isInRun = true
            runIsBold = false
            runIsItalic = false
            runIsStrikethrough = false
            runText = ""
        case "b" where isInRun:
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" { runIsBold = true }
        case "i" where isInRun:
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" { runIsItalic = true }
        case "strike" where isInRun:
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" { runIsStrikethrough = true }
        case "br":
            currentParagraphText += "\n"
        case "hyperlink":
            isInHyperlink = true
            hyperlinkRelId = attributes["r:id"] ?? ""
            hyperlinkText = ""
        case "tbl":
            isInTable = true
            tableRows = []
        case "tr":
            isInTableRow = true
            currentRowCells = []
        case "tc":
            isInTableCell = true
            currentCellText = ""
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
        case "r":
            if isInRun {
                let text = runText
                if !text.isEmpty {
                    var formatted = text
                    if runIsBold && runIsItalic {
                        formatted = "***\(formatted)***"
                    } else if runIsBold {
                        formatted = "**\(formatted)**"
                    } else if runIsItalic {
                        formatted = "*\(formatted)*"
                    }
                    if runIsStrikethrough { formatted = "~~\(formatted)~~" }
                    currentParagraphText += formatted
                }
                isInRun = false
            }
        case "p":
            let text = currentParagraphText.trimmingCharacters(in: .whitespaces)

            if isInTableCell {
                if !currentCellText.isEmpty && !text.isEmpty { currentCellText += " " }
                currentCellText += text
                isInParagraph = false
            } else if text.isEmpty {
                markdown += "\n"
                isInParagraph = false
            } else if let headingLevel = styles.headingLevels[currentParagraphStyle] {
                let prefix = String(repeating: "#", count: headingLevel)
                markdown += "\n\(prefix) \(text)\n\n"
                isInParagraph = false
            } else if let numId = listNumId {
                let lt = numbering.listType(numId: numId, level: listLevel)
                let indent = String(repeating: "    ", count: listLevel)
                if lt == "bullet" {
                    markdown += "\(indent)- \(text)\n"
                } else {
                    var counter = listCounters[numId] ?? [:]
                    let current = (counter[listLevel] ?? 0) + 1
                    counter[listLevel] = current
                    listCounters[numId] = counter
                    markdown += "\(indent)\(current). \(text)\n"
                }
                isInParagraph = false
            } else if styles.bulletListStyles.contains(currentParagraphStyle) {
                markdown += "- \(text)\n"
                isInParagraph = false
            } else if styles.numberedListStyles.contains(currentParagraphStyle) {
                let key = "style-\(currentParagraphStyle)"
                var counter = listCounters[key] ?? [:]
                let current = (counter[0] ?? 0) + 1
                counter[0] = current
                listCounters[key] = counter
                markdown += "\(current). \(text)\n"
                isInParagraph = false
            } else {
                markdown += "\n\(text)\n"
                isInParagraph = false
            }
        case "hyperlink":
            if isInHyperlink {
                let text = hyperlinkText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    if let target = relationships[hyperlinkRelId], !target.isEmpty {
                        currentParagraphText += "[\(text)](\(target))"
                    } else {
                        currentParagraphText += text
                    }
                }
                isInHyperlink = false
            }
        case "tbl":
            isInTable = false
            guard !tableRows.isEmpty else { break }
            let colCount = tableRows.map { $0.count }.max() ?? 0
            guard colCount > 0 else { break }
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
        case "tr":
            if isInTableRow {
                tableRows.append(currentRowCells)
                isInTableRow = false
            }
        case "tc":
            if isInTableCell {
                currentRowCells.append(currentCellText.trimmingCharacters(in: .whitespacesAndNewlines))
                isInTableCell = false
            }
        default: break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    private func normalizeWhitespace(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - DAISY Parser

/// Metadata from a DAISY book
struct DAISYMetadata {
    var title: String
    var author: String
}

/// Parsed OPF package data (test version matching app's DAISYOPFResult)
struct DAISYOPFResult {
    var title: String = ""
    var author: String = ""
    var manifest: [String: DAISYManifestItem] = [:]
    var spineItemRefs: [String] = []
}

/// A single item from the OPF manifest
struct DAISYManifestItem {
    var id: String
    var href: String
    var mediaType: String
}

/// OPF parser with spine support (test version matching app's DAISYOPFParser)
class DAISYOPFParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var result = DAISYOPFResult()
    private var elementStack: [String] = []
    private var currentText = ""

    init(data: Data) { self.data = data }

    func parse() -> DAISYOPFResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        elementStack.append(local)
        currentText = ""

        switch local {
        case "item":
            if let id = attributes["id"], let href = attributes["href"],
               let mediaType = attributes["media-type"] {
                result.manifest[id] = DAISYManifestItem(id: id, href: href, mediaType: mediaType)
            }
        case "itemref":
            if let idref = attributes["idref"] {
                result.spineItemRefs.append(idref)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if local == "title" && result.title.isEmpty && !text.isEmpty { result.title = text }
        if local == "creator" && result.author.isEmpty && !text.isEmpty { result.author = text }
        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}

/// Shared parser utilities (test version matching app's ParserUtilities)
enum ParserUtilities {
    static func stripNamespacePrefix(_ elementName: String) -> String {
        elementName.components(separatedBy: ":").last ?? elementName
    }

    static func normalizeMarkdownWhitespace(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines = lines.map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Check if a ZIP file is a DAISY package
func isDAISYZipFile(url: URL) -> Bool {
    guard let archive = try? Archive(url: url, accessMode: .read) else { return false }
    // Check for OPF file (DAISY 3) or ncc.html (DAISY 2.02)
    for entry in archive {
        let lower = entry.path.lowercased()
        if lower.hasSuffix(".opf") { return true }
        if lower.hasSuffix("ncc.html") || lower.hasSuffix("ncc.htm") { return true }
    }
    return false
}

/// Parse metadata from a DAISY ZIP
func parseDAISYMetadata(from url: URL) throws -> DAISYMetadata {
    guard let archive = try? Archive(url: url, accessMode: .read) else {
        throw TestError.assertionFailed("Cannot open DAISY ZIP")
    }

    // Find OPF file
    for entry in archive where entry.path.lowercased().hasSuffix(".opf") {
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        let parser = DAISYTestOPFParser(data: data)
        return parser.parse()
    }

    // Try ncc.html for DAISY 2.02
    for entry in archive where entry.path.lowercased().hasSuffix("ncc.html") {
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        guard let html = String(data: data, encoding: .utf8) else { continue }
        let parser = DAISYTestNCCParser(html: html)
        return parser.parse()
    }

    throw TestError.assertionFailed("No DAISY metadata found")
}

/// Convert a DAISY ZIP to Markdown
func parseDAISYToMarkdown(from url: URL) throws -> String {
    guard let archive = try? Archive(url: url, accessMode: .read) else {
        throw TestError.assertionFailed("Cannot open DAISY ZIP")
    }

    // Find DTBook XML file
    for entry in archive where entry.path.lowercased().hasSuffix(".xml") {
        let filename = (entry.path as NSString).lastPathComponent.lowercased()
        if filename.hasSuffix(".xsl") { continue }

        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }

        // Check if this is actually DTBook XML
        let prefix = String(data: data.prefix(500), encoding: .utf8) ?? ""
        if prefix.contains("dtbook") {
            return convertDTBookData(data)
        }
    }

    throw TestError.assertionFailed("No DTBook XML found in DAISY ZIP")
}

/// Convert a DTBook XML string snippet to Markdown (for unit testing)
func convertDTBookSnippet(_ xml: String) -> String {
    guard let data = xml.data(using: .utf8) else { return "" }
    return convertDTBookData(data)
}

/// Convert DTBook XML data to Markdown
func convertDTBookData(_ data: Data) -> String {
    let converter = DTBookTestConverter()
    return converter.convert(data: data)
}

/// OPF parser for tests
private class DAISYTestOPFParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var title = ""
    private var author = ""
    private var elementStack: [String] = []
    private var currentText = ""

    init(data: Data) { self.data = data }

    func parse() -> DAISYMetadata {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return DAISYMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        elementStack.append(local)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if local == "title" && title.isEmpty && !text.isEmpty { title = text }
        if local == "creator" && author.isEmpty && !text.isEmpty { author = text }
        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}

/// NCC parser for tests (DAISY 2.02)
private class DAISYTestNCCParser: NSObject, XMLParserDelegate {
    private let html: String
    private var title = ""
    private var author = ""

    init(html: String) { self.html = html }

    func parse() -> DAISYMetadata {
        var cleaned = html
        if !cleaned.hasPrefix("<?xml") {
            cleaned = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + cleaned
        }
        guard let data = cleaned.data(using: .utf8) else {
            return DAISYMetadata(title: "", author: "")
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return DAISYMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        if local == "meta" {
            let name = (attributes["name"] ?? "").lowercased()
            let content = attributes["content"] ?? ""
            if name == "dc:title" && title.isEmpty { title = content }
            if name == "dc:creator" && author.isEmpty { author = content }
        }
    }
}

/// DTBook XML to Markdown converter for tests
private class DTBookTestConverter: NSObject, XMLParserDelegate {
    private var markdown = ""
    private var elementStack: [String] = []
    private var listTypeStack: [String] = []
    private var listCounterStack: [Int] = []
    private var listDepth = 0
    private var skipDepth = 0

    func convert(data: Data) -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return normalizeWhitespace(markdown)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        elementStack.append(local)

        if skipDepth > 0 { skipDepth += 1; return }

        switch local {
        case "head": skipDepth = 1
        case "prodnote": skipDepth = 1
        case "doctitle": ensureBlankLine(); markdown += "# "
        case "docauthor": ensureBlankLine(); markdown += "*"
        case "h1": ensureBlankLine(); markdown += "# "
        case "h2": ensureBlankLine(); markdown += "## "
        case "h3": ensureBlankLine(); markdown += "### "
        case "h4": ensureBlankLine(); markdown += "#### "
        case "h5": ensureBlankLine(); markdown += "##### "
        case "h6": ensureBlankLine(); markdown += "###### "
        case "hd": ensureBlankLine(); markdown += "## "
        case "p": ensureBlankLine()
        case "em": markdown += "*"
        case "strong": markdown += "**"
        case "list":
            let type = (attributes["type"]?.lowercased() == "ol") ? "ol" : "ul"
            listTypeStack.append(type)
            listCounterStack.append(0)
            listDepth += 1
            ensureNewline()
        case "li":
            let indent = String(repeating: "    ", count: max(0, listDepth - 1))
            if let currentType = listTypeStack.last {
                if currentType == "ol" {
                    let count = (listCounterStack.last ?? 0) + 1
                    if !listCounterStack.isEmpty { listCounterStack[listCounterStack.count - 1] = count }
                    markdown += "\(indent)\(count). "
                } else {
                    markdown += "\(indent)- "
                }
            } else {
                markdown += "- "
            }
        case "blockquote": ensureBlankLine(); markdown += "> "
        case "a": markdown += "["
        case "br": markdown += "\n"
        case "hr": ensureBlankLine(); markdown += "---\n"
        case "line": ensureNewline()
        case "poem": ensureBlankLine()
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        markdown += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()

        if skipDepth > 0 {
            skipDepth -= 1
            if !elementStack.isEmpty { elementStack.removeLast() }
            return
        }

        switch local {
        case "doctitle": markdown += "\n\n"
        case "docauthor": markdown += "*\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6", "hd": markdown += "\n\n"
        case "p": markdown += "\n\n"
        case "em": markdown += "*"
        case "strong": markdown += "**"
        case "list":
            if !listTypeStack.isEmpty { listTypeStack.removeLast() }
            if !listCounterStack.isEmpty { listCounterStack.removeLast() }
            listDepth = max(0, listDepth - 1)
            ensureNewline()
        case "li": ensureNewline()
        case "blockquote": markdown += "\n\n"
        case "a": markdown += "]"
        case "line": markdown += "\n"
        case "poem": markdown += "\n\n"
        default: break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    private func ensureBlankLine() {
        if markdown.isEmpty { return }
        if !markdown.hasSuffix("\n\n") {
            markdown += markdown.hasSuffix("\n") ? "\n" : "\n\n"
        }
    }

    private func ensureNewline() {
        if !markdown.isEmpty && !markdown.hasSuffix("\n") { markdown += "\n" }
    }

    private func normalizeWhitespace(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - DAISY 2.02 Helpers

/// Parse DAISY 2.02 metadata from a ZIP containing ncc.html
func parseDAISY202MetadataFromZip(url: URL) throws -> DAISYMetadata {
    guard let archive = try? Archive(url: url, accessMode: .read) else {
        throw TestError.assertionFailed("Cannot open ZIP")
    }
    for entry in archive where entry.path.lowercased().hasSuffix("ncc.html") || entry.path.lowercased().hasSuffix("ncc.htm") {
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        guard let html = String(data: data, encoding: .utf8) else { continue }
        let parser = DAISYTestNCCParser(html: html)
        return parser.parse()
    }
    throw TestError.assertionFailed("No ncc.html found")
}

/// Convert a DAISY 2.02 ZIP to Markdown by extracting NCC headings and content files
func parseDAISY202ToMarkdown(url: URL) throws -> String {
    guard let archive = try? Archive(url: url, accessMode: .read) else {
        throw TestError.assertionFailed("Cannot open ZIP")
    }

    // Find and parse ncc.html
    var nccHTML: String?
    var nccDir = ""
    for entry in archive where entry.path.lowercased().hasSuffix("ncc.html") || entry.path.lowercased().hasSuffix("ncc.htm") {
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        nccHTML = String(data: data, encoding: .utf8)
        nccDir = (entry.path as NSString).deletingLastPathComponent
        break
    }

    guard let html = nccHTML else {
        throw TestError.assertionFailed("No ncc.html found")
    }

    let parser = DAISYTestNCCParser(html: html)
    let metadata = parser.parse()

    // Try to find and convert HTML content files
    var markdown = ""
    for entry in archive {
        let path = entry.path.lowercased()
        // Skip ncc.html itself, skip non-HTML
        if path.hasSuffix("ncc.html") || path.hasSuffix("ncc.htm") { continue }
        if !path.hasSuffix(".html") && !path.hasSuffix(".htm") && !path.hasSuffix(".xhtml") { continue }

        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        if let contentHTML = String(data: data, encoding: .utf8) {
            let converted = (try? parseHTML(html: contentHTML).chapters.first?.text) ?? ""
            if !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                markdown += converted + "\n\n"
            }
        }
    }

    // Fall back to NCC headings if no content HTML found
    if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        markdown = "# \(metadata.title)\n\n"
    }

    return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
}


// MARK: - MD5 Hashing

func md5Hash(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { handle.closeFile() }
    var hasher = Insecure.MD5()
    let bufferSize = 1024 * 1024
    while autoreleasepool(invoking: {
        let chunk = handle.readData(ofLength: bufferSize)
        guard !chunk.isEmpty else { return false }
        hasher.update(data: chunk)
        return true
    }) {}
    let digest = hasher.finalize()
    return digest.map { String(format: "%02hhx", $0) }.joined()
}
