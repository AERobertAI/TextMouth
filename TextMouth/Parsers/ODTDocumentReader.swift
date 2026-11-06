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
    /// - Parameter reportDamagedPart: receives the damage of `styles.xml` or
    ///   `meta.xml` when that part is damaged, missing its end, or past its
    ///   limit. The book is then read without what the part gave (the styles'
    ///   headings and emphasis, or the title and author), as the DOCX reader
    ///   reads a document with damaged properties. The default writes one
    ///   line to the console and the debug log.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for a file, `content.xml`, or text past
    ///   `DocumentByteLimit`, the file system's error for a file that cannot
    ///   be read, and `TextutilConverter.Failure.unreadable` for a file that
    ///   is not an OpenDocument text package, or whose `content.xml` is
    ///   damaged. Only `content.xml` refuses the book.
    static func html(
        of url: URL,
        includesPages: Bool,
        reportDamagedPart: (ODTPartDamage) -> Void = ODTDocumentReader.logDamagedPart
    ) throws -> String {
        try checkSize(of: url)
        let package = try Package(at: url)
        return try html(of: package, includesPages: includesPages, reportDamagedPart: reportDamagedPart)
    }

    /// Default report for a damaged optional part: one line in the console
    /// and in the debug log. The import layer has no warning channel yet.
    static func logDamagedPart(_ damage: ODTPartDamage) {
        PackageDamage.log(damage, tag: "ODT_DAMAGED_PART")
    }

    /// Refuses a file that is empty or past the byte limit, before it is
    /// opened: the archive itself is not read into memory, only its parts
    /// as they are needed.
    private static func checkSize(of url: URL) throws {
        _ = try DocumentByteLimit.size(ofFileAt: url)
    }

    /// The HTML document of the package: its styles, then its content, with
    /// the title and author its metadata names.
    private static func html(
        of package: Package,
        includesPages: Bool,
        reportDamagedPart: (ODTPartDamage) -> Void
    ) throws -> String {
        let sheet = ODTStyleSheet()
        // The styles are optional: what was read of a damaged part stands.
        do {
            if let styles = try package.part(Package.stylesPath) {
                try ODTStylesReader(data: styles, file: Package.stylesPath, sheet: sheet).read()
            }
        } catch {
            reportDamagedPart(ODTPartDamage(file: Package.stylesPath, error: error))
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
        do {
            if let meta = try package.part(Package.metaPath) {
                let metadata = ODTMetadataReader(data: meta, file: Package.metaPath)
                try metadata.read()
                document.title = metadata.title
                document.author = metadata.author
            }
        } catch {
            reportDamagedPart(ODTPartDamage(file: Package.metaPath, error: error))
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

        /// What every OpenDocument media type begins with.
        private static let openDocumentMediaTypes = "application/vnd.oasis.opendocument."

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
            // uncompressed. Packages written by other tools may lack it or
            // damage it: only a type that can be read and is not text refuses.
            if let mediaType = try? part(Self.mimetypePath, limit: 256) {
                let text = String(decoding: mediaType, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                // Only a type that says another kind of OpenDocument document
                // refuses; one that is junk says nothing.
                guard text.hasPrefix(Self.textMediaType) || !text.hasPrefix(Self.openDocumentMediaTypes) else {
                    throw TextutilConverter.Failure.unreadable(.odt)
                }
            }
        }

        /// The bytes of the part at `path`, or nil when the package has no
        /// such part. The part is held to the byte limit, and to the size
        /// the archive records for it, as it is inflated.
        /// - Throws: `DocumentTooLargeError` for a part past the limit, and
        ///   `TextutilConverter.Failure.unreadable(.odt)` for a part that
        ///   holds more than the archive records for it, whose checksum is
        ///   not the one the archive records, or that cannot be inflated.
        func part(_ path: String, limit: Int64 = DocumentByteLimit.current) throws -> Data? {
            guard let entry = archive.file(at: path), entry.type == .file else { return nil }
            do {
                let part = try ArchiveEntryReader.read(entry, in: archive, limit: limit, holdingToDeclaredSize: true)
                // The reader only takes the checksum of what it read: a part
                // that is not the part the archive recorded is damaged.
                guard part.checksum == entry.checksum else { throw TextutilConverter.Failure.unreadable(.odt) }
                return part.data
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

    /// An element starts: the title or the creator is the one whose text is read.
    override func startElement(_ name: String, attributes: [String: String]) {
        current = ["dc:title", "dc:creator", "meta:initial-creator"].contains(name) ? name : nil
    }

    /// An element ends: at the end of the metadata the first creator stands in for a missing author.
    override func endElement(_ name: String) {
        current = nil
        if name == "office:meta" && author.isEmpty { author = initialCreator }
    }

    /// Text of the title or a creator.
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

// MARK: - A Damaged Optional Part

/// The damage of a part of an OpenDocument package that the book can be read
/// without: `styles.xml` or `meta.xml`. Its sentence is the one every format
/// gives for a damaged file in a package (`PackageDamage`).
struct ODTPartDamage: LocalizedError {
    /// The part's path inside the package.
    let file: String
    /// What was wrong, completing "is damaged or incomplete: …".
    let reason: String

    /// The damage `error` was, found while reading `file`.
    init(file: String, error: Error) {
        self.file = file
        reason = error is DocumentTooLargeError
            ? "it holds more than TextMouth reads from one file"
            : "its markup is not well-formed or it could not be unpacked"
    }

    var errorDescription: String? {
        PackageDamage.message(file: file, reason: reason, container: "this document", original: "the document")
    }
}
