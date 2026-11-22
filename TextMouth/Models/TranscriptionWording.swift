import Foundation

/// The words of transcription (FR05): the commands, the Transcribe Audio
/// sheet, and what VoiceOver hears as a transcription ends, each built once
/// for the screen and VoiceOver alike.
///
/// Every text is localized (FR34): each is a computed property or a function
/// that reads the String Catalog when it is asked, with a comment for its
/// translators. A transcript file's own text is the listener's content and is
/// never translated; only what TextMouth says about it is.
enum TranscriptionWording {
    // MARK: Commands

    /// The command that opens the Transcribe Audio sheet for an audiobook,
    /// in the library's context menu and VoiceOver actions and the reader's
    /// Book menu.
    static var transcribeCommandTitle: String {
        // Translators: Menu item and VoiceOver action that opens the sheet for turning an audiobook's speech into text. The ellipsis means a sheet follows.
        InterfaceText.line("transcription.transcribeCommandTitle", "Transcribe Audio…")
    }
    /// The same command once the book has a transcript: it transcribes the
    /// audio again, replacing the transcript, so it is named for that.
    static var retranscribeCommandTitle: String {
        // Translators: Menu item and VoiceOver action, in place of Transcribe Audio, for an audiobook that already has a transcript: it transcribes the audio again and replaces the transcript. The ellipsis means a sheet follows.
        InterfaceText.line("transcription.retranscribeCommandTitle", "Retranscribe Audio…")
    }
    /// The title of the command that opens the Transcribe Audio sheet for a
    /// book that has a transcript when `hasTranscript`, and for one that has
    /// none otherwise: Retranscribe Audio… or Transcribe Audio….
    static func transcribeCommandTitle(hasTranscript: Bool) -> String {
        hasTranscript ? retranscribeCommandTitle : transcribeCommandTitle
    }
    /// The command that deletes a transcribed audiobook's transcript, in the
    /// same places, after a confirmation naming the book.
    static var deleteCommandTitle: String {
        // Translators: Menu item and VoiceOver action that deletes an audiobook's transcript after asking. The ellipsis means a question follows.
        InterfaceText.line("transcription.deleteCommandTitle", "Delete Transcript…")
    }

    /// What a feed episode's transcript's listener is told as they edit or
    /// clean it up: it stays with the episode, not with its download.
    static var feedEpisodeTranscriptNote: String {
        // Translators: Note under a podcast episode's transcript editor and cleanup sheet. Move to Library is the name of a command in the feed's episode menu.
        InterfaceText.line("transcription.feedEpisodeTranscriptNote", "The transcript, with your changes, stays with the episode in its feed, even after its download is deleted. Deleting the episode or feed deletes it; Move to Library keeps it as a book.")
    }

    // MARK: Refusals

    /// Why the command was refused for several books at once: transcription
    /// works on one book at a time.
    static var oneBookAtATime: String {
        SentenceWording.joined([
            // Translators: First sentence of the alert shown when Transcribe Audio is chosen with several books selected.
            InterfaceText.line("transcription.oneBookAtATime.works", "Transcription works on one audiobook at a time."),
            // Translators: Second sentence of the alert shown when Transcribe Audio is chosen with several books selected. Transcribe Audio is the command's name.
            InterfaceText.line("transcription.oneBookAtATime.transcribe", "Select one audiobook, then choose Transcribe Audio again.")
        ])
    }

    /// Why the command was refused for a book that is not an audiobook.
    static func notAnAudiobook(bookTitle: String) -> String {
        // Translators: Alert shown when Transcribe Audio is chosen for a book that is text, not audio. %@ is the book's title.
        InterfaceText.line("transcription.notAnAudiobook", "\(bookTitle) isn't an audiobook; only audiobooks can be transcribed.")
    }

    // MARK: The Sheet

    /// The sheet's heading before a transcription: "Transcribe Moby-Dick".
    static func sheetTitle(bookTitle: String) -> String {
        // Translators: Heading of the Transcribe Audio sheet before transcribing. %@ is the audiobook's title.
        InterfaceText.line("transcription.sheetTitle", "Transcribe \(bookTitle)")
    }

    /// The sheet's heading before a book that has a transcript is transcribed
    /// again: "Retranscribe Moby-Dick".
    static func retranscribeSheetTitle(bookTitle: String) -> String {
        // Translators: Heading of the Transcribe Audio sheet for an audiobook that already has a transcript, which transcribing again replaces. %@ is the audiobook's title.
        InterfaceText.line("transcription.retranscribeSheetTitle", "Retranscribe \(bookTitle)")
    }

    /// The sheet's heading while it explains why it cannot transcribe, as
    /// on a system older than macOS 26, or for several books at once.
    static var unavailableTitle: String {
        // Translators: Heading of the Transcribe Audio sheet when it can only explain why transcription is not possible.
        InterfaceText.line("transcription.transcribeAudio", "Transcribe Audio")
    }

    /// The sheet's heading while the book is being transcribed:
    /// "Transcribing Moby-Dick".
    static func progressTitle(bookTitle: String) -> String {
        // Translators: Heading of the Transcribe Audio sheet while the audiobook is being transcribed. %@ is the audiobook's title.
        InterfaceText.line("transcription.progressTitle", "Transcribing \(bookTitle)")
    }

