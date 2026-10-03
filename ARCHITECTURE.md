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
  - ViewModels: LibraryViewModel and ReaderViewModel, each split into extensions by topic, plus SettingsViewModel and BookSearchModel.
  - Views: the SwiftUI views of the library, the reader, and settings, plus VoiceOverFocus.swift, which places VoiceOver's focus in new windows and sheets.
- Concurrency: the view models, the window router, the settings mirror, the sleep timer, and the statistics run on the main actor. Disk work runs on queues that each own their work: serial queues for the library index and for package records (LibraryPersistenceService), for imports (SerialImportQueue), and for logs (TextMouthPaths), and at most two workers for cache updates (TextCacheUpdateQueue). The app target builds in the Swift 5 language mode with minimal concurrency checking; the coding agents' test runs turn on complete checking.

## Launch

- AppDelegate.applicationWillFinishLaunching starts the router before any window exists, so a book Finder hands over waits for the first Library window instead of opening a second.
- LibraryViewModel's initializer copies a sandboxed release's data on first launch, creates the data directory's folders, removes leftover archive extraction folders, and loads the library index (loadLibraryIndex).
- Loading repairs the index against the disk (migrateOldBooksIfNeeded): books removed with Remove from Library Only stay out, equivalent folder rows merge, stale file paths are fixed, legacy books move into packages, packages that two books shared are separated, misplaced packages move into their folders, packages missing from the index are adopted, and the result is saved. An unreadable index skips all of this and enters recovery instead (below).
- LibraryViewModel then brings every book's text cache up to date, and after that its statistics, in the background (updateContentCachesAndStatistics).
- SettingsViewModel's initializer applies config.json, reconciles it with the preferences, and starts ConfigService watching the file.

## Who owns each kind of state

Each entry names a kind of state, then its owner, who may write it, how others observe it, and the files involved.

### The library index

- The library: every book's row, the folders, and each location's sort.
  - Owner: LibraryViewModel.library, published on the main actor. It is the live copy; library.json is its saved form.
  - Who may write it: LibraryViewModel and its extensions, on the main actor. Each change is followed by save(), which hands a snapshot to LibraryPersistenceService.save(_:). That waits half a second on the service's serial queue, and only the newest snapshot is written, so an older snapshot never lands after a newer one. flushPendingSave() writes a waiting snapshot before the app quits. Every write replaces library.json atomically.
  - How others observe it: SwiftUI views observe LibraryViewModel. A reader takes a copy of its book when it opens and reports back through LibraryViewModel: updateLiveReadingPosition (the row in memory, saving nothing), persistReadingPosition (the row and the package record), and updateContentIndex.
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
- The content index (BookContentIndex): chapter starts and lengths, word counts, headings with their offsets, totals, and, for audiobooks, the media layout and timing.
  - Owner: the package record, as bookInfo.json's contentIndex. Its version is BookContentIndex.currentVersion ("1.0.0"). library.json keeps only the totals and contentIndexVersion, so launch never decodes every heading in the library.
  - Who may write it: BookContentAnalysisService builds it (BookContentIndex.build) from parsed content, and it is saved only through LibraryPersistenceService (saveContentAnalysis or saveBookInfo(for:contentIndex:)).
  - How others observe it: BookContentAnalysisService.load uses a saved index only when it passes validationFailure(for:audioBaseURL:) and, for a text book, alignmentFailure(with:countingWords:) against the parsed chapters. One that fails is logged as CONTENT_INDEX_REJECTED and replaced by a fresh index. The reader takes headings, chapter offsets, and totals from the index inside its DocumentContent.
  - Which version to change: a change to source extraction changes MarkdownCacheService.currentCacheVersion. A change only to how the reading text or the index is derived changes BookContentIndex.currentVersion instead, so existing Markdown is indexed again without converting every source.
  - Files: Models/BookContentIndex.swift, Models/DocumentContent.swift, Services/BookContentAnalysisService.swift.
