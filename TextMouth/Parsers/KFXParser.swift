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

    /// The containers of one book: the main ones, and what sits beside the
    /// main file.
    private struct Opened {
        var main: [KFXContainer]
        var sidecars: [KFXContainer] = []
    }

    /// The prepared book of the containers of one book.
    private static func prepared(from opened: Opened, fallbackTitle: String, includesPages: Bool) throws -> PreparedBook {
        let book = try KFXBook(containers: opened.main, sidecars: opened.sidecars, includesPages: includesPages)
        return try MOBIParser.preparedBook(
            sections: book.sections, metadata: book.metadata, fallbackTitle: fallbackTitle, includesPages: includesPages)
    }

    // MARK: Containers

    /// Whether anything beside the book at `url` (its `.sdr` folder, a
    /// voucher with its name) says it is protected. The app asks this of a
    /// source file before it copies the file into the library, where the
    /// folder is not.
    static func isProtected(near url: URL) -> Bool {
        KFXSidecar.scan(near: url).isProtected
    }

    /// The containers of the book at `url`: the containers of a set in a ZIP,
    /// or a main file with what sits beside it. The first bytes decide, and a
    /// protected book is refused before anything else is read (its size
    /// included: the sentence is the protected one, however large).
    private static func containers(at url: URL) throws -> Opened {
        switch try KFXSignature.kind(ofFileAt: url) {
        case .zip:
            switch try KFXPackage.kind(ofArchiveAt: url) {
            case .protected: throw MOBIError.copyProtected
            case .kindleCreate: throw KFXError.kindleCreatePackage
            case .other: throw MOBIError.notAKindleBook
            case .containers: return Opened(main: try KFXPackage.containers(inArchiveAt: url))
            }
        case .protected:
            throw MOBIError.copyProtected
        case .container:
            return try containers(of: [UInt8](try DocumentByteLimit.contents(of: url)), near: url)
        case .other:
            throw MOBIError.notAKindleBook
        }
    }

    /// The containers of the book whose main file holds `bytes`: that file,
    /// and the containers in the folder beside it (`url`'s `.sdr`), which
    /// add whatever the main file lacks, such as its metadata (a fragment
    /// the main file holds is the one read, whatever a sidecar says).
    /// - Throws: `MOBIError.copyProtected` when `bytes` or anything beside the
    ///   file is protected, and what `KFXContainer.init(bytes:)` throws for the
    ///   main file. A sidecar that does not read is left out.
    private static func containers(of bytes: [UInt8], near url: URL?) throws -> Opened {
        switch KFXSignature.kind(ofPrefix: Array(bytes.prefix(KFXSignature.prefixLength))) {
        case .protected: throw MOBIError.copyProtected
        case .container: break
        case .zip, .other: throw MOBIError.notAKindleBook
        }
        var neighbours = KFXSidecar.Scan()
        if let url { neighbours = KFXSidecar.scan(near: url) }
        // Nothing beside a protected book is opened.
        if neighbours.isProtected { throw MOBIError.copyProtected }

        var opened = Opened(main: [try KFXContainer(bytes: bytes)])
        var total: Int64 = 0
        for sidecar in neighbours.containers {
            guard let data = try? DocumentByteLimit.contents(of: sidecar) else { continue }
            total += Int64(data.count)
            guard total <= maximumSidecarBytes else { break }
            if let container = try? KFXContainer(bytes: [UInt8](data)) { opened.sidecars.append(container) }
        }
        return opened
    }

    // MARK: Metadata

    /// What the KFX book at `url` says about itself, without reading its
    /// text.
    /// - Throws: As `prepareBook(url:fallbackTitle:includesPages:)`.
    static func readMetadata(url: URL) throws -> MOBIBook.Metadata {
        let opened = try containers(at: url)
        return try KFXBook.metadata(of: opened.main, sidecars: opened.sidecars)
    }

    /// What the KFX container in `bytes` says about itself. A protected
    /// container names nothing (its metadata is never opened), so it is
    /// refused here as it is when its text is asked for.
    /// - Throws: `MOBIError.copyProtected` for a protected container,
    ///   `MOBIError.notAKindleBook` for a file of another kind.
    static func readMetadata(bytes: [UInt8], near url: URL? = nil) throws -> MOBIBook.Metadata {
        let opened = try containers(of: bytes, near: url)
        return try KFXBook.metadata(of: opened.main, sidecars: opened.sidecars)
    }
}
