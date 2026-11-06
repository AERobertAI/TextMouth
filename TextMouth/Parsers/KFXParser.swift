import Foundation

/// Reads a DRM-free Kindle KFX book into the reading text: TextMouth's own
/// reader (FMT52), the same on the Mac and on iOS, with no helper program.
///
/// Written from KFX-FORMAT-NOTES-2026-11-05.md and the public Ion
/// specification only. It reads the file's bytes first (`KFXSignature`) and
/// refuses what it must before anything else: a copy-protected container is
/// never opened and nothing here ever tries to decrypt one. That check is
/// made on every container of a set, and on the files that sit beside a book
/// (`KFXSidecar`).
///
/// A KFX book becomes the same `MOBIParser.PreparedBook` a MOBI book does,
/// so the direct reader and the Markdown cache hand it on as they hand on
/// any Kindle book.
enum KFXParser {

    /// A book read in its chapters (the MOBI reader's type, shared).
    typealias PreparedBook = MOBIParser.PreparedBook

    /// The most bytes of sidecar containers read beside a book, all together.
    static let maximumSidecarBytes: Int64 = 2 * DocumentByteLimit.standard

    // MARK: Reading

    /// Reads the KFX book at `url` for direct reading.
    /// - Throws: what `prepareBook(url:fallbackTitle:includesPages:)` throws.
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
    /// - Parameters:
    ///   - fallbackTitle: The title for a book that names none; its file's
    ///     name when nil.
    ///   - includesPages: Whether the book's print page list is written as
    ///     pages, as the EPUB reader does for a direct reading.
    /// - Throws: `MOBIError.copyProtected` for a protected book (a protected
    ///   container, a voucher beside it, or any protected member of a set),
    ///   `MOBIError.notAKindleBook` and `.damaged` for a file that is not a
    ///   readable KFX book, `KFXError` for the books and packages not read,
    ///   `DocumentTooLargeError` for a file past `DocumentByteLimit`.
    static func prepareBook(url: URL, fallbackTitle: String? = nil, includesPages: Bool = true) throws -> PreparedBook {
        let fallback = fallbackTitle ?? url.deletingPathExtension().lastPathComponent
        return try prepared(from: try containers(at: url), fallbackTitle: fallback, includesPages: includesPages)
    }

    /// Prepares the single KFX container in `bytes`. The MOBI reader hands
    /// an `.azw` file here when its bytes are KFX, as Kindle's apps name
    /// their KFX books.
    /// - Parameter url: Where the file lies, when it lies somewhere: the
    ///   files beside it are looked at too.
    /// - Throws: As `prepareBook(url:fallbackTitle:includesPages:)`.
    static func prepareBook(
        bytes: [UInt8], fallbackTitle: String, includesPages: Bool = true, near url: URL? = nil
    ) throws -> PreparedBook {
        try prepared(
            from: try containers(of: bytes, near: url), fallbackTitle: fallbackTitle, includesPages: includesPages)
    }

    /// The prepared book of the containers of one book.
    private static func prepared(
        from containers: [KFXContainer], fallbackTitle: String, includesPages: Bool
    ) throws -> PreparedBook {
        let book = try KFXBook(containers: containers, includesPages: includesPages)
        return try MOBIParser.preparedBook(
            sections: book.sections, metadata: book.metadata, fallbackTitle: fallbackTitle, includesPages: includesPages)
    }

    // MARK: Containers

    /// The containers of the book at `url`: the containers of a set in a ZIP,
    /// or a main file with what sits beside it. The first bytes decide, and a
    /// protected book is refused before anything else is read.
    private static func containers(at url: URL) throws -> [KFXContainer] {
        switch try KFXSignature.kind(ofFileAt: url) {
        case .zip:
            switch try KFXPackage.kind(ofArchiveAt: url) {
            case .protected: throw MOBIError.copyProtected
            case .kindleCreate: throw KFXError.kindleCreatePackage
            case .other: throw MOBIError.notAKindleBook
            case .containers: return try KFXPackage.containers(inArchiveAt: url)
            }
        case .container, .protected:
            return try containers(of: [UInt8](try DocumentByteLimit.contents(of: url)), near: url)
        case .other:
            throw MOBIError.notAKindleBook
        }
    }

    /// The containers of the book whose main file holds `bytes`: that file,
    /// then the containers in the folder beside it (`url`'s `.sdr`), which
    /// add whatever the main file lacks, such as its metadata (a fragment
    /// the main file holds is the one read, whatever a sidecar says).
    /// - Throws: `MOBIError.copyProtected` when `bytes` or anything beside the
    ///   file is protected, and what `KFXContainer.init(bytes:)` throws for the
    ///   main file. A sidecar that does not read is left out.
    private static func containers(of bytes: [UInt8], near url: URL?) throws -> [KFXContainer] {
        switch KFXSignature.kind(ofPrefix: Array(bytes.prefix(KFXSignature.prefixLength))) {
        case .protected: throw MOBIError.copyProtected
        case .container: break
        case .zip, .other: throw MOBIError.notAKindleBook
        }
        var neighbours = KFXSidecar.Scan()
        if let url { neighbours = KFXSidecar.scan(near: url) }
        // Nothing beside a protected book is opened.
        if neighbours.isProtected { throw MOBIError.copyProtected }

        var containers = [try KFXContainer(bytes: bytes)]
        var total: Int64 = 0
        for sidecar in neighbours.containers {
            guard let data = try? DocumentByteLimit.contents(of: sidecar) else { continue }
            total += Int64(data.count)
            guard total <= maximumSidecarBytes else { break }
            if let container = try? KFXContainer(bytes: [UInt8](data)) { containers.append(container) }
        }
        return containers
    }

    // MARK: Metadata

    /// What the KFX book at `url` says about itself, without reading its
    /// text.
    /// - Throws: As `prepareBook(url:fallbackTitle:includesPages:)`.
    static func readMetadata(url: URL) throws -> MOBIBook.Metadata {
        try KFXBook.metadata(of: try containers(at: url))
    }

    /// What the KFX container in `bytes` says about itself. A protected
    /// container names nothing (its metadata is never opened), so it is
    /// refused here as it is when its text is asked for.
    /// - Throws: `MOBIError.copyProtected` for a protected container,
    ///   `MOBIError.notAKindleBook` for a file of another kind.
    static func readMetadata(bytes: [UInt8], near url: URL? = nil) throws -> MOBIBook.Metadata {
        try KFXBook.metadata(of: try containers(of: bytes, near: url))
    }
}
