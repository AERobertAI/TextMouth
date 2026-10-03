# TextMouth architecture

This document explains how TextMouth is put together and, above all, which part of the app owns each kind of state: who keeps it, who may change it, and how everything else finds out about a change. It describes main as of October 3, 2026. When a change moves the ownership of some state, update its entry here in the same branch.

README.md covers building, testing, and the files in the data directory. Paths below are relative to the TextMouth source folder unless they start with the name of another top-level folder, and names in the text are the names of Swift types, functions, and properties.

## The parts of the app

- One SwiftUI application. TextMouthApp (App/TextMouthApp.swift) declares three kinds of window:
  - Library windows (LibraryWindowView, ContentView, and LibraryView). The first opens at launch, and Command-N opens more.
  - Reader windows, one per book, identified by the book's ID (BookReaderWindowView, in the scene whose ID is BookReaderWindowView.windowID). Window restoration is off, so none reopen at launch.
  - The Settings window (SettingsView), with eight tabs.
- App-wide objects, created once by TextMouthApp and given to every window as environment objects:
  - LibraryViewModel: the library in memory, and every operation on it.
  - SettingsViewModel: the global settings, and the config.json mirror.
  - KeyboardShortcutManager: every action's keyboard shortcuts.
  - SoundEffectService: the sounds that playback events play.
  - LibraryWindowRouter.shared: which window takes each app-wide action.
- AppDelegate (App/AppDelegate.swift) starts the router before Finder can hand over a file, owns MenuVisibilityManager, turns off window restoration, and asks before quitting with unsaved changes.
- Each reader window has its own ReaderViewModel, which has its own SpeechService, AudioPlaybackService, and NowPlayingSession. Readers share SleepTimerService.shared, ReadingStatsService.shared, TextSubstitutionService.shared, ReaderAutoplayRequests.shared, and SpeechRenderCoordinator.shared.
- The source folders:
  - App: the entry point, the delegate, the menu commands, the build identity, the process runtime (TextMouthRuntime), and the check made before quitting.
  - Models: value types and small rule tables, such as Book, BookInfo, Library, BookContentIndex, SettingsPolicy, StoredPreference, and the wording helpers.
  - Parsers: one reader per format, each turning a source file into DocumentContent (chapters, headings, and an index), plus shared readers for archives, packages, and text encodings.
  - Services: everything that owns a file, a queue, or a system resource.
  - ViewModels: LibraryViewModel and ReaderViewModel, each split into extensions by topic, plus SettingsViewModel, BookSearchModel, and LibraryBookUpdates.
  - Views: the SwiftUI views of the library, the reader, and settings, plus VoiceOverFocus.swift, which places VoiceOver's focus in new windows and sheets.
- Concurrency: the view models, the window router, the settings mirror, the sleep timer, and the statistics run on the main actor. Disk work runs on queues that each own their work: serial queues for the library index and for package records (LibraryPersistenceService), for imports (SerialImportQueue), and for logs (TextMouthPaths), and at most two workers for cache updates (TextCacheUpdateQueue). The app target builds in the Swift 5 language mode with minimal concurrency checking; the coding agents' test runs turn on complete checking.

## Launch

- AppDelegate.applicationWillFinishLaunching starts the router before any window exists, so a book Finder hands over waits for the first Library window instead of opening a second.
- LibraryViewModel's initializer copies a sandboxed release's data on first launch (through DataDirectoryMigrator, keeping the original), creates the data directory's folders, removes leftover archive extraction folders, and loads the library index (loadLibraryIndex).
- Loading repairs the index against the disk (migrateOldBooksIfNeeded): books removed with Remove from Library Only stay out, equivalent folder rows merge, stale file paths are fixed, legacy books move into packages, packages that two books shared are separated, misplaced packages move into their folders, packages missing from the index are adopted, and the result is saved. An unreadable index skips all of this and enters recovery instead (below).
- LibraryViewModel then brings every book's text cache up to date, and after that its statistics, in the background (updateContentCachesAndStatistics).
- SettingsViewModel's initializer applies config.json, reconciles it with the preferences, and starts ConfigService watching the file.

## Who owns each kind of state

Each entry names a kind of state, then its owner, who may write it, how others observe it, and the files involved.

### The library index

