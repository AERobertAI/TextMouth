# Transcription
<!-- id: transcription; keys: speech to text, audio to text, transcript, recognition; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Transcription in progress
<!-- id: transcription-progress; keys: speech to text, locale, language model, recognition engine, Transcribe Audio; src: TextMouth/Services/TranscriptionService.swift, TextMouth/Services/TranscriptionEngine.swift, TextMouth/Services/TranscriptionAvailability.swift, TextMouth/Services/TranscriptSentenceBuilder.swift, TextMouth/Models/TranscriptionLanguage.swift, TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouthProductionTests/TranscriptionFixtureTests.swift -->

A transcription in progress (FR05).

- Owner: TranscriptionService.shared, an actor that runs one transcription at a time: a second is refused with TranscriptionError.busy, naming the book under way.
  It checks the language and its model before reading any audio (TranscriptionEngine.prepare(locale:)).
  It plans the book's audio off the main thread (TranscriptionPlan: each file once, in the order the book plays them, measured, refusing a book with a file only in the cloud before measuring any).
  It transcribes file by file, fingerprinting each file just before it is read, through a TranscriptionEngine.
  SystemTranscriptionEngine uses SpeechAnalyzer's SpeechTranscriber on macOS 26: each file handed over as an AVAudioFile, only final results asked for, with their time ranges and confidence, and the model kept loaded between files (lingering).
  A file refused because its language isn't reserved is tried once more after reserving it, which downloads nothing.
  On an earlier system it refuses, saying that transcription needs macOS 26.
  TranscriptSentenceBuilder turns the results into sentences with the system's sentence tokenizer.
  A language nobody chose, the system's English, gives way to US English when the recognizer doesn't support it (TranscriptionLanguage.languagesToTry(in:)); a chosen one never does.
- Who may write it: the caller of transcribe(_:language:progress:), which returns the Transcript and writes nothing.
  Or the caller of transcribeAndSave(_:language:currentBook:progress:), which saves it ([Transcripts](package-records-places-and-files.md)) into the book as the library holds it once the transcription is done, while the service still counts as busy.
  Cancelling the task that awaits either stops the recognizer within a moment (cancelAndFinishNow) and throws TranscriptionError.cancelled, and nothing is written before the transcript is saved.
  In the app the caller is TranscriptionJobCenter (below), which calls transcribe and saves the transcript itself; transcribeAndSave serves the fixture tests (TranscriptionFixtureTests).
