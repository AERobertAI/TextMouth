import Foundation

/// The words of Edit Text in Default Editor and Edit Text With… (FR05):
/// the commands, the explanation given the first time, the app chooser,
/// and what VoiceOver hears as an edit is taken or refused, each built
/// once for the screen and VoiceOver alike.
enum BookTextEditWording {
    // MARK: Commands

    /// The command that opens a book's text in the default app for Markdown.
    static var editTitle: String {
        // Translators: Menu command that opens a book's text, as a Markdown file, in the Mac's default app for Markdown files.
        InterfaceText.line("bookTextEdit.editTitle", "Edit Text in Default Editor")
    }
    /// The command that opens it in an app the user chooses.
    static var editWithTitle: String {
        // Translators: Menu command that lets the user choose an app to edit a book's text with. The ellipsis shows that a chooser follows.
        InterfaceText.line("bookTextEdit.editWithTitle", "Edit Text With…")
    }

    // MARK: The First Time

    /// The title of the explanation given the first time Edit Text is used.
    static func explanationTitle(bookTitle: String) -> String {
        // Translators: Title of the alert shown the first time Edit Text is used. %@ is the book's title.
        InterfaceText.line("bookTextEdit.explanationTitle", "Edit the Text of \(bookTitle)?")
    }

    /// What the explanation says will happen: five whole sentences, joined
    /// the way the language joins sentences.
    static var explanation: String {
        SentenceWording.joined([
            // Translators: First sentence of the Edit Text explanation. Markdown is the name of a text format.
            InterfaceText.line("bookTextEdit.explanation.markdown", "TextMouth opens the book's text in your text editor, as a Markdown file."),
            // Translators: Second sentence of the Edit Text explanation. "<!-- chapter:" is the literal text that begins a chapter line in the file; it stays exactly as written.
            InterfaceText.line("bookTextEdit.explanation.beginning", "Each line beginning with <!-- chapter: starts a chapter; keep those lines."),
            // Translators: Third sentence of the Edit Text explanation. "<!-- page: … -->" is the literal text of a page marker in the file; it stays exactly as written.
            InterfaceText.line("bookTextEdit.explanation.begins", "Each <!-- page: … --> marks where a page begins."),
            // Translators: Fourth sentence of the Edit Text explanation: what happens when the user saves the edited text.
            InterfaceText.line("bookTextEdit.explanation.updates", "When you save, the book updates and keeps your place as near as it can."),
            // Translators: Last sentence of the Edit Text explanation: it is shown only the first time.
            InterfaceText.line("common.thisExplanationAppearsOnlyOnce", "This explanation appears only once."),
        ])
    }

    /// The explanation's buttons: going on, which Return presses, and
    /// Cancel, which Escape presses.
    static var continueTitle: String {
        // Translators: Button of the Edit Text explanation alert that goes on to open the text in the editor. Return presses it.
        InterfaceText.line("common.continue", "Continue")
    }
    static var cancelTitle: String {
        // Translators: Button of the Edit Text explanation alert that stops without opening the editor. Escape presses it.
        InterfaceText.line("common.cancel", "Cancel")
    }

    // MARK: Choosing the App

    /// The app chooser's title, message, and button.
    static var appPanelTitle: String {
        // Translators: Title of the panel in which the user chooses an app to edit a book's text with.
        InterfaceText.line("bookTextEdit.appPanelTitle", "Edit Text With")
    }
    static func appPanelMessage(bookTitle: String) -> String {
        // Translators: Message of the panel in which the user chooses an app to edit a book's text with. %@ is the book's title.
        InterfaceText.line("bookTextEdit.appPanelMessage", "Choose the app to edit the text of \(bookTitle) with.")
    }
    static var appPanelPrompt: String {
        // Translators: Button of the panel in which the user chooses an app to edit a book's text with.
        InterfaceText.line("bookTextEdit.appPanelPrompt", "Edit With")
    }

    // MARK: What VoiceOver Hears

    /// An edit was taken as the book's text.
    static var updated: String {
        // Translators: Announcement after the user saved an edited text and TextMouth took it as the book's text. Written without its full stop.
        InterfaceText.line("bookTextEdit.updated", "Text updated")
    }

    /// The first edit taken in a session of a feed episode's transcript:
    /// "Text updated. This episode's transcript, with your changes, stays
    /// with the episode in its feed, …" (`TranscriptionWording`).
    static var updatedInFeed: String {
        SentenceWording.joined([
            // Translators: Announcement after the user saved an edited text of a feed episode's transcript, followed by a note about where the transcript stays.
            InterfaceText.line("bookTextEdit.updatedInFeed", "Text updated."),
            TranscriptionWording.feedEpisodeTranscriptNote,
        ])
    }

