# The parts of the app
<!-- id: parts-of-the-app; keys: overview, app structure, how the app is organized, source tree, threads and windows; src:  -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

## The SwiftUI windows
<!-- id: swiftui-windows; keys: WindowGroup, openWindow, window ID value, book-reader, multiple Library windows, settings toolbar tabs; src: TextMouth/Platform/macOS/App/TextMouthApp.swift, TextMouth/Views/ContentView.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Views/Settings/SettingsView.swift, TextMouthProductionTests/SettingsTabFitTests.swift -->

One SwiftUI application.
TextMouthApp (Platform/macOS/App/TextMouthApp.swift) declares three kinds of window:

- Library windows (LibraryWindowView, ContentView, and LibraryView).
  The first opens at launch, and Command-N opens more.
- Reader windows, one per book, identified by the book's ID (BookReaderWindowView, in the scene whose ID is BookReaderWindowView.windowID).
  A window's book can change in place when listening goes on to the next book, its scene value becoming the next book's ID in the same window (0.2.5, in [Windows](state/windows.md)).
  Window restoration is off, so none reopen at launch.
- The Settings window (SettingsView), with one tab for each SettingsTab case, at the fixed SettingsView.windowSize.
  SettingsTabContent matches each tab with its view.
  SettingsTabPage draws every tab but Text and Library in the grouped form style, which scrolls and fills the window's width, keeping checkboxes and bordered fields (SettingsTab.scrollsAsAWhole); the Text tab's rule list and the Library tab's list of views scroll by themselves.
  SettingsTabFitTests finds every AppKit control of each tab where the window shows it or a scroll view reaches it, and measures each tab's height and width without a window (TODO A10).

## The AppKit windows
<!-- id: appkit-windows; keys: NSWindowController, windowShouldClose, close prompt, unsaved take, recording window, audio editor window; src: TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift, TextMouth/Views/Recording/RecordingWindowView.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorWindowController.swift, TextMouth/Views/AudioEditor/AudioEditorView.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Platform/macOS/App/TextMouthApp.swift -->

Two more kinds of window are AppKit's, so that closing one can ask first.
The Record window, titled New Recording (RecordingWindowView, in an NSWindow that RecordingWindowController.shared makes, one at a time, with the identifier "new-recording" and restoration off).
TextMouthApp attaches the LibraryViewModel recordings are saved into as a Library window appears.
File > New Recording… and Library > New Recording… show it, as does the first Library window's appearance when recordings were left behind (see Takes left behind in [Recordings](state/recordings.md)).
And the audio editor's windows, one for each book being edited, titled "Edit Audio:" and the book's title (AudioEditorView, in NSWindows that AudioEditorWindowController.shared makes, with the identifier "audio-editor" and restoration off).
Edit Audio… opens them through AudioEditorLauncher (see The editor window in [Audio edits](state/audio-edits.md)).

## App-wide objects
<!-- id: app-wide-objects; keys: EnvironmentObject, StateObject, singletons, app-level services, shared app state; src: TextMouth/Platform/macOS/App/TextMouthApp.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/SoundEffectService.swift, TextMouth/Services/LibraryWindowRouter.swift -->

App-wide objects, created once by TextMouthApp and given to every window as environment objects:

- LibraryViewModel: the library in memory, and every operation on it.
- SettingsViewModel: the global settings, and the config.json mirror.
- KeyboardShortcutManager: every action's keyboard shortcuts.
- SoundEffectService: the sounds that playback events play.
- LibraryWindowRouter.shared: which window takes each app-wide action.

## AppDelegate and quitting
<!-- id: appdelegate-quitting; keys: applicationShouldTerminate, terminateLater, quit hold, Finder open file, unsaved prompt; src: TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorWindowController.swift, TextMouth/App/UnsavedChangesTermination.swift, TextMouth/App/QuitFinisher.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

AppDelegate (Platform/macOS/App/AppDelegate.swift) starts the router before Finder can hand over a file, owns MenuVisibilityManager, turns off window restoration, and holds a quit until nothing would be lost:
- it stops a data-directory move that is copying;
- has the Record window ask about a take it holds (RecordingWindowController.holdQuit) and then each audio editor window about its unsaved edits (AudioEditorWindowController.holdQuit);
- asks when changes are unsaved (UnsavedChangesTerminationGuard);
- and then finishes the work a quit must not cut off, the feed downloads keeping their place (three seconds at most, FeedQuitHold), a book's text read again (ten), and a speech export (five), saying what it finishes (QuitFinisher; see [Launch](launch.md)).

