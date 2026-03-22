import Foundation
import ZIPFoundation

// MARK: - Error Types

/// Errors that can occur when parsing a DAISY book
enum DAISYParserError: LocalizedError {
    case fileNotFound(String)
    case invalidArchive
    case notDAISYBook
    case missingContent(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "DAISY file not found at: \(path)"
        case .invalidArchive: return "The DAISY file could not be opened as a ZIP archive."
        case .notDAISYBook: return "Not a valid DAISY book (no OPF or ncc.html found)."
        case .missingContent(let msg): return "Missing DAISY content: \(msg)"
        case .parseError(let msg): return "DAISY parse error: \(msg)"
        }
    }
}

// MARK: - DAISY Version Detection

/// Which version of the DAISY standard this book uses
enum DAISYVersion {
    case daisy202   // DAISY 2.02 — ncc.html entry point, XHTML content
    case daisy3     // DAISY 3 (Z39.86-2005) — OPF entry point, DTBook XML content
}

// MARK: - Main Parser

/// Parses DAISY 2.02 and DAISY 3 books, extracting text content as Markdown.
/// Handles both zipped packages and unzipped directories.
///
/// DAISY 3: Reads OPF for metadata, DTBook XML for content, NCX for navigation.
/// DAISY 2.02: Reads ncc.html for metadata/navigation, content HTML files for text.
enum DAISYParser {

    // MARK: - Public API

    /// Parse a DAISY book into DocumentContent for reading/playback.
    /// Accepts a ZIP file, a directory, or an individual .opf/.daisy file.
    static func parse(url: URL) throws -> DocumentContent {
        let markdown = try extractMarkdown(from: url)
        let metadata = try? readMetadata(from: url)
        let title = metadata?.title ?? url.deletingPathExtension().lastPathComponent
        let author = metadata?.author ?? "Unknown"

        let content = try MarkdownDocParser.parse(markdown: markdown, title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// Extract Markdown from a DAISY book. Main conversion entry point for
    /// MarkdownCacheService cache generation.
    static func extractMarkdown(from url: URL) throws -> String {
        let provider = try makeFileProvider(from: url)
        let version = detectVersion(in: provider)

        switch version {
        case .daisy3:
            return try extractDAISY3Markdown(from: provider)
        case .daisy202:
            return try extractDAISY202Markdown(from: provider)
        }
    }

    /// Read metadata (title, author) from a DAISY book
    static func readMetadata(from url: URL) throws -> DAISYMetadata? {
        let provider = try makeFileProvider(from: url)
        let version = detectVersion(in: provider)

        switch version {
        case .daisy3:
            return try readDAISY3Metadata(from: provider)
        case .daisy202:
            return try readDAISY202Metadata(from: provider)
        }
    }

    /// Detect whether a ZIP file contains a DAISY book.
    /// Used by the import system to identify DAISY packages in zip imports.
    static func isDAISYZip(url: URL) -> Bool {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return false }
        let provider = ArchiveFileProvider(archive: archive)
        let version = detectVersion(in: provider)
        // notDAISYBook means we couldn't detect either format
        switch version {
        case .daisy202, .daisy3: return true
        }
    }

    /// Detect whether a directory contains a DAISY book
    static func isDAISYDirectory(url: URL) -> Bool {
        let provider = DirectoryFileProvider(baseURL: url)
        let version = detectVersion(in: provider)
        switch version {
        case .daisy202, .daisy3: return true
        }
    }

    // MARK: - File Access Abstraction

    /// Create the appropriate file provider for a URL (ZIP, directory, or single file)
    private static func makeFileProvider(from url: URL) throws -> DAISYFileProvider {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DAISYParserError.fileNotFound(url.path)
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            // Unzipped DAISY directory
            return DirectoryFileProvider(baseURL: url)
        }

        let ext = url.pathExtension.lowercased()

        // If it's a ZIP file, open as archive
        if ext == "zip" || ext == "daisy" {
            do {
                let archive = try Archive(url: url, accessMode: .read)
                return ArchiveFileProvider(archive: archive)
            } catch {
                throw DAISYParserError.invalidArchive
            }
        }

        // If it's an .opf file, treat the containing directory as the DAISY book
        if ext == "opf" {
            let parentDir = url.deletingLastPathComponent()
            return DirectoryFileProvider(baseURL: parentDir)
        }

        // Try opening as ZIP anyway (some DAISY files don't have .zip extension)
        if let archive = try? Archive(url: url, accessMode: .read) {
            return ArchiveFileProvider(archive: archive)
        }

        throw DAISYParserError.notDAISYBook
    }

