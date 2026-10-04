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
    /// The command that deletes a transcribed audiobook's transcript, in the
    /// same places, after a confirmation naming the book.
    static let deleteCommandTitle = "Delete Transcript…"

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
        "Transcribed on \(day(date)), in \(languageName). Transcribing again replaces this transcript."
    }

    /// The line saying another book is being transcribed, which keeps
    /// Transcribe unavailable until it finishes.
    static func busy(bookTitle: String) -> String {
        TranscriptionError.busy(bookTitle).errorDescription ?? bookTitle
    }

    /// The sheet's buttons.
    static let transcribeTitle = "Transcribe"
    static let transcribeAgainTitle = "Transcribe Again"
    static let cancelTitle = "Cancel"
    static let closeTitle = "Close"
    static let okTitle = "OK"

    /// What Transcribe does.
    static let transcribeHint = "Transcribes the book's audio on this Mac, so VoiceOver and the braille display "
        + "can read the narration as text."
    /// What Transcribe Again does.
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
        let words = "\(wordCount.formatted()) \(wordCount == 1 ? "word" : "words")"
        return "Transcribed \(bookTitle): \(words) in \(TimeFormatting.spoken(seconds))."
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
    static let offerTranscribeHint = "Opens Transcribe Audio for the book, which starts transcribing once its "
        + "language's speech model is on this Mac."
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
        let message = "The transcript and the text made from it are deleted. The audiobook's audio, your place, "
            + "and your bookmarks stay as they are, and the book can be transcribed again."
        return isEdited ? message + " Your edits to the transcript are deleted too." : message
    }

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
        "\(bookTitle) is being transcribed. Cancel the transcription first, or delete the transcript once it finishes."
    }

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
