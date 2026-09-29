import Foundation

/// What reading the library index produced. An index that exists but cannot
/// be used is reported as such, never replaced by an empty library.
enum LibraryLoadResult {
    /// The index was read and decoded.
    case loaded(Library)
    /// No index exists at the current or the legacy location: a fresh install.
    case missing
    /// An index exists but could not be read or decoded. Its bytes were
    /// preserved and library index writes are suspended; see
    /// `LibraryPersistenceService`.
    case unreadable(LibraryIndexReadFailure)

    /// The decoded library, or nil when the index was missing or unreadable.
    var library: Library? {
        if case .loaded(let library) = self {
            return library
        }
        return nil
    }
}

/// Why an existing library index could not be used, and where its bytes were
/// preserved.
struct LibraryIndexReadFailure {
    /// The index that failed: `library.json` in the data directory, or the
    /// legacy index in Application Support.
    let indexURL: URL
    /// The preserved copy beside the index, or nil when none could be made.
    let quarantineURL: URL?
    /// The underlying read or decoding error, kept for diagnostics.
    let error: Error
    /// A plain-language explanation for the recovery sheet and VoiceOver.
    let reason: String

    /// Describes a failure. `byteCount` is the size of what was read, or nil
    /// when the file could not be read at all.
    init(indexURL: URL, quarantineURL: URL?, error: Error, byteCount: Int?) {
        self.indexURL = indexURL
        self.quarantineURL = quarantineURL
        self.error = error
        self.reason = Self.plainLanguageReason(for: error, byteCount: byteCount)
    }

    /// Explains `error` without programming jargon. Decoding errors say where
    /// in the file the problem is, in words ("books, item 3, format") that
    /// VoiceOver and a braille display render naturally, not bracket notation.
    static func plainLanguageReason(for error: Error, byteCount: Int?) -> String {
        if byteCount == 0 {
            return "The file is empty."
        }
        if let decodingError = error as? DecodingError {
            return reason(for: decodingError)
        }
        switch (error as? CocoaError)?.code {
        case .fileReadNoPermission?:
            return "TextMouth does not have permission to read the file."
        case .fileReadNoSuchFile?:
            return "The file disappeared while TextMouth was reading it."
        default:
            return "The file could not be read. \(error.localizedDescription)"
        }
    }

    /// Plain-language reasons for each way decoding can fail.
    private static func reason(for error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context) where context.codingPath.isEmpty:
            return "The file is damaged or incomplete, so it is not valid JSON."
        case .dataCorrupted(let context):
            return "The file contains a value this version of TextMouth does not recognize, "
                + "at \(spokenLocation(context.codingPath)). "
                + "A newer version of TextMouth may have saved it."
        case .keyNotFound(let key, let context):
            return "The file is missing required information, at \(spokenLocation(context.codingPath + [key]))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "The file contains information in an unexpected form, at \(spokenLocation(context.codingPath))."
        @unknown default:
            return "The file could not be decoded."
        }
    }

    /// "books, item 3, format" for the coding path `books[2].format`.
    private static func spokenLocation(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "the top level of the file" }
        return codingPath
            .map { key in key.intValue.map { "item \($0 + 1)" } ?? key.stringValue }
            .joined(separator: ", ")
    }
}

/// Refusals of the library index recovery workflow.
enum LibraryIndexRecoveryError: LocalizedError {
    /// An operation that would act on the library index was refused because
    /// the index cannot be read yet.
    case indexUnreadable
    /// Rebuild Library Index would have replaced a file it could not preserve
    /// first, so it replaced nothing.
    case couldNotPreserve(URL)

    var errorDescription: String? {
        switch self {
        case .indexUnreadable:
            return "The library index can't be read. Choose Try Again or Rebuild Library Index "
                + "in the Library window first."
        case .couldNotPreserve(let url):
            return "TextMouth could not save a copy of \(url.path), so it left that file unchanged. "
                + "Make sure its folder can be written to, then try again."
        }
    }
}