    // MARK: - Version Detection

    /// Detect the DAISY version by checking for signature files
    private static func detectVersion(in provider: DAISYFileProvider) -> DAISYVersion {
        // DAISY 2.02: has ncc.html (case-insensitive)
        let allFiles = provider.listFiles()
        let lowerFiles = allFiles.map { $0.lowercased() }

        if lowerFiles.contains("ncc.html") || lowerFiles.contains(where: {
            $0.hasSuffix("/ncc.html") || $0 == "ncc.htm"
        }) {
            return .daisy202
        }

        // DAISY 3: has an .opf file
        if allFiles.contains(where: { $0.lowercased().hasSuffix(".opf") }) {
            return .daisy3
        }

        // Check for DTBook XML as fallback (standalone DTBook)
        if allFiles.contains(where: { $0.lowercased().hasSuffix(".xml") }) {
            // Could be a standalone DTBook — treat as DAISY 3
            return .daisy3
        }

        // Default to DAISY 3 (will fail later with appropriate error)
        return .daisy3
    }

    // MARK: - DAISY 3 Extraction

    /// Extract Markdown from a DAISY 3 book (DTBook XML content)
    private static func extractDAISY3Markdown(from provider: DAISYFileProvider) throws -> String {
        // Find the OPF file
        let allFiles = provider.listFiles()
        guard let opfPath = allFiles.first(where: { $0.lowercased().hasSuffix(".opf") }) else {
            // Try to find a standalone DTBook XML
            guard let xmlPath = findDTBookXML(in: allFiles, provider: provider) else {
                throw DAISYParserError.missingContent("No OPF or DTBook XML found")
            }
            let xmlData = try provider.readFile(at: xmlPath)
            return try convertDTBookToMarkdown(xmlData)
        }

        // Parse OPF to find the DTBook XML file
        let opfData = try provider.readFile(at: opfPath)
        let opfParser = DAISYOPFParser(data: opfData)
        let opfResult = opfParser.parse()

        // Find the DTBook XML in the manifest
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        var dtbookPath: String?

        for (_, item) in opfResult.manifest {
            if item.mediaType.contains("dtbook") || item.mediaType.contains("x-dtbook") {
                dtbookPath = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
                break
            }
        }

        // Fall back to finding any .xml file that looks like DTBook
        if dtbookPath == nil {
            dtbookPath = findDTBookXML(in: allFiles, provider: provider)
        }

        guard let xmlPath = dtbookPath else {
            throw DAISYParserError.missingContent("No DTBook XML found in DAISY package")
        }

        let xmlData = try provider.readFile(at: xmlPath)
        return try convertDTBookToMarkdown(xmlData)
    }

    /// Find a DTBook XML file by scanning for files with <dtbook> root element
    private static func findDTBookXML(in files: [String], provider: DAISYFileProvider) -> String? {
        for path in files where path.lowercased().hasSuffix(".xml") {
            // Skip known non-DTBook XML files
            let filename = (path as NSString).lastPathComponent.lowercased()
            if filename == "metadata.xml" || filename.hasSuffix(".ncx") { continue }

            // Check if this XML has a dtbook root element
            if let data = try? provider.readFile(at: path) {
                let prefix = String(data: data.prefix(500), encoding: .utf8) ?? ""
                if prefix.contains("dtbook") {
                    return path
                }
            }
        }
        return nil
    }