    /// The book's audio length, as the sheet shows and speaks it: "Audio:
    /// 6 hours, 12 minutes, 4 seconds." or, before the book's length is
    /// known, "Audio: length not known yet."
    static func audioLength(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            // Translators: Line of the Transcribe Audio sheet before the audiobook's length is known.
            return InterfaceText.line("transcription.audioLength.known", "Audio: length not known yet.")
        }
        // Translators: Line of the Transcribe Audio sheet giving the audiobook's length. %@ is the length in words, such as "6 hours, 12 minutes, 4 seconds".
        return InterfaceText.line("transcription.audioLength.duration", "Audio: \(TimeFormatting.spoken(seconds)).")
    }

    /// How long the transcription should take, as the sheet shows and speaks
    /// it: "Time to transcribe: about 6 minutes." (`TranscriptionEstimate`).
    static func estimateLine(forAudio seconds: TimeInterval?) -> String {
        guard let words = TranscriptionEstimate.words(forAudio: seconds) else {
            // Translators: Line of the Transcribe Audio sheet before the audiobook's length is known, so no time estimate can be made.
            return InterfaceText.line("transcription.estimateLine.known", "Time to transcribe: not known yet.")
        }
        // Translators: Line of the Transcribe Audio sheet estimating how long transcribing will take. %@ is the estimate in words, such as "about 6 minutes" or "less than a minute".
        return InterfaceText.line("transcription.estimateLine.transcribe", "Time to transcribe: \(words).")
    }

    /// What the sheet says while it checks the language's speech model.
    static var checking: String {
        // Translators: Line of the Transcribe Audio sheet while it checks whether the language's speech model is on this Mac.
        InterfaceText.line("transcription.checking", "Checking the speech model…")
    }

    /// The language line: "Language: English (United States), installed."
    static func languageLine(name: String, status: String) -> String {
        // Translators: Line of the Transcribe Audio sheet naming the transcription language and whether its speech model is ready. %1$@ is the language's name, such as "English (United States)"; %2$@ is its status: installed, needs download, downloading, or not supported.
        InterfaceText.line("transcription.languageLine", "Language: \(name), \(status).")
    }

    /// How the language line words a model's status.
    static var modelInstalled: String {
        // Translators: Status of a language's speech model that is on this Mac, said after the language's name in the Transcribe Audio sheet and Settings.
        InterfaceText.line("transcription.modelInstalled", "installed")
    }
    static var modelNeedsDownload: String {
        // Translators: Status of a language's speech model that is not on this Mac yet, said after the language's name in the Transcribe Audio sheet and Settings.
        InterfaceText.line("transcription.modelNeedsDownload", "needs download")
    }
    static var modelDownloading: String {
        // Translators: Status of a language's speech model that is downloading now, said after the language's name in the Transcribe Audio sheet.
        InterfaceText.line("transcription.modelDownloading", "downloading")
    }
    static var modelUnsupported: String {
        // Translators: Status of a language that the speech recognizer cannot transcribe, said after the language's name in the Transcribe Audio sheet and Settings.
        InterfaceText.line("transcription.modelUnsupported", "not supported")
    }

    /// The name a language's model download goes by: the language without
    /// its region, as one model serves every region ("English").
    static func modelLanguageName(of identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return InterfaceLanguage.current.locale.localizedString(forLanguageCode: code) ?? identifier
    }

    /// The approximate size of one language's speech model: the system's
    /// asset catalog lists about 140 MB (TRANSCRIPTION-RESEARCH-2026-10-03.md),
    /// and the download's progress gives no size before it starts.
    static var modelSize: String {
        // Translators: The approximate size of one language's speech model, said in the Download button's label. MB means megabytes.
        InterfaceText.line("transcription.modelSize", "about 140 MB")
    }

    /// The button that downloads a language's model: "Download the English
    /// model, about 140 MB". Nothing downloads without this press.
    static func downloadTitle(languageName: String) -> String {
        // Translators: Button of the Transcribe Audio sheet that downloads a language's speech model. %1$@ is the language's name, such as "English"; %2$@ is the model's approximate size, such as "about 140 MB".
        InterfaceText.line("transcription.downloadTitle", "Download the \(languageName) model, \(modelSize)")
    }

    /// What the download button does.
    static var downloadHint: String {
        // Translators: VoiceOver hint of the button that downloads a language's speech model.
        InterfaceText.line("transcription.downloadHint", "Downloads the speech model from Apple, kept and shared by macOS. Nothing else is downloaded, and the book's audio never leaves this Mac.")
    }

    /// The download's progress, shown and spoken: "Downloading the English
    /// model: 40 percent." or, before its size is known, "Downloading the
    /// English model…".
    static func downloading(languageName: String, fraction: Double?) -> String {
        guard let fraction else {
            // Translators: Line of the Transcribe Audio sheet while a speech model downloads and its progress is not known yet. %@ is the language's name.
            return InterfaceText.line("transcription.downloading.model", "Downloading the \(languageName) model…")
        }
        // Translators: Line of the Transcribe Audio sheet, and what VoiceOver hears, while a speech model downloads. %1$@ is the language's name; %2$lld is the percent done, from 0 to 100.
        return InterfaceText.line("transcription.downloading.percent", "Downloading the \(languageName) model: \(number: percent(fraction)) percent.")
    }

    /// The button that stops a download, and what it does.
    static var cancelDownloadTitle: String {
        // Translators: Button of the Transcribe Audio sheet that stops a speech model's download.
        InterfaceText.line("common.cancelDownload", "Cancel Download")
    }
    static var cancelDownloadHint: String {
        // Translators: VoiceOver hint of the Cancel Download button.
        InterfaceText.line("transcription.cancelDownloadHint", "Stops the download. Nothing is installed.")
    }

    /// What VoiceOver hears when a model has downloaded.
    static func downloaded(languageName: String) -> String {
        // Translators: What VoiceOver hears, and the Transcribe Audio sheet shows, when a speech model has finished downloading. %@ is the language's name.
        InterfaceText.line("transcription.downloaded", "The \(languageName) model is downloaded. The book can be transcribed now.")
    }

    /// What VoiceOver hears, and the sheet shows, when a download stopped.
    static func downloadCancelled(languageName: String) -> String {
        // Translators: What VoiceOver hears, and the Transcribe Audio sheet shows, when a speech model's download was stopped. %@ is the language's name.
        InterfaceText.line("transcription.downloadCancelled", "The \(languageName) model's download was cancelled.")
    }

    /// Why a download failed, shown and spoken.
    static func downloadFailed(languageName: String, reason: String) -> String {
        // Translators: What VoiceOver hears, and the Transcribe Audio sheet shows, when a speech model's download failed. %1$@ is the language's name; %2$@ is the system's reason, a sentence.
        InterfaceText.line("transcription.downloadFailed", "The \(languageName) model couldn't be downloaded: \(reason)")
    }

    /// The line naming the transcript a book has already, which
    /// transcribing again replaces: "Transcribed on October 4, 2026, in
    /// English (United States). Transcribing again replaces this
    /// transcript."
    static func alreadyTranscribed(on date: Date, languageName: String) -> String {
        SentenceWording.joined([transcribedOn(date, languageName: languageName), transcribingAgainReplaces])
    }

    /// The sentence saying when and in which language recognition made a
    /// transcript: "Transcribed on October 4, 2026, in English (United
    /// States)." The sheet's line and Book Information's both begin with it.
    private static func transcribedOn(_ date: Date, languageName: String) -> String {
        // Translators: Sentence in the Transcribe Audio sheet and Book Information saying when and in which language TextMouth made an audiobook's transcript. %1$@ is a date, such as "October 4, 2026"; %2$@ is the language's name.
        InterfaceText.line("transcription.transcribedOn", "Transcribed on \(day(date)), in \(languageName).")
    }

    /// The line naming a transcript the book has from outside TextMouth's
    /// recognizer (FMT23, FMT25), which transcribing again replaces: one
    /// sentence of where it came from and when, as in "Attached from
    /// “lecture.vtt” on October 30, 2026. Transcribing again replaces this
    /// transcript."
    static func outsideTranscript(_ source: TranscriptSource, on date: Date) -> String {
        SentenceWording.joined([cameFrom(source, on: day(date)), transcribingAgainReplaces])
    }

    /// What each line naming the book's transcript ends with.
    private static var transcribingAgainReplaces: String {
        // Translators: Last sentence of the Transcribe Audio sheet's line about the transcript a book already has.
        InterfaceText.line("transcription.transcribingAgainReplaces", "Transcribing again replaces this transcript.")
    }

    /// Where a transcript from outside came from, as one sentence ending with
    /// `day`, the day the book was given it: attached from a file, named
    /// when one file was read and otherwise by its format; found when the
    /// book was imported; or the podcast's own. An origin a later TextMouth
    /// wrote, which this one cannot name, is said only to be attached.
    private static func cameFrom(_ source: TranscriptSource, on day: String) -> String {
        let fileName = source.fileName
        let formatName = source.knownFormat?.name
        // Every format the files were of, said together: "WebVTT and
        // SubRip", when this TextMouth knows them all.
        let formatNames = source.knownFormats.flatMap { formats in
            formats.isEmpty ? nil : CountWording.list(formats.map(\.name))
        }
        switch source.knownOrigin {
        case .attached:
            if let fileName {
                // Translators: Sentence saying a transcript came from one file the user attached. %1$@ is the file's name; %2$@ is a date, such as "October 30, 2026".
                return InterfaceText.line("transcription.cameFrom.attached.fromNamedOn", "Attached from “\(fileName)” on \(day).")
            }
            if let formatName {
                // Translators: Sentence saying a transcript came from a file the user attached, whose name is not known. %1$@ is the file format's name, such as WebVTT or SubRip; %2$@ is a date.
                return InterfaceText.line("transcription.cameFrom.attached.fromKindFileOn", "Attached from a \(formatName) file on \(day).")
            }
            // Translators: Sentence saying a transcript came from a file the user attached, whose name and format are not known. %@ is a date, such as "October 30, 2026".
            return InterfaceText.line("transcription.cameFrom.attached.file", "Attached from a file on \(day).")
        case .imported:
            // One file by its name; several by their formats, when known.
            if let fileName {
                // Translators: Sentence saying a transcript came from a file found beside the audio when the book was imported. %1$@ is the file's name; %2$@ is a date.
                return InterfaceText.line("transcription.cameFrom.imported.attachedImport", "Attached from “\(fileName)” at import, on \(day).")
            }
            if let formatNames {
                // Translators: Sentence saying a transcript came from files found beside the audio when the book was imported. %1$@ is the files' formats, such as "WebVTT and SubRip"; %2$@ is a date.
                return InterfaceText.line("transcription.cameFrom.imported.kindFiles", "Attached from \(formatNames) files at import, on \(day).")
            }
            // Translators: Sentence saying a transcript came from files found beside the audio when the book was imported, whose names and formats are not known. %@ is a date.
            return InterfaceText.line("transcription.cameFrom.imported.attachedFiles", "Attached from files at import, on \(day).")
        case .podcast:
            // Translators: Sentence saying a podcast episode's transcript is the one the podcast published. %@ is a date.
            return InterfaceText.line("transcription.cameFrom.podcast", "The podcast's own transcript, downloaded with the episode on \(day).")
        case nil:
            // Translators: Sentence saying when a transcript was attached, when its origin is not known. %@ is a date.
            return InterfaceText.line("transcription.cameFrom.nil", "Attached on \(day).")
        }
    }

    /// The line warning that transcribing again replaces the user's own
    /// edits: "You edited this transcript on October 5, 2026. Transcribing
    /// again replaces your edits."
    static func editedTranscript(on date: Date) -> String {
        // Translators: Line of the Transcribe Audio sheet warning that transcribing again replaces the user's own edits. %@ is a date, such as "October 5, 2026".
        InterfaceText.line("transcription.editedTranscript", "You edited this transcript on \(day(date)). Transcribing again replaces your edits.")
    }

    /// The line warning that transcribing again replaces the user's cleanup
    /// of the transcript: "You cleaned up this transcript on October 5,
    /// 2026. Transcribing again replaces the cleanup."
    static func cleanedUpTranscript(on date: Date) -> String {
        // Translators: Line of the Transcribe Audio sheet warning that transcribing again replaces the cleanup the user applied. %@ is a date, such as "October 5, 2026".
        InterfaceText.line("transcription.cleanedUpTranscript", "You cleaned up this transcript on \(day(date)). Transcribing again replaces the cleanup.")
    }

    /// The line for a book whose transcript, transcript.json, is only in
    /// iCloud, which this Mac did not read: it cannot be seen, or its edits
    /// and cleanup told of, so the sheet offers no Retranscribe until the
    /// book is downloaded. In the words of `textInCloud`, which says the same
    /// of the transcript's text.
    static var transcriptInCloud: String {
        // Translators: Line of the Transcribe Audio sheet when the book's transcript file has not been downloaded from iCloud to this Mac.
        InterfaceText.line("transcription.transcriptInCloud", "The transcript is only in iCloud, so TextMouth leaves it. Download the book, then try again.")
    }

    /// The line for a book whose text, content.md, is only in iCloud: a
    /// transcription is saved over that text, which TextMouth never does
    /// while the file is not on this Mac, so the sheet offers no Retranscribe
    /// until the book is downloaded, rather than refuse the finished
    /// transcript after the audio was transcribed. Also what a refused
    /// install says (`TranscriptTextError.textOnlyInCloud`).
    static var textInCloud: String {
        // Translators: Line of the Transcribe Audio sheet, and an error, when the book's text file has not been downloaded from iCloud to this Mac.
        InterfaceText.line("transcription.textInCloud", "The book's text is only in iCloud, so TextMouth leaves it. Download the book, then try again.")
    }

    /// The line for a transcript written in a layout this TextMouth does
    /// not read.
    static var transcriptFromLaterVersion: String {
        SentenceWording.joined([
            laterVersionSentence,
            // Translators: Last sentence of the Transcribe Audio sheet's line about a transcript made by a later version of TextMouth.
            InterfaceText.line("transcription.transcriptFromLaterVersion", "Transcribing again replaces it.")
        ])
    }

    /// The sentence saying a book's transcript is a later TextMouth's, which
    /// the sheet's line and Book Information's both begin with.
    private static var laterVersionSentence: String {
        // Translators: Sentence in the Transcribe Audio sheet and Book Information saying the book's transcript was written by a newer version of this app, which this version cannot read.
        InterfaceText.line("transcription.laterVersionSentence", "This book has a transcript made by a later version of TextMouth.")
    }

    /// The line saying another book is being transcribed, which keeps
    /// Transcribe unavailable until it finishes.
    static func busy(bookTitle: String) -> String {
        TranscriptionError.busy(bookTitle).errorDescription ?? bookTitle
    }

    /// The sheet's buttons.
    static var transcribeTitle: String {
        // Translators: Button of the Transcribe Audio sheet that starts transcribing the audiobook.
        InterfaceText.line("transcription.transcribe", "Transcribe")
    }
    /// The button of a book that has a transcript already: "Retranscribe".
    static var transcribeAgainTitle: String {
        // Translators: Button of the Transcribe Audio sheet, in place of Transcribe, for an audiobook that already has a transcript.
        InterfaceText.line("transcription.transcribeAgainTitle", "Retranscribe")
    }
    static var cancelTitle: String {
        // Translators: Button that closes a sheet or dialog without doing what it offered.
        InterfaceText.line("common.cancel", "Cancel")
    }
    static var closeTitle: String {
        // Translators: Button that closes a sheet.
        InterfaceText.line("common.close", "Close")
    }
    static var okTitle: String {
        // Translators: Button that dismisses an alert after reading it.
        InterfaceText.line("common.ok", "OK")
    }

    /// What Transcribe does.
    static var transcribeHint: String {
        // Translators: VoiceOver hint of the Transcribe button.
        InterfaceText.line("transcription.transcribeHint", "Transcribes the book's audio on this Mac, so VoiceOver and braille can read the narration as text.")
    }
    /// What Retranscribe does.
    static var transcribeAgainHint: String {
        // Translators: VoiceOver hint of the Retranscribe button.
        InterfaceText.line("transcription.transcribeAgainHint", "Transcribes the book's audio again, replacing its transcript.")
    }
    /// What Cancel does before a transcription.
    static var cancelHint: String {
        // Translators: VoiceOver hint of the Cancel button of the Transcribe Audio sheet before transcribing.
        InterfaceText.line("transcription.cancelHint", "Closes this without transcribing.")
    }

    /// What VoiceOver hears as the sheet appears, after its focus lands:
    /// its lines in one go, the heading first.
    static func sheetAnnouncement(lines: [String]) -> String {
        SentenceWording.joined(lines)
    }

    // MARK: Progress

    /// Which file is being transcribed: "File 3 of 12", or, once every file
    /// is done, "All 12 files".
    static func fileLine(_ progress: TranscriptionProgress) -> String {
        guard progress.fileIndex < progress.fileCount else {
            // Translators: Line of the Transcribe Audio sheet once every audio file of the book is transcribed. %lld is the number of files.
            return InterfaceText.line("transcription.fileLine.files", "All \(number: progress.fileCount) files")
        }
        // Translators: Line of the Transcribe Audio sheet saying which audio file of the book is being transcribed. %1$lld is that file's place, from 1; %2$lld is the number of files.
        return InterfaceText.line("transcription.fileLine.numberOfTotal", "File \(number: progress.fileIndex + 1) of \(number: progress.fileCount)")
    }

    /// The same as `fileLine`, written to follow a comma in the progress
    /// bar's value: "file 3 of 12", or "all 12 files".
    private static func fileLineAfterComma(_ progress: TranscriptionProgress) -> String {
        guard progress.fileIndex < progress.fileCount else {
            // Translators: End of the transcription progress bar's spoken value once every audio file is transcribed, after "100 percent, ". %lld is the number of files.
            return InterfaceText.line("transcription.fileLineAfterComma.files", "all \(number: progress.fileCount) files")
        }
        // Translators: End of the transcription progress bar's spoken value, after "40 percent, ", saying which audio file is being transcribed. %1$lld is that file's place, from 1; %2$lld is the number of files.
        return InterfaceText.line("transcription.fileLineAfterComma.numberOfTotal", "file \(number: progress.fileIndex + 1) of \(number: progress.fileCount)")
    }

    /// How much of the audio is done: "40 minutes of 6 hours, 12 minutes
    /// transcribed".
    static func secondsLine(_ progress: TranscriptionProgress) -> String {
        // Translators: Line of the Transcribe Audio sheet while transcribing. %1$@ is the length of audio transcribed so far, in words such as "40 minutes"; %2$@ is the audiobook's whole length in words, such as "6 hours, 12 minutes".
        InterfaceText.line("transcription.secondsLine", "\(TimeFormatting.spoken(progress.secondsDone)) of \(TimeFormatting.spoken(progress.secondsTotal)) transcribed")
    }

    /// How long the transcription has run: "Elapsed: 12 seconds".
    static func elapsedLine(_ seconds: TimeInterval) -> String {
        // Translators: Line of the Transcribe Audio sheet while transcribing, saying how long it has run. %@ is a length of time in words, such as "12 seconds".
        InterfaceText.line("transcription.elapsedLine", "Elapsed: \(TimeFormatting.spoken(seconds))")
    }

    /// What the sheet says before the first file has begun, while the
    /// system loads its speech model.
    static var starting: String {
        // Translators: Line of the Transcribe Audio sheet before the first audio file has begun, while the speech model loads.
        InterfaceText.line("transcription.starting", "Starting…")
    }

    /// The progress bar's label.
    static var progressLabel: String {
        // Translators: VoiceOver label of the progress bar in the Transcribe Audio sheet.
        InterfaceText.line("transcription.progressLabel", "Transcription progress")
    }

    /// The progress bar's value, which VoiceOver reads: "40 percent, file 3
    /// of 12", or "Starting" before the first file has begun.
    static func progressValue(_ progress: TranscriptionProgress?) -> String {
        guard let progress else {
            // Translators: VoiceOver value of the transcription progress bar before the first audio file has begun.
            return InterfaceText.line("common.starting", "Starting")
        }
        // Translators: VoiceOver value of the transcription progress bar. %1$lld is the percent done, from 0 to 100; %2$@ says which audio file is being transcribed, such as "file 3 of 12".
        return InterfaceText.line("transcription.progressValue", "\(number: progress.percentDone) percent, \(fileLineAfterComma(progress))")
    }

    /// What the sheet's Cancel does while the book is transcribed.
    static var stopHint: String {
        // Translators: VoiceOver hint of the Cancel button of the Transcribe Audio sheet while transcribing.
        InterfaceText.line("transcription.stopHint", "Stops transcribing. The book stays as it was.")
    }

    // MARK: What VoiceOver Hears

    /// A transcription began: "Transcribing Moby-Dick, about 1 minute.", or,
    /// before the audio's length is known, "Transcribing Moby-Dick."
    static func started(bookTitle: String, audioSeconds: TimeInterval?) -> String {
        guard let estimate = TranscriptionEstimate.words(forAudio: audioSeconds) else {
            // Translators: What VoiceOver hears as a transcription begins, when the audio's length is not known. %@ is the audiobook's title.
            return InterfaceText.line("transcription.started.untimed", "Transcribing \(bookTitle).")
        }
        // Translators: What VoiceOver hears as a transcription begins. %1$@ is the audiobook's title; %2$@ is the time it should take, such as "about 1 minute".
        return InterfaceText.line("transcription.started.withEstimate", "Transcribing \(bookTitle), \(estimate).")
    }

    /// The quarters a transcription is announced at, in percent.
    static let milestones = [25, 50, 75]

    /// A transcription passed a quarter: "Moby-Dick: 25 percent
    /// transcribed."
    static func milestone(bookTitle: String, percent: Int) -> String {
        // Translators: What VoiceOver hears as a transcription passes a quarter of the audio. %1$@ is the audiobook's title; %2$lld is the percent done: 25, 50, or 75.
        InterfaceText.line("transcription.milestone", "\(bookTitle): \(number: percent) percent transcribed.")
    }

    /// A transcription ended with the transcript saved: "Transcribed
    /// Moby-Dick: 7,077 words in 51 seconds." The count is written with the
    /// user's grouping, as in "7,077".
    static func finished(bookTitle: String, wordCount: Int, seconds: TimeInterval) -> String {
        // Translators: What VoiceOver hears when a transcription finishes and the transcript is saved. %1$@ is the audiobook's title; %2$@ is the number of words, such as "7,077 words"; %3$@ is how long it took, such as "51 seconds".
        InterfaceText.line("transcription.finished", "Transcribed \(bookTitle): \(words(wordCount)) in \(TimeFormatting.spoken(seconds)).")
    }

    /// Why a transcription stopped, as `TranscriptionError` words it, or as
    /// the error itself says when it is another.
    static func failed(_ error: Error) -> String {
        if let transcription = error as? TranscriptionError {
            // Translators: What VoiceOver hears when a transcription stopped for a reason that has no words of its own.
            return transcription.errorDescription ?? InterfaceText.line("transcription.failed.stopped", "Transcription stopped.")
        }
        // Translators: What VoiceOver hears when a transcription stopped because of an error from the system. %@ is the system's own sentence.
        return InterfaceText.line("transcription.failed.withReason", "Transcription stopped: \(error.localizedDescription)")
    }

    // MARK: Settings

    /// The group's heading in Playback settings.
    static var settingsSection: String {
        // Translators: Heading of the group of transcription settings in Playback settings.
        InterfaceText.line("transcription.settingsSection", "Transcription")
    }
    /// The language pop-up's label.
    static var languageLabel: String {
        // Translators: Label of the pop-up in Playback settings that chooses the language audiobooks are transcribed in.
        InterfaceText.line("transcription.languageLabel", "Transcription language")
    }
    /// What the pop-up chooses.
    static var languagePickerHint: String {
        // Translators: VoiceOver hint of the transcription language pop-up. "needs download" is the status word a language's menu item shows when its speech model is not on this Mac, and Transcribe Audio is the command's name.
        InterfaceText.line("transcription.languagePickerHint", "Sets the transcription language. A language marked needs download downloads only from the Transcribe Audio sheet.")
    }
    /// One language in the pop-up: "English (United States), installed".
    static func languageChoice(name: String, status: String?) -> String {
        guard let status else { return name }
        // Translators: A language's menu item in the transcription language pop-up, with its speech model's status. %1$@ is the language's name, such as "English (United States)"; %2$@ is the status: installed, needs download, or not supported.
        return InterfaceText.line("common.nameAndNote", "\(name), \(status)")
    }
    /// The checkbox that offers a transcription after each audiobook import.
    static var offerTitle: String {
        // Translators: Label of the checkbox in Playback settings that makes TextMouth ask about transcribing after each audiobook is imported.
        InterfaceText.line("transcription.offerTitle", "Offer to transcribe after importing an audiobook")
    }
    /// What the checkbox does.
    static var offerHint: String {
        // Translators: VoiceOver hint of the checkbox that offers transcribing after an import. Transcribe Audio is the command's name.
        InterfaceText.line("transcription.offerHint", "Asks after each audiobook import whether to transcribe it. Off, audiobooks are transcribed only with Transcribe Audio.")
    }
    /// Where the language is chosen, said under the sheet's language line.
    static var languageHint: String {
        // Translators: Line under the Transcribe Audio sheet's language line saying where the language is chosen. Settings, Playback, and Transcription are the names of the settings window, its Playback pane, and its Transcription group.
        InterfaceText.line("transcription.languageHint", "Choose the language in Settings, Playback, Transcription.")
    }

    // MARK: The Offer After an Import

    /// The offer's title, as the import question sheet shows it.
    static var offerQuestionTitle: String {
        // Translators: Title of the question asked after an audiobook is imported, offering to transcribe it.
        InterfaceText.line("transcription.offerQuestionTitle", "Transcribe the Audiobook?")
    }

    /// What the offer asks: "“Moby-Dick” was imported, with 6 hours, 12
    /// minutes of audio. Transcribing it takes about 6 minutes. Transcribe
    /// it now?"
    static func offerMessage(bookTitle: String, audioSeconds: TimeInterval?) -> String {
        var sentences: [String] = []
        if let audioSeconds, audioSeconds.isFinite, audioSeconds > 0 {
            // Translators: First sentence of the question offering to transcribe a new audiobook. %1$@ is the audiobook's title; %2$@ is its length in words, such as "6 hours, 12 minutes".
            sentences.append(InterfaceText.line("transcription.offerMessage.audio", "“\(bookTitle)” was imported, with \(TimeFormatting.spoken(audioSeconds)) of audio."))
        } else {
            // Translators: First sentence of the question offering to transcribe a new audiobook whose length is not known. %@ is the audiobook's title.
            sentences.append(InterfaceText.line("transcription.offerMessage.imported", "“\(bookTitle)” was imported."))
        }
        if let estimate = TranscriptionEstimate.words(forAudio: audioSeconds) {
            // Translators: Second sentence of the question offering to transcribe a new audiobook. %@ is the time it should take, such as "about 6 minutes" or "less than a minute".
            sentences.append(InterfaceText.line("transcription.offerMessage.transcribing", "Transcribing it takes \(estimate)."))
        }
        // Translators: Last sentence of the question offering to transcribe a new audiobook.
        sentences.append(InterfaceText.line("transcription.offerMessage.transcribe", "Transcribe it now?"))
        return SentenceWording.joined(sentences)
    }

    /// The offer's buttons and what they do.
    static var offerTranscribeTitle: String {
        // Translators: Button of the question offered after an import that opens Transcribe Audio for the new audiobook.
        InterfaceText.line("transcription.transcribe", "Transcribe")
    }
    static var offerTranscribeHint: String {
        // Translators: VoiceOver hint of the Transcribe button of the question offered after an import. Transcribe Audio is the command's name; Transcribe is the sheet's button.
        InterfaceText.line("transcription.offerTranscribeHint", "Opens Transcribe Audio, which starts at once if the language's model is on this Mac; otherwise, download it there, then choose Transcribe.")
    }
    static var offerNotNowTitle: String {
        // Translators: Button of the question offered after an import that leaves the audiobook untranscribed for now.
        InterfaceText.line("transcription.offerNotNowTitle", "Not Now")
    }
    static var offerNotNowHint: String {
        // Translators: VoiceOver hint of the Not Now button of the question offered after an import. Transcribe Audio is the command's name.
        InterfaceText.line("transcription.offerNotNowHint", "Leaves the audiobook untranscribed; Transcribe Audio does it later.")
    }

    // MARK: Delete Transcript

    /// The confirmation's title: "Delete the Transcript of Moby-Dick?"
    static func deleteConfirmationTitle(bookTitle: String) -> String {
        // Translators: Title of the question asked before an audiobook's transcript is deleted. %@ is the audiobook's title.
        InterfaceText.line("transcription.deleteConfirmationTitle", "Delete the Transcript of \(bookTitle)?")
    }

    /// What the confirmation explains, saying when the user's own edits go
    /// too.
    static func deleteConfirmationMessage(isEdited: Bool) -> String {
        var sentences = [
            // Translators: First sentence of the question asked before an audiobook's transcript is deleted.
            InterfaceText.line("transcription.deleteConfirmationMessage.text", "The transcript and the text made from it are deleted."),
            whatStays,
            // Translators: Last sentence of the question asked before an audiobook's transcript is deleted, after what stays.
            InterfaceText.line("transcription.deleteConfirmation.transcribed", "The book can be transcribed again.")
        ]
        if isEdited {
            // Translators: Last sentence of the question asked before a transcript is deleted, when the user had edited it.
            sentences.append(InterfaceText.line("transcription.deleteConfirmationMessage.edits", "Your edits to the transcript are deleted too."))
        }
        return SentenceWording.joined(sentences)
    }

    /// What a confirmation before a transcript is deleted or replaced promises stays:
    /// "The audiobook's audio, your place, and your bookmarks stay as they
    /// are."
    private static var whatStays: String {
        // Translators: Sentence of the question asked before an audiobook's transcript is deleted or replaced by a file's: what stays.
        InterfaceText.line("transcription.whatStays", "The audiobook's audio, your place, and your bookmarks stay as they are.")
    }

    /// The confirmation's deleting button.
    static var deleteButtonTitle: String {
        // Translators: Button of the question asked before a transcript is deleted, which deletes it.
        InterfaceText.line("transcription.deleteTranscript", "Delete Transcript")
    }

    /// The title of the alert saying why Delete Transcript did nothing.
    static var deleteNoticeTitle: String {
        // Translators: Title of the alert saying why Delete Transcript did nothing.
        InterfaceText.line("transcription.deleteTranscript", "Delete Transcript")
    }

    /// What VoiceOver hears once the transcript is deleted.
    static func deleted(bookTitle: String) -> String {
        // Translators: What VoiceOver hears once an audiobook's transcript is deleted. %@ is the audiobook's title.
        InterfaceText.line("transcription.deleted", "Deleted the transcript of \(bookTitle).")
    }

    /// Why the transcript could not be deleted.
    static func deleteFailed(bookTitle: String, reason: String) -> String {
        // Translators: Alert, and what VoiceOver hears, when an audiobook's transcript could not be deleted. %1$@ is the audiobook's title; %2$@ is the reason, a sentence.
        InterfaceText.line("transcription.deleteFailed", "Couldn't delete the transcript of \(bookTitle): \(reason)")
    }

    /// Why Delete Transcript waits while the same book is transcribed:
    /// "Moby-Dick is being transcribed. Cancel the transcription first, or
    /// delete the transcript once it finishes."
    static func deleteWhileTranscribing(bookTitle: String) -> String {
        // Translators: Alert shown when Delete Transcript is chosen for an audiobook that is being transcribed. %@ is the audiobook's title.
        InterfaceText.line("transcription.deleteWhileTranscribing", "\(bookTitle) is being transcribed. Cancel it, or delete the transcript once it finishes.")
    }

    // MARK: Attach Transcript

    /// The command that gives an audiobook a transcript from a WebVTT or
    /// SubRip file instead of transcribing it, in the reader's Book menu
    /// (FMT23).
    static var attachCommandTitle: String {
        // Translators: Menu item that gives an audiobook a transcript from a WebVTT or SubRip file instead of transcribing it. The ellipsis means a file panel follows.
        InterfaceText.line("transcription.attachCommandTitle", "Attach Transcript…")
    }

    /// What the Open panel asks for: "Choose a WebVTT (.vtt) or SubRip
    /// (.srt) transcript of Moby-Dick. Its times count from the start of the
    /// book's audio." A book of several tracks takes one file for the whole
    /// book, its times running on across the tracks.
    static func attachPanelMessage(bookTitle: String) -> String {
        // Translators: Message of the file panel opened by Attach Transcript. %@ is the audiobook's title. WebVTT and SubRip are subtitle file formats, and .vtt and .srt their file extensions.
        InterfaceText.line("transcription.attachPanelMessage", "Choose a WebVTT (.vtt) or SubRip (.srt) transcript of \(bookTitle), timed from the start of its audio.")
    }

    /// The Open panel's button, which attaches the file chosen.
    static var attachPanelPrompt: String {
        // Translators: Button of the file panel opened by Attach Transcript, which attaches the chosen file.
        InterfaceText.line("transcription.attachPanelPrompt", "Attach")
    }

    /// The title of the alert saying why Attach Transcript did nothing, or
    /// why the file chosen was not attached.
    static var attachNoticeTitle: String {
        // Translators: Title of the alert saying why Attach Transcript did nothing or why the chosen file was not attached.
        InterfaceText.line("transcription.attachNoticeTitle", "Attach Transcript")
    }

    /// The title of the notice saying why Transcribe Audio did nothing.
    static var transcribeNoticeTitle: String {
        // Translators: Title of the alert saying why Transcribe Audio did nothing.
        InterfaceText.line("transcription.transcribeAudio", "Transcribe Audio")
    }

    /// Why Transcribe Audio waits while a transcript is being attached to
    /// the same book (follow-up 7): "A transcript is being attached to
    /// Moby-Dick. Transcribe it once that finishes."
    static func transcribeWhileAttaching(bookTitle: String) -> String {
        // Translators: Alert shown when Transcribe Audio is chosen for an audiobook that a transcript is being attached to. %@ is the audiobook's title.
        InterfaceText.line("transcription.transcribeWhileAttaching", "A transcript is being attached to \(bookTitle). Transcribe it once that finishes.")
    }

    /// Why Attach Transcript waits while the same book is transcribed:
    /// "Moby-Dick is being transcribed. Cancel the transcription first, or
    /// attach the transcript once it finishes."
    static func attachWhileTranscribing(bookTitle: String) -> String {
        // Translators: Alert shown when Attach Transcript is chosen for an audiobook that is being transcribed. %@ is the audiobook's title.
        InterfaceText.line("transcription.attachWhileTranscribing", "\(bookTitle) is being transcribed. Cancel it, or attach the transcript once it finishes.")
    }

    /// Why a file of another kind than WebVTT or SubRip was not attached.
    static var attachUnknownFormat: String {
        // Translators: Alert explaining why a chosen file was not attached as a transcript. WebVTT and SubRip are subtitle file formats, and .vtt and .srt their file extensions.
        InterfaceText.line("transcription.attachUnknownFormat", "TextMouth attaches WebVTT (.vtt) and SubRip (.srt) files.")
    }

    /// Why an item that is not a plain file (a named pipe, say) was not attached.
    static var attachNotAFile: String {
        // Translators: Alert explaining why a chosen item was not attached as a transcript: it is not an ordinary file, such as a folder or a pipe.
        InterfaceText.line("transcription.attachNotAFile", "That item isn't a plain file TextMouth can read.")
    }

    /// Why the file chosen was not attached, `reason` saying it in a
    /// sentence of its own: "“lecture.vtt” wasn't attached to Moby-Dick:
    /// The file isn't a WebVTT transcript TextMouth can read."
    static func attachFailed(fileName: String, bookTitle: String, reason: String) -> String {
        // Translators: Alert, and what VoiceOver hears, when a chosen file was not attached as a transcript. %1$@ is the file's name; %2$@ is the audiobook's title; %3$@ is the reason, a sentence.
        InterfaceText.line("transcription.attachFailed", "“\(fileName)” wasn't attached to \(bookTitle): \(reason)")
    }

    /// The title of the confirmation before a transcript from a file
    /// replaces the book's own: "Replace the Transcript of Moby-Dick?"
    static func replaceConfirmationTitle(bookTitle: String) -> String {
        // Translators: Title of the question asked before a transcript from a file replaces an audiobook's transcript. %@ is the audiobook's title.
        InterfaceText.line("transcription.replaceConfirmationTitle", "Replace the Transcript of \(bookTitle)?")
    }

    /// What the confirmation explains: the transcript from the file named
    /// `fileName` replaces the book's and its text, while the audio, the
    /// place, and the bookmarks stay; then whether the user's own edits of
    /// the transcript go too, and whether its cleanup does.
    static func replaceConfirmationMessage(fileName: String, isEdited: Bool, isCleanedUp: Bool) -> String {
        var sentences = [
            // Translators: First sentence of the question asked before a transcript from a file replaces an audiobook's transcript. %@ is the file's name.
            InterfaceText.line("transcription.replaceConfirmation.replaces", "The transcript from “\(fileName)” replaces the book's transcript and the text made from it."),
            whatStays
        ]
        if isEdited {
            // Translators: Sentence of the question asked before a transcript from a file replaces the book's, when the user had edited it.
            sentences.append(InterfaceText.line("transcription.replaceConfirmationMessage.edits", "Your edits to the transcript are replaced too."))
        }
        if isCleanedUp {
            // Translators: Sentence of the question asked before a transcript from a file replaces the book's, when the user had cleaned it up.
            sentences.append(InterfaceText.line("transcription.replaceConfirmationMessage.cleanup", "Its cleanup is replaced too."))
        }
        return SentenceWording.joined(sentences)
    }

    /// The confirmation's replacing button.
    static var replaceButtonTitle: String {
        // Translators: Button of the question asked before a transcript from a file replaces an audiobook's transcript, which replaces it.
        InterfaceText.line("transcription.replaceButtonTitle", "Replace Transcript")
    }

    /// What VoiceOver hears as the file's transcript begins to be saved,
    /// the book's audio measured and fingerprinted, which takes seconds for
    /// a long book: "Attaching “lecture.vtt” to Moby-Dick.", in the words a
    /// transcription's start is said in ("Transcribing Moby-Dick.").
    static func attaching(fileName: String, bookTitle: String) -> String {
        // Translators: What VoiceOver hears as a transcript file starts to be attached. %1$@ is the file's name; %2$@ is the audiobook's title.
        InterfaceText.line("transcription.attaching", "Attaching “\(fileName)” to \(bookTitle).")
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
        var sentences = [
            // Translators: What VoiceOver hears once a transcript file is attached. %1$@ is the file's name; %2$@ is the audiobook's title; %3$@ is the number of words, such as "7,077 words".
            InterfaceText.line("transcription.attached.toAudiobook", "Attached “\(fileName)” to \(bookTitle): \(words(wordCount)).")
        ]
        if skipped > 0 {
            // Translators: Sentence added to the announcement of an attached transcript when some of the file's timed passages could not be read. %lld is how many.
            sentences.append(InterfaceText.line("transcription.attached.unreadable", "\(number: skipped) timed passages were unreadable and left out."))
        }
        if cut > 0 {
            // Translators: Sentence added to the announcement of an attached transcript when some of the file's timed passages were longer than TextMouth keeps. %lld is how many.
            sentences.append(InterfaceText.line("transcription.attached.short", "\(number: cut) timed passages were too long and cut short."))
        }
        return SentenceWording.joined(sentences)
    }

    // MARK: Book Information

    /// The label of the read-only detail in Book Information that says where
    /// a book's transcript came from.
    static var bookInfoLabel: String {
        // Translators: Label of the detail in Book Information that says where the book's transcript came from.
        InterfaceText.line("common.transcript", "Transcript")
    }

    /// What VoiceOver says for the editor's Transcript detail whose line is
    /// `line`: "Transcript: Attached from “lecture.vtt” on October 30, 2026."
    /// (Details of the read-only sheet are spoken by `FeedInfoValue`.)
    static func bookInfoSpokenDetail(_ line: String) -> String {
        // Translators: What VoiceOver says for a detail of Book Information. %1$@ is the detail's label; %2$@ is its value.
        InterfaceText.line("common.valueColonValue", "\(bookInfoLabel): \(line)")
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
            // Translators: Sentence of Book Information's Transcript detail saying when the user edited the transcript. %@ is a date, such as "October 5, 2026".
            sentences.append(InterfaceText.line("transcription.bookInfoLine.edited", "You edited it on \(day(edited))."))
        }
        if let cleaned = transcript.cleanedUp?.cleanedAt {
            // Translators: Sentence of Book Information's Transcript detail saying when the user cleaned up the transcript. %@ is a date, such as "October 5, 2026".
            sentences.append(InterfaceText.line("transcription.bookInfoLine.cleaned", "You cleaned it up on \(day(cleaned))."))
        }
        return SentenceWording.joined(sentences)
    }

    /// The line for a book whose transcript is only in the cloud, which Book
    /// Information does not download, so none of its details can be told
    /// yet: "in the cloud", as the app says it of every cloud drive, not
    /// iCloud alone.
    private static var transcriptDetailsInCloud: String {
        // Translators: Book Information's Transcript detail when the transcript file has not been downloaded from the cloud drive.
        InterfaceText.line("transcription.transcriptDetailsInCloud", "The transcript is only in the cloud. Its details appear once the book is downloaded.")
    }

    // MARK: The Library Row

    /// The note after a transcribed book's title, shown and spoken.
    static var transcribedNote: String {
        // Translators: Note after a book's title in the library, saying the audiobook has a transcript.
        InterfaceText.line("transcription.transcribedNote", "Transcribed")
    }
    /// The note while the book is being transcribed.
    static var transcribingNote: String {
        // Translators: Note after a book's title in the library, saying the audiobook is being transcribed now.
        InterfaceText.line("transcription.transcribingNote", "Transcribing")
    }

    // MARK: Helpers

    /// `fraction`, from 0 to 1, as a whole percent rounded down, so 100
    /// means done.
    static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }

    /// `date` as a day in the user's own words: "October 4, 2026".
    static func day(_ date: Date) -> String {
        date.interfaceFormatted(date: .long, time: .omitted)
    }

    /// `count` words, the count written with the user's grouping: "1 word",
    /// "7,077 words".
    private static func words(_ count: Int) -> String {
        // Translators: A count of the words of a transcript, said in an announcement. %lld is the number of words, written with the region's digit grouping.
        InterfaceText.line("transcription.words", "\(number: count) words")
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
        guard seconds >= 45 else {
            // Translators: A time estimate, said after "Time to transcribe:" or inside a sentence, for a transcription that takes under 45 seconds.
            return InterfaceText.line("transcriptionEstimate.words", "less than a minute")
        }
        let minutes = max(1, (seconds / 60).rounded())
        // Translators: A time estimate, said after "Time to transcribe:" or inside a sentence. %@ is a length of time in words, such as "6 minutes" or "1 hour, 5 minutes".
        return InterfaceText.line("common.aboutValue", "about \(TimeFormatting.spoken(minutes * 60))")
    }
}
