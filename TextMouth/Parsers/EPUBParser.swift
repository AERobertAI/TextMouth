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
    /// decompressed, it does not match the checksum the archive stores for
    /// it, or it holds more than TextMouth reads from one file. `file` is
    /// the file's path inside the package; `reason` completes the sentence
    /// "The file is damaged or incomplete: …".
    case damagedFile(file: String, reason: String)
    /// A file in the package that TextMouth will not read although it is not
    /// damaged: it defines entities of its own, or is written in an encoding
    /// the guard cannot see through (`XMLInputGuard`). `file` is the file's
    /// path inside the package.
    case unsafeFile(file: String, problem: XMLInputGuard.Problem)
    /// No chapter in the reading order holds text that could be read.
    /// `report` names each chapter that could not be read and why; when it
    /// names none, every chapter was blank or the spine held no documents.
    case noReadableChapters(ExtractionReport)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The EPUB file could not be opened as a ZIP archive."
        case .fileNotFound(let path): return "The EPUB file was not found at: \(path)"
        case .missingContainer: return "The EPUB is missing META-INF/container.xml."
        case .missingOPF: return "The EPUB is missing its package document (OPF file)."
        case .invalidOPF: return "The EPUB package document could not be parsed."
        case .missingSpine: return "The EPUB has no reading order (spine)."
        case .writeFailed(let msg): return "Failed to write EPUB metadata: \(msg)"
        case .unsafeFile(let file, let problem):
            return XMLInputGuard.refusalSentence(
                for: problem, file: file, in: EPUBParser.bookNameInMessages, original: "the book")
        case .damagedFile(let file, let reason):
            return PackageDamage.message(
                file: file, reason: reason, container: EPUBParser.bookNameInMessages, original: "the book"
            )
        case .noReadableChapters(let report):
            // Blank pages alone are not damage, so there is nothing to replace.
            guard !report.isComplete else { return "This EPUB book has no text to read." }
            let blank = report.blankChapterCount
            let others = blank == 0 ? ""
                : blank == 1 ? " The other chapter has no text."
                : " The other \(blank) chapters have no text."
            return "\(report.message)\(others) Get a fresh copy of the book, then import it again."
        }
    }
}

enum EPUBParser {

    /// How sentences about a damaged or incomplete EPUB name the book, as in
    /// "The file “OEBPS/ch07.xhtml” in this EPUB book is damaged …".
    static let bookNameInMessages = "this EPUB book"

    /// Where every EPUB keeps its container file, which names the package
    /// document.
    static let containerPath = "META-INF/container.xml"

    /// An EPUB read in reading order: its package metadata, the chapters that
    /// could be read, and a report of the chapters that could not.
    struct PreparedBook {
        var title: String
        var author: String
        var chapters: [PreparedChapter]
        var report: ExtractionReport
    }

    /// Parse the EPUB at `url` for direct reading. Chapters that cannot be
    /// read are left out (see `prepareBook(url:)`).
    static func parse(url: URL) throws -> DocumentContent {
        let book = try prepareBook(url: url)
        return DocumentContent(
            title: book.title,
            author: book.author,
            chapters: book.chapters.map(\.chapter)
        )
    }

    /// Open the EPUB at `url` and prepare every chapter its reading order
    /// names. The direct reader and the Markdown cache both read EPUBs here,
    /// so they share navigation recovery, exact text coordinates, and the
    /// report of chapters left out.
    /// - Parameter includesPages: whether page markers are written (PG05); false writes what cache format 3.0.7 wrote.
    /// - Throws: `EPUBParserError` when the file is missing, is not a ZIP
    ///   archive, or lacks a readable container or package document, and
    ///   `.noReadableChapters` when no chapter holds text.
    static func prepareBook(url: URL, includesPages: Bool = true) throws -> PreparedBook {
        // Every document the book holds is looked up, so its archive's
        // entries are read into an index once (PERF20).
        let archive = IndexedArchive(try openArchive(at: url))

        // Step 1: Read container.xml to find OPF path
        let containerXML = try extractString(archive: archive, path: containerPath)
        let opfPath = try parseContainerForOPFPath(containerXML)

        // Step 2: Read and parse OPF
        let opfXML = try extractString(archive: archive, path: opfPath)
        let opfData = try parseOPF(opfXML, file: opfPath)

        // Step 3: Read the chapters in spine order, recording any left out.
        let prepared = try preparedChapters(
            archive: archive, opfPath: opfPath, opfData: opfData, includesPages: includesPages
        )
        return PreparedBook(
            title: opfData.title,
            author: opfData.author,
            chapters: prepared.chapters,
            report: prepared.report
        )
    }