    /// Read metadata from a DAISY 3 OPF file
    private static func readDAISY3Metadata(from provider: DAISYFileProvider) throws -> DAISYMetadata? {
        let allFiles = provider.listFiles()
        guard let opfPath = allFiles.first(where: { $0.lowercased().hasSuffix(".opf") }) else {
            return nil
        }
        let opfData = try provider.readFile(at: opfPath)
        let opfParser = DAISYOPFParser(data: opfData)
        let result = opfParser.parse()
        return DAISYMetadata(title: result.title, author: result.author)
    }

    // MARK: - DAISY 2.02 Extraction

    /// Extract Markdown from a DAISY 2.02 book (XHTML content)
    private static func extractDAISY202Markdown(from provider: DAISYFileProvider) throws -> String {
        // Find ncc.html (case-insensitive)
        let allFiles = provider.listFiles()
        guard let nccPath = allFiles.first(where: {
            $0.lowercased().hasSuffix("ncc.html") || $0.lowercased().hasSuffix("ncc.htm")
        }) else {
            throw DAISYParserError.missingContent("No ncc.html found for DAISY 2.02")
        }

        let nccData = try provider.readFile(at: nccPath)
        guard let nccHTML = String(data: nccData, encoding: .utf8)
                ?? String(data: nccData, encoding: .isoLatin1) else {
            throw DAISYParserError.parseError("Cannot decode ncc.html")
        }

        // Parse NCC for metadata and navigation structure
        let nccParser = DAISY202NCCParser(html: nccHTML)
        let nccResult = nccParser.parse()

        let nccDir = (nccPath as NSString).deletingLastPathComponent

        // Collect all text content files referenced by SMIL files
        var contentFiles: Set<String> = []
        for heading in nccResult.headings {
            // Heading href → SMIL file → text content file
            let smilRef = heading.href
            let smilPath = nccDir.isEmpty ? smilRef : "\(nccDir)/\(smilRef)"
            let smilFile = smilPath.components(separatedBy: "#").first ?? smilPath

            if let smilData = try? provider.readFile(at: smilFile) {
                let smilParser = DAISYSMILParser(data: smilData)
                let textRefs = smilParser.parseTextReferences()
                for ref in textRefs {
                    let textFile = ref.components(separatedBy: "#").first ?? ref
                    let fullPath = (smilFile as NSString).deletingLastPathComponent
                    let textPath = fullPath.isEmpty ? textFile : "\(fullPath)/\(textFile)"
                    contentFiles.insert(textPath)
                }
            }
        }

        // If we found text content files, extract and convert them
        if !contentFiles.isEmpty {
            var markdown = ""
            // Sort to maintain reading order
            let sortedFiles = contentFiles.sorted()
            for filePath in sortedFiles {
                if let data = try? provider.readFile(at: filePath),
                   let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) {
                    let converted = (try? HTMLToMarkdownConverter.convert(html)) ?? ""
                    if !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        markdown += converted + "\n\n"
                    }
                }
            }
            if !markdown.isEmpty { return markdown }
        }

        // Fallback: build Markdown from just the NCC headings
        // (this happens for audio-only DAISY 2.02 books)
        var markdown = ""
        for heading in nccResult.headings {
            let prefix = String(repeating: "#", count: min(heading.level, 6))
            markdown += "\n\(prefix) \(heading.text)\n\n"
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read metadata from a DAISY 2.02 ncc.html
    private static func readDAISY202Metadata(from provider: DAISYFileProvider) throws -> DAISYMetadata? {
        let allFiles = provider.listFiles()
        guard let nccPath = allFiles.first(where: {
            $0.lowercased().hasSuffix("ncc.html") || $0.lowercased().hasSuffix("ncc.htm")
        }) else {
            return nil
        }
        let nccData = try provider.readFile(at: nccPath)
        guard let nccHTML = String(data: nccData, encoding: .utf8)
                ?? String(data: nccData, encoding: .isoLatin1) else {
            return nil
        }
        let parser = DAISY202NCCParser(html: nccHTML)
        let result = parser.parse()
        return DAISYMetadata(title: result.title, author: result.author)
    }

    // MARK: - DTBook XML → Markdown Converter

    /// Convert DTBook XML data to Markdown text
    private static func convertDTBookToMarkdown(_ data: Data) throws -> String {
        let converter = DTBookToMarkdownConverter()
        return converter.convert(data: data)
    }
}

