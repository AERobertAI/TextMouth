# Reading a book: the path from library row to spoken audio
<!-- id: reading-a-book; keys: overview, playback path, from row to audio, reader life cycle, Play; src:  -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

## Opening a book from the library
<!-- id: opening-book-from-library; keys: double click, Return key, openWindow, window per book, reader scene, open file; src: TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/ContentView.swift, TextMouth/Services/LibraryWindowRouter.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift -->

A book opens from its row in the Library window: VoiceOver's default action on the row, the row's Open command, or the Open Selected Book shortcut calls LibraryView.openBook(_:).
At the Reading List, openBook(_:) first asks the book's reader to read it from the list (see [Reading from the reading list](state/reader-navigation.md)).
It then calls ContentView's onOpenBook, which asks SwiftUI for the reader window whose value is the book's ID.
A book already open comes forward instead of opening twice.
Requests from elsewhere, such as Finder or a finished book continuing to the next, go through LibraryWindowRouter to the same scene.
A reader's own moves to another book (a book's end going on, Next and Previous in Reading List, and Next and Previous in Folder) end in showNextBook, which, as the setting says, makes that same request or switches the reader's own window to the book.
In a switch the scene's binding $bookID changes, .id(bookID) gives the view a new identity, and a new reader loads the book in the same NSWindow, the old one closing and saving its place as any closing reader does (a reader window's book changing in place, in [Windows](state/windows.md)).
The scene builds a BookReaderWindowView, which looks the book up in LibraryViewModel and creates the window's ReaderViewModel with a copy of it.
When the view appears it marks the book opened, and its window accessor gives the reader its window and registers the window with the router.

## Loading the book
<!-- id: loading-book; keys: reader init, book load, parsing, spinner, download from cloud, text extraction; src: TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/ReadingTextCache.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/AsyncBridge.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/Views/Library/LibraryBookInfoLoader.swift, TextMouth/Models/EPUBMetadataSave.swift, TextMouth/Models/Book.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

The new reader loads at once, on a background queue.
It first asks the book storage where the library lives.
Anywhere but a cloud location it reads the book in the same step, as it always has.
In a cloud location it reads the book's cloud state too, and a book with files only in the cloud downloads first, in the reader window.
The book is then read with dataless files left in the cloud, an audiobook after it is cloned into its working copy (see [Getting a book from the cloud](state/reader.md)).
A book being edited in the user's own editor, a text book or a transcribed audiobook, first has any edit saved there checked (settlePendingEdit(of:); see [Edited text](state/text-caches-rereads-edits.md)).
One taken is read as the book's text, and one that can't be taken stops a text book's load, which says why, and leaves out an audiobook's transcript text.
Reading calls BookContentAnalysisService.load, asking for a fresh text cache when the book records an older cache format than MarkdownCacheService.currentCacheVersion, and passes this Mac's ReadingTextCache.
A large book whose kept text matches is read from it instead of content.md, and a parsed one is kept in the background.
For a text book, loading writes content.md if it is missing.
Otherwise it checks the cache against its fingerprints, rebuilding it when the source or the cache has changed, reads it, and uses the content index saved in bookInfo.json when that index validates and lines up with the chapters, or indexes the chapters afresh.
For an audiobook, loading uses a validated saved index, or else reads the audio through AudioBookParser, waiting for it through AsyncBridge, into chapters whose placeholder text stands for time at ten characters a second.
A transcribed audiobook then has its transcript text laid over those chapters, for the text area to show while the audio plays (TranscriptTextLoader.load; see [Transcripts](state/package-records-places-and-files.md)).
When a book that has a transcript shows none of its text, the load says why (Load.withheld, kept as ReaderViewModel.transcriptWithheld) for Search in Book to say.
An audiobook's tags are read as well, but not an EPUB's package metadata.
showEPUBMetadata() shows it from the book's row (Book.keptEPUBMetadata) when the row keeps every field.
Otherwise it reads it off the main thread once the book shows, through LibraryBookInfoReader.system's read, which never downloads, laying the book's edits over it as the book is when the read ends.
It keeps the metadata on the row and in the book's record (Book.keepEPUBMetadata(readFromFile:)), giving only the fields the row lacks the file's values, so an edit stands and later opens read nothing.
Back on the main actor, the reader:
- publishes the content and its headings;
- at the book's first load only, takes the place, bookmarks, and settings its record holds when the record's place was saved later than the row's, as another Mac sharing the library may have saved it (takeNewerRecordedState(_:); see [Package records](state/package-records.md));
- lays the book's own metadata edits over what the files hold, taking them from its copy of the book as it is by then;
- brings the saved position into range;
- commits a new or changed index through LibraryViewModel.updateContentIndex;
- saves the position;
- takes over a sleep timer held for the book (claimSleepTimerHandOver(), in [Timers and statistics](state/timers-and-statistics.md));
- and claims a waiting autoplay request, if one is there.

