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
    /// Whether the books the import adds join the end of the reading list,
    /// as an import made at the Reading List asks (FR09): Import Book, Open
    /// Book..., Import Folder…, or New from Text while the window
    /// shows it. The books themselves go to the folder the window showed
    /// last, as they would anywhere.
    var addsToReadingList = false
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
        /// An audiobook was imported while "Offer to transcribe after
        /// importing an audiobook" is on (FR05): transcribe it, or not now.
        /// Asked after the import's own questions, as the last of them.
        case transcriptionOffer(TranscriptionOffer)
    }

    /// An audiobook just imported, which TextMouth offers to transcribe
    /// (FR05).
    struct TranscriptionOffer {
        /// The book, by ID, as the library lists it: Transcribe opens the
        /// Transcribe Audio sheet for the book as the library holds it then.
        let bookID: UUID
        /// Its title, which the question names.
        let bookTitle: String
        /// How long its audio plays, in seconds, for the estimate, or nil
        /// when not known.
        let audioSeconds: TimeInterval?
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
        /// What replacing does with the two copies' transcripts, when the
        /// new copy brought one from a file beside its audio (FMT23), as
        /// the question says it (`DuplicateReplacement.transcriptOutcome`).
        var transcriptOutcome: DuplicateReplacement.TranscriptOutcome = .asBefore
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
    /// What the question is about. Only `mappingBooks(_:)` changes it.
    private(set) var kind: Kind
    /// What its import was asked to do.
    let request: ImportRequest

    /// This question, the same one, with every book it holds passed through
    /// `transform`: a duplicate's new copy and the library's copy it
    /// matched, or a ZIP archive's books. A data-directory move gives them
    /// their file paths in the new data directory this way (TODO S04).
    func mappingBooks(_ transform: (Book) -> Book) -> ImportDecision {
        var mapped = self
        switch kind {
        case .duplicate(let duplicate):
            mapped.kind = .duplicate(DuplicateBook(
                book: transform(duplicate.book),
                existing: transform(duplicate.existing),
                originalURL: duplicate.originalURL,
                warning: duplicate.warning,
                transcriptOutcome: duplicate.transcriptOutcome
            ))
        case .originalFile, .transcriptionOffer:
            // Neither holds a book's paths: an original file is outside
            // the library, and an offer names its book by ID.
            break
        case .zipFolder(let batch):
            mapped.kind = .zipFolder(ZipBatch(
                archiveURL: batch.archiveURL,
                books: batch.books.map(transform),
                folderPath: batch.folderPath
            ))
        }
        return mapped
    }

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
        case .transcriptionOffer(let offer):
            return offer.bookID
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
    /// An audiobook just imported: transcribe it (FR05).
    case transcribe
    /// Any question: the sheet's Cancel, Keep, No Thanks, or Not Now, which
    /// Escape presses too. A duplicate's new copy is discarded, an original
    /// file is kept, a ZIP archive's books stay where they are, and an
    /// audiobook is left untranscribed.
    case cancel

    /// Whether this answer is one a question of `kind` takes.
    func fits(_ kind: ImportDecision.Kind) -> Bool {
        switch (self, kind) {
        case (.cancel, _),
             (.replaceExisting, .duplicate), (.keepBoth, .duplicate),
             (.deleteOriginal, .originalFile),
             (.createFolder, .zipFolder),
             (.transcribe, .transcriptionOffer):
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
    /// For a duplicate, whether one copy is an audiobook and the other is
    /// not, so replacing keeps only the book's place in the library, which
    /// Replace Existing's hint says too
    /// (`ImportDecisionChoiceWording.replaceExisting(acrossKinds:)`); false
    /// for every other question.
    let replacesAcrossKinds: Bool

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
    ///   - matchingFormat: For a duplicate, the format of the library's copy
    ///     it matches now, which with the new copy's decides what replacing
    ///     keeps; nil for the copy it matched on import.
    ///   - movesToTrash: Whether "Move to Trash instead of deleting" is on,
    ///     which decides the words of an original file's question, as it
    ///     decides where the file goes.
    init(
        for decision: ImportDecision,
        position: Int,
        total: Int,
        matchingTitle: String? = nil,
        matchingFormat: BookFormat? = nil,
        movesToTrash: Bool
    ) {
        replacesAcrossKinds = {
            guard case .duplicate(let duplicate) = decision.kind else { return false }
            return (matchingFormat ?? duplicate.existing.format).isAudio != duplicate.book.format.isAudio
        }()
        switch decision.kind {
        case .duplicate(let duplicate):
            title = Self.counted(Self.duplicateTitle, position: position, total: total)
            message = Self.duplicateMessage(
                duplicate,
                matchingTitle: matchingTitle ?? duplicate.existing.title,
                matchingFormat: matchingFormat ?? duplicate.existing.format,
                movesToTrash: movesToTrash
            )
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
        case .transcriptionOffer(let offer):
            title = Self.counted(TranscriptionWording.offerQuestionTitle, position: position, total: total)
            message = TranscriptionWording.offerMessage(bookTitle: offer.bookTitle, audioSeconds: offer.audioSeconds)
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

    /// What Replace Existing keeps of the library's copy of a text book, and
    /// what it does not (ST04): the new copy takes the old one's place, its
    /// places moved to their words where those are found (a place whose
    /// words nothing finds keeps its place in the text), and an edit of the
    /// old text is kept as a copy, never laid over the new text
    /// (`DuplicateReplacement`).
    static let replacingKeepsTextSentence =
        "Replacing keeps the existing copy's reading position and bookmarks, moved to their words in the new text "
        + "wherever those are found, and its settings, folder, and place on the reading list. "
        + "An edit of its text is kept beside the new text as a copy, not applied to it."

    /// What Replace Existing keeps of the library's copy of an audiobook,
    /// and what it does not (ST04): its transcript only for the same audio,
    /// and never its audio edits or an edit of its manifest (FR17), which
    /// are edits of the old copy's files; its places follow their tracks, or
    /// their times (`DuplicateReplacement.movedAudioPlaces`).
    static let replacingKeepsAudioSentence =
        "\(replacingKeepsAudioPlaces), and its transcript when the audio is the same. \(audioEditsNotKept)"

    /// What Replace Existing keeps of an audiobook when the new copy brought
    /// a transcript from a file beside its audio (FMT23) and the existing
    /// copy's transcript is kept over it (`DuplicateReplacement.TranscriptOutcome.keepsExisting`).
    static let replacingKeepsAudioOverBroughtTranscriptSentence =
        "\(replacingKeepsAudioPlaces), and its transcript when the audio is the same, rather than "
        + "the transcript file found beside the new copy's audio. \(audioEditsNotKept)"

    /// What Replace Existing keeps of an audiobook when the transcript the
    /// new copy brought from a file beside its audio takes the place of the
    /// existing copy's (`DuplicateReplacement.TranscriptOutcome.broughtReplacesExisting`).
    static let replacingWithBroughtTranscriptSentence =
        "\(replacingKeepsAudioPlaces). The transcript file found beside the new copy's audio replaces "
        + "the existing copy's transcript. \(audioEditsNotKept)"

    /// What every sentence of what Replace Existing keeps of an audiobook
    /// begins with.
    private static let replacingKeepsAudioPlaces =
        "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list"

    /// What every sentence of what Replace Existing keeps of an audiobook
    /// ends with.
    private static let audioEditsNotKept = "Edits of its audio or of its manifest are not kept."

    /// What Replace Existing keeps when one copy is an audiobook and the
    /// other is not (ST04): only the book's place in the library. A place in
    /// a text means nothing in a recording, and a recording's speed nothing
    /// to a voice, so the position, the bookmarks with the notes the user
    /// wrote in them, and the settings stay behind (`DuplicateReplacement.carriedBook`),
    /// and the question says so plainly, so Keep Both can keep them. It
    /// tells the copies apart by how TextMouth reads them, never calling one
    /// "not an audiobook": a DAISY talking book, which TextMouth reads from
    /// its text, is an audiobook to its owner (ST04 verify, finding 2).
    static let replacingAcrossKindsSentence =
        "One copy is played from its recording and the other is read aloud from its text, so replacing keeps "
        + "only the existing copy's folder and place on the reading list, not its reading position, "
        + "its bookmarks and their notes, or its settings."

    /// What Replace Existing keeps of the library's copy, in the format
    /// `existing`, for a new copy in the format `new`: chosen from both
    /// kinds, never promising what `DuplicateReplacement.carriedBook` drops.
    /// For two audiobooks, `transcript` says what becomes of a transcript
    /// the new copy brought from a file beside its audio (B1).
    static func replacingKeepsSentence(
        existing: BookFormat,
        new: BookFormat,
        transcript: DuplicateReplacement.TranscriptOutcome = .asBefore
    ) -> String {
        guard existing.isAudio == new.isAudio else { return replacingAcrossKindsSentence }
        guard new.isAudio else { return replacingKeepsTextSentence }
        switch transcript {
        case .asBefore: return replacingKeepsAudioSentence
        case .keepsExisting: return replacingKeepsAudioOverBroughtTranscriptSentence
        case .broughtReplacesExisting: return replacingWithBroughtTranscriptSentence
        }
    }

    /// Where the library's copy goes once replaced. In the Trash its files
    /// can be put back, but never as a book of the library again: its
    /// record names the book the new copy now is, which no launch adopts a
    /// second time (`FileImportService.adoptOrphanedTMBPackages`), so the
    /// Trash's sentence says so rather than promise a recovery. Deleted,
    /// the files go in a removal's own words (`RemovalMode`).
    static func replacedCopySentence(movesToTrash: Bool) -> String {
        guard !movesToTrash else {
            return "The existing copy's files go to the Trash, but putting them back won't return that copy to your library."
        }
        return RemovalMode.deletePermanently.filesClause(of: "The existing copy's") + "."
    }

    /// What a duplicate's question asks: which file matches which book, the
    /// choice, what Replace Existing keeps and does not (ST04), in the words
    /// of both copies' kinds (the matching copy's is `matchingFormat`) and
    /// of where the old copy goes, and, for a copy missing chapters, what it
    /// lacks, so it never replaces a complete copy unannounced. The new copy
    /// is named by the file it came from, or by its title when it came from
    /// no file.
    private static func duplicateMessage(
        _ duplicate: ImportDecision.DuplicateBook,
        matchingTitle: String,
        matchingFormat: BookFormat,
        movesToTrash: Bool
    ) -> String {
        let newCopy = duplicate.book.sourceFilePath
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
            ?? duplicate.book.title
        let choice = "“\(newCopy)” matches “\(matchingTitle)”, which is already in your library. "
            + "Replace the existing copy, or keep both as separate books?"
        let kept = replacingKeepsSentence(
            existing: matchingFormat,
            new: duplicate.book.format,
            transcript: duplicate.transcriptOutcome
        )
        let question = choice + "\n\n" + kept + " " + replacedCopySentence(movesToTrash: movesToTrash)
        guard let warning = duplicate.warning else { return question }
        return question + "\n\nThe copy just imported is incomplete. \(warning)"
    }

    /// `text` ending a sentence: as it is when it ends in a full stop,
    /// question mark, or exclamation mark, and with a full stop otherwise.
    private static func endingSentence(_ text: String) -> String {
        guard let last = text.last, !".?!".contains(last) else { return text }
        return text + "."
    }
}

/// What the library says about the new copies of duplicates, apart from the
/// question itself (`ImportDecisionWording`): the launch's discard of a copy
/// whose question was never answered, and the refusals of an answer that
/// cannot keep a copy. Every sentence names the book, so several in a row
/// are told apart, and none names a file the listener has never seen.
enum DuplicateCopyWording {
    /// What Keep Both and Replace Existing say, keeping the question, while
    /// the library can't be reached (its drive dropped off while the question
    /// waited): "The library can't be reached right now, so TextMouth can't
    /// keep the new copy of “Atlas of Tides”. Answer again once the library
    /// is back." The copy is intact, so Cancel is not offered.
    static func libraryUnreachable(bookTitle: String) -> String {
        "The library can't be reached right now, so TextMouth can't keep the new copy of “\(bookTitle)”. "
            + "Answer again once the library is back."
    }

    /// What they say when the new copy's package is gone while its question
    /// waited (taken by the launch of another Mac sharing the library, or in
    /// Finder): "The files of the new copy of “Atlas of Tides” are no longer
    /// in the library, so it can't be kept. Choose Cancel, then import the
    /// file again." The file the copy came from, which an unanswered copy
    /// never deletes, can be imported again.
    static func copyGone(bookTitle: String) -> String {
        "The files of the new copy of “\(bookTitle)” are no longer in the library, so it can't be kept. "
            + "Choose Cancel, then import the file again."
    }

    /// What Keep Both says when the mark that the copy waits for an answer
    /// could not be taken off it: "TextMouth could not keep the new copy of
    /// “Atlas of Tides”. Choose Cancel to discard the copy, then import the
    /// file again."
    static func markerStays(bookTitle: String) -> String {
        "TextMouth could not keep the new copy of “\(bookTitle)”. "
            + "Choose Cancel to discard the copy, then import the file again."
    }

    /// What an answer says, keeping its question, while the answer to a
    /// question is being carried out off the main actor (Replace Existing of
    /// a book that takes a while to read again): no other answer acts
    /// meanwhile.
    static let answerUnderWay = "TextMouth is still carrying out your last answer. Wait until it finishes."

    /// What VoiceOver hears as Replace Existing begins for the book titled
    /// `bookTitle`, which can take a moment (a long braille book is read
    /// again in the braille file characters it was read in): the sheet's
    /// buttons are dimmed until the answer is done.
    static func replacing(bookTitle: String) -> String {
        "Replacing “\(bookTitle)”. This can take a moment."
    }

    /// Why what would rewrite the text of the book titled `bookTitle`, or
    /// replace it again, waits while Replace Existing makes the new copy
    /// ready to take its place (`LibraryViewModel.readingAgainRefusal(of:)`):
    /// a second re-read of it, Edit Text, Redo Text Extraction, a second
    /// replacement, and a reader opening it.
    static func replacingRefusal(bookTitle: String) -> String {
        "TextMouth is replacing “\(bookTitle)” with the new copy. Try again when that finishes."
    }

    /// What Replace Existing says, keeping the question, when the library's
    /// copy of the book titled `bookTitle` changed while the new copy was
    /// being made ready to take its place: what the replacement carried over
    /// would be out of date. Both copies are left as they are.
    static func changedWhileReplacing(bookTitle: String) -> String {
        "“\(bookTitle)” changed while it was being replaced, so TextMouth left both copies as they are. "
            + "Choose Replace Existing again."
    }

    /// The title of the alert that tells of copies the launch moved to the
    /// Trash.
    static let unansweredTrashedTitle = "Duplicate Copies Moved to the Trash"

    /// What the launch says once it has moved the new copies of `titles`
    /// to the Trash, because the question whether to keep each as a
    /// duplicate was never answered: "TextMouth moved the new copy of Atlas
    /// to the Trash, because the question whether to keep it as a duplicate
    /// was never answered before TextMouth closed. To get it back, open the
    /// Trash and choose Put Back." Up to three books are named; more are
    /// counted.
    static func unansweredTrashed(titles: [String]) -> String {
        let one = titles.count == 1
        let subject: String
        switch titles.count {
        case 1:
            subject = "the new copy of “\(titles[0])”"
        case 2...3:
            subject = "the new copies of \(CountWording.list(titles.map { "“\($0)”" }))"
        default:
            subject = "\(titles.count) new copies of duplicate books"
        }
        return "TextMouth moved \(subject) to the Trash, because the \(one ? "question" : "questions") "
            + "whether to keep \(one ? "it" : "them") as \(one ? "a duplicate" : "duplicates") "
            + "\(one ? "was" : "were") never answered before TextMouth closed. "
            + "To get \(one ? "it" : "them") back, open the Trash and choose Put Back."
    }
}

/// What an import tells the listener of a DAISY archive whose audio it
/// imported while the archive keeps something the book lacks.
enum DAISYArchiveWording {
    /// Said when "After Importing a Book" would have deleted the archive, or
    /// asked, and the archive was kept: "The original file was kept:
    /// TextMouth imported the audio of “Harbour Pilots” from the archive
    /// “pilots.zip”, and the archive is the only copy of its text. The
    /// archive also holds 2 other books that were not imported; unzip it to
    /// import them." The second sentence is for an archive with other books,
    /// and a talking book with no text, in an archive of other books, says
    /// "TextMouth imported only the DAISY book “Harbour Pilots” from the
    /// archive “pilots.zip”" in the first.
    static func originalKept(bookTitle: String, leftovers: DAISYArchiveLeftovers) -> String {
        let archive = "the archive “\(leftovers.archiveName)”"
        let lead = leftovers.holdsText
            ? "TextMouth imported the audio of “\(bookTitle)” from \(archive), and the archive is the only copy of its text"
            : "TextMouth imported only the DAISY book “\(bookTitle)” from \(archive)"
        var notice = "The original file was kept: \(lead)."
        let others = leftovers.otherBookCount
        if others > 0 {
            let phrase = CountWording.phrase(others, singular: "other book", plural: "other books")
            notice += " The archive also holds \(phrase) that \(others == 1 ? "was" : "were") not imported; "
                + "unzip it to import \(others == 1 ? "it" : "them")."
        }
        return notice
    }
}
