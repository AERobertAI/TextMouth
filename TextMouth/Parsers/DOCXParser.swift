import Foundation
import ZIPFoundation

// MARK: - Error Types

/// Errors that can occur when parsing a DOCX file
enum DOCXParserError: LocalizedError {
    case fileNotFound(String)
    case invalidArchive
    case missingEntry(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "DOCX file not found at: \(path)"
        case .invalidArchive: return "The DOCX file could not be opened as a ZIP archive."
        case .missingEntry(let path): return "The DOCX file is missing required entry: \(path)"
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

    /// Paths of the package parts TextMouth reads, as a DOCX package names them.
    enum Part {
        /// The document's text: paragraphs, runs, tables, and hyperlinks.
        static let document = "word/document.xml"
        /// Paragraph style definitions, which mark headings and list styles.
        static let styles = "word/styles.xml"
        /// List definitions, which say whether each list is bulleted or numbered.
        static let numbering = "word/numbering.xml"
        /// The document's relationships, which hold its hyperlink targets.
        static let documentRelationships = "word/_rels/document.xml.rels"
        /// Core properties: the document's title and author.
        static let coreProperties = "docProps/core.xml"
    }

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
        let archive = try openArchive(at: url)

        // Parse styles first so we can identify heading paragraph styles
        let styles = parseStyles(from: archive)

        // Parse numbering definitions for bullet and numbered lists
        let numbering = parseNumbering(from: archive)

        // Parse the main document content
        let documentXML = try extractData(from: archive, path: Part.document)
        guard let xmlString = String(data: documentXML, encoding: .utf8) else {
            throw DOCXParserError.parseError("Could not decode \(Part.document) as UTF-8")
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
        guard let archive = try? openArchive(at: url) else { return nil }

        // Core properties live in docProps/core.xml
        guard let coreData = try? extractData(from: archive, path: Part.coreProperties),
              let coreXML = String(data: coreData, encoding: .utf8) else {
            return nil
        }

        let parser = DOCXMetadataParser(xml: coreXML)
        return parser.parse()
    }

    /// Read style semantics using the same archive path as full conversion.
    /// Exposed internally so regression tests validate the production style parser.
    static func readStyles(from url: URL) throws -> DOCXStyles {
        parseStyles(from: try openArchive(at: url))
    }

    // MARK: - ZIP Extraction Helpers

    /// Open the DOCX package at `url` for reading.
    /// - Throws: `DOCXParserError.fileNotFound` when no file is there, or
    ///   `.invalidArchive` when it cannot be opened as a ZIP archive.
    private static func openArchive(at url: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DOCXParserError.fileNotFound(url.path)
        }
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw DOCXParserError.invalidArchive
        }
    }

    /// Extract raw data from a ZIP archive entry
    private static func extractData(from archive: Archive, path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw DOCXParserError.missingEntry(path)
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return data
    }

    /// Extract and parse the styles.xml to build a map of style IDs to heading levels
    private static func parseStyles(from archive: Archive) -> DOCXStyles {
        guard let data = try? extractData(from: archive, path: Part.styles),
              let xml = String(data: data, encoding: .utf8) else {
            return DOCXStyles()
        }
        let parser = DOCXStylesParser(xml: xml)
        return parser.parse()
    }

    /// Extract and parse numbering.xml for list definitions
    private static func parseNumbering(from archive: Archive) -> DOCXNumbering {
        guard let data = try? extractData(from: archive, path: Part.numbering),
              let xml = String(data: data, encoding: .utf8) else {
            return DOCXNumbering()
        }
        let parser = DOCXNumberingParser(xml: xml)
        return parser.parse()
    }

    /// Extract and parse document relationships for hyperlink targets
    private static func parseRelationships(from archive: Archive) -> [String: String] {
        guard let data = try? extractData(from: archive, path: Part.documentRelationships),
              let xml = String(data: data, encoding: .utf8) else {
            return [:]
        }
        let parser = DOCXRelationshipsParser(xml: xml)
        return parser.parse()
    }
}