- The library: every book's row, the folders, and each location's sort.
  - Owner: LibraryViewModel.library, published on the main actor. It is the live copy; library.json is its saved form.
  - Who may write it: LibraryViewModel and its extensions, on the main actor. Each change is followed by save(), which hands a snapshot to LibraryPersistenceService.save(_:). That waits half a second on the service's serial queue, and only the newest snapshot is written, so an older snapshot never lands after a newer one. flushPendingSave() writes a waiting snapshot before the app quits. Every write replaces library.json atomically.
  - How others observe it: SwiftUI views observe LibraryViewModel. A reader takes a copy of its book when it opens and reports back through LibraryViewModel: updateLiveReadingPosition (the row in memory, saving nothing), persistReadingPosition (the row and the package record), and updateContentIndex. Every change of library is also offered to LibraryViewModel.bookUpdates, which keeps the copies of open readers current (a reader's copy of its book, below).
  - Files: Models/Library.swift, ViewModels/LibraryViewModel.swift and its extensions, Services/LibraryPersistenceService.swift, Services/LibraryLoadResult.swift.
- Index-write suspension: what protects an index that cannot be read.
  - Owner: LibraryPersistenceService. The flag lives on its save queue, beside the waiting snapshot.
  - Who may write it: load() suspends index writes when library.json exists but cannot be read, after LibraryIndexQuarantine has preserved its bytes as library.json.unreadable- followed by the date and time. Only resumeIndexWrites() (Try Again, once the index reads) and replaceUnreadableIndex(with:) (Rebuild Library Index, which first preserves whatever is there) end it. LibraryViewModel+IndexRecovery drives both.
  - How others observe it: LibraryViewModel.indexRecovery is set while recovering, and the Library window shows the recovery banner and its Recovery Options…. Snapshots taken meanwhile are dropped, never kept for later. areIndexWritesSuspended makes data-directory moves refuse. Package records are still written, so reading positions are not lost.
  - Files: Services/LibraryPersistenceService.swift, Services/LibraryIndexQuarantine.swift, ViewModels/LibraryViewModel+IndexRecovery.swift, Views/Library/LibraryIndexRecoveryViews.swift.
- Retirement markers: books removed with Remove from Library Only.
  - Owner: the marker file in the package, removedFromLibrary.json (RemovedFromLibraryMarker), together with LibraryPersistenceService's set of retired packages on its metadata queue.
  - Who may write it: LibraryPersistenceService.retirePackage(of:) writes the marker first. Only once it is on disk does it cancel the writes queued for the book, remember the package, and delete bookInfo.json, a courtesy to older versions of TextMouth. reinstatePackage(of:) deletes the marker when the package is deliberately taken back, by importing it again or adopting it.
  - How others observe it: every package record write checks the set and drops writes into a retired package; orphan adoption skips a package whose marker names its record's book; launch removes retired books from an index saved before their removal.
  - Files: Models/RemovedFromLibraryMarker.swift, Services/LibraryPersistenceService.swift, Services/FileImportService.swift, Services/FileImportService+Packages.swift.

### Package records

- bookInfo.json: each package's record of its book.
  - Owner: LibraryPersistenceService's metadata queue, for every save the running library makes. The record is built from a Book by Book.bookInfo(replacing:contentIndex:revisionFloor:).
  - Who may write it: saveBookInfo(for:) and saveBookInfo(for:contentIndex:), which hold each book's newest snapshot for half a second and write only it; saveContentAnalysis (below); and flushPendingSave(). Imports, folder moves, and migrations write records directly with Book.saveBookInfoThrowing, under the same revision rules but outside the queue's order.
  - How others observe it: content analysis reads the saved index and fingerprints from it (Book.storedBookInfo()), and saveContentAnalysis reads it back as a Book (Book(record:filePath:folderPath:tmbDirectoryName:)) to merge an analysis into. Orphan adoption, which also builds the provisional library while the index cannot be read, and importing a .tmb package rebuild library rows from records with two hand-written copies of that initializer in FileImportService.
  - Files: Models/BookInfo.swift, Models/Book.swift, Services/LibraryPersistenceService.swift.
- Revisions.
  - Owner: BookState.revision, in each record.
  - Who may write it: every write stores one more than the record it replaces, and never less than one more than the highest revision this process has written for the book, so a book's revisions only rise, across restarts too.
  - How others observe it: no decision rests on a revision. Whether an analysis still applies is decided by the book's content (below).
  - Files: Models/BookInfo.swift, Models/Book.swift, Services/LibraryPersistenceService.swift.
- Analysis-owned fields.
  - Owner: the content analysis. Book.ContentAnalysisFields (the word and character counts, the audio duration, the content index version, the cache format version, and the text cache fingerprint) travel together with the content index.
  - Who may write it: LibraryPersistenceService.saveContentAnalysis merges a finished analysis into the book's latest durable state, on the metadata queue: the snapshot still waiting there, or else the record on disk. Only the analysis fields and the index change. A result is dropped, with one CONTENT_ANALYSIS_DROPPED log line, when that state describes other content: another MD5 hash, format, or file path, or another book's record. A save that carries no index keeps the stored index and its fields, so neither kind of write undoes the other. The reader commits a fresh index of its own through LibraryViewModel.updateContentIndex.
  - How others observe it: a library row takes the committed fields and keeps its own reading state, settings, and metadata.
  - Files: Models/Book.swift, Services/LibraryPersistenceService.swift, ViewModels/LibraryViewModel+BookOperations.swift, ViewModels/LibraryViewModel+Migration.swift.

### Text caches and content indexes

- content.md: each text book's text cache, its text as Markdown.
  - Owner: MarkdownCacheService. The format's version is MarkdownCacheService.currentCacheVersion ("3.0.7"), and a book whose recorded cacheFormatVersion is older is extracted again.
  - Who may write it: MarkdownCacheService alone, which writes a new cache only after extraction succeeds and replaces the old one atomically. generateCacheContent runs inside BookContentAnalysisService.load: when an import reads its new book, when a reader opens a book whose cache is missing or outdated, and when a stale cache is rebuilt. generateCacheAnalyzeAndStamp runs for startup maintenance (extractMissingContentCaches, through TextCacheUpdateQueue, which runs ordinary EPUBs on two utility workers and everything else one at a time), for Redo Text Extraction in Storage settings, and for the legacy migration.
  - How others observe it: BookContentAnalysisService.load reads it and parses it into DocumentContent.
  - Files: Services/MarkdownCacheService.swift, Services/TextCacheUpdateQueue.swift, Services/BookContentAnalysisService.swift, ViewModels/LibraryViewModel+Migration.swift.
- The content index (BookContentIndex): chapter starts and lengths, word counts, headings with their offsets, totals, and, for audiobooks, the media layout and timing, with every clip of a chapter that plays several.
  - Owner: the package record, as bookInfo.json's contentIndex. Its version is BookContentIndex.currentVersion ("1.0.0"). library.json keeps only the totals and contentIndexVersion, so launch never decodes every heading in the library.
  - Who may write it: BookContentAnalysisService builds it (BookContentIndex.build) from parsed content, and it is saved only through LibraryPersistenceService (saveContentAnalysis or saveBookInfo(for:contentIndex:)).
  - How others observe it: BookContentAnalysisService.load uses a saved index only when it passes validationFailure(for:audioBaseURL:) and, for a text book, alignmentFailure(with:countingWords:) against the parsed chapters. One that fails is logged as CONTENT_INDEX_REJECTED and replaced by a fresh index. The reader takes headings, chapter offsets, and totals from the index inside its DocumentContent.
  - Which version to change: a change to source extraction changes MarkdownCacheService.currentCacheVersion. A change only to how the reading text or the index is derived changes BookContentIndex.currentVersion instead, so existing Markdown is indexed again without converting every source. Reading Markdown tables a row at a time (each row a paragraph, its cells one space apart, the table set apart from the text around it, as HTMLReadingText reads an HTML table) changed neither version: content.md is unchanged, and the change only adds breaks and spaces, so the saved index of every book it affects, a DOCX or Markdown book holding a Markdown table, no longer lines up with its reading text, fails the alignment check once (CONTENT_INDEX_REJECTED), and is rebuilt from the cache.
  - Files: Models/BookContentIndex.swift, Models/DocumentContent.swift, Services/BookContentAnalysisService.swift.
- Text cache fingerprints (TextCacheFingerprint): for the source and for content.md, the size, the modification time in nanoseconds, and the MD5 digest, as they were when the cache was written.
  - Owner: the package record (state.textCacheFingerprint, also copied into the index), mirrored on the library row.
  - Who may write it: MarkdownCacheService records them when it writes a cache. BookContentAnalysisService fingerprints a current cache written before fingerprints existed, once, the first time the cache passes every check; that result is saved by the usual save.
  - How others observe it: BookContentAnalysisService.loadExistingCache compares the files' sizes and dates with the record before it trusts the cache or its index, and reads a file for its digest only when the size is unchanged but the date is not. A changed file is logged as CACHE_STALE and the cache is rebuilt from the source. Startup maintenance compares the sizes the library row recorded with the files, two stat calls a book, to find stale caches without reading anything, and completedTextCacheIndex checks a package's record when recovering an interrupted batch.
  - Files: Models/TextCacheFingerprint.swift, Services/BookContentAnalysisService.swift, Services/MarkdownCacheService.swift, ViewModels/LibraryViewModel+Migration.swift.

### The data directory

- Its location, and moving it.
  - Owner: TextMouthPaths, whose root is the data directory in use: ~/.TextMouth, or the folder the textMouthDataDirectory preference names, which a test host ignores.
  - Who may write it: only a published move. Change Location and Reset to Default in Storage settings, and a changed dataDirectoryPath in config.json, reach the move in LibraryViewModel+Migration, which refuses while the index cannot be read. TextMouthPaths.moveDataDirectory(to:library:) has DataDirectoryMigrator copy the data, and changes the preference and the library only once the copy is published. The migrator takes each location as the real folder its links lead to (DataDirectoryLocation): a data directory that is a link is copied from its folder, and a new location that is a link to an empty folder receives the data in that folder, the link staying as it is. Before copying, it refuses overlapping real folders, naming both, a link that leads nowhere, a file at the new location, and a folder that is not empty. It copies into a hidden staging folder (.TextMouth-migration- followed by a UUID) beside the new location's real folder, points the copy's package records and library.json at the new location, and checks them. It then looks again: the name must still lead to the same folder, and that folder must still be empty or missing. It removes nothing but an empty folder, with rmdir, which the kernel refuses once anything is inside, and publishes the copy with one rename (moveItem, which never replaces an item). Anything that arrives meanwhile stops the move: the staged copy is deleted, whatever arrived stays, and the data directory in use and its setting stay as they were.
  - How others observe it: config.json's dataDirectoryPath names the folder in use after every attempt. The Storage settings status line, which VoiceOver announces once, or else the library's alert, says "Done. Data is now at…", naming the folder a link leads to, or why nothing moved, naming what arrived and where. The library's new rows reach open readers through LibraryViewModel.bookUpdates. The old folder is left where it was.
  - Files: Services/DataDirectoryMigrator.swift, Services/TextMouthPaths.swift, ViewModels/LibraryViewModel+Migration.swift, Views/Settings/StorageSettingsView.swift.

### Preferences

- The preferences store.
  - Owner: TextMouthRuntime.current.preferences, which is UserDefaults.standard in the app and a sandboxed store under hosted tests. Each preference has one owner that reads and writes it:
    - SettingsViewModel: the Voice, Playback, and Miscellaneous settings, through properties backed by @AppStorage.
    - SoundEffectService: whether sounds play, their volume, and each event's sound.
    - TextSubstitutionService: whether the substitution rules apply, and the repeated-symbol style, threshold, and symbol set (repeatedSymbolStyle, repeatedSymbolThreshold, and repeatedSymbolSet), which that switch does not affect. It also owns the rules, kept in substitutions.json.
    - KeyboardShortcutManager: every action's shortcuts, under customKeyboardBindings.
    - SleepTimerService: the last timer started, under sleepTimer.lastUsedDuration.
    - TextMouthPaths: the data directory's location, under textMouthDataDirectory.
    - DiagnosticLog.TraceSwitch: the hidden trace-logging switch, diagnosticTraceLogging.
  - Who may write it: each preference's owner, through its StoredPreference definition (the key, how the value is read, and how it is written, in one place) or its @AppStorage property. SettingsViewModel also applies config.json's values, using the services' own definitions for theirs.
  - How others observe it: SettingsViewModel publishes its own changes and increments a revision that open playback bars watch. PreferenceObserver (key-value observing) tells SettingsViewModel when a service-owned key changes, so config.json follows. SpeechService reads the speed, pitch, and voice from its store through SettingsPolicy.
  - Files: Models/StoredPreference.swift, ViewModels/SettingsViewModel.swift, Services/SoundEffectService.swift, Services/TextSubstitutionService.swift, Services/KeyboardShortcutManager.swift, Services/SleepTimerService.swift, App/TextMouthRuntime.swift.
- The config.json mirror.
  - Owner: ConfigService.shared, on the main actor. Its config property holds the file's values. While TextMouth runs, the preferences store is the source of truth and config.json follows it; at launch, the file is applied first, because it can change while TextMouth is closed.
  - Who may write it: SettingsViewModel, after each settings change (syncToConfig) and when reconciling at launch, and the Storage settings for the three choices only the file holds. ConfigService.saveToDisk first merges any outside edit not yet handled, writes nothing when the file already holds the same bytes, and reports a failed save to PersistenceFailureCenter.
  - How others observe it: a file-system watcher notices saved edits, tells them from TextMouth's own saves by their bytes, and publishes each once through externalEdits, which SettingsViewModel.applyConfigChanges applies. A changed dataDirectoryPath posts dataDirectoryChangeRequested, and LibraryViewModel moves the data directory.
  - Files: Services/ConfigService.swift, ViewModels/SettingsViewModel.swift, Models/LenientFields.swift.
- The policy table.
  - Owner: SettingsPolicy, the single table of validated preferences. Each rule (NumericSettingRule, EnumSettingRule, KeyedSettingRule, ThresholdSettingRule, or CharacterSetSettingRule) states a key, the supported range, cases, or characters, the default, and, for speed and pitch, the value meaning "not chosen yet", or, for the repeated-symbol threshold, the value that switches it off (-1).
  - Who may write it: no one while the app runs; it is a static table whose ranges match the Settings controls.
  - How others observe it: decoding config.json (LenientFields), applying it, reading @AppStorage values, services reading the store directly, and decoding per-book speed and pitch from bookInfo.json and library.json all pass values through it. ConfigService.AppConfig.Portability lists which preferences config.json mirrors, which only it holds, and which stay on this Mac; the tests take their expectations from those lists.
  - Files: Models/SettingsPolicy.swift, Models/LenientFields.swift, Services/ConfigService.swift.

### The reader

- A reader's state: its content, cursor (chapter and character offset), headings, bookmarks, playback flags, and errors.
  - Owner: one ReaderViewModel per reader window, on the main actor, created by BookReaderWindowView with a copy of the library's Book.
  - Who may write it: the reader itself, in its extensions: Playback, Navigation, Bookmarks, Jump, VoiceAndSpeed, WhereAmI, and LibraryUpdates.
  - How others observe it: ReaderView and its subviews observe the reader, refreshed at most every 0.12 seconds during playback. The library sees the cursor through LibraryViewModel: the live position about once a second (updateLiveReadingPosition), and a durable checkpoint (persistReadingPosition) every 30 seconds of active playback (PlaybackCheckpointPolicy) and whenever the reader pauses, stops, closes, finishes a chapter, or navigates.
  - Files: ViewModels/ReaderViewModel.swift and the ReaderViewModel+ extensions, Views/Reader/.
- A reader's copy of its book.
  - Owner: ReaderViewModel.book, a copy of the library's row taken when the reader opens. Its library fields (Book.LibraryFields: where the book's files are, its editable metadata, and the content analysis fields) follow the library; the rest (the position, bookmarks, voice, speed, and other per-book settings) is the reader's own, and the reader writes each change of it through to the library.
  - Who may write it: the reader, for its own fields and for the metadata its editor saves through the library. Otherwise the library fields change only through LibraryViewModel.bookUpdates (LibraryBookUpdates). LibraryViewModel offers it every change of library, and whenever a book open in a reader has library fields other than those its readers were last given, they receive its row with the book's next revision; no change to the reader's own fields is published, so those never come back to it. A package's move on disk is bracketed: commitLibraryTransition, and a folder rename that only respells the folder, call packagesWillMove before anything moves and packagesDidMove once the library holds the new rows or the move has been put back.
  - How others observe it: ReaderViewModel+LibraryUpdates applies only updates newer than the last it applied, without reloading the text or interrupting speech. A new path points the audio at the files where they are now, and new metadata reaches the metadata editor's starting values and Now Playing; the window title, Where Am I?, and announcements read the copy itself. Audio that is playing when a move is announced stops and releases its file, then plays on from the same place once the move ends; paused audio loads again when it resumes. A load that fails because the book moved meanwhile starts again from the new path.
  - Files: ViewModels/LibraryBookUpdates.swift, ViewModels/ReaderViewModel+LibraryUpdates.swift, ViewModels/LibraryViewModel.swift, ViewModels/LibraryViewModel+BookOperations.swift, ViewModels/LibraryViewModel+FolderManagement.swift, Models/Book.swift.