- How others observe it: TranscriptionProgress (the file's index and the count of files, the seconds done and in all, and the time elapsed) arrives on no particular thread as each file starts and as results arrive.
  TranscriptionAvailability answers what this Mac offers without downloading a model or reserving a language: whether the system can transcribe, the supported and installed languages, and each language's model status, deciding that a model is installed by the recognizer's own list.
  Every TranscriptionError has a sentence ready to show and speak.
  The language is TranscriptionLanguage.preference (transcriptionLocale), mirrored in config.json.
## The app-wide transcription job
<!-- id: app-wide-transcription-job; keys: job, progress, cancel, VoiceOver announcement, Transcribing; src: TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Platform/iOS/Services/BookTextEditor+iOS.swift, TextMouth/Services/TranscriptionService.swift, TextMouth/Services/TranscriptStore.swift, TextMouth/ViewModels/TranscribedBooks.swift, TextMouth/ViewModels/LibraryBookUpdates.swift -->

The transcription the app runs, for every window (FR05).

- Owner: TranscriptionJobCenter.shared, on the main actor: current, the TranscriptionJob under way (the book, its title, when it began, and its progress as last shown), and lastEnding, how the latest one ended (finished, with its word count and seconds; cancelled; or failed, with why).
- Who may write it: start(_:language:library:window:), from a Transcribe Audio sheet, which starts nothing while a transcription is under way.
  It transcribes off the main thread (TranscriptionService.transcribe).
  Then, with the book as the library holds it by then, it pauses the book's Edit Text session (pauseTextEdit, BookTextEditor.pauseEditing(of:)): a check running finishes, an edit saved but not yet checked is taken, and the session ends.
  It saves the transcript through TranscriptStore.install on a global queue (OffMainWork.runThrowing).
  An install that fails begins the session again (resumeTextEdit, BookTextEditor.resumeEditing(of:)), so the listener's later saves are still taken.
  TranscriptionJobCenter.cancel(), from the sheet's Cancel and from AppDelegate.applicationWillTerminate, stops it, leaving the book as it was unless its transcript was being saved already.
- How others observe it: the sheets showing it observe current, which takes the progress at most every 250 milliseconds (progressInterval), and at once when it moves to another file or is done, and lastEnding.
  VoiceOver hears the start, each quarter it passes (TranscriptionWording.milestones), and the end, from the window that started it.
  The debug log records its start, with the language, and its end, with the words found and the seconds taken, or why it failed (TranscriptionLog), naming the book by its title and never quoting a word heard.
  Once the transcript is saved, TranscribedBooks records the book, and LibraryBookUpdates.transcriptReplaced brings the text to its readers.
## Transcribe Audio sheet and dialogs
<!-- id: transcribe-audio-sheet-dialogs; keys: model download, language model, Transcribe command, context menu, sheet phases, focus; src: TextMouth/ViewModels/TranscriptionSheetModel.swift, TextMouth/Views/Transcription/TranscriptionSheet.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Services/TranscriptionModelInstaller.swift, TextMouth/Models/LibraryAudioCommand.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/App/MenuCommands.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/SpeechRefusalReportSheet.swift, TextMouth/Services/TranscriptionService.swift, TextMouth/Services/TranscriptDeletion.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/Views/Transcription/TranscriptCleanupCommands.swift -->

The Transcribe Audio sheet, and each window's transcription dialogs.

- Owner: TranscriptionPresenter, one for each Library window (LibraryTranscriptionSupport) and each reader (kept by ReaderView, which hands it to ReaderBookCommandsSupport and to SpeechRefusalReportPresenter, whose report waits while one of its dialogs shows, isShowingAny).
  It holds the Transcribe Audio sheet showing, the Clean Up sheet showing (a transcript's cleanup, below), the confirmation before Delete Transcript (TranscriptDeletionRequest), and a notice saying why a command did nothing, all shown by TranscriptionPresentation.
  TranscriptionSheetModel, one for each sheet, is in its phase (checking, unavailable, ready, transcribing, or failed) and holds:
  - the book;
  - the language, resolved as TranscriptionService resolves it (TranscriptionLanguage.languagesToTry(in:));
  - its model's status;
  - a download under way;
  - the book's transcript as transcript.json holds it (existing, with when the listener last edited it and last cleaned it up; or unreadableExisting, .inCloud or .laterVersion for one a later TextMouth wrote);
  - whether the book's text, content.md, is only in iCloud (isTextInCloud, asked of TranscriptionSheetServices.isTextInCloud, one lstat that reads nothing); and
  - another book being transcribed.
  The flag hasTranscript, true for any kind of existing transcript, decides the names Retranscribe Audio… and Retranscribe.
  The flag isBookInCloud joins a transcript only in iCloud to a text only in iCloud: either makes canTranscribe false, before any audio is transcribed, and focusTarget Cancel.
  TranscriptionSheetServices is everything the sheet asks of the system and the app, which tests replace.

### The commands that open the sheets
<!-- id: transcribe-audio-sheet-commands; keys: Transcribe Audio, Retranscribe Audio, Clean Up Transcript, Delete Transcript, LibraryAudioCommand, TranscriptionRequest; src: TextMouth/Models/LibraryAudioCommand.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/App/MenuCommands.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Services/TranscriptionModelInstaller.swift, TextMouth/Services/TranscriptDeletion.swift, TextMouth/Views/Transcription/TranscriptCleanupCommands.swift -->

- Who may write it: the commands.
  A library row offers LibraryAudioCommand.commands(for:isTranscribed:) in its context menu and as its VoiceOver actions:
  - Edit Audio… first, for one audiobook in a package of its own alone, never a feed's episode (LibraryAudioCommand.isAudioEditable(_:), which AudioEditorLauncher asks too);
  - then, for one transcribed audiobook alone, Retranscribe Audio… (LibraryAudioCommand.retranscribe, which opens the sheet as transcribe does for one book), Clean Up Transcript (Experimental)…, and Delete Transcript…, a feed's episode included, since a transcript is the listener's own work; or else
  - Transcribe Audio… when one of the books it acts on is an audiobook in a package of its own, which several books get even with a transcribed one among them.
  TranscriptionPresenter.perform(_:library:window:) hands Edit Audio… to AudioEditorLauncher ([The editor window](audio-edits.md)).
  The reader enables the Book menu's Clean Up for every transcribed audiobook (canCleanUpBookTranscript).
  The Book menu's Transcribe Audio… is named Retranscribe Audio… by TranscriptionWording.transcribeCommandTitle(hasTranscript:) while canDeleteBookTranscript says the key reader's book has a transcript.
  It and Clean Up Transcript (Experimental)… and Delete Transcript… post transcribeBookAudio, cleanUpBookTranscript, and deleteBookTranscript to the reader that takes them.
  An offer accepted after an import opens the sheet too ([Import questions](imports.md)).
  TranscriptionRequest refuses several books, or a book that isn't an audiobook, with a sentence.
  A model downloads only when Download is pressed, through TranscriptionModelInstalling (SystemTranscriptionModelInstaller, the asset inventory's installation request on macOS 26), and closing the sheet stops a download.

### How others observe the Transcribe Audio sheet
<!-- id: transcribe-audio-sheet-observers; keys: focusTarget, noticeLines, TranscriptionWording, deletion, Edit Text session; src: TextMouth/Views/Transcription/TranscriptionSheet.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptionSheetModel.swift, TextMouth/Services/TranscriptDeletion.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/ViewModels/LibraryBookUpdates.swift -->

- How others observe it: TranscriptionSheet shows the model, moving VoiceOver and keyboard focus to its first control (focusTarget, through focusing(_:first:_:)), then announcing its lines once for each phase; TranscriptionWording words everything shown and spoken.
  The ready sheet's lines are its heading (retranscribeSheetTitle once hasTranscript), the audio, the estimate, the language, and noticeLines.
  The noticeLines come in order: existingLine (or the later-version line), editedLine, cleanedLine, bookInCloudLine (the transcript's sentence before the text's), busyLine, and the download's notice.
  Both transcribeTitle and transcribeHint follow hasTranscript.
  A deletion the user confirms pauses the book's Edit Text session (pauseEditing(of:)) and runs TranscriptStore.delete(for:) on a global queue.
  It begins the session again if the deletion fails (resumeEditing(of:)).
  Then it records the book as untranscribed and tells its readers (LibraryBookUpdates.transcriptReplaced, with no text).
  While the book is being transcribed, a notice says to cancel first.
## Which audiobooks are transcribed
<!-- id: which-audiobooks-are-transcribed; keys: Transcribed badge, row note, library row, transcript.json; src: TextMouth/ViewModels/TranscribedBooks.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Views/Library/BookCloudNote.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Platform/iOS/Services/BookTextEditor+iOS.swift, TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouth/Models/LibraryAudioCommand.swift -->

Which audiobooks are transcribed.

- Owner: TranscribedBooks.shared, on the main actor: the books with a transcript (bookIDs), and the one being transcribed (transcribingBookID).
  A book's record notes its transcript in its package alone, never in library.json, so a library row can't carry it.
- Who may write it: refresh(_:), which looks for each audiobook's transcript.json off the main thread, reading and downloading nothing.
  It runs as a Library window appears, as the number of books changes, and as TextMouth becomes active (LibraryTranscriptionSupport), when another Mac sharing the library may have transcribed a book.
  And record(_:isTranscribed:), when a transcription saves a transcript or a deletion removes one, which wins over a look begun before it.
  And setTranscribing(_:), from TranscriptionJobCenter.
- How others observe it: each row's note (TranscriptionRowNote, Transcribed or Transcribing, drawn after the cloud notes by RowNoteBadge and spoken in the row's label).
  And its transcription commands (Retranscribe Audio… in place of Transcribe Audio… for a transcribed one: LibraryAudioCommand.commands(for:isTranscribed:)).
  And whether Edit Text is offered for an audiobook, a feed's episode included (BookTextEditor.canEditText(of:)), in its row and in the Book menu.
## A transcript's cleanup
<!-- id: transcript-cleanup; keys: Clean Up Transcript, preview, corrections, Apply, find and replace; src: TextMouth/ViewModels/TranscriptCleanupSheetModel.swift, TextMouth/Views/Transcription/TranscriptCleanupSheet.swift, TextMouth/Views/Transcription/TranscriptCleanupCommands.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Services/TranscriptCleanup.swift, TextMouth/Services/TranscriptCleanupStore.swift, TextMouth/Models/TranscriptCleanupWording.swift, TextMouth/Models/LibraryAudioCommand.swift, TextMouth/Services/TranscriptCleanupRuleFile.swift, TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Platform/iOS/Services/BookTextEditor+iOS.swift, TextMouth/Services/TranscriptStore.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/LibraryBookUpdates.swift -->

A transcript's cleanup (FR05, experimental): the Clean Up sheet, and what it would change.

- Owner: TranscriptCleanupSheetModel, one for each Clean Up sheet, on the main actor, in its phase (checking, unavailable, ready, working, or failed), which holds:
  - the rules in use and where they came from (TranscriptCleanupRuleFile.Lookup: transcript cleanup rules, below);
  - what they would change (TranscriptCleanup.Preview: the transcript as read, the transcript cleaned, each rule's corrections with up to three examples, and how many sentences changed); and
  - whether Undo Cleanup is offered: the transcript records a cleanup and transcript.json.before-cleanup is there, by a look that never downloads.
  TranscriptCleanup applies the rules in order to each sentence.
  A whole-word rule matches whole words, in any case and with any apostrophe, keeping the punctuation around them and a possessive after them.
  Any other rule matches inside words too, the replacement taking the case of what it replaces.
  It reads and writes nothing.
  A sentence a rule would leave with no text keeps its text, and none of its corrections is counted or listed, since the install would refuse a sentence with no text after Apply was offered.
  TranscriptCleanupServices is everything the sheet asks of the app, which tests replace.
- Who may write it: TranscriptionPresenter.cleanUp(_:library:window:), for a row's command or the Book menu's, opens one sheet at a time in a window, for any transcribed audiobook, a feed's episode included.
  The model reads the rules and the transcript off the main thread as the sheet opens (load(), on the book as the library holds it then, since a sheet left open while the book moved would look where it used to be).
  It reads them again whenever TextMouth becomes active (refresh()), as after the user edits the rules, VoiceOver hearing the sheet's lines again when anything changed.
  Apply and Undo Cleanup refuse while the book is being transcribed (TranscriptionJobCenter.current).
  Otherwise they pause the book's Edit Text session (pauseTextEdit: BookTextEditor.pauseEditing(of:)), and run TranscriptStore.cleanUp or undoCleanup ([Transcripts](package-records-places-and-files.md)) off the main thread (OffMainWork.runThrowing), on the book as the library holds it then.
  They begin the session again (resumeTextEdit) when they fail.
- How others observe it: TranscriptCleanupSheet shows the model, moving VoiceOver and keyboard focus to Apply when the rules change something and to Cancel otherwise (focusTarget, through focusing(_:first:_:)), then announcing its lines once for each phase.
  TranscriptCleanupWording words everything shown and spoken.
  A feed episode's sheet has one more line after the experimental line (feedNoteLine: TranscriptionWording.feedEpisodeTranscriptNote).
  A cleanup or an undo saved reaches the book's readers through LibraryBookUpdates.transcriptReplaced, and VoiceOver hears it from the sheet's window.
## Transcript cleanup rules
<!-- id: transcript-cleanup-rules; keys: rules file, custom rules, bundled rules, JSON format, accuracy measurement; src: TextMouth/Services/TranscriptCleanupRuleFile.swift, TextMouth/Models/TranscriptCleanupRules.swift, TextMouth/Resources/transcript-cleanup.json, TextMouth/Services/TranscriptAccuracy.swift, TextMouthProductionTests/TranscriptAccuracyMeasurementTests.swift, TextMouth/Services/SavedFile.swift, TextMouth/Services/TextMouthPaths.swift -->

Transcript cleanup rules (FR05, experimental): TextMouth's own, and the user's copy.

- Owner: TranscriptCleanupRuleFile.
  TextMouth's own rules are transcript-cleanup.json in the app's bundle (Resources/transcript-cleanup.json: format 1, version 1 of `2026-10-04`, its rule list empty, with an about and two worked examples that nothing applies).
  The user's copy, transcript-cleanup.json at the data directory's root beside substitutions.json (TextMouthPaths.transcriptCleanupRulesFile), is used instead whenever it is there and usable.
  TranscriptCleanupRuleSet holds a file's format, version, date, and rules (TranscriptCleanupRule: pattern, replacement, wholeWord, evidence, and note).
  It refuses a file, naming the first field at fault and never quoting a rule, if:
  - its format isn't 1;
  - its version is below 1;
  - its date isn't a day written as YYYY-MM-DD; or
  - one of its rules has an empty pattern or replacement, a pattern without a letter or figure, a whole-word pattern with a word of punctuation alone, negative evidence, or a replacement its own pattern matches, which every cleanup would change again.
- Who may write it: the user, in their own editor.
  TextMouth writes the copy only through prepareUserCopy, for the Clean Up sheet's Edit Rules…, as storage work, and only when there is none: it writes its own file there exactly, staged beside it and moved into place, which fails rather than replace a copy that arrived meanwhile.
  A copy that is there, usable or not, or only in the cloud, is never written over, and nothing is written while the data directory is unavailable.
- How others observe it: load(userCopyAt:reader:builtIn:), off the main thread, as the sheet opens and as TextMouth becomes active, reads the copy as substitutions.json is read (SavedFile, with dataless files left in the cloud).
  A copy only in the cloud is asked of the sync service, and one that can't be read or used is preserved beside itself (SavedFile.preserveUnusable), TextMouth's own rules standing in for either while the sheet says why.
  While the data directory is unavailable, nothing is read and TextMouth's own rules are used.
  A TRANSCRIPT_CLEANUP_RULES line tells of each wait and preserved copy, and the sheet says when TextMouth's own rules have a newer version than the copy.
  A cleaned transcript records the rules' version, date, and source.
  TextMouth's own rules were derived with TranscriptAccuracy from speech whose text is known (research/TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md), which the opt-in TranscriptAccuracyMeasurementTests measure again.
## A transcript that comes from a file
<!-- id: transcript-that-comes-from-file; keys: subtitles, captions, .vtt, .srt, timed text, Podcasting 2.0; src: TextMouth/Services/OutsideTranscript.swift, TextMouth/Services/TranscriptPairing.swift, TextMouth/Parsers/TimedTextReader.swift, TextMouth/Parsers/PodcastTranscriptReader.swift -->

A transcript that comes from a file (FMT23, FMT25; 0.4.2): a WebVTT or SubRip file, or a podcast's own transcript, instead of recognition.

### Where a file transcript is kept
<!-- id: where-file-transcript-kept; keys: cue limits, transcript.json, TranscriptSource, speaker voice, size caps; src: TextMouth/Models/TimedText.swift, TextMouth/Services/OutsideTranscript.swift, TextMouth/Services/TranscriptStore.swift, TextMouth/Models/Transcript.swift, TextMouth/Parsers/TimedTextReader.swift, TextMouth/Parsers/PodcastTranscriptReader.swift, TextMouth/Parsers/TimedTextMarkup.swift -->

Owner: TranscriptStore keeps it as it keeps recognition's, in transcript.json.
It records where it came from in a TranscriptSource (Models/Transcript.swift): an Origin of attached, imported, or podcast, the file's name, a TimedTextFormat, and, since 0.4.3, formats.
The formats are the raw values of every format the files were of, each once, in the order they were read, when files of more than one format were read (01.vtt beside one track and 02.srt beside another).
Otherwise it is nil, as in every transcript an earlier TextMouth wrote, which cannot read the field and keeps format as the first file's.
The field knownFormats is nil when a later TextMouth wrote a format this one does not know, and an imported transcript is then worded "Attached from files when the book was imported, on …".
For imported files of several formats it says "Attached from WebVTT and SubRip files when the book was imported, on …".
An origin or a format a later TextMouth wrote, which this one can't name, is read as unknown and worded "Attached on …".
The files are read by TimedTextReader (WebVTT, SubRip) and PodcastTranscriptReader (Podcasting 2.0 JSON, whose one-word segments of one speaker gather into sentences of at most 60 words, split by a gap of a second), through TimedTextMarkup.
TimedTextLimits: 20 MB for a file from this Mac, 5 MB for a podcast transcript, 1 MB for chapters, 250,000 cues, and 5 seconds past the audio's end for a last cue.
Since 0.4.3 it also holds the limits on a cue:
- maximumCueMilliseconds, 1,000 hours (3,600,000,000 ms): the latest a WebVTT or SubRip cue may end.
  A book's whole transcript is one file timed on the book's timeline, so its times run past the 100 hours a single audio file may last (Transcript.maximumMilliseconds).
  OutsideTranscript cuts them into the book's files afterwards, each time counted from its file's start.
- maximumCueCharacters, 10,000: the most a cue's text keeps, and maximumVoiceNameCharacters, 100, for a speaker's name.
  Reading stops at the cap, so a 5 MB cue costs the cap and not the file, and a Podcasting 2.0 reader gathers no words past it.
  TimedText.finishedText(of:characterLimit:) cuts the text back to where a sentence ends in its second half, failing that to the last space, failing that at the limit; a cut that falls between two words on a sentence's end goes back nothing.
  TimedTextCue.isCutShort marks the cue, and TimedTextDocument counts them (cutCueCount) for the Attach announcement (TranscriptionWording.attached(…cut:)), "1 timed passage was too long and was cut short."
- OutsideTranscript.withinTheLimitOfAFile(_:) holds a sentence to one audio file's 100 hours: nil for a sentence that starts past Transcript.maximumMilliseconds, and one that runs past it ends there, its words kept only when each still ends inside it.
  Span.place calls it for Attach (transcript(bookTimeline:)), and transcript(sentencesByFile:), a track's own file at import, filters through it, so a file longer than 100 hours is left out past its hundredth hour and not refused whole as unusable.
  The Attach announcement adds the sentences left out to the passages it could not read.
  At import the cues left out are not counted or logged.
  OutsideTranscript turns the cues into a Transcript.

### Who writes a file transcript
<!-- id: who-writes-file-transcript; keys: import, Attach Transcript, podcast episode, named pipe; src: TextMouth/Services/TranscriptPairing.swift, TextMouth/Services/FileImportService.swift, TextMouth/ViewModels/TranscriptAttachments.swift, TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/Services/Feeds/FeedEpisodeExtras.swift -->

Who may write it: TranscriptPairing at import, which finds a .vtt, else .srt, named as a track is (besideFile for a single file, inFolder for tracks, a ZIP, or a playlist), tried in lower and upper case.
It never fails an import: a file that can't be used becomes ImportedBook.notice (TranscriptionWording.transcriptNotAttached, transcriptsNotAttached).
Attach Transcript…, in ReaderBookCommands, through TranscriptAttachments (ViewModels/TranscriptAttachments.swift), a main-actor record of the books being attached to, with a deinit safety net, that both Attach and Transcribe Audio… ask (canAttach, canTranscribe).
It reads only a plain file, so a named pipe can't hang it.
FeedEpisodeExtras, for a podcast (see Feeds).

### A transcript file chosen with its audio
<!-- id: transcript-file-chosen-audio; keys: drag and drop, Open Book, Finder, Dock, unsupported format, iPhone import; src: TextMouth/Services/TranscriptPairing.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/Services/FileImportService.swift, TextMouth/Platform/iOS/Services/PhoneImportCopier.swift -->

A transcript file chosen with its audio (0.4.3): TranscriptPairing.droppingTranscriptsChosenWithTheirAudio(_:) takes out of the items to import each .vtt or .srt that a chosen audio file finds as its transcript (besideFile), since the audio's import attaches it.
Both loops over user-chosen items call it, importAndOpenFiles (Finder, the Dock, and the router's openFiles) and importFiles (Open Book…).
A transcript file chosen alone, or beside audio that does not find it, stays in the list and is refused by FileImportError.unsupportedFormat, whose sentence for a .vtt or .srt is "Unsupported file format: .vtt.
A .vtt file is a transcript, not a book.
To use it, import its audio, open the book, and choose Attach Transcript… from the Book menu."
A transcript chosen with an audio file whose import is then skipped is dropped silently, and is untested.
The iOS PhoneImportCopier calls the same filtered functions, and whether its copies sit beside each other for the lookup was not checked.

### Transcribe Audio waits while attaching
<!-- id: transcribe-audio-waits-while-attaching; keys: notice, one book at a time, Attach; src: TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptAttachments.swift -->

Transcribe Audio… waits (0.4.3): TranscriptionPresenter.transcribe shows the notice TranscriptionWording.transcribeWhileAttaching only for a request of one book that TranscriptAttachments.shared.bookIDs holds.
A request for several books gets the sheet that says transcription works on one book at a time, whatever is being attached.

### Installing and replacing a transcript
<!-- id: installing-replacing-transcript; keys: Replace Existing, duplicate, provenance, untouched, import question; src: TextMouth/Services/TranscriptInstallation.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Models/ImportDecision.swift -->

Installing: TranscriptInstallation takes the transcript into the book's storage work.
Its parameter givingWayToAnUntouchedPodcastTranscript is judged inside that work, by holdsUntouchedPodcastTranscript(in:), so an edit made between the check and the install is kept.

Replace Existing: DuplicateReplacement.transcriptOutcome(replacing:with:) returns asBefore, keepsExisting, or broughtReplacesExisting.
It reads the old transcript's provenance without its sentences (TranscriptStore.provenance), downloading nothing.
The old transcript gives way only when it has a source and isTouched is false, and the question (ImportDecisionWording.replacingKeepsSentence) and the replacement both ask the same function, so they never disagree.
The library row follows what the new package holds.

### How others observe a file transcript
<!-- id: how-others-observe-file-transcript; keys: Book Information, Transcript detail, content.md, existing line; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptBookInfoModel.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/ViewModels/TranscribedBooks.swift -->

How others observe it: Book Information's Transcript detail (TranscriptionWording.bookInfoLine, bookInfoSpokenDetail) and the Transcribe Audio sheet's existing line (outsideTranscript).
The book's text is written from the transcript the first time the book opens (TranscriptTextLoader), and TranscribedBooks lists it at once.