// MARK: - Metadata

/// Basic metadata extracted from a DAISY book
struct DAISYMetadata {
    var title: String
    var author: String
}

// MARK: - File Provider Protocol

/// Abstraction for reading files from either a ZIP archive or a directory
protocol DAISYFileProvider {
    /// List all file paths in the package
    func listFiles() -> [String]
    /// Read the contents of a file at the given relative path
    func readFile(at path: String) throws -> Data
}

/// Reads files from a ZIPFoundation Archive
class ArchiveFileProvider: DAISYFileProvider {
    let archive: Archive

    init(archive: Archive) {
        self.archive = archive
    }

    func listFiles() -> [String] {
        archive.compactMap { entry in
            // Skip directories
            guard entry.type == .file else { return nil }
            return entry.path
        }
    }

    func readFile(at path: String) throws -> Data {
        // Try exact match first
        if let entry = archive[path] {
            var data = Data()
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
            return data
        }
        // Try case-insensitive match
        let lowerPath = path.lowercased()
        for entry in archive where entry.type == .file {
            if entry.path.lowercased() == lowerPath {
                var data = Data()
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
                return data
            }
        }
        throw DAISYParserError.missingContent("File not found in archive: \(path)")
    }
}

/// Reads files from a filesystem directory
class DirectoryFileProvider: DAISYFileProvider {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func listFiles() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [String] = []
        let basePath = baseURL.path
        while let url = enumerator.nextObject() as? URL {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !isDir.boolValue {
                let relative = url.path.replacingOccurrences(of: basePath, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                files.append(relative)
            }
        }
        return files
    }

    func readFile(at path: String) throws -> Data {
        let fullURL = baseURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fullURL.path) else {
            throw DAISYParserError.missingContent("File not found: \(path)")
        }
        return try Data(contentsOf: fullURL)
    }
}

// MARK: - DAISY 3 OPF Parser

/// Parsed OPF package data
private struct DAISYOPFResult {
    var title: String = ""
    var author: String = ""
    var manifest: [String: DAISYManifestItem] = [:]
    var spineItemRefs: [String] = []
}

private struct DAISYManifestItem {
    var id: String
    var href: String
    var mediaType: String
}

