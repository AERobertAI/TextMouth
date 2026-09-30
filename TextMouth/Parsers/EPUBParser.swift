import Foundation
import ZIPFoundation
import SwiftSoup

enum EPUBParserError: LocalizedError {
    case invalidArchive
    case fileNotFound(String)
    case missingContainer
    case missingOPF
    case invalidOPF
    case missingSpine
    case writeFailed(String)
    /// A file in the package is present but unusable: its data could not be
    /// decompressed, or it does not match the checksum the archive stores
    /// for it. `file` is the file's path inside the package; `reason`
    /// completes the sentence "The file is damaged or incomplete: …".
    case damagedFile(file: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The EPUB file could not be opened as a ZIP archive."
        case .fileNotFound(let path): return "The EPUB file was not found at: \(path)"
        case .missingContainer: return "The EPUB is missing META-INF/container.xml."
        case .missingOPF: return "The EPUB is missing its package document (OPF file)."
        case .invalidOPF: return "The EPUB package document could not be parsed."
        case .missingSpine: return "The EPUB has no reading order (spine)."
        case .writeFailed(let msg): return "Failed to write EPUB metadata: \(msg)"
        case .damagedFile(let file, let reason):
            return PackageDamage.message(
                file: file, reason: reason, container: EPUBParser.bookNameInMessages, original: "the book"
            )
        }
    }
}

enum EPUBParser {

    /// How sentences about a damaged or incomplete EPUB name the book, as in
    /// "The file “OEBPS/ch07.xhtml” in this EPUB book is damaged …".
    static let bookNameInMessages = "this EPUB book"