- The playback generation.
  - Owner: ReaderViewModel.chapterPlaybackGeneration, and the ChapterPlay token of each play: the chapter it plays and the generation it began in.
  - Who may write it: beginChapterPlay(), which every start of a chapter's speech or audio calls (Play, a resume that starts the chapter again, a chapter advance, or a loop), increases it and returns the new play's token; a move to another chapter, by navigation or a skip, and a loop increase it as well.
  - How others observe it: each play hands its speech or audio service a completion callback made for that play (listenForSpeechEnd, listenForAudioEnd). The end the service reports moves the reader on from the chapter that played only while that play's generation is still current (endsPlayUnderWay); the end of a play the reader has left, or one reported after the reader closed, is logged as one trace line and ignored. Look-ahead renders are kept only within the generation they began in.
  - Files: ViewModels/ReaderViewModel.swift, ViewModels/ReaderViewModel+Navigation.swift, ViewModels/ReaderViewModel+Playback.swift.
- The look-ahead and its render signature.
  - Owner: ReaderViewModel.lookAhead: the next speakable chapter's index, the SpeechRenderSignature its render was asked for (a hash and length of the exact spoken text, and the voice), and the AudioEngineService that holds the audio.
  - Who may write it: preRenderNextChapter(), after each chapter starts; refreshLookAhead(), whenever the voice, the substitution rules or their switch, the repeated-symbol settings, the punctuation pause level, or the skipped sections change (speed and pitch do not count, because they are applied as the audio plays); and discardLookAhead(). Renders wait their turn on SpeechRenderCoordinator.shared, which never lets two calls of AVSpeechSynthesizer.write() overlap.
  - How others observe it: at a chapter's end, takeLookAheadEngine(for:) hands over the engine only when it holds finished audio whose renderedSignature equals the signature of the chapter's speech prepared now. Otherwise the chapter starts from its current text.
  - Files: ViewModels/ReaderViewModel+Playback.swift, Services/AudioEngineService.swift, Services/SpeechService.swift.