- Text cache fingerprints (TextCacheFingerprint): for the source and for content.md, the size, the modification time in nanoseconds, and the MD5 digest, as they were when the cache was written.
  - Owner: the package record (state.textCacheFingerprint, also copied into the index), mirrored on the library row.
  - Who may write it: MarkdownCacheService records them when it writes a cache. BookContentAnalysisService fingerprints a current cache written before fingerprints existed, once, the first time the cache passes every check; that result is saved by the usual save.
  - How others observe it: BookContentAnalysisService.loadExistingCache compares the files' sizes and dates with the record before it trusts the cache or its index, and reads a file for its digest only when the size is unchanged but the date is not. A changed file is logged as CACHE_STALE and the cache is rebuilt from the source. Startup maintenance compares the sizes the library row recorded with the files, two stat calls a book, to find stale caches without reading anything, and completedTextCacheIndex checks a package's record when recovering an interrupted batch.
  - Files: Models/TextCacheFingerprint.swift, Services/BookContentAnalysisService.swift, Services/MarkdownCacheService.swift, ViewModels/LibraryViewModel+Migration.swift.

### Preferences

- The preferences store.
  - Owner: TextMouthRuntime.current.preferences, which is UserDefaults.standard in the app and a sandboxed store under hosted tests. Each preference has one owner that reads and writes it:
    - SettingsViewModel: the Voice, Playback, and Miscellaneous settings, through properties backed by @AppStorage.
    - SoundEffectService: whether sounds play, their volume, and each event's sound.
    - TextSubstitutionService: whether the substitution rules apply. It also owns the rules, kept in substitutions.json.
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
  - Owner: SettingsPolicy, the single table of validated preferences. Each rule (NumericSettingRule, EnumSettingRule, or KeyedSettingRule) states a key, the supported range or cases, the default, and, for speed and pitch, the value meaning "not chosen yet".
  - Who may write it: no one while the app runs; it is a static table whose ranges match the Settings controls.
  - How others observe it: decoding config.json (LenientFields), applying it, reading @AppStorage values, services reading the store directly, and decoding per-book speed and pitch from bookInfo.json and library.json all pass values through it. ConfigService.AppConfig.Portability lists which preferences config.json mirrors, which only it holds, and which stay on this Mac; the tests take their expectations from those lists.
  - Files: Models/SettingsPolicy.swift, Models/LenientFields.swift, Services/ConfigService.swift.

### The reader

- A reader's state: its content, cursor (chapter and character offset), headings, bookmarks, playback flags, and errors.
  - Owner: one ReaderViewModel per reader window, on the main actor, created by BookReaderWindowView with a copy of the library's Book.
  - Who may write it: the reader itself, in its extensions: Playback, Navigation, Bookmarks, Jump, VoiceAndSpeed, and WhereAmI.
  - How others observe it: ReaderView and its subviews observe the reader, refreshed at most every 0.12 seconds during playback. The library sees the cursor through LibraryViewModel: the live position about once a second (updateLiveReadingPosition), and a durable checkpoint (persistReadingPosition) every 30 seconds of active playback (PlaybackCheckpointPolicy) and whenever the reader pauses, stops, closes, finishes a chapter, or navigates.
  - Files: ViewModels/ReaderViewModel.swift and the ReaderViewModel+ extensions, Views/Reader/.
- The playback generation.
  - Owner: ReaderViewModel.chapterPlaybackGeneration.
  - Who may write it: every navigation, skip, loop, and chapter advance increases it.
  - How others observe it: the speech-finished callback compares the generation it started under and ignores the completion of a chapter the reader has already left.
  - Files: ViewModels/ReaderViewModel.swift, ViewModels/ReaderViewModel+Navigation.swift, ViewModels/ReaderViewModel+Playback.swift.
- The look-ahead and its render signature.
  - Owner: ReaderViewModel.lookAhead: the next speakable chapter's index, the SpeechRenderSignature its render was asked for (a hash and length of the exact spoken text, and the voice), and the AudioEngineService that holds the audio.
  - Who may write it: preRenderNextChapter(), after each chapter starts; refreshLookAhead(), whenever the voice, the substitution rules or their switch, the punctuation pause level, or the skipped sections change (speed and pitch do not count, because they are applied as the audio plays); and discardLookAhead(). Renders wait their turn on SpeechRenderCoordinator.shared, which never lets two calls of AVSpeechSynthesizer.write() overlap.
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
  - How others observe it: the reader sets onWordSpoken, which moves its cursor through the offset map, and onUtteranceFinished, and mirrors whether speech is playing or paused and its speed. Switches between the modes are logged in textmouth_transition.log.
  - Files: Services/SpeechService.swift, Services/AudioEngineService.swift.
