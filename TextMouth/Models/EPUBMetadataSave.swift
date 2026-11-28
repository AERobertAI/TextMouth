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

// MARK: - Keeping Metadata Read from the File

extension Book {
    /// Gives each EPUB metadata field this book's row lacks the value read
    /// from its file, `metadata`, as an import gives a new book's row every
    /// one of them (`ImportedFileMetadata`), so that the row then keeps all
    /// of it (`keptEPUBMetadata`). A field the row keeps already stays as it
    /// is: an edit of the publisher or the publication date, even one that
    /// cleared it, and any field kept before. The title and author are the
    /// library's own names for the book and are not touched, and a book in
    /// any other format is left as it is.
    ///
    /// - Returns: Whether any field changed.
    @discardableResult
    mutating func keepEPUBMetadata(readFromFile metadata: EPUBMetadata) -> Bool {
        guard format == .epub else { return false }
        let before = [epubPublisher, epubPublicationDate, epubISBN, epubLanguage, epubIdentifier, epubVersion]
        epubPublisher = epubPublisher ?? metadata.publisher
        epubPublicationDate = epubPublicationDate ?? metadata.publicationDate
        epubISBN = epubISBN ?? metadata.isbn
        epubLanguage = epubLanguage ?? metadata.language
        epubIdentifier = epubIdentifier ?? metadata.identifier
        epubVersion = epubVersion ?? metadata.epubVersion
        return before != [epubPublisher, epubPublicationDate, epubISBN, epubLanguage, epubIdentifier, epubVersion]
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

    /// After the file and the library both took the metadata: "Metadata
    /// saved to the library's copy of “alice.epub”."
    var savedToFile: String {
        // Translators: Announcement after the metadata was saved to the library and to the library's copy of the book's EPUB file. %@ is the EPUB file's name.
        InterfaceText.line("epubMetadataSave.savedToFile", "Metadata saved to the library's copy of “\(fileName)”.")
    }

    /// After writing the file failed, so nothing was saved: "Could not save
    /// metadata to the library's copy of “alice.epub”: The volume is
    /// read-only. Nothing was changed." `reason` is the error's description,
    /// made to end as a sentence ends.
    func writeFailed(reason: String) -> String {
        SentenceWording.joined([
            // Translators: First part of the message when writing the metadata into the library's copy of an EPUB file failed. %1$@ is the EPUB file's name; %2$@ is the reason from the system, written as a sentence.
            InterfaceText.line("epubMetadataSave.writeFailed", "Could not save metadata to the library's copy of “\(fileName)”: \(PersistenceFailure.sentence(reason))"),
            // Translators: Last sentence of a message that says saving failed: nothing the user edited was saved anywhere.
            InterfaceText.line("common.nothingWasChanged", "Nothing was changed."),
        ])
    }

    /// After writing the file failed because the file is not in the library
    /// where it should be, so nothing was saved: it names the file, not its
    /// place on the disk, and the choice that saves to the library alone,
    /// which is the way to keep the edit.
    var fileMissing: String {
        SentenceWording.joined([
            // Translators: First sentence of the message when the library's copy of an EPUB file is missing, so the metadata could not be written into it. %@ is the EPUB file's name.
            InterfaceText.line("epubMetadataSave.fileMissing.because", "Could not save metadata to the library's copy of “\(fileName)”, because that file is missing from the library."),
            // Translators: Second sentence of that message. %@ is the shown name of the editor's switch that also writes the file, quoted.
            InterfaceText.line("epubMetadataSave.fileMissing.turn", "Turn off “\(Self.writeBackToggleTitle)” to save the metadata to the library only."),
            // Translators: Last sentence of a message that says saving failed: nothing the user edited was saved anywhere.
            InterfaceText.line("common.nothingWasChanged", "Nothing was changed."),
        ])
    }

    /// After the library alone took the metadata, as asked.
    static var savedToLibraryOnly: String {
        // Translators: Announcement after the metadata was saved to the library only, as the user chose; the book's EPUB file was not rewritten.
        InterfaceText.line("epubMetadataSave.savedToLibraryOnly", "Metadata saved to the library only; the EPUB file is unchanged.")
    }
}

// MARK: - The Editor's Words

extension EPUBMetadataSaveWording {
    /// The metadata editor's choice to write the file too, which VoiceOver
    /// also reads as the choice's label.
    nonisolated static var writeBackToggleTitle: String {
        // Translators: Label of the metadata editor's switch that also writes the edited title, author, publisher and date into the library's own copy of the book's EPUB file.
        InterfaceText.line("epubMetadataSave.writeBackToggleTitle", "Also write to the library's copy of the EPUB file")
    }

    /// VoiceOver's hint for that choice: which file is written, and that the
    /// file the user imported is not.
    nonisolated static var writeBackToggleHint: String {
        SentenceWording.joined([
            // Translators: First sentence of the hint of the metadata editor's switch that also writes the EPUB file.
            InterfaceText.line("epubMetadataSave.writeBackToggleHint.publisher", "Writes the title, author, publisher, and date into the library's copy of this book."),
            // Translators: Last sentence of the hint of the metadata editor's switch that also writes the EPUB file: the file the user first imported stays as it was.
            InterfaceText.line("epubMetadataSave.writeBackToggleHint.original", "The original file you imported is not touched."),
        ])
    }

    /// Shown under the choice while it is on.
    nonisolated static var writeBackNote: String {
        SentenceWording.joined([
            // Translators: First sentence of the warning shown under the metadata editor's switch while it is on. MD5 is the name of a checksum and stays as written.
            InterfaceText.line("epubMetadataSave.writeBackNote.recalculate", "Warning: This will rewrite the library's copy of the EPUB file and recalculate its MD5 hash."),
            // Translators: Last sentence of the warning shown under the metadata editor's switch while it is on: the file the user first imported stays as it was.
            InterfaceText.line("epubMetadataSave.writeBackNote.original", "The original file you imported is not changed."),
        ])
    }

    /// What VoiceOver says for the editor's Save button, which tells where
    /// the metadata goes: to the library only, or to the library and to the
    /// library's copy of the EPUB file.
    static func saveButtonLabel(writesToFile: Bool) -> String {
        writesToFile
            // Translators: Label of the metadata editor's Save button while the switch that also writes the EPUB file is on.
            ? InterfaceText.line("epubMetadataSave.saveButtonLabel.copy", "Save metadata to the library and to the library's copy of the EPUB file")
            // Translators: Label of the metadata editor's Save button while the switch that also writes the EPUB file is off.
            : InterfaceText.line("epubMetadataSave.saveButtonLabel.only", "Save metadata to the library only")
    }
}
