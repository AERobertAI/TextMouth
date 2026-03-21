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

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The EPUB file could not be opened as a ZIP archive."
        case .fileNotFound(let path): return "The EPUB file was not found at: \(path)"
        case .missingContainer: return "The EPUB is missing META-INF/container.xml."
        case .missingOPF: return "The EPUB is missing its package document (OPF file)."
        case .invalidOPF: return "The EPUB package document could not be parsed."
        case .missingSpine: return "The EPUB has no reading order (spine)."
        case .writeFailed(let msg): return "Failed to write EPUB metadata: \(msg)"
        }
    }
}

enum EPUBParser {

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
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        let opfData = try parseOPF(opfXML)

        // Step 3: Read chapters in spine order
        var chapters: [Chapter] = []
        for itemRef in opfData.spineItemRefs {
            guard let manifestItem = opfData.manifest[itemRef],
                  manifestItem.mediaType.contains("html") || manifestItem.mediaType.contains("xml") else {
                continue
            }

            let chapterPath: String
            if opfDirectory.isEmpty {
                chapterPath = manifestItem.href
            } else {
                chapterPath = "\(opfDirectory)/\(manifestItem.href)"
            }

            // Decode percent-encoded paths and validate against path traversal
            let decodedPath = chapterPath.removingPercentEncoding ?? chapterPath
            guard !decodedPath.contains("..") && !decodedPath.hasPrefix("/") else {
                continue
            }

            guard let chapterHTML = try? extractString(archive: archive, path: decodedPath) else {
                continue
            }

            let chapter = try parseChapterHTML(chapterHTML)
            chapters.append(chapter)
        }

        return DocumentContent(
            title: opfData.title,
            author: opfData.author,
            chapters: chapters
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
    static func writeMetadata(_ metadata: EPUBMetadata, to url: URL) throws -> String {
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

        // Replace original with modified
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)

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

    // MARK: - Container Parsing

    private static func parseContainerForOPFPath(_ xml: String) throws -> String {
        let doc = try XMLDocument(xmlString: xml)
        let rootfiles = try doc.nodes(forXPath: "//*[local-name()='rootfile']")
        guard let rootfile = rootfiles.first,
              let element = rootfile as? XMLElement,
              let fullPath = element.attribute(forName: "full-path")?.stringValue else {
            throw EPUBParserError.missingOPF
        }
        return fullPath
    }

    // MARK: - OPF Parsing

    private struct OPFData {
        var title: String
        var author: String
        var manifest: [String: ManifestItem]  // id -> item
        var spineItemRefs: [String]  // ordered manifest IDs
    }

    private struct ManifestItem {
        var href: String
        var mediaType: String
    }

    private static func parseOPF(_ xml: String) throws -> OPFData {
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
            manifest[id] = ManifestItem(href: href, mediaType: mediaType)
        }

        // Spine
        let spineNodes = try doc.nodes(forXPath: "//*[local-name()='itemref']")
        let spineItemRefs = spineNodes.compactMap { node -> String? in
            (node as? XMLElement)?.attribute(forName: "idref")?.stringValue
        }

        guard !spineItemRefs.isEmpty else {
            throw EPUBParserError.missingSpine
        }

        return OPFData(
            title: title,
            author: author,
            manifest: manifest,
            spineItemRefs: spineItemRefs
        )
    }

    // MARK: - Chapter HTML Parsing

    private static func parseChapterHTML(_ html: String) throws -> Chapter {
        let doc = try SwiftSoup.parse(html)

        // Remove script and style elements
        try doc.select("script, style").remove()

        // Extract headings with their positions
        let body = doc.body() ?? doc
        let allText = try body.text()

        var headings: [Heading] = []
        let headingElements = try doc.select("h1, h2, h3, h4, h5, h6")
        var searchStart = allText.startIndex

        for element in headingElements.array() {
            let tag = element.tagName()
            let level = tag.last.flatMap({ Int(String($0)) }) ?? 1
            let headingText = try element.text()

            // Find the next occurrence after our search position
            let offset: Int
            if let range = allText.range(of: headingText, range: searchStart..<allText.endIndex) {
                offset = allText.distance(from: allText.startIndex, to: range.lowerBound)
                searchStart = range.upperBound
            } else {
                offset = allText.distance(from: allText.startIndex, to: searchStart)
            }

            headings.append(Heading(level: level, text: headingText, characterOffset: offset))
        }

        // Get chapter title from first heading or empty
        let chapterTitle = headings.first?.text ?? ""

        return Chapter(title: chapterTitle, text: allText, headings: headings)
    }

    // MARK: - ZIP Helpers

    private static func extractString(archive: Archive, path: String) throws -> String {
        guard let entry = archive[path] else {
            if path == "META-INF/container.xml" {
                throw EPUBParserError.missingContainer
            }
            throw EPUBParserError.invalidOPF
        }

        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
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
