import Foundation
import ZIPFoundation
import SwiftSoup

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

/// Wraps a DAISYFileProvider to cache the listFiles() result. DAISY parsing
/// calls listFiles() many times (version detection, OPF lookup, metadata, etc.)
/// and each call enumerates the ZIP archive or filesystem. Caching avoids
/// redundant I/O.
class CachingFileProvider: DAISYFileProvider {
    private let inner: DAISYFileProvider
    private var cachedFiles: [String]?

    init(wrapping provider: DAISYFileProvider) {
        self.inner = provider
    }

    func listFiles() -> [String] {
        if let cached = cachedFiles { return cached }
        let files = inner.listFiles()
        cachedFiles = files
        return files
    }

    func readFile(at path: String) throws -> Data {
        try inner.readFile(at: path)
    }
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
        guard let version = detectVersion(in: provider) else {
            throw DAISYParserError.notDAISYBook
        }

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
        guard let version = detectVersion(in: provider) else {
            throw DAISYParserError.notDAISYBook
        }

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
        return detectVersion(in: provider) != nil
    }

    /// Detect whether a directory contains a DAISY book
    static func isDAISYDirectory(url: URL) -> Bool {
        let provider = DirectoryFileProvider(baseURL: url)
        return detectVersion(in: provider) != nil
    }

    // MARK: - File Access Abstraction

    /// Create the appropriate file provider for a URL (ZIP, directory, or single file).
    /// Returns a CachingFileProvider that avoids redundant listFiles() calls during
    /// version detection, OPF lookup, and metadata extraction.
    private static func makeFileProvider(from url: URL) throws -> DAISYFileProvider {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DAISYParserError.fileNotFound(url.path)
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        let base: DAISYFileProvider

        if isDir.boolValue {
            // Unzipped DAISY directory
            base = DirectoryFileProvider(baseURL: url)
        } else {
            let ext = url.pathExtension.lowercased()

            if ext == "zip" || ext == "daisy" {
                // ZIP archive
                do {
                    let archive = try Archive(url: url, accessMode: .read)
                    base = ArchiveFileProvider(archive: archive)
                } catch {
                    throw DAISYParserError.invalidArchive
                }
            } else if ext == "opf" {
                // .opf file — treat the containing directory as the DAISY book
                let parentDir = url.deletingLastPathComponent()
                base = DirectoryFileProvider(baseURL: parentDir)
            } else if let archive = try? Archive(url: url, accessMode: .read) {
                // Try opening as ZIP anyway (some DAISY files don't have .zip extension)
                base = ArchiveFileProvider(archive: archive)
            } else {
                throw DAISYParserError.notDAISYBook
            }
        }

        return CachingFileProvider(wrapping: base)
    }

    // MARK: - Version Detection

    /// Detect the DAISY version by checking for format-specific signatures.
    /// Returns nil when the provider contains no DAISY package structure.
    private static func detectVersion(in provider: DAISYFileProvider) -> DAISYVersion? {
        let allFiles = provider.listFiles()

        // DAISY 2.02 packages use ncc.html (or the older .htm spelling) as
        // their navigation entry point. Compare the final path component so
        // packages nested inside a directory are detected consistently.
        if allFiles.contains(where: {
            let fileName = ($0 as NSString).lastPathComponent.lowercased()
            return fileName == "ncc.html" || fileName == "ncc.htm"
        }) {
            return .daisy202
        }

        // DAISY 3: has an .opf file
        if allFiles.contains(where: { $0.lowercased().hasSuffix(".opf") }) {
            return .daisy3
        }

        // A standalone DTBook can omit the OPF package. Inspect candidate XML
        // files rather than treating every archive containing XML as DAISY.
        if findDTBookXML(in: allFiles, provider: provider) != nil {
            return .daisy3
        }

        return nil
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

        // Collect DTBook content files, using spine order when available
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        var dtbookPaths: [String] = []

        if !opfResult.spineItemRefs.isEmpty {
            // Use spine order to determine reading sequence
            for idref in opfResult.spineItemRefs {
                guard let item = opfResult.manifest[idref] else { continue }
                if item.mediaType.contains("dtbook") || item.mediaType.contains("x-dtbook") {
                    let path = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
                    dtbookPaths.append(path)
                }
            }
        }

        // Fall back to scanning manifest if spine didn't yield DTBook files
        if dtbookPaths.isEmpty {
            for (_, item) in opfResult.manifest {
                if item.mediaType.contains("dtbook") || item.mediaType.contains("x-dtbook") {
                    let path = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
                    dtbookPaths.append(path)
                }
            }
        }

        // Last resort: find any .xml file that looks like DTBook
        if dtbookPaths.isEmpty {
            if let xmlPath = findDTBookXML(in: allFiles, provider: provider) {
                dtbookPaths.append(xmlPath)
            }
        }

        guard !dtbookPaths.isEmpty else {
            throw DAISYParserError.missingContent("No DTBook XML found in DAISY package")
        }

        // Convert each content file and concatenate in reading order
        var allMarkdown: [String] = []
        for path in dtbookPaths {
            let xmlData = try provider.readFile(at: path)
            let markdown = try convertDTBookToMarkdown(xmlData)
            if !markdown.isEmpty {
                allMarkdown.append(markdown)
            }
        }
        return allMarkdown.joined(separator: "\n\n")
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

        // Collect text fragments referenced by SMIL files, preserving NCC
        // heading order. Do not collapse "book.html#p1" down to "book.html":
        // many DAISY 2.02 books repeat wrapper/title text at the file level,
        // while SMIL points at the precise spoken fragment.
        var textReferences: [String] = []
        var seenReferences: Set<String> = []
        for heading in nccResult.headings {
            // Heading href → SMIL file → text content file
            let smilFile = ParserUtilities.resolvedPackagePath(
                heading.href,
                relativeTo: nccPath,
                preserveFragment: false
            )

            if let smilData = try? provider.readFile(at: smilFile) {
                let smilParser = DAISYSMILParser(data: smilData)
                let textRefs = smilParser.parseTextReferences()
                for ref in textRefs {
                    let textPath = ParserUtilities.resolvedPackagePath(
                        ref,
                        relativeTo: smilFile,
                        preserveFragment: true
                    )
                    if seenReferences.insert(textPath).inserted {
                        textReferences.append(textPath)
                    }
                }
            }
        }

        // If we found text references, extract and convert only those fragments.
        if !textReferences.isEmpty {
            let markdown = try extractDAISY202Fragments(from: textReferences, provider: provider)
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

    /// Extract DAISY 2.02 text references from their HTML fragments.
    /// Fragment-less references still convert the whole file, but SMIL
    /// references with #ids are narrowed to that element so content.md does not
    /// bake in duplicate wrapper text or unrelated file-level content.
    private static func extractDAISY202Fragments(
        from references: [String],
        provider: DAISYFileProvider
    ) throws -> String {
        var documents: [String: SwiftSoup.Document] = [:]
        var htmlByPath: [String: String] = [:]
        var fragments: [String] = []
        var lastNormalized = ""

        for reference in references {
            let split = ParserUtilities.splitFragment(reference)
            guard !split.path.isEmpty else { continue }

            let doc: SwiftSoup.Document
            let html: String
            if let cachedDoc = documents[split.path], let cachedHTML = htmlByPath[split.path] {
                doc = cachedDoc
                html = cachedHTML
            } else {
                guard let data = try? provider.readFile(at: split.path),
                      let decodedHTML = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1),
                      !decodedHTML.isEmpty else {
                    continue
                }
                html = decodedHTML
                doc = try SwiftSoup.parse(decodedHTML)
                documents[split.path] = doc
                htmlByPath[split.path] = decodedHTML
            }

            let fragmentMarkdown: String
            if split.fragment.isEmpty {
                fragmentMarkdown = (try? HTMLToMarkdownConverter.convert(html)) ?? ""
            } else if let element = try doc.getElementById(split.fragment) {
                fragmentMarkdown = try convertDAISY202FragmentElement(element)
            } else {
                continue
            }

            let normalized = ParserUtilities.normalizeMarkdownWhitespace(fragmentMarkdown)
            guard !normalized.isEmpty, normalized != lastNormalized else { continue }
            fragments.append(normalized)
            lastNormalized = normalized
        }

        return ParserUtilities.normalizeMarkdownWhitespace(fragments.joined(separator: "\n\n"))
    }

    private static func convertDAISY202FragmentElement(_ element: SwiftSoup.Element) throws -> String {
        let tag = element.tagName().lowercased()
        if tag == "a" {
            return try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let childElements = element.children().array()
        if ["span", "strong", "em", "b", "i", "sup", "sub"].contains(tag),
           let firstChild = childElements.first {
            return try convertDAISY202FragmentElement(firstChild)
        }

        let html = try element.outerHtml()
        return try HTMLToMarkdownConverter.convert(html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