- Autoplay requests: Continue to Next Book.
  - Owner: ReaderAutoplayRequests.shared: at most one request per book, usable for 30 seconds, claimed at most once.
  - Who may write it: a reader whose book ends with Continue to Next Book finds the next book with LibraryViewModel.nextBookInFolder(after:), which follows the folder's manual order as the list shows it (ManualBookOrder.orderedBooks), announces it, leaves a request for it, and posts continueToNextBook. LibraryWindowRouter then opens that book's reader, or brings it forward.
  - How others observe it: the next book's reader claims the request when it finishes loading, or at once when it was already open and loaded, and starts playing. A reader that cannot load its book discards the request.
  - Files: Services/ReaderAutoplayRequests.swift, ViewModels/ReaderViewModel+Playback.swift, ViewModels/LibraryViewModel+SortAndOrder.swift, Services/LibraryWindowRouter.swift.

### Media playback

- Speech, for text books.
  - Owner: each reader's SpeechService. speak() starts the text at once with AVSpeechSynthesizer.speak(), the direct mode, and, for a text of at most SpeechRenderCoordinator.maximumTextLength UTF-16 units, renders the same text in the background into an AudioEngineService (AVAudioEngine with a time-pitch unit, for instant seeking and speed changes). The rendered audio takes over only at a natural break: a seek, a pause and resume, a sleep timer's fade, or the next chapter through the look-ahead. Speech never hands over from direct mode to rendered audio while it runs uninterrupted, because the synthesizer's word callbacks run ahead of the sound by an amount that cannot be known.
  - Who may write it: the reader, through speak, pause, resume, seek, and stop.
  - How others observe it: the reader sets onWordSpoken, which moves its cursor through the offset map, and, for each play, onUtteranceFinished (the playback generation, above), and mirrors whether speech is playing or paused and its speed. A finished utterance is held until its finish is handled on the main queue, so a new utterance made at a reused address can never take that finish for its own. Switches between the modes are logged in textmouth_transition.log.
  - Files: Services/SpeechService.swift, Services/AudioEngineService.swift.
