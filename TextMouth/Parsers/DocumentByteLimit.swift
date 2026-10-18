import Foundation

// MARK: - The Limit

/// The most bytes TextMouth reads from one document that its own readers
/// take whole: a rich-text, Word 97-2003, OpenDocument, or Word 2003 XML
/// document before textutil converts it, the HTML textutil writes from it,
/// a web archive, and an SSML file (FMT13, FMT03, FMT07).
///
/// It is 64 MB, the limit for one text file inside a book's archive
/// (`ArchiveEntryLimits.standard.text`): a 1,000-page novel is 2 to 5 MB as
/// rich text, so it fits many times over, while a file far larger is
/// refused with a sentence instead of filling the Mac's memory.
enum DocumentByteLimit {
    /// The documented limit every reader uses.
    static let standard: Int64 = ArchiveEntryLimits.standard.text

    /// The limit readers use: `standard`, unless a test binds a smaller one
    /// with `DocumentByteLimit.$current.withValue(_:operation:)`, which
    /// changes only the reading that operation does on its own thread. A
    /// detached task does not inherit it, so a reader checks a size before
    /// it hands any work to one.
    @TaskLocal static var current: Int64 = standard

    /// Refuses `byteCount` bytes when they pass the limit in force.
    /// - Throws: `DocumentTooLargeError` naming that limit.
    static func check(byteCount: Int64) throws {
        guard byteCount <= current else { throw DocumentTooLargeError(limit: current) }
    }

    /// The bytes of the document file at `url`, read whole once its size,
    /// taken from the file system before anything is read, is known to be
    /// within the limit; the bytes read are checked again, for a file that
    /// grew meanwhile.
    /// - Throws: `FileImportError.noTextToRead` for an empty file,
    ///   `DocumentTooLargeError` for one past the limit, and the file
    ///   system's error for one that cannot be read.
    static func contents(of url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw FileImportError.noTextToRead }
        try check(byteCount: Int64(size))
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw FileImportError.noTextToRead }
        try check(byteCount: Int64(data.count))
        return data
    }
}

// MARK: - The Refusal

/// A document that holds more than the most TextMouth reads from one
/// document (`DocumentByteLimit`). Its sentence names the limit, never the
/// file: an import's failure names the file before it (`ImportFailure`).
struct DocumentTooLargeError: LocalizedError, Equatable {
    /// The limit the document passed, in bytes.
    let limit: Int64

    var errorDescription: String? {
        "This document holds more than \(ArchiveFigures.size(limit)), the most TextMouth reads from one document."
    }
}
