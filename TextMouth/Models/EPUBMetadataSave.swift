import Foundation

// Saving edited EPUB metadata (TODO A09). TextMouth keeps its own copy of
// every EPUB inside the book's package in the library. Writing metadata back
// changes only that copy, never the file the book was imported from, which
// may since have been moved or deleted, and it is written before anything
// else changes, so a write that fails leaves every view of the book as it
// was.

// MARK: - Writing the File

/// Writes edited metadata into the library's copy of a book's EPUB file.
/// Tests replace `write` to make the write fail.
struct EPUBMetadataWriter: Sendable {
    /// Writes `metadata` into the EPUB file at `file` and returns the file's
    /// new MD5 hash. A write that throws has left the file as it was.
    var write: @MainActor @Sendable (_ metadata: EPUBMetadata, _ file: URL) throws -> String

    /// The write the app makes: the EPUB parser's, which prepares the change
    /// in a copy and replaces the file with it in one step.
    static let system = EPUBMetadataWriter { metadata, file in
        try EPUBParser.writeMetadata(metadata, to: file)
    }
}

// MARK: - What a Save Did

/// What saving edited EPUB metadata did, for the editor that asked to
/// report: a success closes the editor, and a failure keeps it open with the
/// user's edits beside the reason.
enum EPUBMetadataSave {
    /// The metadata was saved. `book` is the book as the library now records
    /// it, and `message` says where the metadata went.
    case saved(Book, message: String)
    /// Nothing was saved. `message` says why, naming the library's copy of
    /// the EPUB file whenever writing it was what failed.
    case failed(message: String)

    /// What VoiceOver hears, and the editor shows after a failure.
    var message: String {
        switch self {
        case .saved(_, let message), .failed(let message):
            return message
        }
    }

    /// This save as the editor acts on it.
    var outcome: OperationOutcome {
        switch self {
        case .saved(_, let message): return .success(message)
        case .failed(let message): return .failure(message)
        }
    }

    /// The book as the library records it after a save that succeeded, or
    /// nil after a failure, which changed nothing.
    var savedBook: Book? {
        if case .saved(let book, _) = self { return book }
        return nil
    }
}

// MARK: - Wording

/// The words that report a save of edited EPUB metadata. Every sentence that
/// mentions the EPUB file names it as the library's copy, so it is never
/// mistaken for the file the book was imported from.
struct EPUBMetadataSaveWording {
    /// The name of the library's copy of the book's EPUB file, such as
    /// "alice.epub".
    let fileName: String

    /// The words for the library's copy of the EPUB file at `filePath`.
    init(filePath: String) {
        fileName = URL(fileURLWithPath: filePath).lastPathComponent
    }

    /// The file as a sentence names it: "the library's copy of “alice.epub”".
    var libraryCopy: String {
        "the library's copy of “\(fileName)”"
    }

    /// After the file and the library both took the metadata: "Metadata
    /// saved to the library's copy of “alice.epub”."
    var savedToFile: String {
        "Metadata saved to \(libraryCopy)."
    }

    /// After writing the file failed, so nothing was saved: "Could not save
    /// metadata to the library's copy of “alice.epub”: The volume is
    /// read-only. Nothing was changed." `reason` is the error's description,
    /// made to end as a sentence ends.
    func writeFailed(reason: String) -> String {
        "Could not save metadata to \(libraryCopy): \(PersistenceFailure.sentence(reason)) Nothing was changed."
    }

    /// After the library alone took the metadata, as asked.
    static let savedToLibraryOnly = "Metadata saved to the library only; the EPUB file is unchanged."

    /// When the book titled `title` has left the library, so its edit has
    /// nowhere to go: "Could not save metadata: “Notes” is no longer in the
    /// library. Nothing was changed."
    static func notInLibrary(title: String) -> String {
        "Could not save metadata: “\(title)” is no longer in the library. Nothing was changed."
    }
}
