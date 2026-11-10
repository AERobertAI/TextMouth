import Foundation

/// The words of transcription (FR05): the commands, the Transcribe Audio
/// sheet, and what VoiceOver hears as a transcription ends, each built once
/// for the screen and VoiceOver alike.
enum TranscriptionWording {
    // MARK: Commands

    /// The command that opens the Transcribe Audio sheet for an audiobook,
    /// in the library's context menu and VoiceOver actions and the reader's
    /// Book menu.
    static let transcribeCommandTitle = "Transcribe Audio…"
    /// The same command once the book has a transcript: it transcribes the
    /// audio again, replacing the transcript, so it is named for that.
    static let retranscribeCommandTitle = "Retranscribe Audio…"
    /// The title of the command that opens the Transcribe Audio sheet for a
    /// book that has a transcript when `hasTranscript`, and for one that has
    /// none otherwise: Retranscribe Audio… or Transcribe Audio….
    static func transcribeCommandTitle(hasTranscript: Bool) -> String {
        hasTranscript ? retranscribeCommandTitle : transcribeCommandTitle
    }
    /// The command that deletes a transcribed audiobook's transcript, in the
    /// same places, after a confirmation naming the book.
    static let deleteCommandTitle = "Delete Transcript…"

    /// What a feed episode's transcript's listener is told as they edit or
    /// clean it up: it stays with the episode, not with its download.
    static let feedEpisodeTranscriptNote = "This episode's transcript, with your changes, stays with the episode "
        + "in its feed, even after its download is deleted. Deleting the episode or the feed deletes it; "
        + "Move to Library keeps it with the episode as a book."

    // MARK: Refusals

    /// Why the command was refused for several books at once: transcription
    /// works on one book at a time.
    static let oneBookAtATime = "Transcription works on one audiobook at a time. "
        + "Select one audiobook, then choose Transcribe Audio again."

    /// Why the command was refused for a book that is not an audiobook.
    static func notAnAudiobook(bookTitle: String) -> String {
        "\(bookTitle) isn't an audiobook. Only an audiobook's audio can be transcribed."
    }

    // MARK: The Sheet

    /// The sheet's heading before a transcription: "Transcribe Moby-Dick".
    static func sheetTitle(bookTitle: String) -> String {
        "Transcribe \(bookTitle)"
    }

    /// The sheet's heading before a book that has a transcript is transcribed
    /// again: "Retranscribe Moby-Dick".
    static func retranscribeSheetTitle(bookTitle: String) -> String {
        "Retranscribe \(bookTitle)"
    }

    /// The sheet's heading while it explains why it cannot transcribe, as
    /// on a system older than macOS 26, or for several books at once.
    static let unavailableTitle = "Transcribe Audio"

    /// The sheet's heading while the book is being transcribed:
    /// "Transcribing Moby-Dick".
    static func progressTitle(bookTitle: String) -> String {
        "Transcribing \(bookTitle)"
    }

