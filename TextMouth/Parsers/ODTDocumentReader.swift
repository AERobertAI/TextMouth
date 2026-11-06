import Foundation
import ZIPFoundation

// MARK: - TextMouth's Own Reader of OpenDocument Text

/// TextMouth's own reader of OpenDocument text documents (FMT27): `.odt`
/// files and the `.ott` template, which is the same package under another
/// media type. It turns a document into the HTML `OwnDocumentReaders`
/// describes, and runs in both apps, with no `textutil` and no AppKit.
///
/// Compared with textutil's reading, which this reader replaces where
/// `isOn` says so:
/// - the headings are the document's own: `text:h` with its
///   `text:outline-level`, and a paragraph whose style has
///   `style:default-outline-level`. A document that names none keeps the
///   headings textutil's reading finds by size (`RTFSizeHeadings`);
/// - bold and italic in body text are `strong` and `em`, through styles
///   and the styles they are based on;
/// - lists are lists, numbered or bulleted by their list style, and the
///   number or bullet an item shows is not read as one of its words;
///   tables are tables;
/// - page breaks (a style's `fo:break-before` and `fo:break-after`, a
///   paragraph or table that names a master page, and the layout's own
///   `text:soft-page-break`) are pages, where textutil's HTML loses them;
/// - hidden text, tracked deletions, comments, headers, and footers are not
///   read; notes follow the text; a field is read for its result
///   (`ODTContentReader` lists every rule).
///
/// The package is a ZIP archive read with ZIPFoundation and, for its XML
/// parts, `XMLParser` with external entities off and no document type
/// declaration allowed. Every part is held to `DocumentByteLimit` as it is
/// inflated, and to the size the archive records for it, so a ZIP bomb is
/// refused.
///
/// The specification is OpenDocument 1.3 (OASIS, 2021). The reader is
/// written from it; odfdo (Apache 2.0) and the ODF Toolkit (Apache 2.0)
/// were maps of the format only, and none of their code is used.
///
/// A document is untrusted input. One that cannot be read ends the read
/// with `TextutilConverter.Failure.unreadable(.odt)`, the sentence the
/// textutil reader gives for a document it cannot read.
enum ODTDocumentReader {

    // MARK: The Switch

    /// Whether this platform reads OpenDocument text with this reader: iOS,
    /// which has no textutil, always; the Mac once the reader has been
    /// checked against textutil's reading of the same files
    /// (`ODTTextutilComparisonTests`).
    static var isOn: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    // MARK: Reading

    /// The HTML document of the OpenDocument text at `url`.
    /// - Parameter includesPages: whether page-break elements are written.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for a file, a part, or text past
    ///   `DocumentByteLimit`, the file system's error for a file that cannot
    ///   be read, and `TextutilConverter.Failure.unreadable` for a file that
    ///   is not an OpenDocument text package, or is damaged.
    static func html(of url: URL, includesPages: Bool) throws -> String {
        try checkSize(of: url)
        let package = try Package(at: url)
        return try html(of: package, includesPages: includesPages)
    }

