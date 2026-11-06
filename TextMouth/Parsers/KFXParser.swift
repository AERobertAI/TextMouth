import Foundation

/// Reads a DRM-free Kindle KFX book into the reading text: TextMouth's own
/// reader (FMT52), the same on the Mac and on iOS, with no helper program.
///
/// Written from KFX-FORMAT-NOTES-2026-11-05.md and the public Ion
/// specification only. It reads the file's bytes first (`KFXSignature`) and
/// refuses what it must before anything else: a copy-protected container is
/// never opened and nothing here ever tries to decrypt one.
///
/// A KFX book becomes the same `MOBIParser.PreparedBook` a MOBI book does,
/// so the direct reader and the Markdown cache hand it on as they hand on
/// any Kindle book.
enum KFXParser {

    /// A book read in its chapters (the MOBI reader's type, shared).
    typealias PreparedBook = MOBIParser.PreparedBook

    // MARK: Reading

    /// Reads the KFX book at `url` for direct reading.
    /// - Throws: what `prepareBook(url:fallbackTitle:)` throws.
    static func parse(url: URL) throws -> DocumentContent {
        let book = try prepareBook(url: url)
        return DocumentContent(
            title: book.title,
            author: book.author,
            chapters: book.chapters.map(\.chapter)
        )
    }

    /// Opens the KFX book at `url` and prepares each of its sections that
    /// holds text as a chapter. The direct reader and the Markdown cache
    /// both read a KFX book here, so they hear the same words.
    /// - Parameter fallbackTitle: The title for a book that names none; its
    ///   file's name when nil.
    /// - Throws: `MOBIError.copyProtected` for a protected book,
    ///   `MOBIError.notAKindleBook` and `.damaged` for a file that is not a
    ///   readable KFX book, `KFXError` for the books and packages not read,
    ///   `DocumentTooLargeError` for a file past `DocumentByteLimit`.
    static func prepareBook(url: URL, fallbackTitle: String? = nil) throws -> PreparedBook {
        // The first bytes decide, so a ZIP is not read whole to be told apart.
        switch try KFXSignature.kind(ofFileAt: url) {
        case .zip:
            return try prepareBook(archiveAt: url, fallbackTitle: fallbackTitle)
        case .container, .protected, .other:
            return try prepareBook(
                bytes: [UInt8](try DocumentByteLimit.contents(of: url)),
                fallbackTitle: fallbackTitle ?? url.deletingPathExtension().lastPathComponent
            )
        }
    }

    /// Prepares the single KFX container in `bytes`. The MOBI reader hands
    /// an `.azw` file here when its bytes are KFX, as Kindle's apps name
    /// their KFX books.
    /// - Throws: As `prepareBook(url:fallbackTitle:)`.
    static func prepareBook(bytes: [UInt8], fallbackTitle: String) throws -> PreparedBook {
        switch KFXSignature.kind(ofPrefix: Array(bytes.prefix(KFXSignature.prefixLength))) {
        case .protected:
            // Never decrypted: the same sentence as a protected MOBI book.
            throw MOBIError.copyProtected
        case .container:
            throw KFXError.notReadableYet
        case .zip, .other:
            throw MOBIError.notAKindleBook
        }
    }

    /// Prepares the set of containers in the ZIP archive at `url`, or
    /// refuses an archive that is not one.
    private static func prepareBook(archiveAt url: URL, fallbackTitle: String?) throws -> PreparedBook {
        switch try KFXPackage.kind(ofArchiveAt: url) {
        case .protected:
            throw MOBIError.copyProtected
        case .kindleCreate:
            throw KFXError.kindleCreatePackage
        case .containers:
            throw KFXError.notReadableYet
        case .other:
            throw MOBIError.notAKindleBook
        }
    }

    /// What the KFX book at `url` says about itself, without reading its
    /// text.
    /// - Throws: As `prepareBook(url:fallbackTitle:)`.
    static func readMetadata(url: URL) throws -> MOBIBook.Metadata {
        if try KFXSignature.kind(ofFileAt: url) == .zip {
            _ = try prepareBook(url: url)
        }
        return try readMetadata(bytes: [UInt8](try DocumentByteLimit.contents(of: url)))
    }

    /// What the KFX container in `bytes` says about itself. Until the walk
    /// exists a book names nothing: reading metadata never fails an import,
    /// so the refusal is the import's own.
    static func readMetadata(bytes: [UInt8]) throws -> MOBIBook.Metadata {
        _ = try prepareBook(bytes: bytes, fallbackTitle: "")
        throw KFXError.notReadableYet
    }
}
