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
            return "The file is empty." // l10n: no (damage reason inside a file, question 3)
        }
        if let decodingError = error as? DecodingError {
            return reason(for: decodingError)
        }
        switch (error as? CocoaError)?.code {
        case .fileReadNoPermission?:
            // Translators: Why the library index could not be loaded: macOS refused TextMouth permission to read it.
            return InterfaceText.line("libraryIndexReadFailure.fileReadNoPermission", "TextMouth does not have permission to read the file.")
        case .fileReadNoSuchFile?:
            // Translators: Why the library index could not be loaded: the file vanished during the read.
            return InterfaceText.line("libraryIndexReadFailure.fileReadNoSuchFile", "The file disappeared while TextMouth was reading it.")
        default:
            // Translators: Why the library index could not be loaded: a read error. %@ is the system's own description of the error.
            return InterfaceText.line("libraryIndexReadFailure.other", "The file could not be read. \(error.localizedDescription)")
        }
    }

    /// Plain-language reasons for each way decoding can fail.
    private static func reason(for error: DecodingError) -> String {
        switch error {
        // What is wrong inside a file stays in English, whatever language the interface speaks (question 3).
        case .dataCorrupted(let context) where context.codingPath.isEmpty:
            return "The file is damaged or incomplete, so it is not valid JSON." // l10n: no (damage reason inside a file, question 3)
        case .dataCorrupted(let context):
            return "The file contains a value this version of TextMouth does not recognize, " // l10n: no (damage reason inside a file, question 3)
                + "at \(spokenLocation(context.codingPath)). " // l10n: no (damage reason inside a file, question 3)
                + "A newer version of TextMouth may have saved it." // l10n: no (damage reason inside a file, question 3)
        case .keyNotFound(let key, let context):
            return "The file is missing required information, at \(spokenLocation(context.codingPath + [key]))." // l10n: no (damage reason inside a file, question 3)
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "The file contains information in an unexpected form, at \(spokenLocation(context.codingPath))." // l10n: no (damage reason inside a file, question 3)
        @unknown default:
            return "The file could not be decoded." // l10n: no (damage reason inside a file, question 3)
        }
    }

    /// "books, item 3, format" for the coding path `books[2].format`.
    private static func spokenLocation(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "the top level of the file" } // l10n: no (damage reason inside a file, question 3)
        return codingPath
            .map { key in key.intValue.map { "item \($0 + 1)" } ?? key.stringValue } // l10n: no (damage reason inside a file, question 3)
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
    /// Rebuild Library Index found that the index a load would read now can
    /// be read again, as when the user restored it from a backup, so it
    /// replaced nothing: Try Again uses that index.
    case indexReadableAgain

    var errorDescription: String? {
        switch self {
        case .indexUnreadable:
            // Translators: Why a command that acts on the library index was refused: the index can't be read yet. Try Again and Rebuild Library Index are button names in the Library window.
            return InterfaceText.line("libraryIndexRecoveryError.indexUnreadable", "The library index can't be read. Choose Try Again or Rebuild Library Index in the Library window first.")
        case .couldNotPreserve(let url):
            return SentenceWording.joined([
                // Translators: First sentence of why Rebuild Library Index replaced nothing. %@ is the file's path.
                InterfaceText.line("libraryIndexRecoveryError.couldNotPreserve", "TextMouth could not save a copy of \(url.path), so it left that file unchanged."),
                // Translators: Last sentence of why Rebuild Library Index replaced nothing: what to do.
                InterfaceText.line("libraryIndexRecoveryError.couldNotPreserveFix", "Make sure its folder can be written to, then try again."),
            ])
        case .indexReadableAgain:
            // Said after "The library index was not rebuilt." (the recovery
            // sheet's outcome), so it names the index once.
            // Translators: Why Rebuild Library Index replaced nothing: the library index can be read again. It follows the sentence "The library index was not rebuilt.", so "It" is the index. Try Again is a button name.
            return InterfaceText.line("libraryIndexRecoveryError.indexReadableAgain", "It can be read again now. Choose Try Again to use it.")
        }
    }
}
