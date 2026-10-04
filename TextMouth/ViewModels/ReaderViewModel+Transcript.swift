import Foundation

// MARK: - Transcript Text (FR05)

/// A change of an audiobook's transcript text that arrived while its reader
/// was still loading, kept until loading ends.
struct TranscriptTextChange: Sendable {
    /// The text to show, or nil once the book has none.
    let text: TranscriptText?
}

/// How an open audiobook's reader follows its transcript: transcribed,
/// transcribed again, edited in the user's editor, or deleted.
///
/// The library sends the transcript text through the readers' usual updates
/// (`LibraryBookEvent.transcriptReplaced`) once it is saved in the book's
/// package. The reader shows it in place of the text it had, at the
/// sentence heard where the cursor stands; its audio plays on, and its
/// cursor, position, and bookmarks are untouched, since they count time,
/// which a transcript does not change.
extension ReaderViewModel {

    /// Shows `text` as this audiobook's transcript text, or none when nil.
    /// A reader still loading keeps it until loading ends, since what it
    /// loads may be the text from before.
    func showTranscript(_ text: TranscriptText?) {
        guard !hasClosed, isAudioBook else { return }
        guard !isLoading, content != nil else {
            transcriptWaitingForLoad = TranscriptTextChange(text: text)
            return
        }
        content?.transcript = text
        refreshPlaybackUI(forceVisibleTextRefresh: true)
    }

    /// Shows the transcript text that changed while this reader loaded, if
    /// any: called as loading ends.
    func showTranscriptWaitingForLoad() {
        guard let change = transcriptWaitingForLoad else { return }
        transcriptWaitingForLoad = nil
        showTranscript(change.text)
    }
}