- Audiobook playback, and its failures.
  - Owner: each reader's AudioPlaybackService, which plays files with AVPlayer at a speed held to the steps AudioSpeed.normalized(_:) allows. A chapter is a whole file, or a time range within one (AudioSegment).
  - Who may write it: the reader (playAudioChapter, setAudioSpeed, retryAudioPlayback).
  - How others observe it: a file that cannot be played is reported through one channel, AudioPlaybackService.failure (an AudioPlaybackFailure naming the file) and onPlaybackFailed. Playback stops where it was, and the reader publishes audioPlaybackFailure, which shows an alert with Retry.
  - Files: Services/AudioPlaybackService.swift, ViewModels/ReaderViewModel+Playback.swift, Parsers/AudioBookParser.swift, Parsers/AudioMediaProbe.swift.
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
  - Who may write it: Library windows register and unregister themselves (ContentView); reader windows register (BookReaderWindowView); AppDelegate supplies the way to open a Library window. Menu commands, keyboard shortcuts, and finished books post notifications that the router listens for on the default center from launch (GlobalAction.routedNotificationNames), and AppDelegate hands over the files Finder opens; each becomes one call of route(_:).
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
  - How others observe it: LibraryViewModel publishes progress for the overlay, asks about duplicates (LibraryViewModel+Duplicates), and adds the published book to the library.
  - Files: Services/FileImportService.swift, Services/FileImportService+Packages.swift, Services/ImportStaging.swift, Services/ImportFailure.swift, Services/ArchiveBudget.swift, Services/ArchiveExtraction.swift, Parsers/ArchiveEntryReader.swift, ViewModels/LibraryViewModel+Import.swift, ViewModels/LibraryViewModel+Duplicates.swift.

### Logs

- The diagnostic logs.
  - Owner: DiagnosticLog, the one policy for what a log line may say and which lines are written. TextMouthPaths.appendLog writes the lines on one serial queue, never blocking or crashing the app, and keeps each file to two generations of at most 2 MB.
  - Who may write it: any code, through DiagnosticLog.event, for a line that is always written and echoed to the console, or DiagnosticLog.trace, for routine lines written only while tracing is on and at most 20 a second in each category. Lines never hold book text or substitution rules, name files by their place inside the data directory, and give book titles only in event lines; LogContentPolicyTests scans the source for calls that break these rules.
  - How others observe it: by reading Logs/textmouth_debug.log, textmouth_timer.log, and textmouth_transition.log in the data directory.
  - Files: Services/DiagnosticLog.swift, Services/TextMouthPaths.swift.

### The hosted-test sandbox

- The process's runtime.
  - Owner: TextMouthRuntime.current, decided once at first use: whether the process hosts the tests (the XCTestConfigurationFilePath environment variable is set), the directory that stands for the user's home, and the preferences store. In a test host they are a TextMouthTests- folder named after the process number, in the temporary directory, and a preferences store inside it, emptied at the start.
  - Who may write it: no one; it is immutable. A test that needs the app's behavior builds a runtime value of its own.
  - How others observe it: everything that could reach the user's data follows it: TextMouthPaths.root (which ignores a custom data directory in a test host), the legacy data locations, AppDelegate's window-restoration setting, and every preference owner. SpeechService's convenience initializer still uses UserDefaults.standard directly.
  - Files: App/TextMouthRuntime.swift, Services/TextMouthPaths.swift.
- VoiceOver announcements.
  - Owner: VoiceOverAnnouncer, through which the reader, the library, the sleep timer, and settings announce. Its poster asks VoiceOver to speak in the app and records the announcement instead under hosted tests; a test may install a poster of its own and must restore the previous one. ContentView's folder announcement still posts directly.
  - Files: Services/VoiceOverAnnouncer.swift.
- Reader windows a test leaves open.
  - Owner: ReaderWindowLeakCheck, registered by the test bundle's principal class, TextMouthTestBundle. It notes the reader windows open when each test starts, then closes any new one after the test's teardown blocks and fails the test.
  - Files: TextMouthProductionTests/HostedTestObservers.swift.