    /// Refuses a file that is empty or past the byte limit, before it is
    /// opened: the archive itself is not read into memory, only its parts
    /// as they are needed.
    private static func checkSize(of url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw FileImportError.noTextToRead }
        try DocumentByteLimit.check(byteCount: Int64(size))
    }

    /// The HTML document of the package: its styles, then its content, with
    /// the title and author its metadata names.
    private static func html(of package: Package, includesPages: Bool) throws -> String {
        let sheet = ODTStyleSheet()
        if let styles = try package.part(Package.stylesPath) {
            try ODTStylesReader(data: styles, file: Package.stylesPath, sheet: sheet).read()
        }
        guard let content = try package.part(Package.contentPath) else {
            throw TextutilConverter.Failure.unreadable(.odt)
        }
        let reader = ODTContentReader(
            data: content,
            file: Package.contentPath,
            sheet: sheet,
            includesPages: includesPages,
            limit: DocumentByteLimit.current
        )
        try reader.read()
        let body = try reader.finish()

        var document = RTFDocument()
        document.blocks = body.blocks
        document.pageBreaks = body.pageBreaks
        // The names are the document's own, when it gives them. A damaged
        // metadata part loses the names and nothing else.
        if let meta = try package.part(Package.metaPath) {
            let metadata = ODTMetadataReader(data: meta, file: Package.metaPath)
            if (try? metadata.read()) != nil {
                document.title = metadata.title
                document.author = metadata.author
            }
        }
        return RTFHTMLWriter.html(of: document, includesPages: includesPages)
    }

    // MARK: The Package

    /// An OpenDocument package: a ZIP archive whose parts are read one at a
    /// time.
    struct Package {
        /// The parts this reader reads.
        static let contentPath = "content.xml"
        static let stylesPath = "styles.xml"
        static let metaPath = "meta.xml"
        private static let mimetypePath = "mimetype"

        /// The media type every text document begins with: the document,
        /// its template (`-template`), its master (`-master`), and its web
        /// form (`-web`).
        private static let textMediaType = "application/vnd.oasis.opendocument.text"

        private let archive: Archive

        /// Opens the package at `url`.
        /// - Throws: `TextutilConverter.Failure.unreadable(.odt)` for a file
        ///   that is not a ZIP archive, or whose media type, when it states
        ///   one, is not that of an OpenDocument text document (a
        ///   spreadsheet with an `.odt` name, say).
        init(at url: URL) throws {
            do {
                archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
            } catch {
                throw TextutilConverter.Failure.unreadable(.odt)
            }
            // The media type is the first entry of a package, stored
            // uncompressed. Packages written by other tools may lack it.
            if let mediaType = try part(Self.mimetypePath, limit: 256) {
                let text = String(decoding: mediaType, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix(Self.textMediaType) else {
                    throw TextutilConverter.Failure.unreadable(.odt)
                }
            }
        }

        /// The bytes of the part at `path`, or nil when the package has no
        /// such part. The part is held to the byte limit, and to the size
        /// the archive records for it, as it is inflated.
        /// - Throws: `DocumentTooLargeError` for a part past the limit, and
        ///   `TextutilConverter.Failure.unreadable(.odt)` for a part that
        ///   holds more than the archive records for it or cannot be
        ///   inflated.
        func part(_ path: String, limit: Int64 = DocumentByteLimit.current) throws -> Data? {
            guard let entry = archive.file(at: path), entry.type == .file else { return nil }
            do {
                return try ArchiveEntryReader.read(entry, in: archive, limit: limit, holdingToDeclaredSize: true).data
            } catch let overflow as ArchiveEntryOverflow {
                switch overflow {
                case .pastLimit: throw DocumentTooLargeError(limit: limit)
                case .pastDeclaredSize: throw TextutilConverter.Failure.unreadable(.odt)
                }
            } catch {
                throw TextutilConverter.Failure.unreadable(.odt)
            }
        }
    }
}

// MARK: - The Title and Author

/// Reads the title and author a document's `meta.xml` names: `dc:title`
/// and `dc:creator`, or else `meta:initial-creator`, who made it first.
final class ODTMetadataReader: ODTXMLReader {
    /// The title, empty when the document names none.
    private(set) var title = ""
    /// The author, empty when the document names none.
    private(set) var author = ""

    /// The creator that first made the document, which stands in for an
    /// author the document does not name.
    private var initialCreator = ""
    /// The element whose text is being read, if it is one of these.
    private var current: String?

    override func startElement(_ name: String, attributes: [String: String]) {
        current = ["dc:title", "dc:creator", "meta:initial-creator"].contains(name) ? name : nil
    }

    override func endElement(_ name: String) {
        current = nil
        if name == "office:meta" && author.isEmpty { author = initialCreator }
    }

    override func characters(_ text: String) {
        // A name is a few words; a part that holds more is not read further.
        switch current {
        case "dc:title" where title.utf8.count < 4_096: title += text
        case "dc:creator" where author.utf8.count < 4_096: author += text
        case "meta:initial-creator" where initialCreator.utf8.count < 4_096: initialCreator += text
        default: break
        }
    }
}