- Audiobook playback, and its failures.
  - Owner: each reader's AudioPlaybackService, which plays files with AVPlayer at a speed held to the steps AudioSpeed.normalized(_:) allows. A chapter is a whole file, a time range within one, or, in a segmented book such as a DAISY audiobook, a section (AudioSegment) holding a list of clips, each a time range of a file. playClips(_:fromChapterTime:) plays a section's clips one after another as one chain (AudioClipChain), timed from the chapter's start whichever clip and file are playing. DAISYAudioConverter (Parsers/DAISYParser+Audio.swift) gathers every clip a heading plays, up to the next heading and across files, when the book is imported, and the content index records and validates every clip.
  - Who may write it: the reader (playAudioChapter, setAudioSpeed, retryAudioPlayback).
  - How others observe it: what plays ends once. Every load, play from a time, seek, stop, and finish begins a new play (AudioPlaybackGeneration), and AudioEndNoticePolicy judges each of AVFoundation's end-of-file notices by the generation and the playhead read when it was posted. The notice ends the play under way; or it is held while playback is paused, and finishes the play when it resumes; or it is ignored, when it was posted during an earlier play; or, as the late end of an earlier playthrough of the same file, it is ignored while the play under way starts again on a fresh player. onPlaybackFinished is called once for each play that runs to its end, never while paused. A file that cannot be played is reported through one channel, AudioPlaybackService.failure (an AudioPlaybackFailure naming the file) and onPlaybackFailed, and never also as finished. Playback stops where it was, and the reader publishes audioPlaybackFailure, which shows an alert with Retry.
  - Files: Services/AudioPlaybackService.swift, Models/AudioSegment.swift, ViewModels/ReaderViewModel+Playback.swift, Parsers/AudioBookParser.swift, Parsers/AudioMediaProbe.swift, Parsers/DAISYParser+Audio.swift.
- Now Playing and media keys.
  - Owner: NowPlayingService.shared, the one coordinator of the system's remote commands and Now Playing information for the whole process. It also blocks the play command macOS sends by mistake when Bluetooth headphones disconnect, and feeds the experimental restart-timer gesture (MediaGestureDetector). Each reader talks to it through its own NowPlayingSession.
  - Who may write it: readers, through their sessions.
  - How others observe it: remote commands go to the active owner: the reader that is playing, or else the reader focused most recently.
  - Files: Services/NowPlayingService.swift, Services/MediaGestureDetector.swift.

### Timers and statistics

- The sleep timer.
  - Owner: SleepTimerService.shared, the app's one timer, and its owner: the ID of the book that started it.
  - Who may write it: a reader starts, cancels, or restarts the timer, passing its book's ID, and starting a timer replaces any other. Pausing and resuming the countdown, and the end of a document, count only when they come from the owning book, so another window's playback never affects the timer. The last timer started is saved, as sleepTimer.lastUsedDuration, for Restart Sleep Timer. A reader that closes stops the timer if its book owns it.
  - How others observe it: every sleep timer sheet shows the shared state; the owning reader's callbacks fade out and pause its playback; textmouth_timer.log records each timer from start to expiry.
  - Files: Services/SleepTimerService.swift, Views/Reader/SleepTimerView.swift, ViewModels/ReaderViewModel+Playback.swift.
- Listening checkpoints.
  - Owner: ReadingStatsService.shared: the statistics, saved as reading_stats.json, and the open listening session.
  - Who may write it: a reader starts a session when it plays and ends it when it pauses or stops. Every 60 seconds a timer checkpoints the open session, crediting the time since the previous checkpoint and saving, so a crash loses at most a minute. markBookFinished records each finished book.
  - How others observe it: the Stats tab reads every figure at one instant on each tick (ReadingStatsFigures), including the open session's time since its last checkpoint.
  - Files: Services/ReadingStatsService.swift, Models/ReadingStatsTile.swift, Views/Settings/ReadingStatsView.swift.
- Day keys.
  - Owner: ListeningDays. A day key such as "2026-10-02" names one local day, written in the Gregorian calendar, the POSIX locale, and ASCII digits whatever the user's settings, in the time zone current when the time is credited. Time already credited never moves.
  - Who may write it: ReadingStatsService credits time under these keys, and ListeningDayKeyMigration converts, once, keys saved under the system's own calendar (ReadingStats.dayKeyVersion).
  - Files: Services/ListeningDays.swift, Services/ListeningDayKeyMigration.swift, Services/ReadingStatsService.swift.

### Windows