- Build slots.
  - Owner: the build-slot wrapper, .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh, which runs each build while holding one of three machine-wide slots: directories made atomically with mkdir, released on exit, and reclaimed once they are old and their owner is gone. BUILD_SLOT_ROOT moves the slots elsewhere. Scripts/check.sh uses such a wrapper when TEXTMOUTH_BUILD_SLOT names one.
  - Files: .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh, Scripts/check.sh.

## Reading a book: the path from library row to spoken audio

A book opens from its row in the Library window: VoiceOver's default action on the row, the row's Open command, or the Open Selected Book shortcut calls ContentView's onOpenBook, which asks SwiftUI for the reader window whose value is the book's ID. A book already open comes forward instead of opening twice. Requests from elsewhere, such as Finder or a finished book continuing to the next, go through LibraryWindowRouter to the same scene. The scene builds a BookReaderWindowView, which looks the book up in LibraryViewModel and creates the window's ReaderViewModel with a copy of it. When the view appears it marks the book opened, and its window accessor gives the reader its window and registers the window with the router.

The new reader loads at once, on a background queue. It calls BookContentAnalysisService.load, asking for a fresh text cache when the book records an older cache format than MarkdownCacheService.currentCacheVersion. For a text book, loading writes content.md if it is missing; otherwise it checks the cache against its fingerprints, rebuilding it when the source or the cache has changed, reads it, and uses the content index saved in bookInfo.json when that index validates and lines up with the chapters, or indexes the chapters afresh. For an audiobook, loading uses a validated saved index, or else reads the audio through AudioBookParser, waiting for it through AsyncBridge, into chapters whose placeholder text stands for time at ten characters a second. EPUB metadata and audio tags are read as well. Back on the main actor, the reader publishes the content and its headings, brings the saved position into range, commits a new or changed index through LibraryViewModel.updateContentIndex, saves the position, and claims a waiting autoplay request, if one is there.

Play starts nothing while the book is loading or while Where Am I? is speaking. For a text book, the reader first prepares what it will say. The chapter's text goes through the playback pipeline (preparedSpeech): skipped sections are removed, punctuation pauses are added, and the substitution rules are applied, while a ComposedOffsetMap keeps track of where every spoken character came from. When nothing speakable remains, the book ends at once through its end-of-book behavior. Otherwise the reader claims the media controls through its NowPlayingSession, plays the play sound, records when playback started (for rewind on resume), starts a listening session in ReadingStatsService, resumes the sleep timer's countdown if this book owns a paused one, and starts speaking.

Speaking hands the spoken text and the starting offset to SpeechService.speak, which starts the synthesizer speaking directly at once and renders the same text into an AudioEngineService in the background, through SpeechRenderCoordinator, for the next natural break. The reader then pre-renders the next speakable chapter, recording what that render was asked for as its signature. As each word is spoken, onWordSpoken moves the cursor back through the offset map to the original text. The reader refreshes its view at most every 0.12 seconds, gives the library its cursor about once a second, and saves a durable checkpoint every 30 seconds.

When a chapter's speech finishes, onUtteranceFinished checks the playback generation, saves the position, tells the sleep timer that this book's document ended, and moves to the next speakable chapter, increasing the generation. If the look-ahead holds that chapter's audio, rendered with the signature its speech has now, the engine plays it at once and the chapter after it is pre-rendered; otherwise the chapter is spoken from its current text. When no speakable chapter remains, handleEndOfBook stops, starts the book again, or continues to the next book in the folder, as the book's end-of-book behavior says.

An audiobook takes the other branch at Play: playAudioChapter loads the chapter's file into AudioPlaybackService and plays it from the cursor's time, counted from the chapter's start within the file when the chapter is a time range, at the book's speed. The service's callbacks advance through the chapters the same way. A file that cannot be played stops playback where it was, and the reader shows an alert with Retry.

Pausing records when playback stopped, pauses the sleep timer's countdown if this book owns the timer, ends the listening session (crediting its last slice), and saves the position. Closing the window unregisters it from the router and closes the reader, which stops playback, saves the position, releases its Now Playing session, and stops the sleep timer if this book owns it. The book's library row and its bookInfo.json then hold the last checkpoint, and LibraryPersistenceService writes both within half a second, or at the latest when the app quits.

