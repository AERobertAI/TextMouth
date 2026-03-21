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