If the library moves the book's package while it loads, the load waits for the move or starts again from where the book is then (a reader's copy of its book, in [The reader](state/reader.md)).
After claiming a waiting autoplay request, the reader prepares the opened chapter's speech off the main thread (prepareOpenedChapterSpeech).

## Play: preparing and starting speech
<!-- id: play-preparing-starting-speech; keys: spacebar, Play button, start speaking, text preprocessing, word mapping, speech preparation; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ChapterSpeechCache.swift, TextMouth/Services/RepeatedSymbolRule.swift, TextMouth/Services/OffsetMap.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/SleepTimerService.swift -->

Play starts nothing while the book is loading or while Where Am I? is speaking.
For a text book, the reader first prepares what it will say, or takes what it prepared before from the same inputs (see [Prepared speech](state/reader-playback.md)).
The chapter's text goes through the playback pipeline (ChapterSpeechInputs.prepare()):
- skipped sections are removed;
- runs of a repeated symbol are rewritten (RepeatedSymbolRule, which runs before the pauses because their periods and commas would lengthen runs of those symbols);
- punctuation pauses are added;
- and the substitution rules are applied, while a ComposedOffsetMap keeps track of where every spoken character came from.

A position anywhere inside a rewritten run maps into the words that replaced it, and back.
When nothing speakable remains, the book ends at once through its end-of-book behavior.
Otherwise the reader claims the media controls through its NowPlayingSession, plays the play sound, records when playback started (for rewind on resume), starts a listening session in ReadingStatsService, resumes the sleep timer's countdown if this reader owns a paused one, and starts speaking.

Code that asks where Play will start must not prepare speech to find out: Play's own waiting path exists so that a long chapter is never prepared on the main actor.

## Speaking a chapter
<!-- id: speaking-chapter; keys: AVSpeechSynthesizer, AVAudioEngine, word highlight, speech synthesis, highlighting, progress save; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/SpeechService.swift, TextMouth/Services/AudioEngineService.swift, TextMouth/ViewModels/LiveReadingPositions.swift, TextMouth/Services/LibraryPersistenceService.swift -->

Speaking begins a new play of the chapter (ChapterPlay), which gives the speech service a finish callback made for that play, and hands the spoken text and the starting offset to SpeechService.speak.
SpeechService.speak starts the synthesizer speaking directly at once, from a short first chunk, and renders the same text into an AudioEngineService in the background, through SpeechRenderCoordinator, for the next natural break.
The reader then prepares the next speakable chapter's speech at once, carrying it to the chapter's start, and renders its audio once the playing chapter's end is within the lead (5 minutes at least).
The render's signature records what it was asked for; a chapter too long to render ahead is not rendered, and only its speech is prepared, off the main actor.
As each word is spoken, onWordSpoken moves the cursor back through the offset map to the original text.
The reader refreshes its view at most every 0.12 seconds, gives the library's rows and summary bar its cursor about once a second, through LiveReadingPositions, and saves a durable checkpoint every 30 seconds, into the book's record at once and into library.json within five minutes.

## The end of a chapter and of the book
<!-- id: end-chapter-book; keys: auto advance, repeat book, Stop at end, finished book, AirPods rewind, sleep timer at chapter end; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+GoingOn.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift, TextMouth/Models/EndOfBookRule.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Models/Book.swift, TextMouth/Services/AudioPlaybackService.swift -->