## Shared helpers

These small types each own one rule that several parts of the app follow; use them rather than writing the rule again.

- LibraryWindowRouter (Services/LibraryWindowRouter.swift): decides which window takes each app-wide action.
- TextCacheFingerprint (Models/TextCacheFingerprint.swift): what a text cache was written from, checked by size and date before any file is read.
- PersistenceFailureCenter (Services/PersistenceFailureCenter.swift): where every failed save is reported and settled.
- ImportStaging (Services/ImportStaging.swift): builds a package out of sight and publishes it with one rename.
- ArchiveExtraction, ArchiveBudget, and ArchiveEntryReader (Services/ArchiveExtraction.swift, Services/ArchiveBudget.swift, Parsers/ArchiveEntryReader.swift): bounded, cancellable ZIP extraction, and the one way to read an archive entry.
- SettingsPolicy (Models/SettingsPolicy.swift): the table of every validated preference.
- StoredPreference and PreferenceObserver (Models/StoredPreference.swift): one definition of each preference's key and stored form, and notice of its changes.
- VoiceOverAnnouncer (Services/VoiceOverAnnouncer.swift): every VoiceOver announcement, recorded instead under tests.
- TextMouthRuntime (App/TextMouthRuntime.swift): the one switch that keeps hosted tests away from the user's data.
- DiagnosticLog (Services/DiagnosticLog.swift): what a log line may say, and which lines are written.
- AsyncBridge (Services/AsyncBridge.swift): lets synchronous parsing and analysis wait for async work, such as reading audio through AVFoundation.
- CountWording (Models/CountWording.swift): a count with the right singular or plural word, so the screen and VoiceOver say the same thing.
- ManualBookOrder and LibraryBookSorter (ViewModels/LibraryViewModel+SortAndOrder.swift, Models/LibraryBookSorter.swift): the library's orderings. Manual order (by position, then title, then book ID) is the one order the list, Move Book Up and Down, dragging, and Continue to Next Book all follow.
- RemovalWording, OperationOutcome, and ReadingStatsTileWording (Models/): the wording of removals, operation results, and statistics, each built once for both the screen and VoiceOver.

## Known duplication

Repeated code that is known and left for now, each with the reason:

- FileImportService.bookFromPackageInfo and orphan adoption build a Book from a package record field by field, as Book(record:filePath:folderPath:tmbDirectoryName:) does, but without the text cache fingerprint, so an imported or adopted package's library row starts without it. Both could call Book(record:…).
- ReaderViewModel (audio metadata when a reader loads) and FileImportService (audio tags during import) keep their own copies of the async-to-sync bridge; both could call AsyncBridge.waitForResult. SpeechService's render wait is a different shape: it waits for a completion callback on the main queue.
- More than a dozen messages still choose singular or plural inline, in FileImportService, LegacyBookMigration, LibraryViewModel+Migration, PersistenceFailureCenter, LibraryViewModel+BookOperations, and AudioBookParser; they could use CountWording. A few sentences deliberately drop the number for one ("Remove Book?", "the book inside") and do not fit it.
- TimeRemainingBar.computeTimeRemaining (Views/Library/LibrarySubviews.swift) repeats LibraryViewModel.totalTimeRemaining(books:wpm:), which nothing calls at all.
- PDFTextParser's two page readers, with and without heading detection, share most of their loop, but record font sizes differently in ways that the paragraph joiner reads, so merging them would change some PDFs' paragraphs.
- VoiceOverFocus.swift repeats its accessibility-tree searches (findElementByIdentifier and findFirstInteractiveElement) and its focus scheduling in StandardVoiceOverFocusTriggerView and VoiceOverFocusTriggerView.
- Several stores configure their own JSON encoder with the same ISO 8601 dates and sorted, pretty output (BookInfo, RemovedFromLibraryMarker, ReadingStatsService, the data-directory migration); library.json's encoder alone does not sort its keys, so sharing one would change that file's layout.
- ContentView opens readers with the literal window ID "book-reader" rather than BookReaderWindowView.windowID, and posts its folder announcement directly rather than through VoiceOverAnnouncer.
- TextMouthPaths.cachedAudioDir names a per-package cachedAudio folder that nothing creates or reads.
