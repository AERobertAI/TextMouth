import Foundation
import ZIPFoundation

// MARK: - Error Types

/// Errors that can occur when parsing a DOCX file
enum DOCXParserError: LocalizedError {
    case fileNotFound(String)
    case invalidArchive
    case missingEntry(String)
    /// A part of the package is damaged: its markup breaks off or is not
    /// well-formed, so reading on would silently yield a partial document,
    /// or it holds more than TextMouth reads from one file. `file` is the
    /// part's path inside the package; `reason` completes the sentence "The
    /// file is damaged or incomplete: …".
    case malformedXML(file: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "DOCX file not found at: \(path)"
        case .invalidArchive: return "The DOCX file could not be opened as a ZIP archive."
        case .missingEntry(let path): return "The DOCX file is missing required entry: \(path)"
        case .malformedXML(let file, let reason):
            return PackageDamage.message(
                file: file, reason: reason, container: "this document", original: "the document"
            )
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
    /// - Parameter reportIncompleteContent: receives a diagnostic when the
    ///   document's text part broke off after some of its text was read.
    ///   That text stays in the result; the diagnostic never enters it. The
    ///   default writes the diagnostic to the console and the debug log.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when the
    ///   styles, numbering, or relationships part is present but damaged,
    ///   since reading on would silently turn headings into plain paragraphs,
    ///   numbered steps into bullets, or links into bare text; or when the
    ///   text part is damaged before any of its text.
    static func extractMarkdown(
        from url: URL,
        reportIncompleteContent: (DOCXParserError) -> Void = DOCXParser.logIncompleteContent
    ) throws -> String {
        let archive = IndexedArchive(try openArchive(at: url))

        // Parse styles first so we can identify heading paragraph styles
        let styles = try parseStyles(from: archive)

        // Parse numbering definitions for bullet and numbered lists
        let numbering = try parseNumbering(from: archive)

        // Read the main document content. Its raw bytes go to the parser,
        // which honors the declared encoding and reports any invalid byte.
        let documentXML = try extractData(from: archive, path: Part.document)

        // Parse relationships for hyperlink targets
        let relationships = try parseRelationships(from: archive)

        let conversion = try DOCXToMarkdownConverter(
            data: documentXML,
            file: Part.document,
            styles: styles,
            numbering: numbering,
            relationships: relationships
        ).convert()
        if let diagnostic = conversion.diagnostic {
            reportIncompleteContent(diagnostic)
        }
        return conversion.markdown
    }

    /// Default report for a document whose text part broke off after some of
    /// its text was read: one line in the console and in the debug log. The
    /// import layer has no warning channel yet, so the reader is not told;
    /// the recovered words stay readable either way.
    static func logIncompleteContent(_ diagnostic: DOCXParserError) {
        PackageDamage.log(diagnostic, tag: "DOCX_INCOMPLETE_CONTENT")
    }

    /// Read basic metadata (title, author) from the DOCX core properties.
    /// - Parameter reportDamagedMetadata: receives the error when the core
    ///   properties part is present but damaged. Its metadata is then not
    ///   used at all, so the document keeps its file name as its title: a
    ///   damaged part never fails an import. The default writes the error
    ///   to the console and the debug log.
    /// - Returns: nil when the file cannot be opened, has no core properties,
    ///   or has damaged ones.
    static func readMetadata(
        from url: URL,
        reportDamagedMetadata: (DOCXParserError) -> Void = DOCXParser.logDamagedMetadata
    ) throws -> DOCXMetadata? {
        guard let archive = (try? openArchive(at: url)).map(IndexedArchive.init) else { return nil }

        // Core properties live in docProps/core.xml
        guard let coreData = try? extractData(from: archive, path: Part.coreProperties) else {
            return nil
        }

        do {
            return try DOCXMetadataParser(data: coreData, file: Part.coreProperties).parse()
        } catch let damage as DOCXParserError {
            reportDamagedMetadata(damage)
            return nil
        }
    }

    /// Default report for damaged core properties: one line in the console
    /// and in the debug log. The document is read under its file name.
    static func logDamagedMetadata(_ damage: DOCXParserError) {
        PackageDamage.log(damage, tag: "DOCX_DAMAGED_METADATA")
    }

    /// Read style semantics using the same archive path as full conversion.
    /// Exposed internally so regression tests validate the production style parser.
    /// - Throws: `DOCXParserError.malformedXML` when the styles part is damaged.
    static func readStyles(from url: URL) throws -> DOCXStyles {
        try parseStyles(from: IndexedArchive(try openArchive(at: url)))
    }

    // MARK: - ZIP Extraction Helpers

    // Each part is found in the package's entries, read once into an index
    // when the package is opened (`IndexedArchive`, PERF20).

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
    private static func extractData(from archive: IndexedArchive, path: String) throws -> Data {
        guard let data = try extractOptionalData(from: archive, path: path) else {
            throw DOCXParserError.missingEntry(path)
        }
        return data
    }

    /// Extract the raw data of the entry at `path`, or nil when the archive
    /// has no such entry. The entry is read through the shared
    /// `ArchiveEntryReader`, so a part larger than the most TextMouth reads
    /// from one file is refused rather than read whole into memory (TODO I05).
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it holds
    ///   more than `ArchiveEntryLimits.current` allows, or the archive's
    ///   error when the entry exists but cannot be unpacked.
    private static func extractOptionalData(from archive: IndexedArchive, path: String) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        do {
            return try ArchiveEntryReader.read(entry, in: archive.archive).data
        } catch let overflow as ArchiveEntryOverflow {
            throw DOCXParserError.malformedXML(file: path, reason: overflow.reason)
        }
    }

    // MARK: - Structure Parts

    /// Parse the optional part at `path` with `parse`, which receives the
    /// part's bytes and its path, or return `absent` when the package has no
    /// such part: a document without lists, say, simply has no numbering.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   present but damaged, or the archive's error when it cannot be unpacked.
    private static func parseOptionalPart<Content>(
        _ path: String,
        in archive: IndexedArchive,
        absent: Content,
        parse: (_ data: Data, _ path: String) throws -> Content
    ) throws -> Content {
        guard let data = try extractOptionalData(from: archive, path: path) else { return absent }
        return try parse(data, path)
    }

    /// Extract and parse the styles.xml to build a map of style IDs to heading levels
    private static func parseStyles(from archive: IndexedArchive) throws -> DOCXStyles {
        try parseOptionalPart(Part.styles, in: archive, absent: DOCXStyles()) { data, path in
            try DOCXStylesParser(data: data, file: path).parse()
        }
    }

    /// Extract and parse numbering.xml for list definitions
    private static func parseNumbering(from archive: IndexedArchive) throws -> DOCXNumbering {
        try parseOptionalPart(Part.numbering, in: archive, absent: DOCXNumbering()) { data, path in
            try DOCXNumberingParser(data: data, file: path).parse()
        }
    }

    /// Extract and parse document relationships for hyperlink targets
    private static func parseRelationships(from archive: IndexedArchive) throws -> [String: String] {
        try parseOptionalPart(Part.documentRelationships, in: archive, absent: [:]) { data, path in
            try DOCXRelationshipsParser(data: data, file: path).parse()
        }
    }
}