    /// The book's audio length, as the sheet shows and speaks it: "Audio:
    /// 6 hours, 12 minutes, 4 seconds." or, before the book's length is
    /// known, "Audio: length not known yet."
    static func audioLength(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "Audio: length not known yet." }
        return "Audio: \(TimeFormatting.spoken(seconds))."
    }

    /// How long the transcription should take, as the sheet shows and speaks
    /// it: "Time to transcribe: about 6 minutes." (`TranscriptionEstimate`).
    static func estimateLine(forAudio seconds: TimeInterval?) -> String {
        guard let words = TranscriptionEstimate.words(forAudio: seconds) else {
            return "Time to transcribe: not known until the audio's length is."
        }
        return "Time to transcribe: \(words)."
    }

    /// What the sheet says while it checks the language's speech model.
    static let checking = "Checking the speech model…"

    /// The language line: "Language: English (United States), installed."
    static func languageLine(name: String, status: String) -> String {
        "Language: \(name), \(status)."
    }

    /// How the language line words a model's status.
    static let modelInstalled = "installed"
    static let modelNeedsDownload = "needs download"
    static let modelDownloading = "downloading"
    static let modelUnsupported = "not supported"

    /// The name a language's model download goes by: the language without
    /// its region, as one model serves every region ("English").
    static func modelLanguageName(of identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return Locale.current.localizedString(forLanguageCode: code) ?? identifier
    }

    /// The approximate size of one language's speech model: the system's
    /// asset catalog lists about 140 MB (TRANSCRIPTION-RESEARCH-2026-10-03.md),
    /// and the download's progress gives no size before it starts.
    static let modelSize = "about 140 MB"

    /// The button that downloads a language's model: "Download the English
    /// model, about 140 MB". Nothing downloads without this press.
    static func downloadTitle(languageName: String) -> String {
        "Download the \(languageName) model, \(modelSize)"
    }

    /// What the download button does.
    static let downloadHint = "Downloads the speech model from Apple. macOS keeps it and shares it with other apps. "
        + "Nothing else is downloaded, and the book's audio never leaves this Mac."

    /// The download's progress, shown and spoken: "Downloading the English
    /// model: 40 percent." or, before its size is known, "Downloading the
    /// English model…".
    static func downloading(languageName: String, fraction: Double?) -> String {
        guard let fraction else { return "Downloading the \(languageName) model…" }
        return "Downloading the \(languageName) model: \(percent(fraction)) percent."
    }

    /// The button that stops a download, and what it does.
    static let cancelDownloadTitle = "Cancel Download"
    static let cancelDownloadHint = "Stops the download. Nothing is installed."

    /// What VoiceOver hears when a model has downloaded.
    static func downloaded(languageName: String) -> String {
        "The \(languageName) model is downloaded. The book can be transcribed now."
    }

    /// What VoiceOver hears, and the sheet shows, when a download stopped.
    static func downloadCancelled(languageName: String) -> String {
        "The \(languageName) model's download was cancelled."
    }

    /// Why a download failed, shown and spoken.
    static func downloadFailed(languageName: String, reason: String) -> String {
        "The \(languageName) model couldn't be downloaded: \(reason)"
    }

    /// The line naming the transcript a book has already, which
    /// transcribing again replaces: "Transcribed on October 4, 2026, in
    /// English (United States). Transcribing again replaces this
    /// transcript."
    static func alreadyTranscribed(on date: Date, languageName: String) -> String {
        "\(transcribedOn(date, languageName: languageName)) \(transcribingAgainReplaces)"
    }

    /// The sentence saying when and in which language recognition made a
    /// transcript: "Transcribed on October 4, 2026, in English (United
    /// States)." The sheet's line and Book Information's both begin with it.
    private static func transcribedOn(_ date: Date, languageName: String) -> String {
        "Transcribed on \(day(date)), in \(languageName)."
    }

    /// The line naming a transcript the book has from outside TextMouth's
    /// recognizer (FMT23, FMT25), which transcribing again replaces: one
    /// sentence of where it came from and when, as in "Attached from
    /// “lecture.vtt” on October 30, 2026. Transcribing again replaces this
    /// transcript."
    static func outsideTranscript(_ source: TranscriptSource, on date: Date) -> String {
        "\(cameFrom(source, on: day(date))) \(transcribingAgainReplaces)"
    }

    /// What each line naming the book's transcript ends with.
    private static let transcribingAgainReplaces = "Transcribing again replaces this transcript."

    /// Where a transcript from outside came from, as one sentence ending with
    /// `day`, the day the book was given it: attached from a file, named
    /// when one file was read and otherwise by its format; found when the
    /// book was imported; or the podcast's own. An origin a later TextMouth
    /// wrote, which this one cannot name, is said only to be attached.
    private static func cameFrom(_ source: TranscriptSource, on day: String) -> String {
        let quotedName = source.fileName.map { "“\($0)”" }
        let formatName = source.knownFormat?.name
        // Every format the files were of, said together: "WebVTT and
        // SubRip", when this TextMouth knows them all.
        let formatNames = source.knownFormats?.map(\.name).joined(separator: " and ")
        switch source.knownOrigin {
        case .attached:
            if let quotedName { return "Attached from \(quotedName) on \(day)." }
            if let formatName { return "Attached from a \(formatName) file on \(day)." }
            return "Attached from a file on \(day)."
        case .imported:
            // One file by its name; several by their formats, when known.
            let files = quotedName ?? formatNames.map { "\($0) files" } ?? "files"
            return "Attached from \(files) when the book was imported, on \(day)."
        case .podcast:
            return "The podcast's own transcript, downloaded with the episode on \(day)."
        case nil:
            return "Attached on \(day)."
        }
    }

    /// The line warning that transcribing again replaces the user's own
    /// edits: "You edited this transcript on October 5, 2026. Transcribing
    /// again replaces your edits."
    static func editedTranscript(on date: Date) -> String {
        "You edited this transcript on \(day(date)). Transcribing again replaces your edits."
    }

    /// The line warning that transcribing again replaces the user's cleanup
    /// of the transcript: "You cleaned up this transcript on October 5,
    /// 2026. Transcribing again replaces the cleanup."
    static func cleanedUpTranscript(on date: Date) -> String {
        "You cleaned up this transcript on \(day(date)). Transcribing again replaces the cleanup."
    }

    /// The line for a book whose transcript, transcript.json, is only in
    /// iCloud, which this Mac did not read: it cannot be seen, or its edits
    /// and cleanup told of, so the sheet offers no Retranscribe until the
    /// book is downloaded. In the words of `textInCloud`, which says the same
    /// of the transcript's text.
    static let transcriptInCloud = "The book's transcript is only in iCloud, so TextMouth leaves it as it is. "
        + "Download the book, then try again."

    /// The line for a book whose text, content.md, is only in iCloud: a
    /// transcription is saved over that text, which TextMouth never does
    /// while the file is not on this Mac, so the sheet offers no Retranscribe
    /// until the book is downloaded, rather than refuse the finished
    /// transcript after the audio was transcribed. Also what a refused
    /// install says (`TranscriptTextError.textOnlyInCloud`).
    static let textInCloud = "The book's text is only in iCloud, so TextMouth leaves it as it is. "
        + "Download the book, then try again."

    /// The line for a transcript written in a layout this TextMouth does
    /// not read.
    static let transcriptFromLaterVersion = "\(laterVersionSentence) Transcribing again replaces it."

    /// The sentence saying a book's transcript is a later TextMouth's, which
    /// the sheet's line and Book Information's both begin with.
    private static let laterVersionSentence = "This book has a transcript made by a later version of TextMouth."

    /// The line saying another book is being transcribed, which keeps
    /// Transcribe unavailable until it finishes.
    static func busy(bookTitle: String) -> String {
        TranscriptionError.busy(bookTitle).errorDescription ?? bookTitle
    }

    /// The sheet's buttons.
    static let transcribeTitle = "Transcribe"
    /// The button of a book that has a transcript already: "Retranscribe".
    static let transcribeAgainTitle = "Retranscribe"
    static let cancelTitle = "Cancel"
    static let closeTitle = "Close"
    static let okTitle = "OK"

    /// What Transcribe does.
    static let transcribeHint = "Transcribes the book's audio on this Mac, so VoiceOver and the braille display "
        + "can read the narration as text."
    /// What Retranscribe does.
    static let transcribeAgainHint = "Transcribes the book's audio again, replacing its transcript."
    /// What Cancel does before a transcription.
    static let cancelHint = "Closes this without transcribing."

    /// What VoiceOver hears as the sheet appears, after its focus lands:
    /// its lines in one go, the heading first.
    static func sheetAnnouncement(lines: [String]) -> String {
        lines.joined(separator: " ")
    }

    // MARK: Progress

    /// Which file is being transcribed: "File 3 of 12", or, once every file
    /// is done, "All 12 files".
    static func fileLine(_ progress: TranscriptionProgress) -> String {
        guard progress.fileIndex < progress.fileCount else {
            return "All \(CountWording.phrase(progress.fileCount, singular: "file", plural: "files"))"
        }
        return "File \(progress.fileIndex + 1) of \(progress.fileCount)"
    }

    /// How much of the audio is done: "40 minutes of 6 hours, 12 minutes
    /// transcribed".
    static func secondsLine(_ progress: TranscriptionProgress) -> String {
        "\(TimeFormatting.spoken(progress.secondsDone)) of \(TimeFormatting.spoken(progress.secondsTotal)) transcribed"
    }

    /// How long the transcription has run: "Elapsed: 12 seconds".
    static func elapsedLine(_ seconds: TimeInterval) -> String {
        "Elapsed: \(TimeFormatting.spoken(seconds))"
    }

    /// What the sheet says before the first file has begun, while the
    /// system loads its speech model.
    static let starting = "Starting…"

    /// The progress bar's label.
    static let progressLabel = "Transcription progress"

    /// The progress bar's value, which VoiceOver reads: "40 percent, file 3
    /// of 12", or "Starting" before the first file has begun.
    static func progressValue(_ progress: TranscriptionProgress?) -> String {
        guard let progress else { return "Starting" }
        let file = fileLine(progress)
        return "\(progress.percentDone) percent, \(file.prefix(1).lowercased() + file.dropFirst())"
    }

    /// What the sheet's Cancel does while the book is transcribed.
    static let stopHint = "Stops transcribing. The book stays as it was."

    // MARK: What VoiceOver Hears

    /// A transcription began: "Transcribing Moby-Dick, about 1 minute.", or,
    /// before the audio's length is known, "Transcribing Moby-Dick."
    static func started(bookTitle: String, audioSeconds: TimeInterval?) -> String {
        guard let estimate = TranscriptionEstimate.words(forAudio: audioSeconds) else {
            return "Transcribing \(bookTitle)."
        }
        return "Transcribing \(bookTitle), \(estimate)."
    }

    /// The quarters a transcription is announced at, in percent.
    static let milestones = [25, 50, 75]

    /// A transcription passed a quarter: "Moby-Dick: 25 percent
    /// transcribed."
    static func milestone(bookTitle: String, percent: Int) -> String {
        "\(bookTitle): \(percent) percent transcribed."
    }

    /// A transcription ended with the transcript saved: "Transcribed
    /// Moby-Dick: 7,077 words in 51 seconds." The count is written with the
    /// user's grouping, as in "7,077".
    static func finished(bookTitle: String, wordCount: Int, seconds: TimeInterval) -> String {
        "Transcribed \(bookTitle): \(words(wordCount)) in \(TimeFormatting.spoken(seconds))."
    }

    /// Why a transcription stopped, as `TranscriptionError` words it, or as
    /// the error itself says when it is another.
    static func failed(_ error: Error) -> String {
        if let transcription = error as? TranscriptionError {
            return transcription.errorDescription ?? "Transcription stopped."
        }
        return "Transcription stopped: \(error.localizedDescription)"
    }

    // MARK: Settings

    /// The group's heading in Playback settings.
    static let settingsSection = "Transcription"
    /// The language pop-up's label.
    static let languageLabel = "Transcription language"
    /// What the pop-up chooses.
    static let languagePickerHint = "The language audiobooks are transcribed in. A language marked needs download "
        + "is downloaded from the Transcribe Audio sheet, only when you ask."
    /// One language in the pop-up: "English (United States), installed".
    static func languageChoice(name: String, status: String?) -> String {
        status.map { "\(name), \($0)" } ?? name
    }
    /// The checkbox that offers a transcription after each audiobook import.
    static let offerTitle = "Offer to transcribe after importing an audiobook"
    /// What the checkbox does.
    static let offerHint = "After each audiobook is imported, TextMouth asks whether to transcribe it. "
        + "Off, audiobooks are transcribed only when you choose Transcribe Audio."
    /// Where the language is chosen, said under the sheet's language line.
    static let languageHint = "The language is chosen in Settings, under Playback, Transcription."

    // MARK: The Offer After an Import

    /// The offer's title, as the import question sheet shows it.
    static let offerQuestionTitle = "Transcribe the Audiobook?"

    /// What the offer asks: "“Moby-Dick” was imported, with 6 hours, 12
    /// minutes of audio. Transcribing it takes about 6 minutes. Transcribe
    /// it now?"
    static func offerMessage(bookTitle: String, audioSeconds: TimeInterval?) -> String {
        var sentences: [String] = []
        if let audioSeconds, audioSeconds.isFinite, audioSeconds > 0 {
            sentences.append("“\(bookTitle)” was imported, with \(TimeFormatting.spoken(audioSeconds)) of audio.")
        } else {
            sentences.append("“\(bookTitle)” was imported.")
        }
        if let estimate = TranscriptionEstimate.words(forAudio: audioSeconds) {
            sentences.append("Transcribing it takes \(estimate).")
        }
        sentences.append("Transcribe it now?")
        return sentences.joined(separator: " ")
    }

    /// The offer's buttons and what they do.
    static let offerTranscribeTitle = "Transcribe"
    static let offerTranscribeHint = "Opens Transcribe Audio for the book, which starts transcribing at once when its "
        + "language's speech model is on this Mac; otherwise, download the model there, then choose Transcribe."
    static let offerNotNowTitle = "Not Now"
    static let offerNotNowHint = "Leaves the audiobook as it is. You can transcribe it later with Transcribe Audio."

    // MARK: Delete Transcript

    /// The confirmation's title: "Delete the Transcript of Moby-Dick?"
    static func deleteConfirmationTitle(bookTitle: String) -> String {
        "Delete the Transcript of \(bookTitle)?"
    }

    /// What the confirmation explains, saying when the user's own edits go
    /// too.
    static func deleteConfirmationMessage(isEdited: Bool) -> String {
        let message = "The transcript and the text made from it are deleted. \(whatStays), "
            + "and the book can be transcribed again."
        return isEdited ? message + " Your edits to the transcript are deleted too." : message
    }

    /// What a confirmation before a transcript goes, deleted or replaced,
    /// promises stays: "The audiobook's audio, your place, and your
    /// bookmarks stay as they are", the same words in each.
    private static let whatStays = "The audiobook's audio, your place, and your bookmarks stay as they are"

    /// The confirmation's deleting button.
    static let deleteButtonTitle = "Delete Transcript"

    /// The title of the alert saying why Delete Transcript did nothing.
    static let deleteNoticeTitle = "Delete Transcript"

    /// What VoiceOver hears once the transcript is deleted.
    static func deleted(bookTitle: String) -> String {
        "Deleted the transcript of \(bookTitle)."
    }

    /// Why the transcript could not be deleted.
    static func deleteFailed(bookTitle: String, reason: String) -> String {
        "Couldn't delete the transcript of \(bookTitle): \(reason)"
    }

    /// Why Delete Transcript waits while the same book is transcribed.
    static func deleteWhileTranscribing(bookTitle: String) -> String {
        whileTranscribing(bookTitle: bookTitle, orElse: "delete the transcript")
    }

    /// Why a command waits while the same book is transcribed, as Delete
    /// Transcript and Attach Transcript say it: "Moby-Dick is being
    /// transcribed. Cancel the transcription first, or `action` once it
    /// finishes."
    private static func whileTranscribing(bookTitle: String, orElse action: String) -> String {
        "\(bookTitle) is being transcribed. Cancel the transcription first, or \(action) once it finishes."
    }

    // MARK: Attach Transcript

    /// The command that gives an audiobook a transcript from a WebVTT or
    /// SubRip file instead of transcribing it, in the reader's Book menu
    /// (FMT23).
    static let attachCommandTitle = "Attach Transcript…"

    /// What the Open panel asks for: "Choose a WebVTT (.vtt) or SubRip
    /// (.srt) transcript of Moby-Dick. Its times count from the start of the
    /// book's audio." A book of several tracks takes one file for the whole
    /// book, its times running on across the tracks.
    static func attachPanelMessage(bookTitle: String) -> String {
        "Choose a WebVTT (.vtt) or SubRip (.srt) transcript of \(bookTitle). "
            + "Its times count from the start of the book's audio."
    }

    /// The Open panel's button, which attaches the file chosen.
    static let attachPanelPrompt = "Attach"

    /// The title of the alert saying why Attach Transcript did nothing, or
    /// why the file chosen was not attached.
    static let attachNoticeTitle = "Attach Transcript"

    /// The title of the notice saying why Transcribe Audio did nothing.
    static let transcribeNoticeTitle = "Transcribe Audio"

    /// Why Transcribe Audio waits while a transcript is being attached to
    /// the same book (follow-up 7): "A transcript is being attached to
    /// Moby-Dick. Transcribe it once that finishes."
    static func transcribeWhileAttaching(bookTitle: String) -> String {
        "A transcript is being attached to \(bookTitle). Transcribe it once that finishes."
    }

    /// Why Attach Transcript waits while the same book is transcribed.
    static func attachWhileTranscribing(bookTitle: String) -> String {
        whileTranscribing(bookTitle: bookTitle, orElse: "attach the transcript")
    }

    /// Why a file of another kind than WebVTT or SubRip was not attached.
    static let attachUnknownFormat = "TextMouth attaches WebVTT (.vtt) and SubRip (.srt) files."

    /// Why an item that is not a plain file (a named pipe, say) was not attached.
    static let attachNotAFile = "That item isn't a plain file TextMouth can read."

    /// Why the file chosen was not attached, `reason` saying it in a
    /// sentence of its own: "“lecture.vtt” wasn't attached to Moby-Dick:
    /// The file isn't a WebVTT transcript TextMouth can read."
    static func attachFailed(fileName: String, bookTitle: String, reason: String) -> String {
        "“\(fileName)” wasn't attached to \(bookTitle): \(reason)"
    }

    /// The title of the confirmation before a transcript from a file
    /// replaces the book's own: "Replace the Transcript of Moby-Dick?"
    static func replaceConfirmationTitle(bookTitle: String) -> String {
        "Replace the Transcript of \(bookTitle)?"
    }

    /// What the confirmation explains: the transcript from the file named
    /// `fileName` replaces the book's and its text, while the audio, the
    /// place, and the bookmarks stay; then whether the user's own edits of
    /// the transcript go too, and whether its cleanup does.
    static func replaceConfirmationMessage(fileName: String, isEdited: Bool, isCleanedUp: Bool) -> String {
        var message = "The transcript from “\(fileName)” replaces the book's transcript and the text made from it. "
            + "\(whatStays)."
        if isEdited {
            message += " Your edits to the transcript are replaced too."
        }
        if isCleanedUp {
            message += " Its cleanup is replaced too."
        }
        return message
    }

    /// The confirmation's replacing button.
    static let replaceButtonTitle = "Replace Transcript"

    /// What VoiceOver hears as the file's transcript begins to be saved,
    /// the book's audio measured and fingerprinted, which takes seconds for
    /// a long book: "Attaching “lecture.vtt” to Moby-Dick.", in the words a
    /// transcription's start is said in ("Transcribing Moby-Dick.").
    static func attaching(fileName: String, bookTitle: String) -> String {
        "Attaching “\(fileName)” to \(bookTitle)."
    }

    /// What VoiceOver hears once the file is attached: "Attached
    /// “lecture.vtt” to Moby-Dick: 7,077 words.", the count written with the
    /// user's grouping, as a finished transcription says it; then, when
    /// `skipped` of the file's timed passages could not be read, how many
    /// were left out: " 1 timed passage couldn't be read and was left out.";
    /// then, when `cut` of the passages were longer than TextMouth keeps and
    /// were cut short (`TimedTextLimits.maximumCueCharacters`), how many:
    /// " 1 timed passage was too long and was cut short."
    static func attached(fileName: String, bookTitle: String, wordCount: Int, skipped: Int, cut: Int = 0) -> String {
        var sentence = "Attached “\(fileName)” to \(bookTitle): \(words(wordCount))."
        if skipped > 0 {
            let leftOut = grouped(
                skipped,
                singular: "timed passage couldn't be read and was left out",
                plural: "timed passages couldn't be read and were left out"
            )
            sentence += " \(leftOut)."
        }
        if cut > 0 {
            let cutShort = grouped(
                cut,
                singular: "timed passage was too long and was cut short",
                plural: "timed passages were too long and were cut short"
            )
            sentence += " \(cutShort)."
        }
        return sentence
    }

    // MARK: Book Information

    /// The label of the read-only detail in Book Information that says where
    /// a book's transcript came from.
    static let bookInfoLabel = "Transcript"

    /// What VoiceOver says for the editor's Transcript detail whose line is
    /// `line`: "Transcript: Attached from “lecture.vtt” on October 30, 2026."
    /// (Details of the read-only sheet are spoken by `FeedInfoValue`.)
    static func bookInfoSpokenDetail(_ line: String) -> String {
        "\(bookInfoLabel): \(line)"
    }

    /// What Book Information's detail says of a book's transcript, from what
    /// a read of it found: nil when the book has none the sheet could name
    /// (none, or one set aside as unusable, as the Transcribe Audio sheet
    /// counts them), and otherwise one line, with no word about
    /// transcribing again, which Book Information does not offer.
    static func bookInfoLine(for lookup: TranscriptStore.Lookup) -> String? {
        switch lookup {
        case .missing, .unusable:
            return nil
        case .inCloud:
            return transcriptDetailsInCloud
        case .unsupportedVersion:
            return laterVersionSentence
        case .found(let transcript):
            return bookInfoLine(of: transcript)
        }
    }

    /// The line for a transcript that was read: where it came from and when
    /// (from outside, as the sheet words it, or from recognition, with its
    /// language), then, when the listener changed it, when they edited it
    /// and when they cleaned it up.
    static func bookInfoLine(of transcript: Transcript) -> String {
        var sentences: [String]
        if let source = transcript.source {
            // A transcript from outside names no language worth saying; as
            // in the sheet, where it came from is said instead.
            sentences = [cameFrom(source, on: day(transcript.createdAt))]
        } else {
            let language = TranscriptionLanguage.name(of: transcript.locale)
            sentences = [transcribedOn(transcript.createdAt, languageName: language)]
        }
        if let edited = transcript.editedAt {
            sentences.append("You edited it on \(day(edited)).")
        }
        if let cleaned = transcript.cleanedUp?.cleanedAt {
            sentences.append("You cleaned it up on \(day(cleaned)).")
        }
        return sentences.joined(separator: " ")
    }

    /// The line for a book whose transcript is only in the cloud, which Book
    /// Information does not download, so none of its details can be told
    /// yet: "in the cloud", as the app says it of every cloud drive, not
    /// iCloud alone.
    private static let transcriptDetailsInCloud =
        "The transcript is only in the cloud. Its details appear once the book is downloaded."

    // MARK: The Library Row

    /// The note after a transcribed book's title, shown and spoken.
    static let transcribedNote = "Transcribed"
    /// The note while the book is being transcribed.
    static let transcribingNote = "Transcribing"

    // MARK: Helpers

    /// `fraction`, from 0 to 1, as a whole percent rounded down, so 100
    /// means done.
    static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }

    /// `date` as a day in the user's own words: "October 4, 2026".
    static func day(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }

    /// `count` words, the count written with the user's grouping: "1 word",
    /// "7,077 words".
    private static func words(_ count: Int) -> String {
        grouped(count, singular: "word", plural: "words")
    }

    /// `count`, written with the user's grouping, followed by `singular`
    /// after exactly one and `plural` after every other count, as
    /// `CountWording.phrase` counts but with "7,077" in place of "7077".
    private static func grouped(_ count: Int, singular: String, plural: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural)"
    }
}

