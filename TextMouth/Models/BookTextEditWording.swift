import Foundation

/// The words of Edit Text in Default Editor and Edit Text With… (FR05):
/// the commands, the explanation given the first time, the app chooser,
/// and what VoiceOver hears as an edit is taken or refused, each built
/// once for the screen and VoiceOver alike.
enum BookTextEditWording {
    // MARK: Commands

    /// The command that opens a book's text in the default app for Markdown.
    static let editTitle = "Edit Text in Default Editor"
    /// The command that opens it in an app the user chooses.
    static let editWithTitle = "Edit Text With…"

    // MARK: The First Time

    /// The title of the explanation given the first time Edit Text is used.
    static func explanationTitle(bookTitle: String) -> String {
        "Edit the Text of \(bookTitle)?"
    }

    /// What the explanation says will happen.
    static let explanation = "TextMouth opens the book's text in your text editor, as a Markdown file. "
        + "Each line beginning with <!-- chapter: starts a chapter; keep those lines. "
        + "Each <!-- page: … --> marks where a page begins. "
        + "When you save, TextMouth reads your changes and updates the book, keeping your place as near as it can. "
        + "This explanation appears only once."

    /// The explanation's buttons: going on, which Return presses, and
    /// Cancel, which Escape presses.
    static let continueTitle = "Continue"
    static let cancelTitle = "Cancel"

    // MARK: Choosing the App

    /// The app chooser's title, message, and button.
    static let appPanelTitle = "Edit Text With"
    static func appPanelMessage(bookTitle: String) -> String {
        "Choose the app to edit the text of \(bookTitle) with."
    }
    static let appPanelPrompt = "Edit With"

    // MARK: What VoiceOver Hears

    /// An edit was taken as the book's text.
    static let updated = "Text updated"

    /// The first edit taken in a session of a feed episode's transcript:
    /// "Text updated. This episode's transcript, with your changes, stays
    /// with the episode in its feed, …" (`TranscriptionWording`).
    static let updatedInFeed = updated + ". " + TranscriptionWording.feedEpisodeTranscriptNote

    /// A session ended because its book left the library: it was removed, or
    /// it is a feed episode whose download was deleted. The user's later
    /// saves are not taken, so they are told.
    static func stoppedBookGone(bookTitle: String) -> String {
        "Text not updated: \(bookTitle) was removed, or its download deleted, so Edit Text has stopped for it."
    }

    /// A session ended because Replace Existing put a new copy in its book's
    /// place (ST04): the book keeps its ID, but the text being edited went
    /// with the old copy, so the user's later saves would never be taken.
    /// Said as the session ends, with what to do to edit the new text.
    static func stoppedBookReplaced(bookTitle: String) -> String {
        "Edit Text has stopped for \(bookTitle), since a new copy replaced it. "
            + "Choose Edit Text again to edit the new copy's text."
    }

    /// A session ended because the listener had its book's file read again
    /// in another encoding from Book Information (encodingchoice): the new
    /// reading replaced the text being edited, which was kept beside it.
    /// Said once the re-read is done, as the last part of what VoiceOver
    /// hears of it (`TextEncodingWording.readAgainAnnouncement`), with what
    /// to do to edit the new text.
    static func stoppedBookReadAgain(bookTitle: String) -> String {
        "Edit Text has stopped for \(bookTitle), since its file was read again. "
            + "Choose Edit Text again to edit the new text."
    }

    /// Why an edit was not taken, as VoiceOver hears it once a check found
    /// it, then where the edited text was kept (`kept(_:)`), as in "Text not
    /// updated: the edited text of Harbour Pilots isn't UTF-8 text. Save it
    /// as UTF-8 in your editor; until then, the book keeps the text it had.
    /// Your edited text was also kept as content.md.edited-20261004T123012Z,
    /// in the book's package."
    static func notTaken(_ refusal: BookTextEditRefusal, bookTitle: String, keptCopy: URL?) -> String {
        "\(refused(refusal, bookTitle: bookTitle)) \(kept(keptCopy))"
    }

