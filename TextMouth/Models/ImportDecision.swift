import Foundation

// MARK: - Where an Import Started

/// The Library window an import started in, named by its window number
/// (`NSWindow.windowNumber`), so the questions the import raises are asked
/// in that window (TODO I01). A window number is unique among the windows
/// open at one time.
struct ImportOrigin: Hashable, Sendable {
    /// The window's number.
    let windowNumber: Int
}

// MARK: - What an Import Was Asked to Do

/// What the user asked of one import, carried by every question the import
/// raises (TODO I01), so each answer acts as that import was asked to, however
/// many other imports finish before the user gives it.
struct ImportRequest: Sendable {
    /// The Library window the import started in, which asks its questions;
    /// nil when no window started it.
    var origin: ImportOrigin?
    /// Whether the book the import adds opens in a reader once it is in the
    /// library and every question about it is answered, as for a book opened
    /// from Finder.
    var opensAfterImport = false
    /// The cancellation the import shares with every import queued with it
    /// (`SerialImportQueue.currentCancellation`). The progress overlay's
    /// Cancel sets it, which withdraws the questions of the whole batch too
    /// (`LibraryViewModel.cancelImports()`). A request made outside the
    /// import queue has a batch of its own, which nothing cancels.
    var batch = ImportCancellation()

    /// Whether the batch the import belongs to was cancelled.
    var isCancelled: Bool { batch.isCancelled }
}

// MARK: - One Question

/// One question an import is waiting to ask the user (TODO I01), holding
/// everything its answer acts on, captured when the import finished: the
/// books and files it is about, and the request the import was made with.
/// Answering it can never act on another import's book or file.
struct ImportDecision: Identifiable {
    /// What a question is about, and what its answer acts on.
    enum Kind {
        /// The book just imported matches one already in the library:
        /// replace that copy, keep both, or discard the new copy.
        case duplicate(DuplicateBook)
        /// A book was imported from a file that "After Importing a Book"
        /// says to ask about: delete the file, to the Trash or permanently
        /// as "Move to Trash instead of deleting" says, or keep it.
        case originalFile(OriginalFile)
        /// A ZIP archive added several books: put them in a new folder, or
        /// leave them where they are.
        case zipFolder(ZipBatch)
    }

    /// A book imported as a copy of one already in the library.
    struct DuplicateBook {
        /// The new copy, already in a package of its own but not yet in the
        /// library.
        let book: Book
        /// The library's copy the new one matched when it was imported.
        /// Answers act on whichever copy matches when they are given
        /// (`LibraryViewModel.duplicateMatch(for:)`), since an earlier answer
        /// may have replaced this one; it names the copy only when none does.
        let existing: Book
        /// The file the new copy was imported from, when the preference may
        /// delete it once the copy is kept; nil when it must stay.
        let originalURL: URL?
        /// What the new copy is missing, told with the question so it never
        /// needs an alert of its own.
        let warning: String?
    }

    /// The original file of a book, or of a ZIP archive's books, just added
    /// to the library.
    struct OriginalFile {
        /// The file the question offers to delete.
        let url: URL
        /// The book imported from it; nil for a ZIP archive, which can hold
        /// many.
        let bookID: UUID?
    }

    /// The books one ZIP archive added to the library.
    struct ZipBatch {
        /// The archive they came from.
        let archiveURL: URL
        /// The books, as they were added.
        let books: [Book]
        /// The library folder they were imported into, which would hold
        /// their new folder.
        let folderPath: String
    }

    /// Tells this question from every other, so an answer meant for it is
    /// never applied to the question asked after it.
    let id = UUID()
    /// What the question is about.
    let kind: Kind
    /// What its import was asked to do.
    let request: ImportRequest

    /// The book the question is about, which opens once the question is
    /// settled with the book in the library, when its import asked for that;
    /// nil for a ZIP archive's books.
    var bookID: UUID? {
        switch kind {
        case .duplicate(let duplicate):
            return duplicate.book.id
        case .originalFile(let original):
            return original.bookID
        case .zipFolder:
            return nil
        }
    }
}

// MARK: - Answers

/// An answer to an import question (TODO I01). Each kind of question takes
/// answers of its own, and every kind takes Cancel.
enum ImportDecisionAnswer: Equatable {
    /// A duplicate: replace the library's copy with the new one.
    case replaceExisting
    /// A duplicate: keep both copies as separate books.
    case keepBoth
    /// An original file: delete it.
    case deleteOriginal
    /// A ZIP archive's books: put them in a new folder of this name, inside
    /// the folder they were imported into.
    case createFolder(named: String)
    /// Any question: the sheet's Cancel, Keep, or No Thanks, which Escape
    /// presses too. A duplicate's new copy is discarded, an original file is
    /// kept, and a ZIP archive's books stay where they are.
    case cancel