At quit it cancels a transcription under way, asking nothing, and ends the session lease.

## A reader window's own objects
<!-- id: reader-window-objects; keys: per-window services, StateObject, singletons, ObservableObject, shared across readers; src: TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Services/SpeechService.swift, TextMouth/Services/AudioPlaybackService.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/TextSubstitutionService.swift, TextMouth/Services/ReaderAutoplayRequests.swift, TextMouth/Services/ReadingListOpenRequests.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/ReaderWorkingCopy.swift -->

Each reader window has its own ReaderViewModel, which has its own SpeechService, AudioPlaybackService, and NowPlayingSession, and, on the Mac, its window's own SleepTimerService.
ReaderWindowContent keeps that SleepTimerService above the books the window shows (the iPhone's readers share SleepTimerService.shared; see [Timers and statistics](state/timers-and-statistics.md)).
Readers share ReadingStatsService.shared, TextSubstitutionService.shared, ReaderAutoplayRequests.shared, ReadingListOpenRequests.shared, and SpeechRenderCoordinator.shared, and, through ReaderCloudServices, the installed book storage, BookCloudStates.shared, and ReaderWorkingCopies.shared.

## The source folders
<!-- id: source-folders; keys: project layout, directory structure, where code lives, xcodegen, file tree, target membership; src: TextMouth/App/, TextMouth/Models/, TextMouth/Parsers/, TextMouth/Services/, TextMouth/Services/Feeds/, TextMouth/Services/AudioEditing/, TextMouth/Services/Export/, TextMouth/Services/MP3/, Vendor/lame/, TextMouth/ViewModels/, TextMouth/Views/, TextMouth/Phone/, TextMouth/Platform/, project.yml -->

The source folders:

- App: the entry point, the delegate, the menu commands, the build identity, the process runtime (TextMouthRuntime), and the check made before quitting.
- Models: value types and small rule tables, such as Book, BookInfo, Library, BookContentIndex, SettingsPolicy, StoredPreference, and the wording helpers.
- Parsers: one reader per format, each turning a source file into DocumentContent (chapters, headings, and an index), plus shared readers for archives, packages, and text encodings.
- Services: everything that owns a file, a queue, or a system resource.
  - InProcessEngine, which runs a C library inside the app on a thread of its own with a time limit, since the iPhone starts no helper program, timed by RunningClock:
    - liblouis, for braille (see [Imports: braille tables and the translator](state/imports-braille-tables.md));
    - FFmpeg's session (see [Imports: audio only FFmpeg reads](state/imports-audio-ffmpeg.md));
  - Services/Feeds holds the feed engine, whose FeedCenter.shared LibraryViewModel starts and offers as feeds;
  - Services/AudioEditing the audio editing engine, which works without a window (see [Audio edits](state/audio-edits.md));
  - Services/Export the model, walker, and writers of text export, which the Export dialog's Convert to picker chooses among (see [Exports](state/exports.md));
  - Services/Sync, whose pure types are in Models/Sync, the library sync (see [Library sync](state/library-sync.md));
  - and Services/MP3 the MP3 encoder over the LAME library that project.yml builds from Vendor/lame (see MP3 files TextMouth writes in [Audio edits](state/audio-edits.md)).
- ViewModels: LibraryViewModel and ReaderViewModel, each split into extensions by topic, plus SettingsViewModel, BookSearchModel, and LibraryBookUpdates.
- Views: the SwiftUI views of the library, the reader, settings, the Record window, the audio editor window (Views/AudioEditor), the Export dialog (Views/Export), transcription's sheets, dialogs, and settings group (Views/Transcription), and the feed reader's interface (Views/Feeds).
  Views also holds ViewBodyCounter.swift, which counts body evaluations for the hosted tests.
  VoiceOverFocus.swift, which places VoiceOver's focus in new windows and sheets, is in Platform/macOS/Views.
- Phone: the iPhone app's plain types, which import no UIKit: PhoneSession, PhoneAppModel, the models and policies behind the reader, the Library, and the sheets, and the iPhone's words.
  Both apps compile it and the Mac's tests cover it, but the Mac's own app never makes one (see [The two apps and the platform folders](platforms.md)).
- Platform: what differs between the Mac app and the iOS app (see [The two apps and the platform folders](platforms.md)).
  Platform/macOS holds what only the Mac compiles, in the same folder layout as the code around it:
  - the entry point and delegate (Platform/macOS/App);
  - the Edit Text and Edit Manifest editors, the helper-program runner WatchedProcess, and the Word 97-2003 export writer (Platform/macOS/Services);
  - and the Record and audio editor windows' controllers, the VoiceOver focus code, and the read-only text area (Platform/macOS/Views).

  Platform/iOS holds the iPhone app's own code (its delegates, views, and services) and the stand-ins that only the iOS app compiles; the iPhone's plain types are in the shared folder Phone.
  The files directly in Platform (PlatformTypes, PlatformApplication, PlatformControlStyles) are shared by both apps.

## TextMouthBraille, the braille helper
<!-- id: braille-helper-program; keys: BRF, translation helper, subprocess, C program, tables folder, braille tables; src: TextMouthBraille/, TextMouthBraille/TextMouthBrailleLibrary.c, TextMouthBraille/include/TextMouthBrailleProtocol.h, Vendor/liblouis/, TextMouth/Services/BrailleTranslator.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

TextMouthBraille, a folder beside the TextMouth source folder rather than in it, is the C source of a second program built into the app: the helper that runs liblouis (Vendor/liblouis, which only it and the iPhone's braille library link) for braille.
Its translation is a library, TextMouthBrailleLibrary.c, which main.c wraps and which the iPhone app calls in its own process.
It uses the tables of the folder it is given: the app's own, unpacked from BrailleTables.pack at first use (see [Braille table pack](state/braille-table-pack.md)), or VoiceOver's for one of this Mac's tables.
Its line protocol with the app, protocol 2, is defined once, in TextMouthBraille/include/TextMouthBrailleProtocol.h.
The Mac app target copies it into Contents/MacOS, and only BrailleTranslator starts it, under WatchedProcess (see Braille files, in [Imports: braille tables and the translator](state/imports-braille-tables.md)).

## TextMouthFFmpeg, the FFmpeg helper
<!-- id: ffmpeg-helper-program; keys: FFmpeg, WMA, Matroska, WebM, helper program, C program, libtmffmpeg; src: TextMouthFFmpeg/main.c, TextMouthFFmpeg/Session/session.c, TextMouthFFmpeg/include/TextMouthFFmpegProtocol.h, Scripts/vendor/ffmpeg/build.py, TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Platform/iOS/Services/FFmpegInProcessRun.swift -->

TextMouthFFmpeg, a folder beside the TextMouth source folder, is the C source of a third program built into the app: the helper that runs FFmpeg 9.0.2 (Scripts/vendor/ffmpeg/build.py builds it, as a static library of the Mac and one of the iPhone) to read the formats macOS cannot.
Only FFmpegAudioConverter starts it, under WatchedProcess.runStreaming, and on the Mac it confines itself with a sandbox once its file is open (see [Imports: audio only FFmpeg reads](state/imports-audio-ffmpeg.md)).
Its protocol with the app is defined once, in TextMouthFFmpeg/include/TextMouthFFmpegProtocol.h.
The iPhone starts no program, so the app links the same session (TextMouthFFmpeg/Session/session.c, in the library FFmpeg_iOS).
FFmpegAudioConverter.runSession runs it in the app through InProcessEngine, the one place the two platforms part (see [Imports: audio only FFmpeg reads](state/imports-audio-ffmpeg.md)).
Both builds of the C files have Clang modules off.

## Concurrency and threads
<!-- id: concurrency-threads; keys: MainActor, data race, strict concurrency, thread safety, DispatchQueue, async await, deadlock, Swift concurrency; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/Services/LogWriter.swift, TextMouth/Services/TextCacheUpdateQueue.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/ViewModels/ChapterSpeechCache.swift, TextMouth/Services/AudioEngineService.swift, TextMouth/Services/VoiceCatalog.swift, TextMouth/Services/TranscriptionService.swift, TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Services/RecordingCaptureBackend.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/SpeechService.swift, TextMouth/ViewModels/LibraryInfoSpeaker.swift, TextMouth/Services/BookManifestEditing.swift, TextMouthProductionTests/UncheckedConcurrencyPolicyTests.swift, project.yml, TextMouthTests/Package.swift, Scripts/check.sh -->

Concurrency: the view models, the window router, the settings mirror, the sleep timer, the statistics, the books' cloud states, the books kept on this Mac, the list cache, the live reading positions, and the voice list run on the main actor.
Disk work runs on queues that each own their work: serial queues for the library index and for package records (LibraryPersistenceService), for imports (SerialImportQueue), and for logs (LogWriter), and at most two workers for cache updates (TextCacheUpdateQueue).
Each import, text extraction, and book analysis on those queues runs through StorageBoundary.perform, which a data-directory move holds back and waits for, so none runs across the move's publication.
The move then copies the data directory off the main actor, while every Library window's sheet keeps the library from changing.
Rebuild Directory and the folder edits made from the library's sheets hold storage work the same way; a folder edit moves its packages and rewrites their records off the main actor, then publishes the new rows on it, keeping any change made to the library meanwhile (performLibraryTransition).
Work that can wait on a drive or the network never runs on the main thread.
The list's cloud refreshes and commands call the cloud services from detached tasks, and work that holds its thread for as long as it takes runs on a global dispatch queue (ReaderViewModel.offMain, OffMainWork) rather than on one of Swift's cooperative threads:
- the reader's requests to the book storage and its reads of a book;
- the check of a folder chosen for the library;
- the count of books only in the cloud before a move;
- a move's copy;
- and a folder edit's moves.

Library sync's engine is an actor, its file calls run on a queue of their own with limits, and the main actor only applies a merge (see [Library sync: books and rules](state/library-sync-store.md)).
The audio editor's level measurement reads its composition on a Thread of its own for the same reason: a reader may block for as long as CoreMedia takes, and a few cancelled measurements blocked there starve the cooperative pool.
A read that must never download runs inside DatalessFiles.withoutDownloading, which leaves dataless files in the cloud for its own thread only.
Other work leaves the main thread too.
The look-ahead prepares the speech of a chapter too long to render ahead on a global queue, which ChapterSpeechInputs allows by being values and prepare() by being pure, and the main actor keeps the result only while the chapter's inputs are unchanged.
Rendered speech is fed to the engine's player node from RenderedSpeechFeeder's own serial queue, which every call on the node goes through, so a busy main thread never leaves the node without audio, and a completion handler of the node never waits on the feeder.
The installed voices are listed on a queue of VoiceCatalog's own (`listingQueue`), which waits at most `listingDeadline`, ten seconds, for each listing.
Launch finds the books its cache batch must rebuild on a utility queue, where its metadata refresh reads the files of the rows an older reader read too.
Storage settings ask whether the data directory exists off the main thread.
Transcription runs on an actor of its own (TranscriptionService), one book at a time, with its blocking reads on a global queue (OffMainWork).
The main actor's TranscriptionJobCenter saves each transcript on a global queue too, a window's TranscriptionPresenter deletes one there, and its Clean Up sheet reads the cleanup's rules, cleans a transcript up, and undoes a cleanup there.
The Record window's capture backend (CaptureSessionRecordingBackend) is an actor running on a serial queue of its own, since a capture session blocks while it starts and stops.
The feed engine runs on the main actor.
A feed's fetch, its parse, and a first merge run off it.
Its records, this Mac's fetch details, and its imports are written on queues of their own.
The files its after-playing sweep and newest-N rule remove go on the imports' queue (FeedDownloadManager.runBesideImports(_:)), once the records and the feeds' indexes are written on the main actor.
Audio editing reads, renders (LAME encoding an MP3 within a render), and deletes originals off the main thread, as storage work (StorageWork.audioEditing).
Each change of a book's edit history is made under one lock (AudioEditHistoryStore), and the FFmpeg helper and an installed ffmpeg (the editor's filters) run as child processes, never on the main thread.
The editor window's model runs on the main actor, measuring the edited audio's levels off it, and plays through an AVPlayer.
On the iPhone, the in-app engines of braille and FFmpeg count their time by RunningClock.app, which counts only the time TextMouth runs (B18).
It does so because iOS keeps the system's clocks counting while it holds the app suspended (see [Imports: audio only FFmpeg reads](state/imports-audio-ffmpeg.md#the-in-app-run)).

### Swift 6 mode and unchecked declarations
<!-- id: swift6-mode-unchecked-declarations; keys: Swift 6, strict concurrency, unchecked Sendable, nonisolated(unsafe), isolation checks, UncheckedConcurrencyPolicyTests; src: project.yml, TextMouthProductionTests/UncheckedConcurrencyPolicyTests.swift, TextMouth/Services/SpeechService.swift, TextMouth/Services/AudioEngineService.swift, TextMouth/Services/SpeechExport/SpeechBufferSynthesizer.swift, TextMouth/ViewModels/LibraryInfoSpeaker.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/Services/BookManifestEditing.swift, TextMouth/Services/LibraryPersistenceService.swift -->

Every target builds in the Swift 6 language mode, set once in project.yml (TextMouthTests/Package.swift matches it), so concurrency diagnostics are errors.
`make check` fails on any Swift warning and on a Release app larger than 40 MB, and warns above 30 MB.
`make build` does not compile with code coverage, and the symbols are stripped into a dSYM that `make install` keeps for the last five installs.
The mode adds runtime isolation checks to `@objc` methods of main-actor classes and to main-actor closures handed to Objective-C APIs; each of the app's checks runs on the main thread, and VoiceWarmUp's buffer callback relies on AVSpeechSynthesizer calling back on the thread that called write().
SpeechService handles every callback of its direct synthesizer on the main queue, so its announcement of a text the speech engine refused, made only when no reader listens, asserts the main actor there (endDirectSpeechRefused(at:refusing:spanning:)).
A write of AVSpeechSynthesizer ends at SpeechWriteRelay's didFinish (TextMouth/Services/SpeechExport/SpeechBufferSynthesizer.swift), shared by the speech export and AudioEngineService.render, not at an empty buffer.
On macOS 27 the synthesizer sends an empty buffer after each segment, about a sentence, and a render that stopped at the first kept one sentence of each chapter (B31).
The relay, called on whatever thread the synthesizer uses, signals the semaphore the render queue waits on at didFinish, and at didCancel (a refused write delivers no audio) sets a flag in an OSAllocatedUnfairLock first.
A synthesizer that never says didFinish ends the write after 10 seconds without a buffer following a segment's end (SpeechBufferDelivery.quietAfterSegmentEnd).
A render the engine lets go of ends its wait at once, since stopSpeaking(at:) does not stop a write on macOS 27 and the render queue would hold the next render meanwhile.
It is Sendable, as the SDK makes every synthesizer delegate (AVSpeechSynthesizerDelegate is NS_SWIFT_SENDABLE), and the compiler checks it, with no `@unchecked`.
Speak Info's LibraryInfoSpeechDelegate ends an announcement at once when called on the main thread, and otherwise on the next turn of the main queue, and the reader's WhereAmIDelegateHelper hands each finish and cancel of an announcement to the main queue.
UncheckedConcurrencyPolicyTests requires a comment naming a lock, queue, actor, or thread on the three lines above each `@unchecked Sendable` or `nonisolated(unsafe)` declaration and pins their counts (31 and 16).
One `@unchecked Sendable` is LinkedFFmpegSession, the iPhone's open FFmpeg session, whose pointer and descriptor only the FFmpeg engine's one thread uses, one call at a time.
One `@unchecked Sendable` is ManifestOwedFields, the record of the title and author a manifest is owed, whose one stored property is a constant and UserDefaults is documented thread-safe.
One `nonisolated(unsafe)` is the record of each feed's index on disk, LibraryPersistenceService.feedIndexesOnDisk, confined to the save queue, and another the record of library.json on disk beside it, libraryIndexOnDisk, confined the same way.
Work that can block for good, such as listing voices or decoding audio with `AVAssetReader`, runs on a dispatch queue with a deadline and never in Swift's concurrency pool, which has one thread for each core: a blocked task there starves every other task of the process.

## The memory guard
<!-- id: memory-guard; keys: memory leak, out of memory, RAM, memory limit, save and quit, AUDIO_MEMORY_RUNAWAY; src: TextMouth/Services/PlaybackMemoryGuard.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

PlaybackMemoryGuard (Services/PlaybackMemoryGuard.swift) reads TextMouth's memory from launch on, whether or not anything plays (REV17a): applicationDidFinishLaunching begins the readings (beginWatching(), which starts no second loop), and readers report to it through followPlaybackForMemoryGuard.
MemoryGuardPolicy decides from the state and the last reading alone.
Its readWait(whileAnythingPlays:readInterval:idleReadInterval:) gives 5 seconds (readInterval) while anything plays, while playback it stopped for a runaway has not recovered, and while the last reading was at or above 1 GB (watchCloselyFootprint), and 30 seconds (idleReadInterval) otherwise.
It stops playback at 3 GB, only while something plays, and saves and quits at 6 GB in every state, nothing playing included (B07).
MemoryQuitMarker, the marker the next launch tells of, carries wasNothingPlaying, true when nothing played and no playback had been stopped for the runaway, which makes announcement() leave the book out ("… while nothing was playing."); a marker written before the field existed reads as false.
PlaybackMemoryGuard.quitAtOnce() ends the converting children (WatchedProcess.terminateAll()) before it calls _exit.