    /// A session ended because its book left the library: it was removed, or
    /// it is a feed episode whose download was deleted. The user's later
    /// saves are not taken, so they are told.
    static func stoppedBookGone(bookTitle: String) -> String {
        // Translators: Announcement when an Edit Text session ends because the book left the library. %@ is the book's title. Edit Text is a menu command.
        InterfaceText.line("bookTextEdit.stoppedBookGone", "Text not updated: \(bookTitle) was removed, or its download deleted, so Edit Text has stopped for it.")
    }

    /// A session ended because Replace Existing put a new copy in its book's
    /// place (ST04): the book keeps its ID, but the text being edited went
    /// with the old copy, so the user's later saves would never be taken.
    /// Said as the session ends, with what to do to edit the new text.
    static func stoppedBookReplaced(bookTitle: String) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the announcement when an Edit Text session ends because Replace Existing put a new copy in the book's place. %@ is the book's title. Edit Text is a menu command.
            InterfaceText.line("bookTextEdit.stoppedBookReplaced.since", "Edit Text has stopped for \(bookTitle), since a new copy replaced it."),
            // Translators: Second sentence of that announcement: what to do to edit the new copy. Edit Text is a menu command.
            InterfaceText.line("bookTextEdit.stoppedBookReplaced.choose", "Choose Edit Text again to edit the new copy's text."),
        ])
    }

    /// A session ended because the listener had its book's file read again
    /// in another encoding from Book Information (encodingchoice): the new
    /// reading replaced the text being edited, which was kept beside it.
    /// Said once the re-read is done, as the last part of what VoiceOver
    /// hears of it (`TextEncodingWording.readAgainAnnouncement`), with what
    /// to do to edit the new text.
    static func stoppedBookReadAgain(bookTitle: String) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the announcement when an Edit Text session ends because the book's file was read again in another encoding. %@ is the book's title. Edit Text is a menu command.
            InterfaceText.line("bookTextEdit.stoppedBookReadAgain.since", "Edit Text has stopped for \(bookTitle), since its file was read again."),
            // Translators: Second sentence of that announcement: what to do to edit the new text. Edit Text is a menu command.
            InterfaceText.line("bookTextEdit.stoppedBookReadAgain.choose", "Choose Edit Text again to edit the new text."),
        ])
    }

    /// Why an edit was not taken, as VoiceOver hears it once a check found
    /// it, then where the edited text was kept (`kept(_:)`), as in "Text not
    /// updated: the edited text of Harbour Pilots isn't UTF-8 text. Save it
    /// as UTF-8; the book keeps its old text until then.
    /// Your edited text was also kept as content.md.edited-20261004T123012Z,
    /// in the book's package."
    static func notTaken(_ refusal: BookTextEditRefusal, bookTitle: String, keptCopy: URL?) -> String {
        SentenceWording.joined([refused(refusal, bookTitle: bookTitle), kept(keptCopy)])
    }

    /// Why an edit was not taken: the book keeps the text it had, unless its
    /// own file changed too, which its text is read from again.
    static func refused(_ refusal: BookTextEditRefusal, bookTitle: String) -> String {
        switch refusal {
        case .notText:
            // Translators: Announcement when an edited text was refused because it is not UTF-8 text. %@ is the book's title. UTF-8 is a text encoding.
            return InterfaceText.line("bookTextEdit.refused.notText", "Text not updated: the edited text of \(bookTitle) isn't UTF-8 text. Save it as UTF-8; the book keeps its old text until then.")
        case .noChapters:
            // Translators: Announcement when an edited text was refused because no chapter has any text left. %@ is the book's title.
            return InterfaceText.line("bookTextEdit.refused.noChapters", "Text not updated: the edited text of \(bookTitle) has no chapter with any text. Undo the change and save again; the book keeps its old text until then.")
        case .nestedTooDeeply(let chapter, let limit):
            // The chapter is named by its number: its title is the book's text.
            let nests = MarkdownNestingWording.nestsTooDeeply(limit: limit)
            if let chapter {
                // Translators: Announcement when an edited text was refused because one chapter nests lists or quotes too deeply. %1$@ is the chapter's number, an identifier written without digit grouping; %2$@ is the book's title; %3$@ is a clause such as "nests more than 20 levels deep", written by another part of the app.
                return InterfaceText.line("bookTextEdit.refused.nestedTooDeeply.chapter", "Text not updated: chapter \(String(chapter)) of the edited text of \(bookTitle) \(nests), which TextMouth can't read safely. Flatten it and save again, or undo the change; the book keeps its old text until then.")
            }
            // Translators: Announcement when an edited text was refused because it nests lists or quotes too deeply. %1$@ is the book's title; %2$@ is a clause such as "nests more than 20 levels deep", written by another part of the app.
            return InterfaceText.line("bookTextEdit.refused.nestedTooDeeply.updated", "Text not updated: the edited text of \(bookTitle) \(nests), which TextMouth can't read safely. Flatten it and save again, or undo the change; the book keeps its old text until then.")
        case .sourceChanged:
            // Translators: Announcement when an edited text was not taken because the book's own file changed too. %@ is the book's title.
            return InterfaceText.line("bookTextEdit.refused.sourceChanged", "Text not updated: the original file of \(bookTitle) changed too. The book's text is read from it again the next time the book opens.")
        case .transcriptChanged:
            // Translators: Announcement when an edited text was not taken because the book's transcript changed too. %@ is the book's title.
            return InterfaceText.line("bookTextEdit.refused.transcriptChanged", "Text not updated: the transcript of \(bookTitle) changed too. The book's text is written from it again the next time the book opens.")
        case .chaptersChanged(let found, let expected):
            // Translators: Announcement when an edited transcript was refused because its number of chapters no longer matches the audiobook's. %1$@ is the book's title; %2$@ and %3$@ are counts of chapters such as "3 chapters". "<!-- chapter:" is literal text in the file and stays exactly as written.
            return InterfaceText.line("bookTextEdit.refused.chaptersChanged", "Text not updated: the edited transcript of \(bookTitle) has \(chapters(found)), but the audiobook has \(chapters(expected)). Keep every line beginning with <!-- chapter: and save again; the book keeps its old text until then.")
        case .headingChanged:
            // Translators: Announcement when an edited transcript was refused because the user changed a chapter's heading. %@ is the book's title.
            return InterfaceText.line("bookTextEdit.refused.headingChanged", "Text not updated: the edited transcript of \(bookTitle) changes a chapter's heading, which comes from its audio. Put it back and save again; the book keeps its old text until then.")
        case .wordsWithoutSentences:
            // Translators: Announcement when an edited transcript was refused because the user added words to a chapter with no speech. %@ is the book's title.
            return InterfaceText.line("bookTextEdit.refused.wordsWithoutSentences", "Text not updated: the edited transcript of \(bookTitle) adds words to a chapter with no speech, where they can't be kept. Remove them and save again; the book keeps its old text until then.")
        case .failed(let reason):
            // Translators: Announcement when an edited text could not be taken for a reason the system or another part of the app gives. %@ is the reason.
            return InterfaceText.line("bookTextEdit.refused.failed", "Text not updated: \(reason)")
        }
    }

    /// `count` chapters, in words: "1 chapter", "3 chapters".
    private static func chapters(_ count: Int) -> String {
        // Translators: A count of chapters inside a sentence about an edited transcript, such as "3 chapters". %lld is the number.
        InterfaceText.line("bookTextEdit.chapters", "\(number: count) chapters")
    }

    /// Where the edited text was kept, beside content.md: "Your edited text
    /// was also kept as content.md.edited-20261004T123012Z, in the book's
    /// package." Without a copy, nothing replaces content.md, which holds
    /// the edit, and that is said instead.
    static func kept(_ copy: URL?) -> String {
        guard let copy else {
            // Translators: Sentence saying that no backup of the user's edited text could be made. content.md is the file name of the book's text and stays as written.
            return InterfaceText.line("bookTextEdit.kept.content", "No copy of your edited text could be kept, so TextMouth leaves content.md as it is.")
        }
        // Translators: Sentence saying where a backup of the user's edited text was kept. %@ is a file name such as content.md.edited-20261004T123012Z, which stays as written.
        return InterfaceText.line("bookTextEdit.kept.package", "Your edited text was also kept as \(copy.lastPathComponent), in the book's package.")
    }

    /// What a reader shows in place of a book it does not open while the
    /// book's edited text cannot be taken (`BookTextEditPending`), as in
    /// "Harbour Pilots can't open while its edited text can't be used: it
    /// isn't UTF-8 text. Save it as UTF-8, and the book
    /// opens. Your edited text was also kept as content.md.edited-…, in the
    /// book's package." The reader opens the book once an edit is taken.
    static func held(_ refusal: BookTextEditRefusal, bookTitle: String, keptCopy: URL?) -> String {
        SentenceWording.joined([
            // Translators: First part of the message a reader shows in place of a book whose edited text can't be used. %1$@ is the book's title; %2$@ is the reason, a clause that begins in lower case and ends with its full stop.
            InterfaceText.line("bookTextEdit.held", "\(bookTitle) can't open while its edited text can't be used: \(heldReason(refusal))"),
            kept(keptCopy),
        ])
    }

    /// Why an edit cannot be used while it stands, and what the user can do
    /// about it, as the end of a sentence about the book: "it isn't UTF-8
    /// text. Save it as UTF-8, and the book opens." For an
    /// audiobook (`forAudiobook`), whose book does open, with its audio and
    /// without its text, what follows saving is that the text shows.
    static func heldReason(_ refusal: BookTextEditRefusal, forAudiobook: Bool = false) -> String {
        switch refusal {
        case .notText:
            return forAudiobook
                // Translators: Reason after a colon, for an audiobook whose edited text is not UTF-8 text; begins in lower case. UTF-8 is a text encoding.
                ? InterfaceText.line("bookTextEdit.heldReason.notText.shows", "it isn't UTF-8 text. Save it as UTF-8, and the text shows.")
                // Translators: Reason after a colon, for a book whose edited text is not UTF-8 text; begins in lower case. UTF-8 is a text encoding.
                : InterfaceText.line("bookTextEdit.heldReason.notText.opens", "it isn't UTF-8 text. Save it as UTF-8, and the book opens.")
        case .noChapters:
            return forAudiobook
                // Translators: Reason after a colon, for an audiobook whose edited text has no chapter with any text; begins in lower case.
                ? InterfaceText.line("bookTextEdit.heldReason.noChapters.shows", "it has no chapter with any text. Undo the change and save again, and the text shows.")
                // Translators: Reason after a colon, for a book whose edited text has no chapter with any text; begins in lower case.
                : InterfaceText.line("bookTextEdit.heldReason.noChapters.opens", "it has no chapter with any text. Undo the change and save again, and the book opens.")
        case .nestedTooDeeply(let chapter, let limit):
            let nests = MarkdownNestingWording.nestsTooDeeply(limit: limit)
            if let chapter {
                return forAudiobook
                    // Translators: Reason after a colon, for an audiobook whose edited text nests one chapter too deeply; begins in lower case. %1$@ is the chapter's number, an identifier written without digit grouping; %2$@ is a clause such as "nests more than 20 levels deep", written by another part of the app.
                    ? InterfaceText.line("bookTextEdit.nestedTooDeeply.chapterShows", "its chapter \(String(chapter)) \(nests), which TextMouth can't read safely. Flatten it and save again, or undo the change, and the text shows.")
                    // Translators: Reason after a colon, for a book whose edited text nests one chapter too deeply; begins in lower case. %1$@ is the chapter's number, an identifier written without digit grouping; %2$@ is a clause such as "nests more than 20 levels deep", written by another part of the app.
                    : InterfaceText.line("bookTextEdit.heldReason.nestedTooDeeply.chapter", "its chapter \(String(chapter)) \(nests), which TextMouth can't read safely. Flatten it and save again, or undo the change, and the book opens.")
            }
            return forAudiobook
                // Translators: Reason after a colon, for an audiobook whose edited text nests too deeply; begins in lower case. %@ is a clause such as "nests more than 20 levels deep", written by another part of the app.
                ? InterfaceText.line("bookTextEdit.heldReason.nestedTooDeeply.shows", "it \(nests), which TextMouth can't read safely. Flatten it and save again, or undo the change, and the text shows.")
                // Translators: Reason after a colon, for a book whose edited text nests too deeply; begins in lower case. %@ is a clause such as "nests more than 20 levels deep", written by another part of the app.
                : InterfaceText.line("bookTextEdit.heldReason.nestedTooDeeply.opens", "it \(nests), which TextMouth can't read safely. Flatten it and save again, or undo the change, and the book opens.")
        case .sourceChanged:
            // Translators: Reason after a colon: the book's own file changed after the text was edited; begins in lower case.
            return InterfaceText.line("bookTextEdit.heldReason.sourceChanged", "the book's own file changed too. Open the book again to read its text from that file.")
        case .transcriptChanged:
            // Translators: Reason after a colon: the book's transcript changed after the text was edited; begins in lower case.
            return InterfaceText.line("bookTextEdit.heldReason.transcriptChanged", "the book's transcript changed too. Open the book again to read its text from that transcript.")
        case .chaptersChanged(let found, let expected):
            // Translators: Reason after a colon: the edited transcript's number of chapters no longer matches the audiobook's; begins in lower case. %1$@ and %2$@ are counts of chapters such as "3 chapters". "<!-- chapter:" is literal text in the file and stays exactly as written.
            return InterfaceText.line("bookTextEdit.heldReason.chaptersChanged", "it has \(chapters(found)), where the audiobook has \(chapters(expected)). Keep every line beginning with <!-- chapter: and save again, and the text shows.")
        case .headingChanged:
            // Translators: Reason after a colon: the user changed a chapter's heading in an edited transcript; begins in lower case.
            return InterfaceText.line("bookTextEdit.heldReason.headingChanged", "it changes a chapter's heading, which comes from the audio. Put it back and save again, and the text shows.")
        case .wordsWithoutSentences:
            // Translators: Reason after a colon: the user added words to a chapter of a transcript that has no speech; begins in lower case.
            return InterfaceText.line("bookTextEdit.heldReason.wordsWithoutSentences", "it adds words to a chapter with no speech, where they can't be kept. Remove them and save again, and the text shows.")
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
        // Translators: Sentence saying where a backup of a book's earlier text was kept. %@ is a file name such as content.md.edited-20261024T123012Z, which stays as written.
        InterfaceText.line("bookTextEdit.earlierTextKept", "Its earlier text was kept as \(copy.lastPathComponent), in the book's package.")
    }

    /// A rebuild read the book's text from its own file again, over other
    /// text in content.md, which was kept first: "The text of Harbour Pilots
    /// was read again from its own file. The text content.md held before was
    /// kept as content.md.edited-20261004T123012Z, in the book's package."
    /// That text is most often what the user saved, but may be an earlier
    /// reading of the file, so it is not called theirs.
    static func replaced(bookTitle: String, keptCopy: URL) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the message after a book's text was read again from its own file. %@ is the book's title.
            InterfaceText.line("bookTextEdit.replaced.again", "The text of \(bookTitle) was read again from its own file."),
            // Translators: Second sentence of that message. content.md is the file name of the book's text and stays as written; %@ is the backup's file name such as content.md.edited-20261004T123012Z, which stays as written.
            InterfaceText.line("bookTextEdit.replaced.content", "The text content.md held before was kept as \(keptCopy.lastPathComponent), in the book's package."),
        ])
    }

    /// Why adding a book back to the library stopped when the text its
    /// package held differed from the text of the book's file, which the
    /// import replaces, and no copy of it could be kept: "Harbour Pilots was
    /// not added back: no copy of the text its package held could be kept
    /// first, so TextMouth left the text as it was."
    static func addBackNoCopyKept(bookTitle: String) -> String {
        // Translators: Message when adding a book back to the library stopped because no backup of the text it held could be made. %@ is the book's title.
        InterfaceText.line("bookTextEdit.addBackNoCopyKept", "\(bookTitle) was not added back: no copy of the text its package held could be kept first, so TextMouth left the text as it was.")
    }

    /// What a rebuild says when it left a book's text alone because the
    /// user changed it with Edit Text and the rebuild was automatic (B12):
    /// "TextMouth kept the text you changed in Harbour Pilots. Choose Redo
    /// Text Extraction to read the book's file again."
    static func keptOnReRead(bookTitle: String) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the message when an automatic rebuild left a book's edited text alone. %@ is the book's title.
            InterfaceText.line("bookTextEdit.keptOnReRead.changed", "TextMouth kept the text you changed in \(bookTitle)."),
            // Translators: Second sentence of that message. Redo Text Extraction is the name of a menu command.
            InterfaceText.line("bookTextEdit.keptOnReRead.extraction", "Choose Redo Text Extraction to read the book's file again."),
        ])
    }

    /// Why an edit could not be committed while the book's record could
    /// not take it.
    static var recordUnavailable: String {
        // Translators: Reason after a colon: an edit could not be saved to the library now; begins in lower case.
        InterfaceText.line("bookTextEdit.recordUnavailable", "the book's record can't be changed now. TextMouth tries again when you next save or return.")
    }

    /// Why a rebuild left a content.md that is only in the cloud alone.
    static var onlyInCloud: String {
        // Translators: Reason after a colon: a rebuild left the book's text file alone because it is only in the cloud. content.md is a file name and stays as written.
        InterfaceText.line("bookTextEdit.onlyInCloud", "content.md is only in the cloud, so TextMouth leaves it as it is.")
    }

    /// Why a rebuild left content.md alone when no copy of the text it would
    /// replace could be kept.
    static var noCopyKept: String {
        // Translators: Reason after a colon: a rebuild left the book's text alone because no backup could be made; begins in lower case. content.md is a file name and stays as written.
        InterfaceText.line("bookTextEdit.noCopyKept", "no copy of the edited text could be kept, so TextMouth leaves content.md as it is.")
    }

    /// Why a rebuild left alone a save no check had read yet; the check that
    /// reads it follows.
    static var notReadYet: String {
        // Translators: Reason after a colon: a rebuild left the book's text alone because the latest save of the edited text is not read yet.
        InterfaceText.line("bookTextEdit.notReadYet", "TextMouth hasn't read the latest save yet.")
    }

    /// Why Edit Text could not begin for the book `bookTitle`.
    static func cannotBegin(_ failure: BookTextEditStartFailure, bookTitle: String) -> String {
        switch failure {
        case .inCloud:
            return LibraryCloudWording.notDownloaded(titles: [bookTitle])
        case .missing:
            return SentenceWording.joined([
                // Translators: First sentence of the message when Edit Text finds the book's text file missing. %@ is the book's title.
                InterfaceText.line("bookTextEdit.cannotBegin.missing.ready", "The text of \(bookTitle) isn't ready to edit yet."),
                // Translators: Second sentence of that message: opening the book makes its text ready.
                InterfaceText.line("bookTextEdit.cannotBegin.missing.again", "Open the book once, then try again."),
            ])
        case .unreadable:
            // Translators: Message when Edit Text finds the book's text file unreadable. %@ is the book's title.
            return InterfaceText.line("bookTextEdit.cannotBegin.unreadable", "The text of \(bookTitle) can't be read, so it can't be edited.")
        }
    }

    /// An audiobook without a transcript has no text to edit (FR05).
    static func noText(bookTitle: String) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the message when Edit Text is chosen for an audiobook with no transcript. %@ is the book's title.
            InterfaceText.line("bookTextEdit.noText.audiobook", "\(bookTitle) is an audiobook without a transcript, so it has no text to edit."),
            // Translators: Second sentence of that message. Transcribe Audio is the name of a menu command.
            InterfaceText.line("bookTextEdit.noText.transcribe", "Transcribe it first, with Transcribe Audio."),
        ])
    }

    /// Why a transcript no longer fits its audiobook, as the end of a
    /// sentence (FR05).
    static var transcriptStaleReason: String {
        // Translators: Reason after a colon: an audiobook's audio changed after it was transcribed, so its transcript no longer fits; begins in lower case.
        InterfaceText.line("bookTextEdit.transcriptStaleReason", "the audiobook's audio changed since it was transcribed, so its transcript no longer fits it.")
    }

    /// Why a transcribed audiobook's edit was not taken while its audio is
    /// not the audio transcribed any more (FR05).
    static var transcriptStale: String {
        SentenceWording.joined([
            transcriptStaleReason,
            // Translators: Sentence after the reason that an audiobook's transcript no longer fits its audio: what to do.
            InterfaceText.line("bookTextEdit.transcriptStale", "Transcribe it again, then edit the new transcript."),
        ])
    }

    /// Why a transcribed audiobook's edit was not taken while its
    /// transcript cannot be read (FR05).
    static var transcriptUnavailable: String {
        // Translators: Reason after a colon: an audiobook's transcript can't be read, so an edit can't be taken into it; begins in lower case.
        InterfaceText.line("bookTextEdit.transcriptUnavailable", "the audiobook's transcript can't be read now, so the edit can't be taken into it.")
    }

    /// Why a transcribed audiobook's edit could not be laid over its audio
    /// (FR05).
    static var transcriptUnindexable: String {
        // Translators: Reason after a colon: an edited transcript could not be matched to the audiobook's audio; begins in lower case.
        InterfaceText.line("bookTextEdit.transcriptUnindexable", "the edited transcript can't be laid over the audiobook's audio.")
    }

    /// The editor could not be opened, with why.
    static func openFailed(bookTitle: String, reason: String) -> String {
        // Translators: Message when the app that edits a book's text could not be opened. %1$@ is the book's title; %2$@ is the reason from the system.
        InterfaceText.line("bookTextEdit.openFailed", "Couldn't open the text of \(bookTitle): \(reason)")
    }
}