/// SAX parser for DAISY 3 OPF package files.
/// These use the OEB package namespace and contain dc-metadata for Dublin Core fields.
private class DAISYOPFParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var result = DAISYOPFResult()

    // Parsing state
    private var elementStack: [String] = []
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> DAISYOPFResult {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        elementStack.append(localName.lowercased())
        currentText = ""

        switch localName.lowercased() {
        case "item":
            // Manifest item
            if let id = attributes["id"], let href = attributes["href"],
               let mediaType = attributes["media-type"] {
                result.manifest[id] = DAISYManifestItem(id: id, href: href, mediaType: mediaType)
            }
        case "itemref":
            // Spine item reference
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
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localName {
        case "title":
            if result.title.isEmpty && !text.isEmpty { result.title = text }
        case "creator":
            if result.author.isEmpty && !text.isEmpty { result.author = text }
        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}

// MARK: - DTBook XML → Markdown Converter

/// Converts DTBook XML (DAISY 3 text content) to Markdown.
/// Uses SAX parsing to walk the DTBook element tree and emit Markdown output.
private class DTBookToMarkdownConverter: NSObject, XMLParserDelegate {
    private var markdown = ""
    private var elementStack: [String] = []

    // Track whether we're in a list and its type
    private var listTypeStack: [String] = [] // "ul" or "ol"
    private var listCounterStack: [Int] = []
    private var listDepth = 0

    // Inline formatting
    private var isInEmphasis = false
    private var isInStrong = false

    // Track block context for proper spacing
    private var lastOutputWasBlock = false

    // Skip elements (head, prodnote content, etc.)
    private var skipDepth = 0

    /// Convert DTBook XML data to Markdown
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
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
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

        // Page numbers — emit as a comment marker
        case "pagenum":
            break // We'll capture the text and emit it in endElement

        // Table elements
        case "table":
            ensureBlankLine()
        case "tr":
            markdown += "| "
        case "th", "td":
            break // text will be captured

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
        markdown += string
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastOutputWasBlock = false
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()

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

        case "blockquote":
            markdown += "\n\n"
            lastOutputWasBlock = true

        case "a":
            // Close link — we'd need the href, but in DTBook links are rare
            // For simplicity, just close the bracket
            markdown += "]"

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

// MARK: - DAISY 2.02 NCC Parser

/// Parsed NCC (Navigation Control Center) data from a DAISY 2.02 book
private struct DAISY202NCCResult {
    var title: String = ""
    var author: String = ""
    var headings: [NCCHeading] = []
}

private struct NCCHeading {
    var level: Int
    var text: String
    var href: String
}

/// SAX parser for DAISY 2.02 ncc.html files.
/// Extracts metadata from <meta> tags and navigation structure from headings.
private class DAISY202NCCParser: NSObject, XMLParserDelegate {
    private let html: String
    private var result = DAISY202NCCResult()

    // Parsing state
    private var elementStack: [String] = []
    private var currentText = ""
    private var currentHeadingLevel: Int?
    private var currentHref = ""
    private var inHeading = false
    private var inAnchor = false

    init(html: String) {
        self.html = html
    }

    func parse() -> DAISY202NCCResult {
        // NCC files may not be well-formed XML, so try to clean them up
        var cleanedHTML = html
        // Add XML declaration if missing
        if !cleanedHTML.hasPrefix("<?xml") {
            cleanedHTML = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + cleanedHTML
        }

        guard let data = cleanedHTML.data(using: .utf8) else { return result }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        elementStack.append(localName)

        switch localName {
        case "meta":
            // Extract Dublin Core metadata from meta tags
            let name = (attributes["name"] ?? "").lowercased()
            let content = attributes["content"] ?? ""
            switch name {
            case "dc:title":
                if result.title.isEmpty { result.title = content }
            case "dc:creator":
                if result.author.isEmpty { result.author = content }
            default:
                break
            }

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(localName.last!)) ?? 1
            currentHeadingLevel = level
            currentText = ""
            currentHref = ""
            inHeading = true

        case "a" where inHeading:
            currentHref = attributes["href"] ?? ""
            inAnchor = true

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inHeading {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()

        switch localName {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if let level = currentHeadingLevel {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.headings.append(NCCHeading(level: level, text: text, href: currentHref))
                }
            }
            inHeading = false
            currentHeadingLevel = nil

        case "a":
            inAnchor = false

        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }
}

// MARK: - SMIL Parser

/// Minimal SAX parser for DAISY SMIL files.
/// Extracts text content references (the src attributes of <text> elements).
private class DAISYSMILParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var textReferences: [String] = []

    init(data: Data) {
        self.data = data
    }

    func parseTextReferences() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return textReferences
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        if localName == "text" {
            if let src = attributes["src"], !src.isEmpty {
                textReferences.append(src)
            }
        }
    }
}