    /// Open the EPUB at `url` for reading.
    /// - Throws: `EPUBParserError.fileNotFound` when no file is there, checked
    ///   first so a missing file is not reported as `.invalidArchive`, which
    ///   is thrown when the file cannot be opened as a ZIP archive.
    private static func openArchive(at url: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EPUBParserError.fileNotFound(url.path)
        }
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBParserError.invalidArchive
        }
    }

    // MARK: - Metadata

    static func readMetadata(url: URL) throws -> EPUBMetadata {
        let archive = try openArchive(at: url)
        let containerXML = try extractString(archive: archive, path: containerPath)
        let opfPath = try parseContainerForOPFPath(containerXML)
        let opfXML = try extractString(archive: archive, path: opfPath)
        return try parseMetadata(opfXML, file: opfPath)
    }

    private static func parseMetadata(_ xml: String, file: String) throws -> EPUBMetadata {
        try readingXML(xml, file: file) { doc in
            let title = (try? doc.nodes(forXPath: "//*[local-name()='title']"))?.first?.stringValue ?? ""
            let author = authorName(in: doc) ?? ""
            let publisher = (try? doc.nodes(forXPath: "//*[local-name()='publisher']"))?.first?.stringValue ?? ""
            let date = (try? doc.nodes(forXPath: "//*[local-name()='date']"))?.first?.stringValue ?? ""
            var language = (try? doc.nodes(forXPath: "//*[local-name()='language']"))?.first?.stringValue ?? ""
            // "und" is the tag for a language that is undetermined, which is how a
            // book says it names none (TextMouth's own EPUB export does, for a
            // book whose language it does not know): there is no language to show.
            if language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "und" {
                language = ""
            }

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
    }

    /// Write updated metadata back to the EPUB file in place.
    /// Returns the new MD5 hash of the modified file.
    ///
    /// The update is prepared and checked in a copy beside the file, and the
    /// copy then replaces the file in one step. The copy is hashed before
    /// that step, which moves exactly those bytes into place, so nothing that
    /// could fail is left once the file has been replaced: a write that
    /// throws has always left the file as it was, and the hash returned
    /// describes the file the caller now has (TODO A09).
    static func writeMetadata(
        _ metadata: EPUBMetadata,
        to url: URL,
        replacingWith replacement: ((URL, URL) throws -> Void)? = nil
    ) throws -> String {
        // A file that is not there is said to be missing, not to be a damaged
        // archive, as reading the metadata says it.
        let archive = try openArchive(at: url)

        let containerXML = try extractString(archive: archive, path: containerPath)
        let opfPath = try parseContainerForOPFPath(containerXML)
        let opfXML = try extractString(archive: archive, path: opfPath)

        // Parse and modify the OPF XML
        let updatedXML = try updateOPFMetadata(opfXML: opfXML, file: opfPath, metadata: metadata)

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

        // Remove old OPF and add updated one. Reading finds the package
        // document without regard to case (ST09), so the write does too: a
        // book whose container.xml spells the path in another case than its
        // ZIP does is saved, and the new entry takes the spelling the ZIP
        // already used, so nothing else in the book is renamed.
        guard let oldEntry = writeArchive.file(at: opfPath) else {
            throw EPUBParserError.writeFailed("Could not find OPF entry")
        }
        let storedOPFPath = oldEntry.path
        try writeArchive.remove(oldEntry)

        let updatedData = updatedXML.data(using: .utf8) ?? Data()
        try writeArchive.addEntry(
            with: storedOPFPath,
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
        guard let preparedArchive = Archive.openedForReading(at: tempURL),
              let preparedOPF = try? extractString(archive: preparedArchive, path: opfPath) else {
            throw EPUBParserError.writeFailed("Updated archive failed validation")
        }
        _ = try parseOPF(preparedOPF, file: opfPath)

        // Hash the prepared archive while a failure still leaves the original
        // untouched; the replacement below installs these exact bytes.
        let newHash = try FileImportService.md5Hash(of: tempURL)

        // Replace in one filesystem operation. Both files are in the same
        // directory, allowing FileManager to perform an atomic swap instead of
        // exposing a window where the original path does not exist.
        let replace = replacement ?? { originalURL, preparedURL in
            _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: preparedURL)
        }
        try replace(url, tempURL)
        return newHash
    }

    private static func updateOPFMetadata(opfXML: String, file: String, metadata: EPUBMetadata) throws -> String {
#if os(macOS)
        try readingXML(opfXML, file: file) { doc in
            // Update title
            if let titleNode = (try? doc.nodes(forXPath: "//*[local-name()='title']"))?.first {
                titleNode.stringValue = metadata.title
            }

            // The author goes into the creator that names the author, or else
            // into the first creator, which named no one. A package without any
            // creator gets one, unless the author is the placeholder, which
            // names no one and is not worth an element.
            if let creator = creatorElement(in: doc) ?? elements(in: doc, matching: creatorPath).first {
                creator.stringValue = metadata.author
            } else if !Book.isUnknownAuthor(metadata.author), let metadataNode = metadataElement(in: doc) {
                let creator = XMLElement(name: "dc:creator")
                creator.stringValue = metadata.author
                metadataNode.addChild(creator)
            }

            // Update publisher
            if let pubNode = (try? doc.nodes(forXPath: "//*[local-name()='publisher']"))?.first {
                pubNode.stringValue = metadata.publisher
            } else if !metadata.publisher.isEmpty, let metadataNode = metadataElement(in: doc) {
                // Add publisher if it doesn't exist
                let pubElem = XMLElement(name: "dc:publisher")
                pubElem.stringValue = metadata.publisher
                metadataNode.addChild(pubElem)
            }

            // Update date
            if let dateNode = (try? doc.nodes(forXPath: "//*[local-name()='date']"))?.first {
                dateNode.stringValue = metadata.publicationDate
            } else if !metadata.publicationDate.isEmpty, let metadataNode = metadataElement(in: doc) {
                let dateElem = XMLElement(name: "dc:date")
                dateElem.stringValue = metadata.publicationDate
                metadataNode.addChild(dateElem)
            }

            return doc.xmlString(options: [.nodePrettyPrint])
        }
#else
        // Phase 0 of the iOS port: the portable XML tree (PortableXML.swift) only reads. It
        // cannot change a package document and write it back as Foundation's tree does, and
        // nothing less faithful should rewrite a book's own file, so iOS does not save a
        // book's details into its EPUB yet.
        throw IOSUnavailable.feature("Saving a book's details into its EPUB file")
#endif
    }

    // MARK: - The Author a Package Names

    /// The XPath naming every `dc:creator` element of a package document.
    private static let creatorPath = "//*[local-name()='creator']"

    /// The author the package document `doc` names, or nil when it names
    /// no one.
    ///
    /// Most packages name the author in a `dc:creator` element, read first
    /// (`creatorElement(in:refinedRoles:)`). Packages written by some EPUB
    /// 3 converters name the author only in a
    /// `<meta property="dcterms:creator">` element, the generic form EPUB
    /// 3.0 allowed for every Dublin Core term, read next: on October 7,
    /// 2026, 150 of the 729 EPUBs in the user's library named their author
    /// that way alone, and every one was listed under an unknown author. A
    /// `dc:contributor` with the author role is read last. Every name is
    /// read by `name(of:)`, so an element holding only the placeholder
    /// "Unknown", which calibre writes for a book with no author, names no
    /// one, and the next place is read.
    static func authorName(in doc: XMLDocument) -> String? {
        let roles = refinedRoles(in: doc)
        if let creator = creatorElement(in: doc, refinedRoles: roles) {
            return name(of: creator)
        }
        let termMetas = elements(in: doc, matching: "//*[local-name()='meta'][@property='dcterms:creator']")
        if let named = termMetas.lazy.compactMap(name(of:)).first {
            return named
        }
        let contributors = elements(in: doc, matching: "//*[local-name()='contributor']")
        return contributors.first { name(of: $0) != nil && hasAuthorRole($0, refinedRoles: roles) }.flatMap(name(of:))
    }

    /// The `dc:creator` element of `doc` that names the author, when one
    /// names anyone: the first with the author role, or else the first
    /// naming anyone, so a package listing its illustrator before its author
    /// names the author. An edit of the author is written into this element
    /// (`updateOPFMetadata`). `refinedRoles` are the roles `doc`'s meta
    /// elements give (`refinedRoles(in:)`), read here when not given.
    static func creatorElement(in doc: XMLDocument, refinedRoles: [String: String]? = nil) -> XMLElement? {
        let roles = refinedRoles ?? self.refinedRoles(in: doc)
        let named = elements(in: doc, matching: creatorPath).filter { name(of: $0) != nil }
        return named.first { hasAuthorRole($0, refinedRoles: roles) } ?? named.first
    }

    /// The name `element` holds: its text without the spaces and line
    /// breaks around it, or nil when it holds none, or only the placeholder
    /// `Book.unknownAuthor`.
    private static func name(of element: XMLElement) -> String? {
        let text = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Book.isUnknownAuthor(text) ? nil : text
    }

    /// Whether `element` has the author role: `aut`, the MARC relator for
    /// an author, in its `opf:role` attribute (EPUB 2) or in the meta
    /// element refining it (EPUB 3, `refinedRoles`).
    private static func hasAuthorRole(_ element: XMLElement, refinedRoles: [String: String]) -> Bool {
        var role = element.attribute(forName: "opf:role")?.stringValue
            ?? element.attribute(forName: "role")?.stringValue
        if role == nil, let id = element.attribute(forName: "id")?.stringValue {
            role = refinedRoles[id]
        }
        return role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "aut"
    }

    /// The roles the EPUB 3 meta elements of `doc` give the elements they
    /// refine, by the refined element's ID: `<meta refines="#aut"
    /// property="role" scheme="marc:relators">aut</meta>` gives the element
    /// with the ID `aut` the role `aut`. The first role given to an element
    /// counts.
    private static func refinedRoles(in doc: XMLDocument) -> [String: String] {
        var roles: [String: String] = [:]
        for meta in elements(in: doc, matching: "//*[local-name()='meta'][@refines][@property='role']") {
            guard let refines = meta.attribute(forName: "refines")?.stringValue, let role = meta.stringValue else {
                continue
            }
            let id = refines.hasPrefix("#") ? String(refines.dropFirst()) : refines
            if roles[id] == nil {
                roles[id] = role
            }
        }
        return roles
    }

    /// The package's metadata element, which holds every Dublin Core
    /// element, or nil in a package document without one.
    private static func metadataElement(in doc: XMLDocument) -> XMLElement? {
        elements(in: doc, matching: "//*[local-name()='metadata']").first
    }

    /// The elements `path` names in `doc`, in document order; none when the
    /// path cannot be evaluated.
    private static func elements(in doc: XMLDocument, matching path: String) -> [XMLElement] {
        ((try? doc.nodes(forXPath: path)) ?? []).compactMap { $0 as? XMLElement }
    }

    // MARK: - Reading XML

    /// Read `xml`, one of the book's XML files (its container, package
    /// document, or NCX), as an XML document, and return what `body` makes
    /// of it. Every XML file of an EPUB is read here.
    ///
    /// External entities are never loaded (U01). By default XMLDocument
    /// loads every entity a `SYSTEM "file:///…"` declaration names on this
    /// Mac, so a crafted EPUB could put a local file's text into its title,
    /// author, or headings, from there into the library, and on Edit
    /// Metadata into the EPUB itself. Such an entity reads as nothing, as
    /// in the app's other XML readers (the feed and OPML readers).
    ///
    /// The document lasts only while `body` runs: then its tree is taken
    /// apart (`takeApart(_:)`), so `body` finishes all its work with the
    /// document, a write of it back into the book included, and returns
    /// none of its nodes.
    /// - Parameters:
    ///   - xml: The file's text.
    ///   - file: The file's path inside the book, which a refusal names.
    /// - Throws: `EPUBParserError.damagedFile` for a tag with more attributes
    ///   than `XMLInputGuard` allows, XMLDocument's error when `xml` is not
    ///   well-formed, or what `body` throws.
    static func readingXML<Result>(
        _ xml: String, file: String, _ body: (XMLDocument) throws -> Result
    ) throws -> Result {
        // A tag the XML parser would take too long over is refused as damage
        // before the parser reads it, and entities of its own or an encoding
        // the guard cannot read in the sentence for those (`XMLInputGuard`).
        // The text is decoded already, so its declared encoding is only read
        // for its name.
        if let problem = XMLInputGuard.problem(with: Data(xml.utf8), isDecodedText: true) {
            if problem == .tooManyAttributes {
                throw EPUBParserError.damagedFile(file: file, reason: XMLInputGuard.tooManyAttributesProblem)
            }
            throw EPUBParserError.unsafeFile(file: file, problem: problem)
        }
        let document = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        defer { takeApart(document) }
        return try body(document)
    }

    /// Take `document`'s tree apart, deepest nodes first, so that releasing
    /// it never recurses. Foundation releases a tree one nested call per
    /// level, about 280 bytes of stack each: an XML file nested 2,000 levels
    /// deep, which XMLDocument reads without complaint, overflowed the
    /// 512 KiB stack of the worker thread an import runs on when it was
    /// released, ending TextMouth.
    ///
    /// Every node is gathered with an explicit stack, parents before their
    /// children; in the reverse of that order each element comes after all
    /// of its descendants, so emptying the elements in that order leaves
    /// none holding another by the time the nodes are released.
    private static func takeApart(_ document: XMLDocument) {
        var nodes: [XMLNode] = []
        var stack: [XMLNode] = [document]
        while let node = stack.popLast() {
            nodes.append(node)
            stack += node.children ?? []
        }
        for node in nodes.reversed() {
            (node as? XMLElement)?.setChildren(nil)
        }
    }

    // MARK: - Container Parsing (shared with MarkdownCacheService)

    static func parseContainerForOPFPath(_ xml: String) throws -> String {
        try readingXML(xml, file: containerPath) { doc in
            let rootfiles = try doc.nodes(forXPath: "//*[local-name()='rootfile']")
            guard let rootfile = rootfiles.first,
                  let element = rootfile as? XMLElement,
                  let fullPath = element.attribute(forName: "full-path")?.stringValue else {
                throw EPUBParserError.missingOPF
            }
            return fullPath
        }
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

    /// - Parameter file: The package document's path inside the book, which a
    ///   refusal of it names.
    static func parseOPF(_ xml: String, file: String = "package document") throws -> OPFData {
        try readingXML(xml, file: file) { doc in
            // Metadata
            let titles = try doc.nodes(forXPath: "//*[local-name()='title']")
            let title = titles.first?.stringValue ?? "Untitled"

            let author = authorName(in: doc) ?? Book.unknownAuthor

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
        try extractString(entry: archive.file(at: path), at: path, in: archive)
    }

    /// The text of the member at `path` of an archive whose entries are
    /// indexed, found in its index (see `extractString(archive:path:)`).
    static func extractString(archive: IndexedArchive, path: String) throws -> String {
        try extractString(entry: archive.file(at: path), at: path, in: archive.archive)
    }

    /// The text of `entry`, the member at `path` of `archive`, or nil when
    /// the archive has no member there.
    private static func extractString(entry: Entry?, at path: String, in archive: Archive) throws -> String {
        guard let entry else {
            if path == containerPath {
                throw EPUBParserError.missingContainer
            }
            throw EPUBParserError.invalidOPF
        }
        return try text(of: entry, in: archive)
    }

    /// The text of the archive member `entry`, decoded as UTF-8, or as ISO
    /// Latin 1 when it is not valid UTF-8.
    ///
    /// The member is read through the shared `ArchiveEntryReader`, so one
    /// larger than the most TextMouth reads from a file is refused rather
    /// than read whole into memory (TODO I05).
    ///
    /// ZIPFoundation's `extract` returns the checksum of the bytes it read
    /// without comparing it to the one the archive stores, so a damaged
    /// member would otherwise read as garbled text. The comparison is made
    /// here, except when the stored checksum is 0: ZIPFoundation reports 0
    /// for an entry whose data descriptor it could not read, so that value
    /// cannot judge the data. (Empty data's real checksum is 0 as well, and
    /// it has nothing to verify.)
    /// - Throws: `EPUBParserError.damagedFile` naming the member when its
    ///   data cannot be decompressed, does not match its checksum, or holds
    ///   more than `ArchiveEntryLimits.current` allows.
    static func text(of entry: Entry, in archive: Archive) throws -> String {
        let data: Data
        let checksum: CRC32
        do {
            (data, checksum) = try ArchiveEntryReader.read(entry, in: archive)
        } catch let overflow as ArchiveEntryOverflow {
            throw EPUBParserError.damagedFile(file: entry.path, reason: overflow.reason)
        } catch {
            let reason = ArchiveEntryReader.unreadableReason(of: entry, error: error, tag: "EPUB_ZIP_ERROR")
            throw EPUBParserError.damagedFile(file: entry.path, reason: reason)
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