    static func parse(url: URL) throws -> DocumentContent {
        // Verify the file exists before attempting to open as a ZIP archive,
        // so the error message distinguishes "missing file" from "corrupt archive"
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EPUBParserError.fileNotFound(url.path)
        }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBParserError.invalidArchive
        }

        // Step 1: Read container.xml to find OPF path
        let containerXML = try extractString(archive: archive, path: "META-INF/container.xml")
        let opfPath = try parseContainerForOPFPath(containerXML)

        // Step 2: Read and parse OPF
        let opfXML = try extractString(archive: archive, path: opfPath)
        let opfData = try parseOPF(opfXML)

        // Share navigation recovery and exact text coordinates with the cache.
        let chapters = try preparedChapters(archive: archive, opfPath: opfPath, opfData: opfData)

        return DocumentContent(
            title: opfData.title,
            author: opfData.author,
            chapters: chapters.map(\.chapter)
        )
    }

    // MARK: - Metadata

    static func readMetadata(url: URL) throws -> EPUBMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EPUBParserError.fileNotFound(url.path)
        }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBParserError.invalidArchive
        }
        let containerXML = try extractString(archive: archive, path: "META-INF/container.xml")
        let opfPath = try parseContainerForOPFPath(containerXML)
        let opfXML = try extractString(archive: archive, path: opfPath)
        return try parseMetadata(opfXML)
    }

    private static func parseMetadata(_ xml: String) throws -> EPUBMetadata {
        let doc = try XMLDocument(xmlString: xml)

        let title = (try? doc.nodes(forXPath: "//*[local-name()='title']"))?.first?.stringValue ?? ""
        let author = (try? doc.nodes(forXPath: "//*[local-name()='creator']"))?.first?.stringValue ?? ""
        let publisher = (try? doc.nodes(forXPath: "//*[local-name()='publisher']"))?.first?.stringValue ?? ""
        let date = (try? doc.nodes(forXPath: "//*[local-name()='date']"))?.first?.stringValue ?? ""
        let language = (try? doc.nodes(forXPath: "//*[local-name()='language']"))?.first?.stringValue ?? ""

        // Extract identifier (often ISBN)
        let identifiers = (try? doc.nodes(forXPath: "//*[local-name()='identifier']")) ?? []
        var isbn = ""
        var mainIdentifier = ""
        for node in identifiers {
            let val = node.stringValue ?? ""
            mainIdentifier = val
            // Check for ISBN pattern or opf:scheme="ISBN"
            if let elem = node as? XMLElement {
                let scheme = elem.attribute(forName: "scheme")?.stringValue ?? ""
                let opfScheme = elem.attribute(forName: "opf:scheme")?.stringValue ?? ""
                if scheme.uppercased().contains("ISBN") || opfScheme.uppercased().contains("ISBN") {
                    isbn = val
                }
            }
            // Heuristic: if it looks like an ISBN
            let stripped = val.replacingOccurrences(of: "-", with: "")
            if stripped.count == 10 || stripped.count == 13, stripped.allSatisfy({ $0.isNumber || $0 == "X" }) {
                isbn = val
            }
        }

        // EPUB version from package element
        let packageNodes = try doc.nodes(forXPath: "//*[local-name()='package']")
        let version = (packageNodes.first as? XMLElement)?.attribute(forName: "version")?.stringValue ?? ""

        return EPUBMetadata(
            title: title,
            author: author,
            publisher: publisher,
            publicationDate: date,
            isbn: isbn,
            language: language,
            identifier: mainIdentifier,
            epubVersion: version
        )
    }

    /// Write updated metadata back to the EPUB file in place.
    /// Returns the new MD5 hash of the modified file.
    static func writeMetadata(
        _ metadata: EPUBMetadata,
        to url: URL,
        replacingWith replacement: ((URL, URL) throws -> Void)? = nil
    ) throws -> String {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBParserError.invalidArchive
        }

        let containerXML = try extractString(archive: archive, path: "META-INF/container.xml")
        let opfPath = try parseContainerForOPFPath(containerXML)
        let opfXML = try extractString(archive: archive, path: opfPath)

        // Parse and modify the OPF XML
        let updatedXML = try updateOPFMetadata(opfXML: opfXML, metadata: metadata)

        // We need to create a new archive with the updated OPF
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Copy original
        try FileManager.default.copyItem(at: url, to: tempURL)

        // Replace the OPF entry in the copy
        let writeArchive: Archive
        do {
            writeArchive = try Archive(url: tempURL, accessMode: .update)
        } catch {
            throw EPUBParserError.writeFailed("Could not open archive for writing")
        }

        // Remove old OPF and add updated one
        guard let oldEntry = writeArchive[opfPath] else {
            throw EPUBParserError.writeFailed("Could not find OPF entry")
        }
        try writeArchive.remove(oldEntry)

        let updatedData = updatedXML.data(using: .utf8) ?? Data()
        try writeArchive.addEntry(
            with: opfPath,
            type: .file,
            uncompressedSize: Int64(updatedData.count),
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, updatedData.count)
                return updatedData[start..<end]
            }
        )

        // Reopen and parse the prepared archive before touching the original.
        // This catches a corrupt update while the source EPUB is still intact.
        guard let preparedArchive = try? Archive(url: tempURL, accessMode: .read),
              let preparedOPF = try? extractString(archive: preparedArchive, path: opfPath) else {
            throw EPUBParserError.writeFailed("Updated archive failed validation")
        }
        _ = try parseOPF(preparedOPF)

        // Replace in one filesystem operation. Both files are in the same
        // directory, allowing FileManager to perform an atomic swap instead of
        // exposing a window where the original path does not exist.
        let replace = replacement ?? { originalURL, preparedURL in
            _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: preparedURL)
        }
        try replace(url, tempURL)

        // Recalculate hash
        return try FileImportService.md5Hash(of: url)
    }

    private static func updateOPFMetadata(opfXML: String, metadata: EPUBMetadata) throws -> String {
        let doc = try XMLDocument(xmlString: opfXML)

        // Update title
        if let titleNode = (try? doc.nodes(forXPath: "//*[local-name()='title']"))?.first {
            titleNode.stringValue = metadata.title
        }

        // Update author/creator
        if let creatorNode = (try? doc.nodes(forXPath: "//*[local-name()='creator']"))?.first {
            creatorNode.stringValue = metadata.author
        }

        // Update publisher
        if let pubNode = (try? doc.nodes(forXPath: "//*[local-name()='publisher']"))?.first {
            pubNode.stringValue = metadata.publisher
        } else if !metadata.publisher.isEmpty {
            // Add publisher if it doesn't exist
            if let metadataNode = (try? doc.nodes(forXPath: "//*[local-name()='metadata']"))?.first as? XMLElement {
                let pubElem = XMLElement(name: "dc:publisher")
                pubElem.stringValue = metadata.publisher
                metadataNode.addChild(pubElem)
            }
        }

        // Update date
        if let dateNode = (try? doc.nodes(forXPath: "//*[local-name()='date']"))?.first {
            dateNode.stringValue = metadata.publicationDate
        } else if !metadata.publicationDate.isEmpty {
            if let metadataNode = (try? doc.nodes(forXPath: "//*[local-name()='metadata']"))?.first as? XMLElement {
                let dateElem = XMLElement(name: "dc:date")
                dateElem.stringValue = metadata.publicationDate
                metadataNode.addChild(dateElem)
            }
        }

        return doc.xmlString(options: [.nodePrettyPrint])
    }

    // MARK: - Container Parsing (shared with MarkdownCacheService)

    static func parseContainerForOPFPath(_ xml: String) throws -> String {
        let doc = try XMLDocument(xmlString: xml)
        let rootfiles = try doc.nodes(forXPath: "//*[local-name()='rootfile']")
        guard let rootfile = rootfiles.first,
              let element = rootfile as? XMLElement,
              let fullPath = element.attribute(forName: "full-path")?.stringValue else {
            throw EPUBParserError.missingOPF
        }
        return fullPath
    }

    // MARK: - OPF Parsing (shared with MarkdownCacheService)

    struct OPFData {
        var title: String
        var author: String
        var manifest: [String: ManifestItem]  // id -> item
        var spineItemRefs: [String]  // ordered manifest IDs
        var spineTOCID: String? = nil
        var guideTOCHrefs: [String] = []
    }

    struct ManifestItem {
        var href: String
        var mediaType: String
        var properties: String = ""
    }

    static func parseOPF(_ xml: String) throws -> OPFData {
        let doc = try XMLDocument(xmlString: xml)

        // Metadata
        let titles = try doc.nodes(forXPath: "//*[local-name()='title']")
        let title = titles.first?.stringValue ?? "Untitled"

        let creators = try doc.nodes(forXPath: "//*[local-name()='creator']")
        let author = creators.first?.stringValue ?? "Unknown"

        // Manifest
        let manifestNodes = try doc.nodes(forXPath: "//*[local-name()='item']")
        var manifest: [String: ManifestItem] = [:]
        for node in manifestNodes {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue,
                  let mediaType = element.attribute(forName: "media-type")?.stringValue else {
                continue
            }
            manifest[id] = ManifestItem(
                href: href, mediaType: mediaType,
                properties: element.attribute(forName: "properties")?.stringValue ?? ""
            )
        }

        // Spine
        let spineNodes = try doc.nodes(forXPath: "//*[local-name()='itemref']")
        let spineItemRefs = spineNodes.compactMap { node -> String? in
            (node as? XMLElement)?.attribute(forName: "idref")?.stringValue
        }

        guard !spineItemRefs.isEmpty else {
            throw EPUBParserError.missingSpine
        }

        // Preserve the declared NCX and legacy visible-TOC references rather
        // than choosing navigation files by dictionary iteration order.
        let spine = (try doc.nodes(forXPath: "//*[local-name()='spine']")).first as? XMLElement
        let guideReferences = try doc.nodes(forXPath: "//*[local-name()='guide']/*[local-name()='reference']")
        let guideTOCHrefs = guideReferences.compactMap { node -> String? in
            guard let element = node as? XMLElement,
                  element.attribute(forName: "type")?.stringValue == "toc" else { return nil }
            return element.attribute(forName: "href")?.stringValue
        }
        return OPFData(
            title: title,
            author: author,
            manifest: manifest,
            spineItemRefs: spineItemRefs,
            spineTOCID: spine?.attribute(forName: "toc")?.stringValue,
            guideTOCHrefs: guideTOCHrefs
        )
    }

    // MARK: - Chapter HTML Parsing

    /// Convert one EPUB spine document using the same navigation filtering as full parsing.
    static func parseChapterHTML(_ html: String) throws -> Chapter {
        // Markdown records heading offsets during extraction, so an earlier
        // body occurrence of the label cannot steal the heading's position.
        let markdown = try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
        return try MarkdownDocParser.parseChapter(markdown: markdown, title: "")
    }

    // MARK: - ZIP Helpers (shared with MarkdownCacheService)

    /// The text of the archive member at `path`.
    /// - Throws: `EPUBParserError.missingContainer` or `.invalidOPF` when no
    ///   member is at `path`, and `.damagedFile` when it cannot be decoded.
    static func extractString(archive: Archive, path: String) throws -> String {
        guard let entry = archive[path] else {
            if path == "META-INF/container.xml" {
                throw EPUBParserError.missingContainer
            }
            throw EPUBParserError.invalidOPF
        }
        return try text(of: entry, in: archive)
    }

    /// The text of the archive member `entry`, decoded as UTF-8, or as ISO
    /// Latin 1 when it is not valid UTF-8.
    ///
    /// ZIPFoundation's `extract` returns the checksum of the bytes it read
    /// without comparing it to the one the archive stores, so a damaged
    /// member would otherwise read as garbled text. The comparison is made
    /// here, except when the stored checksum is 0: ZIPFoundation reports 0
    /// for an entry whose data descriptor it could not read, so that value
    /// cannot judge the data. (Empty data's real checksum is 0 as well, and
    /// it has nothing to verify.)
    /// - Throws: `EPUBParserError.damagedFile` naming the member when its
    ///   data cannot be decompressed or does not match its checksum.
    static func text(of entry: Entry, in archive: Archive) throws -> String {
        var data = Data()
        let checksum: CRC32
        do {
            checksum = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
        } catch {
            throw EPUBParserError.damagedFile(file: entry.path, reason: "its compressed data could not be decoded")
        }
        guard entry.checksum == 0 || checksum == entry.checksum else {
            throw EPUBParserError.damagedFile(
                file: entry.path, reason: "its contents do not match the checksum stored with them"
            )
        }

        guard let string = String(data: data, encoding: .utf8) else {
            // Try other encodings
            if let latin1 = String(data: data, encoding: .isoLatin1) {
                return latin1
            }
            throw EPUBParserError.invalidOPF
        }
        return string
    }
}
