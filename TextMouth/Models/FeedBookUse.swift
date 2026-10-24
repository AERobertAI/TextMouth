import Foundation

// MARK: - A Feed Download in Use

/// How a feed item's download is in use now (REV11 F1; the feed follow-ups
/// after FR14, item 1): open in a reader, being transcribed, or being
/// exported. The engine's own rules leave a download in use for their next
/// pass; the listener's own deletions (Delete Download, the library's
/// Remove, Delete Episode…, and Delete Feed…) refuse it, saying why, since
/// the work under way reads the file and would lose what it makes with it:
/// a transcript is saved into the package only once all its audio has been
/// heard, which can take many minutes.
///
/// The listener's deletions refuse rather than wait, as the rules do: each
/// is asked for now, by someone who hears what it did, and a deletion that
/// went on minutes later, unannounced, could take a download the listener
/// had since decided to keep. A refusal says what to do instead.
///
/// A download whose text is being edited with Edit Text is not one of these
/// uses: the rules also leave it for their next pass
/// (`LibraryViewModel.feedBooksInUse`), but the listener's deletions go
/// ahead, since an editing session ends only when TextMouth quits and a
/// refusal would stand until then. Its transcript stays in the package when
/// the download goes, and a save made after it went is kept when the episode
/// is downloaded again.
enum FeedBookUse: Equatable, Sendable {
    /// The download is open in a reader, which covers one playing.
    case openInReader
    /// The download is being transcribed (`TranscribedBooks.transcribingBookID`),
    /// from the start of the transcription until its transcript is saved.
    case transcribing
    /// An export is reading the download (`BookExportModel.booksBeingExported`).
    case exporting

    /// What the download is doing, as a sentence goes on after its subject:
    /// "is being transcribed, and deleting its download now would lose the
    /// transcript".
    var clause: String {
        clause(doing: Self.deletingItsDownload)
    }

    /// What the book is doing, as a sentence goes on after its subject, with
    /// what doing `action` now would cost where it would cost something:
    /// "is being transcribed, and replacing it now would lose the
    /// transcript". Replace Existing (ST04) waits for the same uses a
    /// download's deletion refuses, and names its own action.
    func clause(doing action: String) -> String {
        switch self {
        case .openInReader:
            return "is open in a reader"
        case .transcribing:
            return "is being transcribed, and \(action) now would lose the transcript"
        case .exporting:
            return "is being exported, and \(action) now would stop the export"
        }
    }

    /// The action a deletion of a download names in its clause.
    static let deletingItsDownload = "deleting its download"

    /// What the listener can do before trying again: "Close it", or "Wait
    /// until the transcription ends, or cancel it".
    var remedy: String {
        switch self {
        case .openInReader:
            return "Close it"
        case .transcribing:
            return "Wait until the transcription ends, or cancel it"
        case .exporting:
            return "Wait until the export ends"
        }
    }

    /// The refusal of a deletion of the download `subject` names, which ends
    /// with `retry`, what to do once the remedy is done: "“Ep. 368” is being
    /// transcribed, and deleting its download now would lose the transcript.
    /// Wait until the transcription ends, or cancel it, then try again."
    func refusal(of subject: String, retry: String = FeedBookUse.tryAgain) -> String {
        refusal(of: subject, doing: Self.deletingItsDownload, retry: retry)
    }

    /// The refusal of `action`, done to the book `subject` names, which ends
    /// with `retry`: "“Moby-Dick” is being transcribed, and replacing it now
    /// would lose the transcript. Wait until the transcription ends, or
    /// cancel it, then choose Replace Existing again."
    func refusal(of subject: String, doing action: String, retry: String) -> String {
        "\(subject) \(clause(doing: action)). \(remedy), then \(retry)."
    }

    /// The end of a refusal whose command is not named again.
    static let tryAgain = "try again"
}

/// The listener's own deletion of a feed item's download refused while the
/// download is in use (`FeedBookUse`): nothing was deleted. Its description
/// names the download as "It", as the library's list of the books a removal
/// left names each by its title first ("Ep. 368: It is open in a reader.
/// Close it, then try again."); an alert of its own names the title
/// (`sentence`).
struct FeedDownloadInUseError: LocalizedError, Equatable, Sendable {
    /// The download's title.
    let title: String
    /// How it is in use.
    let use: FeedBookUse

    /// The refusal as a sentence of its own, naming the download: "“Ep. 368”
    /// is open in a reader. Close it, then try again."
    var sentence: String {
        use.refusal(of: "“\(title)”")
    }

    var errorDescription: String? {
        use.refusal(of: "It")
    }
}