    /// Whether this answer is one a question of `kind` takes.
    func fits(_ kind: ImportDecision.Kind) -> Bool {
        switch (self, kind) {
        case (.cancel, _),
             (.replaceExisting, .duplicate), (.keepBoth, .duplicate),
             (.deleteOriginal, .originalFile),
             (.createFolder, .zipFolder):
            return true
        default:
            return false
        }
    }
}

// MARK: - Wording

/// What the import question sheet shows, and VoiceOver speaks, for one
/// question (TODO I01), built in one place so the two always agree.
struct ImportDecisionWording: Equatable {
    /// The question's title, followed by its place among the questions
    /// asked since none was waiting when there is more than one, as in
    /// "Duplicate Book Found, 1 of 3".
    let title: String
    /// What the question asks, naming the books and files it is about.
    let message: String
    /// For a question about an original file, the words of its deletion,
    /// including its deleting button's title; nil for every other question.
    let originalFile: OriginalFileDeletionWording?

    /// The title of a duplicate's question.
    static let duplicateTitle = "Duplicate Book Found"
    /// The title of a ZIP archive's folder question.
    static let zipFolderTitle = "Create Folder for Imported Books?"

    /// The wording of `decision`, the question at `position` of the `total`
    /// asked since none was waiting.
    ///
    /// - Parameters:
    ///   - matchingTitle: For a duplicate, the title of the library's copy
    ///     it matches now; nil to name the copy it matched on import.
    ///   - movesToTrash: Whether "Move to Trash instead of deleting" is on,
    ///     which decides the words of an original file's question, as it
    ///     decides where the file goes.
    init(
        for decision: ImportDecision,
        position: Int,
        total: Int,
        matchingTitle: String? = nil,
        movesToTrash: Bool
    ) {
        switch decision.kind {
        case .duplicate(let duplicate):
            title = Self.counted(Self.duplicateTitle, position: position, total: total)
            message = Self.duplicateMessage(duplicate, matchingTitle: matchingTitle ?? duplicate.existing.title)
            originalFile = nil
        case .originalFile(let original):
            let deletion = OriginalFileDeletionWording(
                movesToTrash: movesToTrash,
                fileName: original.url.lastPathComponent
            )
            title = Self.counted(deletion.confirmationTitle, position: position, total: total)
            message = deletion.confirmationMessage
            originalFile = deletion
        case .zipFolder(let batch):
            title = Self.counted(Self.zipFolderTitle, position: position, total: total)
            message = "\(CountWording.books(batch.books.count)) were imported from "
                + "“\(batch.archiveURL.lastPathComponent)”. "
                + "Would you like to create a new folder to hold them?"
            originalFile = nil
        }
    }

    /// What VoiceOver announces when the question appears: its title, then
    /// what it asks.
    var announcement: String {
        "\(Self.endingSentence(title)) \(message)"
    }

    /// `title` followed by the question's place, as in "Duplicate Book
    /// Found, 2 of 3", or `title` alone when it is the only question. A
    /// title that ends in a question mark already pauses there.
    static func counted(_ title: String, position: Int, total: Int) -> String {
        guard total > 1 else { return title }
        let separator = title.hasSuffix("?") ? " " : ", "
        return "\(title)\(separator)\(position) of \(total)"
    }

    /// What a duplicate's question asks: which file matches which book, the
    /// choice, and, for a copy missing chapters, what it lacks, so it never
    /// replaces a complete copy unannounced. The new copy is named by the
    /// file it came from, or by its title when it came from no file.
    private static func duplicateMessage(_ duplicate: ImportDecision.DuplicateBook, matchingTitle: String) -> String {
        let newCopy = duplicate.book.sourceFilePath
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
            ?? duplicate.book.title
        let choice = "“\(newCopy)” matches “\(matchingTitle)”, which is already in your library. "
            + "Replace the existing copy (updates the .tmb and timestamp) or keep both as separate entries?"
        guard let warning = duplicate.warning else { return choice }
        return choice + "\n\nThe copy just imported is incomplete. \(warning)"
    }

    /// `text` ending a sentence: as it is when it ends in a full stop,
    /// question mark, or exclamation mark, and with a full stop otherwise.
    private static func endingSentence(_ text: String) -> String {
        guard let last = text.last, !".?!".contains(last) else { return text }
        return text + "."
    }
}
