import Foundation

/// An offer to transcribe an audiobook just imported, accepted (FR05): the
/// book, and the Library window whose import asked, which opens the
/// Transcribe Audio sheet for it.
struct TranscriptionOfferAcceptance: Equatable, Sendable {
    /// The book to transcribe, by ID, as the library lists it.
    let bookID: UUID
    /// The Library window the book's import started in, which asked the
    /// question; nil when no window started it.
    let origin: ImportOrigin?
}

/// When an import offers to transcribe the book it added (FR05): after
/// importing an audiobook in a package of its own that has no transcript
/// yet, while "Offer to transcribe after importing an audiobook" is on and
/// this Mac can transcribe. The offer is asked as an import question, after
/// the import's own (`ImportDecision.Kind.transcriptionOffer`), and
/// accepting it opens the same Transcribe Audio sheet the command opens.
@MainActor
enum TranscriptionOffers {
    /// Whether an import offers to transcribe `book`, as the setting in the
    /// app's preferences store and this Mac's system decide. A book whose
    /// package holds a transcript already, as one an import gives a
    /// timed-text file found beside its audio (FMT23), is not offered: a
    /// transcription would replace that transcript. Whether it has one is a
    /// look at the package's folder, which never downloads anything
    /// (`TranscriptStore.hasTranscript(of:)`).
    static func offersTranscription(of book: Book) -> Bool {
        LibraryAudioCommand.isTranscribable(book)
            && TranscriptionPreferences.offerAfterImport.read(from: TextMouthRuntime.current.preferences)
            && !TranscriptStore.hasTranscript(of: book)
            && TranscriptionAvailability.systemSupport == .available
    }

    /// The question offering to transcribe `book`, for an import made with
    /// `request`.
    static func question(for book: Book, request: ImportRequest) -> ImportDecision {
        ImportDecision(
            kind: .transcriptionOffer(ImportDecision.TranscriptionOffer(
                bookID: book.id,
                bookTitle: book.title,
                audioSeconds: book.audioDuration
            )),
            request: request
        )
    }
}