- App-wide actions.
  - Owner: LibraryWindowRouter.shared. It keeps weak references to every open Library window, each with its way of taking an action, and to every reader window, each with its way of opening another reader, and decides once which window takes each GlobalAction: Open Book…, New from Text…, Import DAISY Folder…, Go to Library, opening files from Finder, opening a book's reader, and Continue to Next Book. An action that no open window can take waits while a Library window opens.
  - Who may write it: Library windows register and unregister themselves (ContentView); reader windows register (BookReaderWindowView); AppDelegate supplies the way to open a Library window. Menu commands, keyboard shortcuts, finished books, and imports that open their book (LibraryViewModel.readerOpener) post notifications that the router listens for on the default center from launch (GlobalAction.routedNotificationNames), and AppDelegate hands over the files Finder opens; each becomes one call of route(_:).
  - How others observe it: only the chosen window performs the action.
  - Files: Services/LibraryWindowRouter.swift, App/AppDelegate.swift, App/MenuCommands.swift, Views/ContentView.swift, Views/Reader/BookReaderWindowView.swift.
- Each Library window's place.
  - Owner: the window's own views: its folder path, category, search, selection, and back and forward history (FolderNavigationHistory). A second Library window keeps its own.
  - Files: Views/ContentView.swift, Views/Library/LibraryView.swift, Models/FolderNavigationHistory.swift.
- Menus.
  - Owner: MenuVisibilityManager, owned by AppDelegate. It hides the context-specific menus, such as Playback and Navigate, when the key window cannot use them, so VoiceOver never lands in an empty menu.
  - Files: Services/MenuVisibilityManager.swift.

### Saving failures

- Outstanding failed writes.
  - Owner: PersistenceFailureCenter.shared, which keeps the latest failure of each file (of each book, for package records) with its path, error, time, and a retry when the write can run again with the same data.
  - Who may write it: every service that saves a store reports failures and successes from its own queue, without waiting: the library index and package records (LibraryPersistenceService), statistics (ReadingStatsService), settings (ConfigService), substitution rules (TextSubstitutionService), and an import's cleanup of the original file. A later success for the same file settles its failure.
  - How others observe it: the Library window's banner shows one row for each failing subsystem, with Retry and Dismiss, and VoiceOver announces a subsystem once when it starts to fail. While anything is unsaved, hasUnsavedChanges makes quitting ask first (UnsavedChangesTermination, with Retry, Quit Anyway, and Cancel).
  - Files: Services/PersistenceFailureCenter.swift, Views/Library/PersistenceFailureBanner.swift, App/UnsavedChangesTermination.swift.

### Imports

- An import in progress.
  - Owner: LibraryViewModel's SerialImportQueue, which runs one import at a time off the main thread and reports activity on the main queue, and ImportCancellation, which the queued imports share and the progress overlay's Cancel button sets.
  - Who may write it: FileImportService does the work. It identifies the source, builds the package under a hidden staging name (ImportStaging, .import- followed by a UUID and .tmb), copies the content, reads the book as the reader will, writes bookInfo.json and reads it back, and only then publishes the package with one rename. A failure removes whatever was staged and throws an ImportFailure naming the file and the step, and the original file is never touched after a failure. A ZIP is inspected and extracted within an ArchiveBudget into the Archive Extraction folder (ArchiveExtraction), and every format reader takes entries out of archives through ArchiveEntryReader, which holds each entry to its limits.
  - How others observe it: LibraryViewModel publishes progress for the overlay and adds the published book to the library, unless the library already holds a copy; every question an import raises waits its turn in one queue (import questions, below).
  - Files: Services/FileImportService.swift, Services/FileImportService+Packages.swift, Services/ImportStaging.swift, Services/ImportFailure.swift, Services/ArchiveBudget.swift, Services/ArchiveExtraction.swift, Parsers/ArchiveEntryReader.swift, ViewModels/LibraryViewModel+Import.swift, ViewModels/LibraryViewModel+Duplicates.swift.