// MARK: - The Estimate

/// How long transcribing a book's audio should take (FR05), from the speed
/// measured on this kind of Mac: about 65 seconds of audio a second, after
/// a few seconds while the system loads its model
/// (TRANSCRIPTION-RESEARCH-2026-10-03.md).
enum TranscriptionEstimate {
    /// Seconds of audio transcribed each second, as measured.
    static let audioSecondsPerSecond: TimeInterval = 65
    /// Seconds the system takes to load its model before the first result.
    static let startupSeconds: TimeInterval = 5

    /// Seconds a transcription of `audioSeconds` of audio should take; nil
    /// when the length is not known.
    static func seconds(forAudio audioSeconds: TimeInterval?) -> TimeInterval? {
        guard let audioSeconds, audioSeconds.isFinite, audioSeconds > 0 else { return nil }
        return startupSeconds + audioSeconds / audioSecondsPerSecond
    }

    /// The estimate in words: "less than a minute" under 45 seconds, and
    /// otherwise "about" the nearest whole minutes, as in "about 1 minute"
    /// or "about 1 hour, 5 minutes"; nil when the length is not known.
    static func words(forAudio audioSeconds: TimeInterval?) -> String? {
        guard let seconds = seconds(forAudio: audioSeconds) else { return nil }
        guard seconds >= 45 else { return "less than a minute" }
        let minutes = max(1, (seconds / 60).rounded())
        return "about \(TimeFormatting.spoken(minutes * 60))"
    }
}