    /// Why an edit was not taken: the book keeps the text it had, unless its
    /// own file changed too, which its text is read from again.
    static func refused(_ refusal: BookTextEditRefusal, bookTitle: String) -> String {
        switch refusal {
        case .notText:
            return "Text not updated: the edited text of \(bookTitle) isn't UTF-8 text. "
                + "Save it as UTF-8 in your editor; until then, the book keeps the text it had."
        case .noChapters:
            return "Text not updated: the edited text of \(bookTitle) has no chapter left with anything in it. "
                + "Undo the change in your editor and save again; until then, the book keeps the text it had."
        case .sourceChanged:
            return "Text not updated: the original file of \(bookTitle) changed too, "
                + "so TextMouth reads the book's text from that file again the next time the book opens."
        case .transcriptChanged:
            return "Text not updated: the transcript of \(bookTitle) changed too, as when it is transcribed again, "
                + "so TextMouth writes the book's text from that transcript again the next time the book opens."
        case .chaptersChanged(let found, let expected):
            return "Text not updated: the edited transcript of \(bookTitle) has \(chapters(found)), "
                + "but the audiobook has \(chapters(expected)). Keep every line beginning with <!-- chapter: "
                + "and save again; until then, the book keeps the text it had."
        case .headingChanged:
            return "Text not updated: the edited transcript of \(bookTitle) changes a chapter's heading, which comes from its audio. "
                + "Put the heading back as it was and save again; until then, the book keeps the text it had."
        case .wordsWithoutSentences:
            return "Text not updated: the edited transcript of \(bookTitle) adds words to a chapter the transcript heard no speech in, "
                + "where they can't be kept. Remove them and save again; until then, the book keeps the text it had."
        case .failed(let reason):
            return "Text not updated: \(reason)"
        }
    }

    /// `count` chapters, in words: "1 chapter", "3 chapters".
    private static func chapters(_ count: Int) -> String {
        CountWording.phrase(count, singular: "chapter", plural: "chapters")
    }

    /// Where the edited text was kept, beside content.md: "Your edited text
    /// was also kept as content.md.edited-20261004T123012Z, in the book's
    /// package." Without a copy, nothing replaces content.md, which holds
    /// the edit, and that is said instead.
    static func kept(_ copy: URL?) -> String {
        guard let copy else {
            return "No copy of your edited text could be kept, so TextMouth leaves content.md as it is."
        }
        return "Your edited text was also kept as \(copy.lastPathComponent), in the book's package."
    }

    /// What a reader shows in place of a book it does not open while the
    /// book's edited text cannot be taken (`BookTextEditPending`), as in
    /// "Harbour Pilots can't open while its edited text can't be used: it
    /// isn't UTF-8 text. Save it as UTF-8 in your editor, and the book
    /// opens. Your edited text was also kept as content.md.edited-…, in the
    /// book's package." The reader opens the book once an edit is taken.
    static func held(_ refusal: BookTextEditRefusal, bookTitle: String, keptCopy: URL?) -> String {
        "\(bookTitle) can't open while its edited text can't be used: \(heldReason(refusal)) \(kept(keptCopy))"
    }

    /// Why an edit cannot be used while it stands, and what the user can do
    /// about it, as the end of a sentence about the book: "it isn't UTF-8
    /// text. Save it as UTF-8 in your editor, and the book opens." For an
    /// audiobook (`forAudiobook`), whose book does open, with its audio and
    /// without its text, what follows saving is that the text shows.
    static func heldReason(_ refusal: BookTextEditRefusal, forAudiobook: Bool = false) -> String {
        let outcome = forAudiobook ? "the text shows" : "the book opens"
        switch refusal {
        case .notText:
            return "it isn't UTF-8 text. Save it as UTF-8 in your editor, and \(outcome)."
        case .noChapters:
            return "it has no chapter left with anything in it. Undo the change in your editor and save again, "
                + "and \(outcome)."
        case .sourceChanged:
            return "the book's own file changed too. Open the book again to read its text from that file."
        case .transcriptChanged:
            return "the book's transcript changed too. Open the book again to read its text from that transcript."
        case .chaptersChanged(let found, let expected):
            return "it has \(chapters(found)), where the audiobook has \(chapters(expected)). "
                + "Keep every line beginning with <!-- chapter: and save again, and the text shows."
        case .headingChanged:
            return "it changes a chapter's heading, which comes from the audio. Put the heading back as it was and save again, "
                + "and the text shows."
        case .wordsWithoutSentences:
            return "it adds words to a chapter the transcript heard no speech in, where they can't be kept. "
                + "Remove them and save again, and the text shows."
        case .failed(let reason):
            return reason
        }
    }