When a chapter's speech finishes, the callback made for its play ignores the end of a play the reader has already left, a later play having begun.
Otherwise it saves the position and starts the next speakable chapter after the one that played, as a new play.
It does not do so when the reader's own sleep timer stops playback at this chapter's end, where the next chapter begins the next heading, or the book ends (expireAtChapterEnd(endingTheHeading:endingTheBook:by:)): the reader stops there instead, its cursor waiting at the next chapter's start.
If the look-ahead holds that chapter's audio, rendered with the signature its speech has now, the engine plays it at once and the chapter after it is prepared, to render within its own lead; otherwise the chapter is spoken from its current text.
When no speakable chapter remains, handleEndOfBook stops, starts the book again, or continues to the next book in the folder or feed, as the book's end-of-book rule says (EndOfBookRule: its own choice, else its feed's or folder's, else the global setting).
A sleep timer of the reader's can end listening there instead (sleepTimerEndsListeningHere: a running timer counting minutes goes on with the next book).
For a book read from the reading list, handleEndOfBook goes where the list's options say (finishBookReadFromReadingList).
Every end but a loop's calls finishAtTheEnd(replayingAFinishedEnd:) (P07), which tells ReadingStatsService.markBookFinished, unless the end replayed a finished end, writes one BOOK_FINISHED event line, counted, counted already, or a replay, and calls restAtEnd().
ReaderViewModel.restAtEnd() saves the cursor at endOfBookPlace, the last chapter at its full length, so the place's global offset is the book's total, beginning a new playback generation only when that moves it to another chapter.
Book.restsAtEnd, a saved place at or past the book's total, with no field of its own, and the reader's cursorRestsAtEnd, its live counterpart, then read the book as finished.
A book that neither loops back to its beginning nor hands over to the next book rests finished at its end (hasFinishedBook) and keeps its Now Playing session.
So a backward skip that reaches its reader, from the AirPods, the media keys, or the keyboard, plays it again from where the skip lands, while no other book plays (see [Now Playing and media keys](state/media-playback.md)).
A skip, through performSkip, marks that play replaysFinishedEnd, which the end it reaches takes and a jump or a stop clears, and a forward skip from the end stays there.
The play() call on a book whose cursor rests at its end calls playFromTheEnd(), which repeats the end's choice without playing the end:
- Stop says EndOfBookWording.finished(_:notes:sleepTimerExpired:) alone;
- EndOfBookBehavior.stopAndPlayStartsOver, which stops at the end as Stop does, and loop play the book from its beginning through playFromTheBeginning(announcing:) ("Starting again: Dune", or "Restarting: Dune");
- and Continue to Next Book and the reading list go on through continueToNextBookInFolder and followReadingListPastThisBook, which both end in goOnPastThisBook (see [The reader's moves between books, and search](state/reader-navigation.md)).

An audiobook's finished play reports no position (AudioPositionObserverPolicy's hasFinished, from AudioPlaybackService.finishedPlayGeneration), so the player's last tick never moves the cursor off the end.

## Playing an audiobook chapter
<!-- id: playing-audiobook-chapter; keys: AVPlayer, audio file, m4b, mp3 playback, error alert, playback speed; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/AudioPlaybackService.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Services/ReaderWorkingCopy.swift -->

An audiobook takes the other branch at Play: playAudioChapter begins a new play and loads the chapter's file into AudioPlaybackService, from the book's working copy when the reader has one.
It plays the file from the cursor's time, counted from the chapter's start within the file when the chapter is a time range, at the book's speed.
A segmented chapter plays its clips as one chain instead, from the clip that holds the cursor's time.
In a cloud location without a working copy, a chapter whose file is only in the cloud downloads first (chapterFilesReadyToPlay), and plays once it is here.
The service reports the end of each play once, and the reader moves on from the chapter that played, as it does for speech.
A file that cannot be played stops playback where it was, and the reader shows an alert with Retry.

## Pausing and closing the reader
<!-- id: pausing-closing-reader; keys: close window, teardown, cleanup, save position, release resources, Pause button; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/LibraryWindowRouter.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/Services/ReaderWorkingCopy.swift -->

Pausing first ends a Where Am I? announcement, leaving its book paused, then records when playback stopped, pauses the sleep timer's countdown if this reader owns the timer, ends the listening session (crediting its last slice), and saves the position.
Closing the window unregisters it from the router and closes the reader, which:
- stops waiting for any download;
- stops playback;
- saves the position only if it moved (savePositionIfMoved()), so a reader that never moved puts no older place over a later one another reader saved;
- releases its Now Playing session;
- stops the sleep timer if this reader owns it and has not held it for the next book;
- stops a timer held for its own book that it never took when no other reader of the book is left;
- deletes its working copy off the main thread;
- stops watching the library's updates to its book;
- and lets go of everything that grows with the book (see [A closed reader](state/reader.md)).

The book's library row and its bookInfo.json then hold the last checkpoint, and LibraryPersistenceService writes both within half a second, library.json too, since unregistering the book brought its write forward from the checkpoint's deadline, or at the latest when the app quits.

## Pauses between an audiobook's chapters
<!-- id: pauses-between-audiobook-chapters; keys: silence between tracks, delay, track pause, DispatchWorkItem; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Models/ChapterPauses.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

When a multi-file audiobook's chapter ends and a pause follows it (chapterPauses), audioDidFinish, after the sleep timer's check:
- moves the cursor to the next chapter's start;
- lets go of the player at its volume;
- and starts the chapter from a cancellable work item once the pause has passed (startCursorChapter(afterPause:)).

The reader's isPlaybackUnderWay counts the wait.
The wait is cancelled by stopAudioWaitingToPlay, stop() and so closing, a package move, and playAudioChapter(); a jump moves only the cursor.
The fileAfterCurrentChapter property names no file after a chapter a pause follows; without a pause, playback rolls on gaplessly.

## Manifest edits made outside the app
<!-- id: manifest-edits-outside-app; keys: manifest.json, external edit, Edit Manifest, user edited file, app activation; src: TextMouth/ViewModels/ReaderViewModel+ManifestEdit.swift, TextMouth/Platform/macOS/Services/BookManifestEditor.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

A reader of an audiobook of tracks looks at its manifest before it reads the book (readContent, LoadedContent.manifestLook) and whenever TextMouth becomes active (lookForOutsideManifestEdit, with its chapterPauses).
What it finds goes to BookManifestEditor.handle(_:for:in:), which commits it through the library as a session's edit is committed (FR18).