- Import questions.
  - Owner: LibraryViewModel.importDecisions, an ImportDecisionQueue of the questions imports are waiting to ask (whether to replace or keep a duplicate, whether to delete an original file, and whether to put a ZIP archive's books in a new folder), asked one at a time in the order they arose. Each ImportDecision holds everything its answer acts on, captured when its import finished (a duplicate's new copy and the copy it matched, an original file, or a ZIP archive's books and folder), and the ImportRequest its import was made with: the Library window it started in (ImportOrigin), whether to open the book afterwards, and the cancellation its batch shares.
  - Who may write it: LibraryViewModel+Import and LibraryViewModel+Duplicates. ask(_:) queues a question behind those waiting, and a question an answer raises about the same file, such as whether to delete the original of a duplicate just kept, is asked next. answerImportDecision(_:with:) acts only on the question being asked, named by its ID, so a second press can never answer the next one; an answer that fails, such as a folder name the library refuses, keeps the question open with the reason. cancelImports(), the progress overlay's Cancel, withdraws the questions of its batch, those waiting and those raised later: a duplicate's new copy is discarded, an original file is kept, and a ZIP archive's books stay where they are.
  - How others observe it: each Library window's ImportDecisionPresenter watches the queue, and exactly one window asks the question at its front (ImportDecisionQueue.askingWindow): the window its import started in while that is open, or else the first open Library window, the question waiting while none is open. That window shows ImportDecisionSheet, whose words, the screen's and VoiceOver's alike, come from ImportDecisionWording, with a title that gives the question's place when there is more than one, as in "Duplicate Book Found, 2 of 5". The choice that removes nothing comes first; Return and Escape press the marked choices, and Replace Existing and deleting an original file are never on a key. A question that appears while the user is in another window waits without taking focus or being announced. A book whose import asked to open it, as one opened from Finder does, opens through LibraryViewModel.readerOpener once it is in the library and its questions are answered.
  - Files: Models/ImportDecision.swift, Models/ImportDecisionQueue.swift, ViewModels/LibraryViewModel+Duplicates.swift, ViewModels/LibraryViewModel+Import.swift, Views/Library/ImportDecisionPresenter.swift, Views/Library/ImportDecisionSheet.swift, Views/ContentView.swift.

### Logs

- The diagnostic logs.
  - Owner: DiagnosticLog, the one policy for what a log line may say and which lines are written. It alone calls TextMouthPaths.appendLog, the writer beneath it, which writes the lines on one serial queue, never blocking or crashing the app, and keeps each file to two generations of at most 2 MB.
  - Who may write it: any code, through DiagnosticLog.event, for a line that is always written and echoed to the console, or DiagnosticLog.trace, for routine lines written only while tracing is on and at most 20 a second in each category; DiagnosticLog.log takes the level as an argument. Every call names its category: playback, focus, import, storage, statistics, or app. The app category, for the app as a whole, holds the BUILD_IDENTITY line written at launch (which also goes to the unified log) and LibraryWindowRouter's routing, whose failures are events and whose routine waits are trace. Trace lines are marked with their category. A line goes to the debug log unless it is one of the sleep timer's or speech's own (DiagnosticLog.File). Lines never hold book text or substitution rules, name files by their place inside the data directory, and give book titles only in event lines. LogContentPolicyTests scans the source for calls that break these rules, and fails when any file but DiagnosticLog.swift calls the writer; no file is exempt from either check. One gap is out of the scan's sight: a CONTENT_INDEX_REJECTED line carries the reason BookContentIndex gives, which can quote heading labels.
  - How others observe it: by reading Logs/textmouth_debug.log, textmouth_timer.log, and textmouth_transition.log in the data directory.
  - Files: Services/DiagnosticLog.swift, Services/TextMouthPaths.swift, TextMouthProductionTests/LogContentPolicyTests.swift.

### The hosted-test sandbox

- The process's runtime.
  - Owner: TextMouthRuntime.current, decided once at first use: whether the process hosts the tests (the XCTestConfigurationFilePath environment variable is set), the directory that stands for the user's home, and the preferences store. In a test host they are a TextMouthTests- folder named after the process number, in the temporary directory, and a preferences store inside it, emptied at the start.
  - Who may write it: no one; it is immutable. A test that needs the app's behavior builds a runtime value of its own.
  - How others observe it: everything that could reach the user's data follows it: TextMouthPaths.root (which ignores a custom data directory in a test host), the legacy data locations, AppDelegate's window-restoration setting, and every preference owner. SpeechService's convenience initializer still uses UserDefaults.standard directly.
  - Files: App/TextMouthRuntime.swift, Services/TextMouthPaths.swift.
- VoiceOver announcements.
  - Owner: VoiceOverAnnouncer, through which the reader, the library and its import questions, the sleep timer, and settings announce. Its poster asks VoiceOver to speak in the app and records the announcement instead under hosted tests; a test may install a poster of its own and must restore the previous one. ContentView's folder announcement still posts directly.
  - Files: Services/VoiceOverAnnouncer.swift.
- Reader windows a test leaves open.
  - Owner: ReaderWindowLeakCheck, registered by the test bundle's principal class, TextMouthTestBundle. It notes the reader windows open when each test starts, then closes any new one after the test's teardown blocks and fails the test.
  - Files: TextMouthProductionTests/HostedTestObservers.swift.
- Build slots.
  - Owner: the build-slot wrapper, .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh, which runs each build while holding one of three machine-wide slots: directories made atomically with mkdir, released on exit, and reclaimed once they are old and their owner is gone. BUILD_SLOT_ROOT moves the slots elsewhere. Scripts/check.sh uses such a wrapper when TEXTMOUTH_BUILD_SLOT names one.
  - Files: .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh, Scripts/check.sh.

## Reading a book: the path from library row to spoken audio

A book opens from its row in the Library window: VoiceOver's default action on the row, the row's Open command, or the Open Selected Book shortcut calls ContentView's onOpenBook, which asks SwiftUI for the reader window whose value is the book's ID. A book already open comes forward instead of opening twice. Requests from elsewhere, such as Finder or a finished book continuing to the next, go through LibraryWindowRouter to the same scene. The scene builds a BookReaderWindowView, which looks the book up in LibraryViewModel and creates the window's ReaderViewModel with a copy of it. When the view appears it marks the book opened, and its window accessor gives the reader its window and registers the window with the router.

The new reader loads at once, on a background queue. It calls BookContentAnalysisService.load, asking for a fresh text cache when the book records an older cache format than MarkdownCacheService.currentCacheVersion. For a text book, loading writes content.md if it is missing; otherwise it checks the cache against its fingerprints, rebuilding it when the source or the cache has changed, reads it, and uses the content index saved in bookInfo.json when that index validates and lines up with the chapters, or indexes the chapters afresh. For an audiobook, loading uses a validated saved index, or else reads the audio through AudioBookParser, waiting for it through AsyncBridge, into chapters whose placeholder text stands for time at ten characters a second. EPUB metadata and audio tags are read as well. Back on the main actor, the reader publishes the content and its headings, lays the book's own metadata edits over what the files hold, taking them from its copy of the book as it is by then, brings the saved position into range, commits a new or changed index through LibraryViewModel.updateContentIndex, saves the position, and claims a waiting autoplay request, if one is there. If the library moved the book while it loaded, the reader finds its chapter files at the new place, and a load that failed because of the move starts again from there.

Play starts nothing while the book is loading or while Where Am I? is speaking. For a text book, the reader first prepares what it will say. The chapter's text goes through the playback pipeline (preparedSpeech): skipped sections are removed, runs of a repeated symbol are rewritten (RepeatedSymbolRule, which runs before the pauses because their periods and commas would lengthen runs of those symbols), punctuation pauses are added, and the substitution rules are applied, while a ComposedOffsetMap keeps track of where every spoken character came from. A position anywhere inside a rewritten run maps into the words that replaced it, and back. When nothing speakable remains, the book ends at once through its end-of-book behavior. Otherwise the reader claims the media controls through its NowPlayingSession, plays the play sound, records when playback started (for rewind on resume), starts a listening session in ReadingStatsService, resumes the sleep timer's countdown if this book owns a paused one, and starts speaking.

Speaking begins a new play of the chapter (ChapterPlay), which gives the speech service a finish callback made for that play, and hands the spoken text and the starting offset to SpeechService.speak, which starts the synthesizer speaking directly at once and renders the same text into an AudioEngineService in the background, through SpeechRenderCoordinator, for the next natural break. The reader then pre-renders the next speakable chapter, recording what that render was asked for as its signature. As each word is spoken, onWordSpoken moves the cursor back through the offset map to the original text. The reader refreshes its view at most every 0.12 seconds, gives the library its cursor about once a second, and saves a durable checkpoint every 30 seconds.

When a chapter's speech finishes, the callback made for its play ignores the end of a play the reader has already left, a later play having begun. Otherwise it saves the position, tells the sleep timer that this book's document ended, and starts the next speakable chapter after the one that played, as a new play. If the look-ahead holds that chapter's audio, rendered with the signature its speech has now, the engine plays it at once and the chapter after it is pre-rendered; otherwise the chapter is spoken from its current text. When no speakable chapter remains, handleEndOfBook stops, starts the book again, or continues to the next book in the folder, as the book's end-of-book behavior says.

An audiobook takes the other branch at Play: playAudioChapter begins a new play and loads the chapter's file into AudioPlaybackService, playing it from the cursor's time, counted from the chapter's start within the file when the chapter is a time range, at the book's speed. A segmented chapter plays its clips as one chain instead, from the clip that holds the cursor's time. The service reports the end of each play once, and the reader moves on from the chapter that played, as it does for speech. A file that cannot be played stops playback where it was, and the reader shows an alert with Retry.

Pausing records when playback stopped, pauses the sleep timer's countdown if this book owns the timer, ends the listening session (crediting its last slice), and saves the position. Closing the window unregisters it from the router and closes the reader, which stops playback, saves the position, releases its Now Playing session, stops the sleep timer if this book owns it, and stops watching the library's updates to its book. The book's library row and its bookInfo.json then hold the last checkpoint, and LibraryPersistenceService writes both within half a second, or at the latest when the app quits.

## Shared helpers

These small types each own one rule that several parts of the app follow; use them rather than writing the rule again.

- LibraryWindowRouter (Services/LibraryWindowRouter.swift): decides which window takes each app-wide action.
- LibraryBookUpdates (ViewModels/LibraryBookUpdates.swift): how open readers learn that the library changed their book or is moving its files.
- TextCacheFingerprint (Models/TextCacheFingerprint.swift): what a text cache was written from, checked by size and date before any file is read.
- PersistenceFailureCenter (Services/PersistenceFailureCenter.swift): where every failed save is reported and settled.
- ImportStaging (Services/ImportStaging.swift): builds a package out of sight and publishes it with one rename.
- DataDirectoryMigrator and DataDirectoryLocation (Services/DataDirectoryMigrator.swift): copy a whole data directory out of sight and publish it with one rename, and take a location as the real folder its links lead to.
- ArchiveExtraction, ArchiveBudget, and ArchiveEntryReader (Services/ArchiveExtraction.swift, Services/ArchiveBudget.swift, Parsers/ArchiveEntryReader.swift): bounded, cancellable ZIP extraction, and the one way to read an archive entry.
- SettingsPolicy (Models/SettingsPolicy.swift): the table of every validated preference.
- StoredPreference and PreferenceObserver (Models/StoredPreference.swift): one definition of each preference's key and stored form, and notice of its changes.
- VoiceOverAnnouncer (Services/VoiceOverAnnouncer.swift): every VoiceOver announcement, recorded instead under tests.
- TextMouthRuntime (App/TextMouthRuntime.swift): the one switch that keeps hosted tests away from the user's data.
- DiagnosticLog (Services/DiagnosticLog.swift): what a log line may say, and which lines are written.
- AsyncBridge (Services/AsyncBridge.swift): lets synchronous parsing and analysis wait for async work, such as reading audio through AVFoundation.
- AudioSegment and AudioClipChain (Models/AudioSegment.swift, Services/AudioPlaybackService.swift): a segmented chapter's clips, never an empty list, and the one conversion between a time in the chapter and a time in a clip's file.
- CountWording (Models/CountWording.swift): a count with the right singular or plural word, so the screen and VoiceOver say the same thing.
- ManualBookOrder and LibraryBookSorter (ViewModels/LibraryViewModel+SortAndOrder.swift, Models/LibraryBookSorter.swift): the library's orderings. Manual order (by position, then title, then book ID) is the one order the list, Move Book Up and Down, dragging, and Continue to Next Book all follow.
- RemovalWording, OperationOutcome, ReadingStatsTileWording, and ImportDecisionWording (Models/): the wording of removals, operation results, statistics, and import questions, each built once for both the screen and VoiceOver.

## Known duplication

Repeated code that is known and left for now, each with the reason:

- FileImportService.bookFromPackageInfo and orphan adoption build a Book from a package record field by field, as Book(record:filePath:folderPath:tmbDirectoryName:) does, but without the text cache fingerprint, so an imported or adopted package's library row starts without it. Both could call Book(record:…).
- ReaderViewModel (audio metadata when a reader loads) and FileImportService (audio tags during import) keep their own copies of the async-to-sync bridge; both could call AsyncBridge.waitForResult. SpeechService's render wait is a different shape: it waits for a completion callback on the main queue.
- More than a dozen messages still choose singular or plural inline, in FileImportService, LegacyBookMigration, LibraryViewModel+Migration, PersistenceFailureCenter, LibraryViewModel+BookOperations, and AudioBookParser; they could use CountWording. A few sentences deliberately drop the number for one ("Remove Book?", "the book inside") and do not fit it.
- TimeRemainingBar.computeTimeRemaining (Views/Library/LibrarySubviews.swift) repeats LibraryViewModel.totalTimeRemaining(books:wpm:), which nothing calls at all.
- PDFTextParser's two page readers, with and without heading detection, share most of their loop, but record font sizes differently in ways that the paragraph joiner reads, so merging them would change some PDFs' paragraphs.
- VoiceOverFocus.swift repeats its accessibility-tree searches (findElementByIdentifier and findFirstInteractiveElement) and its focus scheduling in StandardVoiceOverFocusTriggerView and VoiceOverFocusTriggerView.
- Several stores configure their own JSON encoder with the same ISO 8601 dates and sorted, pretty output (BookInfo, RemovedFromLibraryMarker, ReadingStatsService, DataDirectoryMigrator); library.json's encoder alone does not sort its keys, so sharing one would change that file's layout.
- ContentView opens readers with the literal window ID "book-reader" rather than BookReaderWindowView.windowID, and posts its folder announcement directly rather than through VoiceOverAnnouncer.
- TextMouthPaths.cachedAudioDir names a per-package cachedAudio folder that nothing creates or reads.
