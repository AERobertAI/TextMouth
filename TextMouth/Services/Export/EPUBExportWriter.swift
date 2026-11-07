import Foundation
import ZIPFoundation

// MARK: - The EPUB 3 Writer (FMT28)

/// Writes a text book as an EPUB 3 file: its chapters, its headings nested in
/// a navigation document, and its pages, so a blind reader's headings,
/// pages, and contents go with the book to any reading system.
///
/// It reads the `ExportDocument` that `ExportWalkOptions.bookStructure` asks
/// for, and never parses Markdown. The chapters' markup is `XHTMLMarkup`'s,
/// the HTML writer's too, so a heading, a list, or a table is written once.
///
/// The package, in the order the ZIP holds it:
/// - `mimetype`, first and stored, as EPUB requires;
/// - `META-INF/container.xml`, which names the package document;
/// - `OEBPS/chapter-N.xhtml`, a file for each chapter, a long chapter
///   continued in another file when it passes `maximumFileBytes`, ending a
///   file where a heading begins when it can, so a file and the string made
///   for it are a part of the book (one block, a single paragraph with no
///   blank line, is still one file);
/// - `OEBPS/nav.xhtml`, the contents from the headings, the chapters, and the
///   places the book's contents point at, and the page list from the pages;
/// - `OEBPS/content.opf`, the package document: identifier, title, creator,
///   language, the modified date, and accessibility metadata that says only
///   what is true of the file.
///
/// What it leaves out: pictures (the book's text holds their alternative
/// text), styles, and the book's cover. Every string it writes is escaped for
/// XML, and a character XML 1.0 forbids is dropped (`XMLEscaping`).
struct EPUBExportWriter: TextExportWriter {
    /// The writer's name in code, never shown.
    let id = "epub"
    /// The name the Convert to picker lists and VoiceOver speaks.
    let name = "EPUB"
    /// The extension of the files it makes.
    let fileExtension = "epub"
    /// What the picker's hint says while this writer is chosen.
    let hint = "An e-book with the book's headings, contents, and page numbers where it has them, for Apple Books and other reading apps. It holds no pictures."

    /// The book's chapters and pages are kept as well as its words.
    var walkOptions: ExportWalkOptions { .bookStructure }

    /// The date the export says it was made on: the clock's, or a fixed one
    /// in a test, so that the bytes written are the same every time.
    let modified: @Sendable () -> Date
    /// How many bytes of markup a chapter's file holds before the chapter
    /// goes on in another: a file is not ended inside a block, so it may pass
    /// this by the last block's size.
    let maximumFileBytes: Int
    /// Called with the path of each file of the package once it is in the
    /// ZIP, and free to throw: a test's way to stop, or fail, the export
    /// exactly after a given file. The export itself sets none.
    let afterEachFile: (@Sendable (String) throws -> Void)?

    /// The file size EPUB reading systems handle comfortably: they load a
    /// whole file to lay it out.
    static let defaultMaximumFileBytes = 256_000

    /// A writer that dates the export by the clock.
    init(
        modified: @escaping @Sendable () -> Date = { Date() },
        maximumFileBytes: Int = defaultMaximumFileBytes,
        afterEachFile: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.modified = modified
        self.maximumFileBytes = maximumFileBytes
        self.afterEachFile = afterEachFile
    }

    /// Writes the EPUB of `document` as a new file at `url`; a file already
    /// there is an error, and is left as it was. A stopped or failed write
    /// removes the file it began, and a file that does not hold every entry
    /// once it is closed (a disk that filled while its last bytes were still
    /// being buffered) is a failure too, not an export.
    ///
    /// Errors that are the system's (a full disk, a folder that cannot be
    /// written) are thrown as they are, so the export names the system's
    /// words as every other writer's failure does; one of the ZIP library's,
    /// which says nothing a listener can use, is a sentence of its own.
    func write(
        _ document: ExportDocument,
        options: NoTextExportOptions,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        // A book already stopped writes nothing, even one with no blocks.
        try cancellation.checkCancelled()
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url])
        }
        do {
            let paths = try writePackage(of: document, to: url, cancellation: cancellation)
            try Self.verify(url, holds: paths)
        } catch {
            // Whatever began the file is not an EPUB: remove it, and say why.
            try? FileManager.default.removeItem(at: url)
            if error is Archive.ArchiveError || error is Data.DataError {
                throw TextExportError("The EPUB file could not be written.")
            }
            throw error
        }
    }

    /// The sentence for a write that failed with the system error `code` (the
    /// `errno` the failed write left): the disk may be full for the errors a
    /// full disk, a quota, or a size limit give, and, for a few others, the
    /// system's own words ("Read-only file system"). Any other, or none, is
    /// taken for a full disk, which is what the ZIP library's write failures
    /// nearly always are.
    static func writeFailureSentence(errno code: Int32) -> String {
        switch code {
        case EIO, EROFS, EACCES, EPERM, ESTALE, ENXIO, ENODEV, ETIMEDOUT:
            return "The EPUB file could not be written: \(String(cString: strerror(code)))."
        default:
            return "The EPUB file could not be written, because the disk may be full."
        }
    }

    /// Writes the package of `document` into a new archive at `url` and
    /// closes it (the archive is closed when this returns, which is what
    /// flushes its last bytes), returning the path of each entry it added.
    private func writePackage(
        of document: ExportDocument,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws -> [String] {
        var builder = EPUBPackageBuilder(
            archive: try Archive(url: url, accessMode: .create),
            document: document,
            date: modified(),
            maximumFileBytes: max(maximumFileBytes, 1),
            cancellation: cancellation,
            afterEachFile: afterEachFile
        )
        do {
            try builder.writePackage()
        } catch is Data.DataError {
            // The ZIP library's failure to write a file's bytes: say why in a
            // sentence, with the system's reason read before anything else
            // can change it.
            throw TextExportError(Self.writeFailureSentence(errno: errno))
        }
        return builder.writtenPaths
    }

    /// Opens the file at `url` again and checks it holds exactly the entries
    /// `paths`, in order, each of which reads back whole and with the checksum
    /// the archive stores for it (the ZIP library returns the checksum of what
    /// it read and leaves the comparison to its caller). The ZIP library does
    /// not report a failure of its last flush, so a file cut short without its
    /// central directory reads as nothing here.
    static func verify(_ url: URL, holds paths: [String]) throws {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        guard entries.map(\.path) == paths else {
            throw TextExportError("The EPUB file could not be written.")
        }
        for entry in entries {
            let checksum = try archive.extract(entry) { _ in }
            guard checksum == entry.checksum else {
                throw TextExportError("The EPUB file could not be written.")
            }
        }
    }

    // MARK: Identity

    /// The book's identifier as the package gives it: "urn:uuid:" and the
    /// book's identity in the library, in lower case, so exporting the same
    /// book twice gives the same one. A book made without an identity (only a
    /// test's details are) gets a new one for each export.
    static func identifier(of book: ExportBookDetails) -> String {
        "urn:uuid:" + (book.identifier ?? UUID()).uuidString.lowercased()
    }

    /// `date` as the package's modified date: UTC, to the second, "Z" at the
    /// end, as EPUB requires ("2026-11-06T17:30:00Z").
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