    /// Where the text a replacement or a re-read replaced was kept, beside
    /// the new text, named as Edit Text names the copies it keeps: "Its
    /// earlier text was kept as content.md.edited-20261024T123012Z, in the
    /// book's package." Replace Existing (ST04) and a re-read in another
    /// encoding (encodingchoice) both say it from here.
    static func earlierTextKept(_ copy: URL) -> String {
        "Its earlier text was kept as \(copy.lastPathComponent), in the book's package."
    }

    /// A rebuild read the book's text from its own file again, over other
    /// text in content.md, which was kept first: "The text of Harbour Pilots
    /// was read again from its own file. The text content.md held before was
    /// kept as content.md.edited-20261004T123012Z, in the book's package."
    /// That text is most often what the user saved, but may be an earlier
    /// reading of the file, so it is not called theirs.
    static func replaced(bookTitle: String, keptCopy: URL) -> String {
        "The text of \(bookTitle) was read again from its own file. "
            + "The text content.md held before was kept as \(keptCopy.lastPathComponent), in the book's package."
    }

    /// What a rebuild says when it left a book's text alone because the
    /// user changed it with Edit Text and the rebuild was automatic (B12):
    /// "TextMouth kept the text you changed in Harbour Pilots. Choose Redo
    /// Text Extraction to read the book's file again."
    static func keptOnReRead(bookTitle: String) -> String {
        "TextMouth kept the text you changed in \(bookTitle). Choose Redo Text Extraction to read the book's file again."
    }

    /// Why an edit could not be committed while the book's record could
    /// not take it.
    static let recordUnavailable = "the book's record can't be changed now. "
        + "TextMouth tries again the next time you save or come back to TextMouth."

    /// Why a rebuild left a content.md that is only in the cloud alone.
    static let onlyInCloud = "content.md is only in the cloud, so TextMouth leaves it as it is."

    /// Why a rebuild left content.md alone when no copy of the text it would
    /// replace could be kept.
    static let noCopyKept = "no copy of the edited text could be kept, so TextMouth leaves content.md as it is."

    /// Why a rebuild left alone a save no check had read yet; the check that
    /// reads it follows.
    static let notReadYet = "TextMouth hasn't read the latest save yet."

    /// Why Edit Text could not begin for the book `bookTitle`.
    static func cannotBegin(_ failure: BookTextEditStartFailure, bookTitle: String) -> String {
        switch failure {
        case .inCloud:
            return LibraryCloudWording.notDownloaded(titles: [bookTitle])
        case .missing:
            return "The text of \(bookTitle) isn't ready to edit yet. Open the book once, then try again."
        case .unreadable:
            return "The text of \(bookTitle) can't be read, so it can't be edited."
        }
    }

    /// An audiobook without a transcript has no text to edit (FR05).
    static func noText(bookTitle: String) -> String {
        "\(bookTitle) is an audiobook without a transcript, so it has no text to edit. "
            + "Transcribe it first, with Transcribe Audio."
    }

    /// Why a transcript no longer fits its audiobook, as the end of a
    /// sentence (FR05).
    static let transcriptStaleReason = "the audiobook's audio changed since it was transcribed, "
        + "so its transcript no longer fits it."

    /// Why a transcribed audiobook's edit was not taken while its audio is
    /// not the audio transcribed any more (FR05).
    static let transcriptStale = transcriptStaleReason + " Transcribe it again, then edit the new transcript."

    /// Why a transcribed audiobook's edit was not taken while its
    /// transcript cannot be read (FR05).
    static let transcriptUnavailable = "the audiobook's transcript can't be read now, so the edit can't be taken into it."

    /// Why a transcribed audiobook's edit could not be laid over its audio
    /// (FR05).
    static let transcriptUnindexable = "the edited transcript can't be laid over the audiobook's audio."

    /// The editor could not be opened, with why.
    static func openFailed(bookTitle: String, reason: String) -> String {
        "Couldn't open the text of \(bookTitle): \(reason)"
    }
}
