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
        String(localized: "Transcribe Audio…",
               comment: "Menu item and VoiceOver action that opens the sheet for turning an audiobook's speech into text. The ellipsis means a sheet follows.")
    }
    /// The same command once the book has a transcript: it transcribes the
    /// audio again, replacing the transcript, so it is named for that.
    static var retranscribeCommandTitle: String {
        String(localized: "Retranscribe Audio…",
               comment: "Menu item and VoiceOver action, in place of Transcribe Audio, for an audiobook that already has a transcript: it transcribes the audio again and replaces the transcript. The ellipsis means a sheet follows.")
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
        String(localized: "Delete Transcript…",
               comment: "Menu item and VoiceOver action that deletes an audiobook's transcript after asking. The ellipsis means a question follows.")
    }

    /// What a feed episode's transcript's listener is told as they edit or
    /// clean it up: it stays with the episode, not with its download.
    static var feedEpisodeTranscriptNote: String {
        String(localized: "This episode's transcript, with your changes, stays with the episode in its feed, even after its download is deleted. Deleting the episode or the feed deletes it; Move to Library keeps it with the episode as a book.",
               comment: "Note under a podcast episode's transcript editor and cleanup sheet. Move to Library is the name of a command in the feed's episode menu.")
    }

    // MARK: Refusals

    /// Why the command was refused for several books at once: transcription
    /// works on one book at a time.
    static var oneBookAtATime: String {
        SentenceWording.joined([
            String(localized: "Transcription works on one audiobook at a time.",
                   comment: "First sentence of the alert shown when Transcribe Audio is chosen with several books selected."),
            String(localized: "Select one audiobook, then choose Transcribe Audio again.",
                   comment: "Second sentence of the alert shown when Transcribe Audio is chosen with several books selected. Transcribe Audio is the command's name.")
        ])
    }

    /// Why the command was refused for a book that is not an audiobook.
    static func notAnAudiobook(bookTitle: String) -> String {
        String(localized: "\(bookTitle) isn't an audiobook. Only an audiobook's audio can be transcribed.",
               comment: "Alert shown when Transcribe Audio is chosen for a book that is text, not audio. %@ is the book's title.")
    }

    // MARK: The Sheet

    /// The sheet's heading before a transcription: "Transcribe Moby-Dick".
    static func sheetTitle(bookTitle: String) -> String {
        String(localized: "Transcribe \(bookTitle)",
               comment: "Heading of the Transcribe Audio sheet before transcribing. %@ is the audiobook's title.")
    }

    /// The sheet's heading before a book that has a transcript is transcribed
    /// again: "Retranscribe Moby-Dick".
    static func retranscribeSheetTitle(bookTitle: String) -> String {
        String(localized: "Retranscribe \(bookTitle)",
               comment: "Heading of the Transcribe Audio sheet for an audiobook that already has a transcript, which transcribing again replaces. %@ is the audiobook's title.")
    }

    /// The sheet's heading while it explains why it cannot transcribe, as
    /// on a system older than macOS 26, or for several books at once.
    static var unavailableTitle: String {
        String(localized: "Transcribe Audio",
               comment: "Heading of the Transcribe Audio sheet when it can only explain why transcription is not possible.")
    }

    /// The sheet's heading while the book is being transcribed:
    /// "Transcribing Moby-Dick".
    static func progressTitle(bookTitle: String) -> String {
        String(localized: "Transcribing \(bookTitle)",
               comment: "Heading of the Transcribe Audio sheet while the audiobook is being transcribed. %@ is the audiobook's title.")
    }

    /// The book's audio length, as the sheet shows and speaks it: "Audio:
    /// 6 hours, 12 minutes, 4 seconds." or, before the book's length is
    /// known, "Audio: length not known yet."
    static func audioLength(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return String(localized: "Audio: length not known yet.",
                          comment: "Line of the Transcribe Audio sheet before the audiobook's length is known.")
        }
        return String(localized: "Audio: \(TimeFormatting.spoken(seconds)).",
                      comment: "Line of the Transcribe Audio sheet giving the audiobook's length. %@ is the length in words, such as \"6 hours, 12 minutes, 4 seconds\".")
    }

    /// How long the transcription should take, as the sheet shows and speaks
    /// it: "Time to transcribe: about 6 minutes." (`TranscriptionEstimate`).
    static func estimateLine(forAudio seconds: TimeInterval?) -> String {
        guard let words = TranscriptionEstimate.words(forAudio: seconds) else {
            return String(localized: "Time to transcribe: not known until the audio's length is.",
                          comment: "Line of the Transcribe Audio sheet before the audiobook's length is known, so no time estimate can be made.")
        }
        return String(localized: "Time to transcribe: \(words).",
                      comment: "Line of the Transcribe Audio sheet estimating how long transcribing will take. %@ is the estimate in words, such as \"about 6 minutes\" or \"less than a minute\".")
    }

    /// What the sheet says while it checks the language's speech model.
    static var checking: String {
        String(localized: "Checking the speech model…",
               comment: "Line of the Transcribe Audio sheet while it checks whether the language's speech model is on this Mac.")
    }

    /// The language line: "Language: English (United States), installed."
    static func languageLine(name: String, status: String) -> String {
        String(localized: "Language: \(name), \(status).",
               comment: "Line of the Transcribe Audio sheet naming the transcription language and whether its speech model is ready. %1$@ is the language's name, such as \"English (United States)\"; %2$@ is its status: installed, needs download, downloading, or not supported.")
    }

    /// How the language line words a model's status.
    static var modelInstalled: String {
        String(localized: "installed",
               comment: "Status of a language's speech model that is on this Mac, said after the language's name in the Transcribe Audio sheet and Settings.")
    }
    static var modelNeedsDownload: String {
        String(localized: "needs download",
               comment: "Status of a language's speech model that is not on this Mac yet, said after the language's name in the Transcribe Audio sheet and Settings.")
    }
    static var modelDownloading: String {
        String(localized: "downloading",
               comment: "Status of a language's speech model that is downloading now, said after the language's name in the Transcribe Audio sheet.")
    }
    static var modelUnsupported: String {
        String(localized: "not supported",
               comment: "Status of a language that the speech recognizer cannot transcribe, said after the language's name in the Transcribe Audio sheet and Settings.")
    }

    /// The name a language's model download goes by: the language without
    /// its region, as one model serves every region ("English").
    static func modelLanguageName(of identifier: String) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return Locale.current.localizedString(forLanguageCode: code) ?? identifier
    }

    /// The approximate size of one language's speech model: the system's
    /// asset catalog lists about 140 MB (TRANSCRIPTION-RESEARCH-2026-10-03.md),
    /// and the download's progress gives no size before it starts.
    static var modelSize: String {
        String(localized: "about 140 MB",
               comment: "The approximate size of one language's speech model, said in the Download button's label. MB means megabytes.")
    }

    /// The button that downloads a language's model: "Download the English
    /// model, about 140 MB". Nothing downloads without this press.
    static func downloadTitle(languageName: String) -> String {
        String(localized: "Download the \(languageName) model, \(modelSize)",
               comment: "Button of the Transcribe Audio sheet that downloads a language's speech model. %1$@ is the language's name, such as \"English\"; %2$@ is the model's approximate size, such as \"about 140 MB\".")
    }

    /// What the download button does.
    static var downloadHint: String {
        String(localized: "Downloads the speech model from Apple. macOS keeps it and shares it with other apps. Nothing else is downloaded, and the book's audio never leaves this Mac.",
               comment: "VoiceOver hint of the button that downloads a language's speech model.")
    }

    /// The download's progress, shown and spoken: "Downloading the English
    /// model: 40 percent." or, before its size is known, "Downloading the
    /// English model…".
    static func downloading(languageName: String, fraction: Double?) -> String {
        guard let fraction else {
            return String(localized: "Downloading the \(languageName) model…",
                          comment: "Line of the Transcribe Audio sheet while a speech model downloads and its progress is not known yet. %@ is the language's name.")
        }
        return String(localized: "Downloading the \(languageName) model: \(percent(fraction)) percent.",
                      comment: "Line of the Transcribe Audio sheet, and what VoiceOver hears, while a speech model downloads. %1$@ is the language's name; %2$lld is the percent done, from 0 to 100.")
    }

    /// The button that stops a download, and what it does.
    static var cancelDownloadTitle: String {
        String(localized: "Cancel Download",
               comment: "Button of the Transcribe Audio sheet that stops a speech model's download.")
    }
    static var cancelDownloadHint: String {
        String(localized: "Stops the download. Nothing is installed.",
               comment: "VoiceOver hint of the Cancel Download button.")
    }

    /// What VoiceOver hears when a model has downloaded.
    static func downloaded(languageName: String) -> String {
        String(localized: "The \(languageName) model is downloaded. The book can be transcribed now.",
               comment: "What VoiceOver hears, and the Transcribe Audio sheet shows, when a speech model has finished downloading. %@ is the language's name.")
    }

    /// What VoiceOver hears, and the sheet shows, when a download stopped.
    static func downloadCancelled(languageName: String) -> String {
        String(localized: "The \(languageName) model's download was cancelled.",
               comment: "What VoiceOver hears, and the Transcribe Audio sheet shows, when a speech model's download was stopped. %@ is the language's name.")
    }

    /// Why a download failed, shown and spoken.
    static func downloadFailed(languageName: String, reason: String) -> String {
        String(localized: "The \(languageName) model couldn't be downloaded: \(reason)",
               comment: "What VoiceOver hears, and the Transcribe Audio sheet shows, when a speech model's download failed. %1$@ is the language's name; %2$@ is the system's reason, a sentence.")
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
        String(localized: "Transcribed on \(day(date)), in \(languageName).",
               comment: "Sentence in the Transcribe Audio sheet and Book Information saying when and in which language TextMouth made an audiobook's transcript. %1$@ is a date, such as \"October 4, 2026\"; %2$@ is the language's name.")
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
        String(localized: "Transcribing again replaces this transcript.",
               comment: "Last sentence of the Transcribe Audio sheet's line about the transcript a book already has.")
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
                return String(localized: "Attached from “\(fileName)” on \(day).",
                              comment: "Sentence saying a transcript came from one file the user attached. %1$@ is the file's name; %2$@ is a date, such as \"October 30, 2026\".")
            }
            if let formatName {
                return String(localized: "Attached from a \(formatName) file on \(day).",
                              comment: "Sentence saying a transcript came from a file the user attached, whose name is not known. %1$@ is the file format's name, such as WebVTT or SubRip; %2$@ is a date.")
            }
            return String(localized: "Attached from a file on \(day).",
                          comment: "Sentence saying a transcript came from a file the user attached, whose name and format are not known. %@ is a date, such as \"October 30, 2026\".")
        case .imported:
            // One file by its name; several by their formats, when known.
            if let fileName {
                return String(localized: "Attached from “\(fileName)” when the book was imported, on \(day).",
                              comment: "Sentence saying a transcript came from a file found beside the audio when the book was imported. %1$@ is the file's name; %2$@ is a date.")
            }
            if let formatNames {
                return String(localized: "Attached from \(formatNames) files when the book was imported, on \(day).",
                              comment: "Sentence saying a transcript came from files found beside the audio when the book was imported. %1$@ is the files' formats, such as \"WebVTT and SubRip\"; %2$@ is a date.")
            }
            return String(localized: "Attached from files when the book was imported, on \(day).",
                          comment: "Sentence saying a transcript came from files found beside the audio when the book was imported, whose names and formats are not known. %@ is a date.")
        case .podcast:
            return String(localized: "The podcast's own transcript, downloaded with the episode on \(day).",
                          comment: "Sentence saying a podcast episode's transcript is the one the podcast published. %@ is a date.")
        case nil:
            return String(localized: "Attached on \(day).",
                          comment: "Sentence saying when a transcript was attached, when its origin is not known. %@ is a date.")
        }
    }

    /// The line warning that transcribing again replaces the user's own
    /// edits: "You edited this transcript on October 5, 2026. Transcribing
    /// again replaces your edits."
    static func editedTranscript(on date: Date) -> String {
        String(localized: "You edited this transcript on \(day(date)). Transcribing again replaces your edits.",
               comment: "Line of the Transcribe Audio sheet warning that transcribing again replaces the user's own edits. %@ is a date, such as \"October 5, 2026\".")
    }

    /// The line warning that transcribing again replaces the user's cleanup
    /// of the transcript: "You cleaned up this transcript on October 5,
    /// 2026. Transcribing again replaces the cleanup."
    static func cleanedUpTranscript(on date: Date) -> String {
        String(localized: "You cleaned up this transcript on \(day(date)). Transcribing again replaces the cleanup.",
               comment: "Line of the Transcribe Audio sheet warning that transcribing again replaces the cleanup the user applied. %@ is a date, such as \"October 5, 2026\".")
    }

    /// The line for a book whose transcript, transcript.json, is only in
    /// iCloud, which this Mac did not read: it cannot be seen, or its edits
    /// and cleanup told of, so the sheet offers no Retranscribe until the
    /// book is downloaded. In the words of `textInCloud`, which says the same
    /// of the transcript's text.
    static var transcriptInCloud: String {
        String(localized: "The book's transcript is only in iCloud, so TextMouth leaves it as it is. Download the book, then try again.",
               comment: "Line of the Transcribe Audio sheet when the book's transcript file has not been downloaded from iCloud to this Mac.")
    }

    /// The line for a book whose text, content.md, is only in iCloud: a
    /// transcription is saved over that text, which TextMouth never does
    /// while the file is not on this Mac, so the sheet offers no Retranscribe
    /// until the book is downloaded, rather than refuse the finished
    /// transcript after the audio was transcribed. Also what a refused
    /// install says (`TranscriptTextError.textOnlyInCloud`).
    static var textInCloud: String {
        String(localized: "The book's text is only in iCloud, so TextMouth leaves it as it is. Download the book, then try again.",
               comment: "Line of the Transcribe Audio sheet, and an error, when the book's text file has not been downloaded from iCloud to this Mac.")
    }

    /// The line for a transcript written in a layout this TextMouth does
    /// not read.
    static var transcriptFromLaterVersion: String {
        SentenceWording.joined([
            laterVersionSentence,
            String(localized: "Transcribing again replaces it.",
                   comment: "Last sentence of the Transcribe Audio sheet's line about a transcript made by a later version of TextMouth.")
        ])
    }

    /// The sentence saying a book's transcript is a later TextMouth's, which
    /// the sheet's line and Book Information's both begin with.
    private static var laterVersionSentence: String {
        String(localized: "This book has a transcript made by a later version of TextMouth.",
               comment: "Sentence in the Transcribe Audio sheet and Book Information saying the book's transcript was written by a newer version of this app, which this version cannot read.")
    }

    /// The line saying another book is being transcribed, which keeps
    /// Transcribe unavailable until it finishes.
    static func busy(bookTitle: String) -> String {
        TranscriptionError.busy(bookTitle).errorDescription ?? bookTitle
    }

    /// The sheet's buttons.
    static var transcribeTitle: String {
        String(localized: "Transcribe",
               comment: "Button of the Transcribe Audio sheet that starts transcribing the audiobook.")
    }
    /// The button of a book that has a transcript already: "Retranscribe".
    static var transcribeAgainTitle: String {
        String(localized: "Retranscribe",
               comment: "Button of the Transcribe Audio sheet, in place of Transcribe, for an audiobook that already has a transcript.")
    }
    static var cancelTitle: String {
        String(localized: "Cancel",
               comment: "Button that closes a sheet or dialog without doing what it offered.")
    }
    static var closeTitle: String {
        String(localized: "Close",
               comment: "Button that closes a sheet.")
    }
    static var okTitle: String {
        String(localized: "OK",
               comment: "Button that dismisses an alert after reading it.")
    }

    /// What Transcribe does.
    static var transcribeHint: String {
        String(localized: "Transcribes the book's audio on this Mac, so VoiceOver and the braille display can read the narration as text.",
               comment: "VoiceOver hint of the Transcribe button.")
    }
    /// What Retranscribe does.
    static var transcribeAgainHint: String {
        String(localized: "Transcribes the book's audio again, replacing its transcript.",
               comment: "VoiceOver hint of the Retranscribe button.")
    }
    /// What Cancel does before a transcription.
    static var cancelHint: String {
        String(localized: "Closes this without transcribing.",
               comment: "VoiceOver hint of the Cancel button of the Transcribe Audio sheet before transcribing.")
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
            return String(localized: "All \(progress.fileCount) files",
                          comment: "Line of the Transcribe Audio sheet once every audio file of the book is transcribed. %lld is the number of files.")
        }
        return String(localized: "File \(progress.fileIndex + 1) of \(progress.fileCount)",
                      comment: "Line of the Transcribe Audio sheet saying which audio file of the book is being transcribed. %1$lld is that file's place, from 1; %2$lld is the number of files.")
    }

    /// The same as `fileLine`, written to follow a comma in the progress
    /// bar's value: "file 3 of 12", or "all 12 files".
    private static func fileLineAfterComma(_ progress: TranscriptionProgress) -> String {
        guard progress.fileIndex < progress.fileCount else {
            return String(localized: "all \(progress.fileCount) files",
                          comment: "End of the transcription progress bar's spoken value once every audio file is transcribed, after \"100 percent, \". %lld is the number of files.")
        }
        return String(localized: "file \(progress.fileIndex + 1) of \(progress.fileCount)",
                      comment: "End of the transcription progress bar's spoken value, after \"40 percent, \", saying which audio file is being transcribed. %1$lld is that file's place, from 1; %2$lld is the number of files.")
    }

    /// How much of the audio is done: "40 minutes of 6 hours, 12 minutes
    /// transcribed".
    static func secondsLine(_ progress: TranscriptionProgress) -> String {
        String(localized: "\(TimeFormatting.spoken(progress.secondsDone)) of \(TimeFormatting.spoken(progress.secondsTotal)) transcribed",
               comment: "Line of the Transcribe Audio sheet while transcribing. %1$@ is the length of audio transcribed so far, in words such as \"40 minutes\"; %2$@ is the audiobook's whole length in words, such as \"6 hours, 12 minutes\".")
    }

    /// How long the transcription has run: "Elapsed: 12 seconds".
    static func elapsedLine(_ seconds: TimeInterval) -> String {
        String(localized: "Elapsed: \(TimeFormatting.spoken(seconds))",
               comment: "Line of the Transcribe Audio sheet while transcribing, saying how long it has run. %@ is a length of time in words, such as \"12 seconds\".")
    }

    /// What the sheet says before the first file has begun, while the
    /// system loads its speech model.
    static var starting: String {
        String(localized: "Starting…",
               comment: "Line of the Transcribe Audio sheet before the first audio file has begun, while the speech model loads.")
    }

    /// The progress bar's label.
    static var progressLabel: String {
        String(localized: "Transcription progress",
               comment: "VoiceOver label of the progress bar in the Transcribe Audio sheet.")
    }

    /// The progress bar's value, which VoiceOver reads: "40 percent, file 3
    /// of 12", or "Starting" before the first file has begun.
    static func progressValue(_ progress: TranscriptionProgress?) -> String {
        guard let progress else {
            return String(localized: "Starting",
                          comment: "VoiceOver value of the transcription progress bar before the first audio file has begun.")
        }
        return String(localized: "\(progress.percentDone) percent, \(fileLineAfterComma(progress))",
                      comment: "VoiceOver value of the transcription progress bar. %1$lld is the percent done, from 0 to 100; %2$@ says which audio file is being transcribed, such as \"file 3 of 12\".")
    }

    /// What the sheet's Cancel does while the book is transcribed.
    static var stopHint: String {
        String(localized: "Stops transcribing. The book stays as it was.",
               comment: "VoiceOver hint of the Cancel button of the Transcribe Audio sheet while transcribing.")
    }

    // MARK: What VoiceOver Hears

    /// A transcription began: "Transcribing Moby-Dick, about 1 minute.", or,
    /// before the audio's length is known, "Transcribing Moby-Dick."
    static func started(bookTitle: String, audioSeconds: TimeInterval?) -> String {
        guard let estimate = TranscriptionEstimate.words(forAudio: audioSeconds) else {
            return String(localized: "Transcribing \(bookTitle).",
                          comment: "What VoiceOver hears as a transcription begins, when the audio's length is not known. %@ is the audiobook's title.")
        }
        return String(localized: "Transcribing \(bookTitle), \(estimate).",
                      comment: "What VoiceOver hears as a transcription begins. %1$@ is the audiobook's title; %2$@ is the time it should take, such as \"about 1 minute\".")
    }

    /// The quarters a transcription is announced at, in percent.
    static let milestones = [25, 50, 75]

    /// A transcription passed a quarter: "Moby-Dick: 25 percent
    /// transcribed."
    static func milestone(bookTitle: String, percent: Int) -> String {
        String(localized: "\(bookTitle): \(percent) percent transcribed.",
               comment: "What VoiceOver hears as a transcription passes a quarter of the audio. %1$@ is the audiobook's title; %2$lld is the percent done: 25, 50, or 75.")
    }

    /// A transcription ended with the transcript saved: "Transcribed
    /// Moby-Dick: 7,077 words in 51 seconds." The count is written with the
    /// user's grouping, as in "7,077".
    static func finished(bookTitle: String, wordCount: Int, seconds: TimeInterval) -> String {
        String(localized: "Transcribed \(bookTitle): \(words(wordCount)) in \(TimeFormatting.spoken(seconds)).",
               comment: "What VoiceOver hears when a transcription finishes and the transcript is saved. %1$@ is the audiobook's title; %2$@ is the number of words, such as \"7,077 words\"; %3$@ is how long it took, such as \"51 seconds\".")
    }

    /// Why a transcription stopped, as `TranscriptionError` words it, or as
    /// the error itself says when it is another.
    static func failed(_ error: Error) -> String {
        if let transcription = error as? TranscriptionError {
            return transcription.errorDescription ?? String(localized: "Transcription stopped.",
                                                            comment: "What VoiceOver hears when a transcription stopped for a reason that has no words of its own.")
        }
        return String(localized: "Transcription stopped: \(error.localizedDescription)",
                      comment: "What VoiceOver hears when a transcription stopped because of an error from the system. %@ is the system's own sentence.")
    }

    // MARK: Settings

    /// The group's heading in Playback settings.
    static var settingsSection: String {
        String(localized: "Transcription",
               comment: "Heading of the group of transcription settings in Playback settings.")
    }
    /// The language pop-up's label.
    static var languageLabel: String {
        String(localized: "Transcription language",
               comment: "Label of the pop-up in Playback settings that chooses the language audiobooks are transcribed in.")
    }
    /// What the pop-up chooses.
    static var languagePickerHint: String {
        String(localized: "The language audiobooks are transcribed in. A language marked needs download is downloaded from the Transcribe Audio sheet, only when you ask.",
               comment: "VoiceOver hint of the transcription language pop-up. \"needs download\" is the status word a language's menu item shows when its speech model is not on this Mac, and Transcribe Audio is the command's name.")
    }
    /// One language in the pop-up: "English (United States), installed".
    static func languageChoice(name: String, status: String?) -> String {
        guard let status else { return name }
        return String(localized: "\(name), \(status)",
                      comment: "A language's menu item in the transcription language pop-up, with its speech model's status. %1$@ is the language's name, such as \"English (United States)\"; %2$@ is the status: installed, needs download, or not supported.")
    }
    /// The checkbox that offers a transcription after each audiobook import.
    static var offerTitle: String {
        String(localized: "Offer to transcribe after importing an audiobook",
               comment: "Label of the checkbox in Playback settings that makes TextMouth ask about transcribing after each audiobook is imported.")
    }
    /// What the checkbox does.
    static var offerHint: String {
        String(localized: "After each audiobook is imported, TextMouth asks whether to transcribe it. Off, audiobooks are transcribed only when you choose Transcribe Audio.",
               comment: "VoiceOver hint of the checkbox that offers transcribing after an import. Transcribe Audio is the command's name.")
    }
    /// Where the language is chosen, said under the sheet's language line.
    static var languageHint: String {
        String(localized: "The language is chosen in Settings, under Playback, Transcription.",
               comment: "Line under the Transcribe Audio sheet's language line saying where the language is chosen. Settings, Playback, and Transcription are the names of the settings window, its Playback pane, and its Transcription group.")
    }

    // MARK: The Offer After an Import

    /// The offer's title, as the import question sheet shows it.
    static var offerQuestionTitle: String {
        String(localized: "Transcribe the Audiobook?",
               comment: "Title of the question asked after an audiobook is imported, offering to transcribe it.")
    }

    /// What the offer asks: "“Moby-Dick” was imported, with 6 hours, 12
    /// minutes of audio. Transcribing it takes about 6 minutes. Transcribe
    /// it now?"
    static func offerMessage(bookTitle: String, audioSeconds: TimeInterval?) -> String {
        var sentences: [String] = []
        if let audioSeconds, audioSeconds.isFinite, audioSeconds > 0 {
            sentences.append(String(localized: "“\(bookTitle)” was imported, with \(TimeFormatting.spoken(audioSeconds)) of audio.",
                                    comment: "First sentence of the question offering to transcribe a new audiobook. %1$@ is the audiobook's title; %2$@ is its length in words, such as \"6 hours, 12 minutes\"."))
        } else {
            sentences.append(String(localized: "“\(bookTitle)” was imported.",
                                    comment: "First sentence of the question offering to transcribe a new audiobook whose length is not known. %@ is the audiobook's title."))
        }
        if let estimate = TranscriptionEstimate.words(forAudio: audioSeconds) {
            sentences.append(String(localized: "Transcribing it takes \(estimate).",
                                    comment: "Second sentence of the question offering to transcribe a new audiobook. %@ is the time it should take, such as \"about 6 minutes\" or \"less than a minute\"."))
        }
        sentences.append(String(localized: "Transcribe it now?",
                                comment: "Last sentence of the question offering to transcribe a new audiobook."))
        return SentenceWording.joined(sentences)
    }

    /// The offer's buttons and what they do.
    static var offerTranscribeTitle: String {
        String(localized: "Transcribe",
               comment: "Button of the question offered after an import that opens Transcribe Audio for the new audiobook.")
    }
    static var offerTranscribeHint: String {
        String(localized: "Opens Transcribe Audio for the book, which starts transcribing at once when its language's speech model is on this Mac; otherwise, download the model there, then choose Transcribe.",
               comment: "VoiceOver hint of the Transcribe button of the question offered after an import. Transcribe Audio is the command's name; Transcribe is the sheet's button.")
    }
    static var offerNotNowTitle: String {
        String(localized: "Not Now",
               comment: "Button of the question offered after an import that leaves the audiobook untranscribed for now.")
    }
    static var offerNotNowHint: String {
        String(localized: "Leaves the audiobook as it is. You can transcribe it later with Transcribe Audio.",
               comment: "VoiceOver hint of the Not Now button of the question offered after an import. Transcribe Audio is the command's name.")
    }

    // MARK: Delete Transcript

    /// The confirmation's title: "Delete the Transcript of Moby-Dick?"
    static func deleteConfirmationTitle(bookTitle: String) -> String {
        String(localized: "Delete the Transcript of \(bookTitle)?",
               comment: "Title of the question asked before an audiobook's transcript is deleted. %@ is the audiobook's title.")
    }

    /// What the confirmation explains, saying when the user's own edits go
    /// too.
    static func deleteConfirmationMessage(isEdited: Bool) -> String {
        var sentences = [
            String(localized: "The transcript and the text made from it are deleted.",
                   comment: "First sentence of the question asked before an audiobook's transcript is deleted."),
            String(localized: "The audiobook's audio, your place, and your bookmarks stay as they are, and the book can be transcribed again.",
                   comment: "Second sentence of the question asked before an audiobook's transcript is deleted: what stays, and that it can be transcribed again.")
        ]
        if isEdited {
            sentences.append(String(localized: "Your edits to the transcript are deleted too.",
                                    comment: "Last sentence of the question asked before a transcript is deleted, when the user had edited it."))
        }
        return SentenceWording.joined(sentences)
    }

    /// What a confirmation before a transcript is replaced promises stays:
    /// "The audiobook's audio, your place, and your bookmarks stay as they
    /// are."
    private static var whatStays: String {
        String(localized: "The audiobook's audio, your place, and your bookmarks stay as they are.",
               comment: "Sentence of the question asked before a transcript from a file replaces an audiobook's transcript: what stays.")
    }

    /// The confirmation's deleting button.
    static var deleteButtonTitle: String {
        String(localized: "Delete Transcript",
               comment: "Button of the question asked before a transcript is deleted, which deletes it.")
    }

    /// The title of the alert saying why Delete Transcript did nothing.
    static var deleteNoticeTitle: String {
        String(localized: "Delete Transcript",
               comment: "Title of the alert saying why Delete Transcript did nothing.")
    }

    /// What VoiceOver hears once the transcript is deleted.
    static func deleted(bookTitle: String) -> String {
        String(localized: "Deleted the transcript of \(bookTitle).",
               comment: "What VoiceOver hears once an audiobook's transcript is deleted. %@ is the audiobook's title.")
    }

    /// Why the transcript could not be deleted.
    static func deleteFailed(bookTitle: String, reason: String) -> String {
        String(localized: "Couldn't delete the transcript of \(bookTitle): \(reason)",
               comment: "Alert, and what VoiceOver hears, when an audiobook's transcript could not be deleted. %1$@ is the audiobook's title; %2$@ is the reason, a sentence.")
    }

    /// Why Delete Transcript waits while the same book is transcribed:
    /// "Moby-Dick is being transcribed. Cancel the transcription first, or
    /// delete the transcript once it finishes."
    static func deleteWhileTranscribing(bookTitle: String) -> String {
        String(localized: "\(bookTitle) is being transcribed. Cancel the transcription first, or delete the transcript once it finishes.",
               comment: "Alert shown when Delete Transcript is chosen for an audiobook that is being transcribed. %@ is the audiobook's title.")
    }

    // MARK: Attach Transcript

    /// The command that gives an audiobook a transcript from a WebVTT or
    /// SubRip file instead of transcribing it, in the reader's Book menu
    /// (FMT23).
    static var attachCommandTitle: String {
        String(localized: "Attach Transcript…",
               comment: "Menu item that gives an audiobook a transcript from a WebVTT or SubRip file instead of transcribing it. The ellipsis means a file panel follows.")
    }

    /// What the Open panel asks for: "Choose a WebVTT (.vtt) or SubRip
    /// (.srt) transcript of Moby-Dick. Its times count from the start of the
    /// book's audio." A book of several tracks takes one file for the whole
    /// book, its times running on across the tracks.
    static func attachPanelMessage(bookTitle: String) -> String {
        String(localized: "Choose a WebVTT (.vtt) or SubRip (.srt) transcript of \(bookTitle). Its times count from the start of the book's audio.",
               comment: "Message of the file panel opened by Attach Transcript. %@ is the audiobook's title. WebVTT and SubRip are subtitle file formats, and .vtt and .srt their file extensions.")
    }

    /// The Open panel's button, which attaches the file chosen.
    static var attachPanelPrompt: String {
        String(localized: "Attach",
               comment: "Button of the file panel opened by Attach Transcript, which attaches the chosen file.")
    }

    /// The title of the alert saying why Attach Transcript did nothing, or
    /// why the file chosen was not attached.
    static var attachNoticeTitle: String {
        String(localized: "Attach Transcript",
               comment: "Title of the alert saying why Attach Transcript did nothing or why the chosen file was not attached.")
    }

    /// The title of the notice saying why Transcribe Audio did nothing.
    static var transcribeNoticeTitle: String {
        String(localized: "Transcribe Audio",
               comment: "Title of the alert saying why Transcribe Audio did nothing.")
    }

    /// Why Transcribe Audio waits while a transcript is being attached to
    /// the same book (follow-up 7): "A transcript is being attached to
    /// Moby-Dick. Transcribe it once that finishes."
    static func transcribeWhileAttaching(bookTitle: String) -> String {
        String(localized: "A transcript is being attached to \(bookTitle). Transcribe it once that finishes.",
               comment: "Alert shown when Transcribe Audio is chosen for an audiobook that a transcript is being attached to. %@ is the audiobook's title.")
    }

    /// Why Attach Transcript waits while the same book is transcribed:
    /// "Moby-Dick is being transcribed. Cancel the transcription first, or
    /// attach the transcript once it finishes."
    static func attachWhileTranscribing(bookTitle: String) -> String {
        String(localized: "\(bookTitle) is being transcribed. Cancel the transcription first, or attach the transcript once it finishes.",
               comment: "Alert shown when Attach Transcript is chosen for an audiobook that is being transcribed. %@ is the audiobook's title.")
    }

    /// Why a file of another kind than WebVTT or SubRip was not attached.
    static var attachUnknownFormat: String {
        String(localized: "TextMouth attaches WebVTT (.vtt) and SubRip (.srt) files.",
               comment: "Alert explaining why a chosen file was not attached as a transcript. WebVTT and SubRip are subtitle file formats, and .vtt and .srt their file extensions.")
    }

    /// Why an item that is not a plain file (a named pipe, say) was not attached.
    static var attachNotAFile: String {
        String(localized: "That item isn't a plain file TextMouth can read.",
               comment: "Alert explaining why a chosen item was not attached as a transcript: it is not an ordinary file, such as a folder or a pipe.")
    }

    /// Why the file chosen was not attached, `reason` saying it in a
    /// sentence of its own: "“lecture.vtt” wasn't attached to Moby-Dick:
    /// The file isn't a WebVTT transcript TextMouth can read."
    static func attachFailed(fileName: String, bookTitle: String, reason: String) -> String {
        String(localized: "“\(fileName)” wasn't attached to \(bookTitle): \(reason)",
               comment: "Alert, and what VoiceOver hears, when a chosen file was not attached as a transcript. %1$@ is the file's name; %2$@ is the audiobook's title; %3$@ is the reason, a sentence.")
    }

    /// The title of the confirmation before a transcript from a file
    /// replaces the book's own: "Replace the Transcript of Moby-Dick?"
    static func replaceConfirmationTitle(bookTitle: String) -> String {
        String(localized: "Replace the Transcript of \(bookTitle)?",
               comment: "Title of the question asked before a transcript from a file replaces an audiobook's transcript. %@ is the audiobook's title.")
    }

    /// What the confirmation explains: the transcript from the file named
    /// `fileName` replaces the book's and its text, while the audio, the
    /// place, and the bookmarks stay; then whether the user's own edits of
    /// the transcript go too, and whether its cleanup does.
    static func replaceConfirmationMessage(fileName: String, isEdited: Bool, isCleanedUp: Bool) -> String {
        var sentences = [
            String(localized: "The transcript from “\(fileName)” replaces the book's transcript and the text made from it.",
                   comment: "First sentence of the question asked before a transcript from a file replaces an audiobook's transcript. %@ is the file's name."),
            whatStays
        ]
        if isEdited {
            sentences.append(String(localized: "Your edits to the transcript are replaced too.",
                                    comment: "Sentence of the question asked before a transcript from a file replaces the book's, when the user had edited it."))
        }
        if isCleanedUp {
            sentences.append(String(localized: "Its cleanup is replaced too.",
                                    comment: "Sentence of the question asked before a transcript from a file replaces the book's, when the user had cleaned it up."))
        }
        return SentenceWording.joined(sentences)
    }

    /// The confirmation's replacing button.
    static var replaceButtonTitle: String {
        String(localized: "Replace Transcript",
               comment: "Button of the question asked before a transcript from a file replaces an audiobook's transcript, which replaces it.")
    }

    /// What VoiceOver hears as the file's transcript begins to be saved,
    /// the book's audio measured and fingerprinted, which takes seconds for
    /// a long book: "Attaching “lecture.vtt” to Moby-Dick.", in the words a
    /// transcription's start is said in ("Transcribing Moby-Dick.").
    static func attaching(fileName: String, bookTitle: String) -> String {
        String(localized: "Attaching “\(fileName)” to \(bookTitle).",
               comment: "What VoiceOver hears as a transcript file starts to be attached. %1$@ is the file's name; %2$@ is the audiobook's title.")
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
            String(localized: "Attached “\(fileName)” to \(bookTitle): \(words(wordCount)).",
                   comment: "What VoiceOver hears once a transcript file is attached. %1$@ is the file's name; %2$@ is the audiobook's title; %3$@ is the number of words, such as \"7,077 words\".")
        ]
        if skipped > 0 {
            sentences.append(String(localized: "\(skipped) timed passages couldn't be read and were left out.",
                                    comment: "Sentence added to the announcement of an attached transcript when some of the file's timed passages could not be read. %lld is how many."))
        }
        if cut > 0 {
            sentences.append(String(localized: "\(cut) timed passages were too long and were cut short.",
                                    comment: "Sentence added to the announcement of an attached transcript when some of the file's timed passages were longer than TextMouth keeps. %lld is how many."))
        }
        return SentenceWording.joined(sentences)
    }

    // MARK: Book Information

    /// The label of the read-only detail in Book Information that says where
    /// a book's transcript came from.
    static var bookInfoLabel: String {
        String(localized: "Transcript",
               comment: "Label of the detail in Book Information that says where the book's transcript came from.")
    }

    /// What VoiceOver says for the editor's Transcript detail whose line is
    /// `line`: "Transcript: Attached from “lecture.vtt” on October 30, 2026."
    /// (Details of the read-only sheet are spoken by `FeedInfoValue`.)
    static func bookInfoSpokenDetail(_ line: String) -> String {
        String(localized: "\(bookInfoLabel): \(line)",
               comment: "What VoiceOver says for a detail of Book Information. %1$@ is the detail's label; %2$@ is its value.")
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
            sentences.append(String(localized: "You edited it on \(day(edited)).",
                                    comment: "Sentence of Book Information's Transcript detail saying when the user edited the transcript. %@ is a date, such as \"October 5, 2026\"."))
        }
        if let cleaned = transcript.cleanedUp?.cleanedAt {
            sentences.append(String(localized: "You cleaned it up on \(day(cleaned)).",
                                    comment: "Sentence of Book Information's Transcript detail saying when the user cleaned up the transcript. %@ is a date, such as \"October 5, 2026\"."))
        }
        return SentenceWording.joined(sentences)
    }

    /// The line for a book whose transcript is only in the cloud, which Book
    /// Information does not download, so none of its details can be told
    /// yet: "in the cloud", as the app says it of every cloud drive, not
    /// iCloud alone.
    private static var transcriptDetailsInCloud: String {
        String(localized: "The transcript is only in the cloud. Its details appear once the book is downloaded.",
               comment: "Book Information's Transcript detail when the transcript file has not been downloaded from the cloud drive.")
    }

    // MARK: The Library Row

    /// The note after a transcribed book's title, shown and spoken.
    static var transcribedNote: String {
        String(localized: "Transcribed",
               comment: "Note after a book's title in the library, saying the audiobook has a transcript.")
    }
    /// The note while the book is being transcribed.
    static var transcribingNote: String {
        String(localized: "Transcribing",
               comment: "Note after a book's title in the library, saying the audiobook is being transcribed now.")
    }

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
        String(localized: "\(count) words",
               comment: "A count of the words of a transcript, said in an announcement. %lld is the number of words, written with the region's digit grouping.")
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
            return String(localized: "less than a minute",
                          comment: "A time estimate, said after \"Time to transcribe:\" or inside a sentence, for a transcription that takes under 45 seconds.")
        }
        let minutes = max(1, (seconds / 60).rounded())
        return String(localized: "about \(TimeFormatting.spoken(minutes * 60))",
                      comment: "A time estimate, said after \"Time to transcribe:\" or inside a sentence. %@ is a length of time in words, such as \"6 minutes\" or \"1 hour, 5 minutes\".")
    }
}
