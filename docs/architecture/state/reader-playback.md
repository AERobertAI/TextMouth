# The reader's playback and speech
<!-- id: reader-playback; keys: reader playback, speech, announcements; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The playback generation
<!-- id: playback-generation; keys: stale callback, ChapterPlay, completion handler, race, chapter advance, loop; src: TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

The playback generation.

- Owner: ReaderViewModel.chapterPlaybackGeneration, and the ChapterPlay token of each play: the chapter it plays and the generation it began in.
- Who may write it: beginChapterPlay(), which every start of a chapter's speech or audio calls (Play, a resume that starts the chapter again, a chapter advance, or a loop), increases it and returns the new play's token.
  A move to another chapter, by navigation or a skip, and a loop increase it as well.
- How others observe it: each play hands its speech or audio service a completion callback made for that play (listenForSpeechEnd, listenForAudioEnd).
  The end the service reports moves the reader on from the chapter that played only while that play's generation is still current (endsPlayUnderWay); the end of a play the reader has left, or one reported after the reader closed, is logged as one trace line and ignored.
  Look-ahead renders are kept only within the generation they began in.

## Prepared speech
<!-- id: prepared-speech; keys: speech cache, chapter speech, render cache, ChapterSpeechInputs, capacity; src: TextMouth/ViewModels/ChapterSpeechCache.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Services/SpeechService.swift -->

Prepared speech: what the reader will say for each chapter.

- Owner: ReaderViewModel.chapterSpeechCache, a ChapterSpeechCache, on the main actor.
  It holds each prepared ChapterSpeech with the ChapterSpeechInputs it was prepared from, for the four chapters prepared last (ChapterSpeechCache.capacity).
  The inputs are the chapter's text, compared byte for byte, its skipped sections, the repeated-symbol rule, the punctuation pause level, and the substitution pass.
  It also holds the look-ahead's speech, carried until its chapter begins.
- Who may write it: preparedSpeech(for:), through which the reader asks for a chapter's speech: speech kept for exactly the current inputs is used again, and anything else is prepared and kept, replacing the chapter's older speech.
  ChapterSpeechInputs.prepare() is pure, so the look-ahead prepares a chapter longer than SpeechRenderCoordinator.maximumTextLength off the main actor instead (prepareInBackground), never twice at once, and chooses again once it is ready; speech whose inputs changed meanwhile is not kept.
  Play's own chapter is prepared at once when nothing is kept for it, unless it is long and a background preparation of exactly its current inputs is under way.
  Play then claims playback and waits (awaitedByPlay, isWaitingForChapterSpeech) showing Playing.
  When the preparation finishes, finishPreparingInBackground starts it from the cursor (continueWaitingPlay), unless Where Am I? is speaking then.
  If it is, the play goes on waiting, showing Playing, until the announcement ends, by itself (whereAmIAnnouncementFinished, after the end sound) or cut short by Where Am I?, a skip, or a jump (startPlayHeldByWhereAmI).
  ReaderViewModel.continueWaitingPlay() waits while isWhereAmISpeakingOrSoundingItsEnd, so speech that is ready while the end sound of an announcement that ended by itself plays starts once the sound has passed (startPlayHeldByWhereAmI, which the end sound's work asks as it passes).
  Play/Pause, even during the announcement, Stop, the sleep timer's stop, and close end the wait, while a cancel of the announcement the reader did not ask for starts the waiting play, as the announcement's end would have (a Where Am I? announcement, below).
  A closed reader empties the cache as close() stops it, and keeps nothing a background preparation finishes afterwards.
  When a text book finishes loading without playing, showLoadedContent calls prepareOpenedChapterSpeech(), which prepares the chapter Play will start in (after a cover without words, the first chapter with words) off the main actor through prepareInBackground(_:forLookAhead: false).
  Then finishPreparingInBackground keeps the result only while its inputs are still current.
- How others observe it: Play, each chapter's start, the look-ahead, and refreshLookAhead() read it, so a chapter is prepared once for as long as its inputs stay the same, and a speed or pitch step prepares nothing.

## The look-ahead and render signature
<!-- id: look-ahead-render-signature; keys: pre-render, next chapter, gapless, speech render signature, AVSpeechSynthesizer, audio engine; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/LookAheadLead.swift, TextMouth/ViewModels/LongPauseWatch.swift, Scripts/agents/probes/speech-render-speed-probe.swift, TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift, TextMouth/ViewModels/ChapterSpeechCache.swift, TextMouth/Services/AudioEngineService.swift, TextMouth/Services/SpeechService.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

The look-ahead and its render signature.

- Owner: ReaderViewModel.lookAhead: the next speakable chapter's index, the SpeechRenderSignature its render was asked for (a hash and length of the exact spoken text, and the voice), and the AudioEngineService that holds the audio.
- Who may write it: preRenderNextChapter(), after each chapter starts; refreshLookAhead(), whenever the voice, the substitution rules or their switch, the repeated-symbol settings, the punctuation pause level, or the skipped sections change; and discardLookAhead().
  Speed and pitch do not count, because they are applied as the audio plays.
  So applyLocalSpeechOverrides, which every playing reader runs at each step of a global setting, refreshes the look-ahead only when the voice in effect is not the one the look-ahead renders in.
  The look-ahead carries its chapter's speech to that chapter's start (ChapterSpeechCache.lookAheadSpeech), so the chapter's end prepares nothing.
  The speech is prepared at once, by preRenderNextChapter(), but rendered only when the listening time left is within LookAheadLead.
  The render waits in lookAheadWait until then.
  The lead is the larger of 5 minutes and 4 times the next chapter's estimated render time (400 UTF-16 units a second).
  The time left counts 7.5 units a word at the reader's speed.
  The cursor asks (startLookAheadRenderIfDue()) at every move, so reaching the lead and a seek into it both start the render.
  A seek back out leaves a render alone, and a chapter shorter than the lead renders at once.
  On the iPhone the render also waits while mayRenderAhead() refuses (memory or heat).
  A text book paused for LongPauseWatch.delay (5 minutes) lets go of the look-ahead's audio, or abandons its render, and keeps its speech (releaseLookAheadAudioForLongPause()).
  A resume within the lead renders again.
  watchPauseForGrowingLong() starts that watch for every pause: Pause, a Where Am I? that ends paused, and speech that paused itself.
  The reader's renders wait their turn on SpeechRenderCoordinator.shared, so the look-ahead never competes with the chapter Play waits for, and a stale or oversized render never starts.
  Overlapping calls of AVSpeechSynthesizer.write() don't change what each one writes: two and three writes at once, in one voice and in two (Samantha, and the Eloquence voice Eddy), each wrote the very samples it wrote alone.
  So the speech export's writes run beside the reader's renders, through synthesizers of their own.
  Not measured: an export's writes beside the reader speaking aloud in direct mode, where a background render of a very long chapter made speak() loop back to text already spoken at a chunk's change (62fc142e, the reason for the coordinator's 100,000-character limit); nor premium and neural voices.
- How others observe it: at a chapter's end, takeLookAheadEngine(for:) hands over the engine only when it holds finished audio whose renderedSignature equals the signature of the chapter's speech prepared now.
  Otherwise the chapter starts from its current text.

## Pause between chapters
<!-- id: pause-between-chapters; keys: chapter gap, silence between tracks, ChapterPauses, audiobook manifest, wait timer; src: TextMouth/Models/ChapterPauses.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Parsers/AudioManifest.swift -->

A pause between chapters (FR15): the silence a book keeps after a chapter before the next starts, while it plays on.

- Owner: ReaderViewModel.chapterPauses (Models/ChapterPauses.swift), set as the book loads and never saved.
  It is supplied for now by ChapterPauses.betweenTracks through AudioTrackPlan, from a multi-file audiobook's manifest.
  One ChapterPauses is equal to another when it gives the same pause after every chapter, whatever list made it ([shared helpers](../shared-helpers-values.md)).
  And chapterStartAfterPause, the cancellable start of the next chapter.
  A later setting of pauses between headings (FR16) makes or combines a ChapterPauses at the same place.
- Who may write it: +Playback's audioDidFinish begins the wait; stopWaitingOutChapterPause(because:) ends it, called from stopAudioWaitingToPlay, stop(), playAudioChapter(), and +LibraryUpdates' pauseAudioForPackageMove.
- How others observe it: through isPlaybackUnderWay and isWaitingOutChapterPause.

## Playback and bookmark fixes
<!-- id: playback-bookmark-fixes; keys: Next Bookmark, Previous Bookmark, clip end, single-file audiobook, review fixes, bookmark order; src: TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/SpeechService.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

Playback and bookmark fixes: the reader's choices that a review found wrong.

- Owner: ReaderViewModel and SpeechService. bookmarksInBookOrder (ReaderViewModel+Bookmarks.swift) orders bookmarks by chapter, then place in the chapter, then number, and Next Bookmark takes the first after the cursor and Previous the last before it, each still saying its own number.
  In one file of chapters, the clip end of chapter n is the start of chapter n + 1 and the last chapter has none (clipEnd(ofChapter:chapterUTF16Lengths:), ReaderViewModel+Playback.swift), so the file's own end finishes the book through onPlaybackFinished and handleEndOfBook().
  ReaderViewModel.stop() lets go of everything an audiobook waits for through stopAudioWaitingToPlay(because:), as pause() does, including a chapter whose files it waited to download, and counts what was under way as pause() does.
  ReaderViewModel.finishStopping halts a minutes sleep timer's countdown at every stop.
  SpeechService.isUsableSpokenRange(_:inTextOfLength:) ignores a range the synthesizer reports that is negative, at NSNotFound, or past the utterance's text, with one SPOKEN_RANGE_IGNORED trace line, since NSString.substring(with:) raises an Objective-C exception for it.

## Where Am I announcement
<!-- id: where-am-i-announcement; keys: Where Am I?, announcement, summary press, brief summary, full summary, AirPods Play, end sound, SummaryPress; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift, TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/Models/SummaryPress.swift, TextMouthProductionTests/FullSummaryReaderTests.swift, TextMouthProductionTests/MediaCommandPlaybackTests.swift, TextMouthProductionTests/IntegrationTestSupport.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/SpeechService.swift, TextMouth/Services/NowPlayingService.swift -->

A Where Am I? announcement: the reader's summary of where it is, spoken in the app's own voice.

- Owner: the reader, which keeps for it:
  - a synthesizer of its own, apart from the speech service's (whereAmISynth);
  - the announcement it speaks (liveWhereAmIUtterance);
  - which summary it says (whereAmIDetail, a SummaryDetail, brief or full, FR12's branch C);
  - whether one speaks (isWhereAmISpeaking);
  - whether it paused a playing book (wasPlayingBeforeWhereAmI);
  - whether one that ended by itself still owes that book its resume, until its end sound has played (isWhereAmIResumePending);
  - whether the end sound of one that ended by itself is playing (isWhereAmIEndSoundPlaying);
  - whether it holds a Play pressed during it (isPlayHeldByWhereAmI), for a book it did not pause or for the one it paused, so the Play survives a cancel; and
  - whether it holds an audiobook's chapter whose files arrived, whose package's move ended, or whose pause before it ended, during it (isChapterHeldByWhereAmI, which counts in isWaitingForChapterDownload).
  The flag isWhereAmIEndSoundPlaying is set in whereAmIAnnouncementFinished(), cleared first by resumeAfterWhereAmIEndSound() whereAmIEndSoundDelay later, and set and cleared nowhere else, so an announcement the system cancels, which plays no end sound, leaves it false.
  The flag isWhereAmISpeakingOrSoundingItsEnd is isWhereAmISpeaking or isWhereAmIEndSoundPlaying.
  The flag isWhereAmIUnderWay is any of the four: an announcement speaking, a resume owed, a Play held, or a chapter held.
  It has no term for the end sound's window: what an announcement leaves for it, a resume, a held Play, or a held chapter, is counted already.
  So a Play pressed in the window by a reader with nothing in Where Am I?'s hands, one that was not playing when the announcement began, starts at once.
  The flag whereAmIWillPlayBook is whether Where Am I? will play the book once it is over: a book the announcement speaking paused, a resume owed, a Play held, or a chapter held.
- Who may write it: ReaderViewModel+WhereAmI. whereAmI(_:) takes Where Am I?
  (.brief, W) and Where Am I?
  Full Summary (.full, W twice), which one handler in ReaderViewModel hears for both notifications, and does what SummaryPress.outcome(pressing:while:sameSubject:) (Models/SummaryPress.swift) decides: speak, after the start sound, pausing the book if it plays.
  Stop, through cancelWhereAmIIfActive(), resuming the book it paused or starting the play it held, for a brief press while any summary speaks or a full press while the full one does.
  Or replace the brief summary with the full one, on a fresh synthesizer (replaceWhereAmISynthesizer()), the book still paused and with no second start sound.
  The reader toolbar's ReaderWhereAmIToolbarButton (Views/Reader/ReaderView.swift) asks for the brief summary when pressed, and for the full one through its VoiceOver action, named ShortcutAction.whereAmIFull.title.
  No press depends on when the last one came.
  ReaderViewModel.speakWhereAmI(_:) hands the guarded text to the synthesizer, or, in a test, to _whereAmIUtteranceRecorderForTesting.

### How an announcement ends
<!-- id: where-am-i-announcement-ends; keys: end sound, resume owed, whereAmIAnnouncementFinished, stopWhereAmISynthesizer, held Play; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Services/SpeechService.swift, TextMouth/Services/NowPlayingService.swift -->

The reader's own stops, a pause (pause(playingPauseSound:)), a press while an announcement speaks, a command that interrupts it, a new announcement, and closing, go through stopWhereAmISynthesizer().
It forgets the announcement before it silences the synthesizer, so the cancel the synthesizer then reports changes nothing.
An announcement that ends by itself (whereAmIAnnouncementFinished()) plays the end sound, makes the resume of the book it paused owed (isWhereAmIResumePending), and opens the end sound's window (isWhereAmIEndSoundPlaying).
It runs resumeAfterWhereAmIEndSound() after whereAmIEndSoundDelay, 0.3 seconds (afterWhereAmIEndSound(_:); tests take the work through _afterWhereAmIEndSoundForTesting and run it with a WhereAmIEndSoundClock).
That closes the window first and then resumes that book, unless whatever settled the book meanwhile took the resume, and starts a held Play.
ReaderViewModel.resumeBookPausedForWhereAmI() plays the book afresh through restartPlaybackAtCursor() when restartPlaybackBackendOnNextResume is set, as when AirPods connected or the library moved a paused audiobook's files during the announcement.
Otherwise it tells Now Playing that the book plays only when the backend's resume returns true, and settles the pause when it does not (WHERE_AM_I_RESUME_REJECTED).
A resumed book lets a Play held for it go.
While isWhereAmIUnderWay, play() and playOrResume() call holdPlayForWhereAmI(), which holds a Play (isPlayHeldByWhereAmI) for the book the speaking announcement paused, so the Play survives a cancel, or for a book the announcement will not play anyway and that is not playing or waiting to play.

### What an announcement holds
<!-- id: where-am-i-announcement-holds; keys: held chapter, held Play, startPlayHeldByWhereAmI, cancelWhereAmIIfActive, endWhereAmIWithoutResuming, REV12; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

A chapter whose files arrive during an announcement waits for it too (isChapterHeldByWhereAmI, from downloadDidFinish).
So does audio set aside for a package move that ends during one (resumeAudioAfterPackageMove(), at the volume it was set aside at).
So does a pause between two chapters that ends during one (startChapterAfterPause(), which sets isChapterHeldByWhereAmI).
These three hold the audio while the announcement's end sound plays too, and so does the play that waits for a chapter's speech (continueWaitingPlay()).
Each of the four asks isWhereAmISpeakingOrSoundingItsEnd, which only these four places ask, where every other test of isWhereAmISpeaking is about the announcement itself.
The end sound's work plays the held audio once (startPlayHeldByWhereAmI()).
ReaderViewModel.startPlayHeldByWhereAmI() plays a held chapter first, through playAudioChapter(), letting a Play held beside it go with it, since a held chapter counts in isWhereAmIUnderWay and the Play would wait on it.
Otherwise it starts a held Play through playOrResume(), with the play sound.
ReaderViewModel.pauseBookForWhereAmI() takes an owed resume over, so Where Am I? pressed in the moment after an announcement ended keeps the book paused until the new one ends.
And cancelWhereAmIIfActive() resumes an owed book at once, as a skip in that moment needs.
ReaderViewModel.navigateTo(chapterIndex:characterOffset:) is every jump's path (Next and Previous Heading, a heading, bookmark, or search result picked from its list, Go to a percent or a time, Return to previous position, and an audiobook's jump into another chapter).
It ends an announcement first through cancelWhereAmIIfActive(), as the skips do, so the jump moves a book that plays, and it plays on from where the jump lands (REV12).
ReaderViewModel.silenceWhereAmI() silences an announcement speaking and records that none speaks, the one place cancelWhereAmIIfActive(), stopWhereAmIWithoutResuming(), and endWhereAmIAsTheBookStops() do it.
ReaderViewModel.stop(), which Release Media Controls, a chapter's download cancelled or failed, and closing the window go through, and a playback failure end an announcement with the book.
That is endWhereAmIAsTheBookStops(): the synthesizer silenced, and wasPlayingBeforeWhereAmI, isWhereAmIResumePending, isPlayHeldByWhereAmI, and isChapterHeldByWhereAmI cleared.
So the announcement's end neither resumes the stopped book nor tells Now Playing that it plays.

### How others observe an announcement
<!-- id: where-am-i-announcement-observers; keys: WhereAmIDelegateHelper, ReportedUtterance, Now Playing, isCurrentlyPlaying, playUnlessUnderWay, WHERE_AM_I_CANCEL_UNEXPECTED; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/Services/NowPlayingService.swift -->

- How others observe it: WhereAmIDelegateHelper hands each finish and each cancel to the main queue with its utterance (ReportedUtterance), which the reader compares with liveWhereAmIUtterance.
  A finish of the announcement speaking ends it with the end sound and then resumes the book it paused, or starts the play it held (whereAmIAnnouncementFinished()); a finish of one the reader stopped or replaced since is ignored.
  A cancel nobody asked for, as the engine's refusal of its text makes (WHERE_AM_I_CANCEL_UNEXPECTED; whereAmISynthesizerCancelled(_:)), ends it without the end sound or the resume, through endWhereAmIWithoutResuming(), so the book it paused stays paused unless a Play was pressed for it.
  It also replaces whereAmISynth, since a synthesizer the engine refused never speaks again.
  It then calls startPlayHeldByWhereAmI(), as the announcement's end does, so a held Play, a held chapter, and a play waiting for its chapter's speech start, while a play waiting for its chapter's files goes on waiting.
  ReaderViewModel.endWhereAmIWithoutResuming() only records that no announcement speaks and settles the pause the announcement left, or the one a resume owed would have undone.
  That is settlePauseLeftByWhereAmI(): the listening session ended, the reader's sleep timer countdown held, the stop recorded for rewind on resume, and an audiobook shown paused.
  It is needed since the announcement paused the book without the rest of a pause, expecting to resume it.
  What else the announcement held is its caller's to settle.
  Both pause(playingPauseSound:) and togglePlayPause() end whatever Where Am I? holds of the book through stopWhereAmIWithoutResuming().
  That silences an announcement speaking, calls endWhereAmIWithoutResuming(), and lets a held Play go, the book left as it was before the Play, so a pause made in the moment after an announcement ended takes the resume it owed and stands.
  Each then pauses whatever is under way (isPlaybackUnderWay: a play waiting for its chapter's speech or files, a held chapter, or audio set aside for a package move), togglePlayPause() in silence, while a Pause that pauses something makes the pause sound.
  Next and Previous in Reading List (goThroughReadingList(_:)) end it through that pause, for a book that was not playing too, and count a book Where Am I? will play as playing.
  A Play from the AirPods or a media key reaches playOrResume(), so during an announcement it is held, as above, and starts the book as the announcement ends.
  The handler the reader gives its NowPlayingSession as isCurrentlyPlaying is whereAmIWillPlayBook || isPlaybackUnderWay, so a book Where Am I? will play, and a play waiting for its chapter's speech or files, count as playing.
  Another book starting (prepareForPlayback(ownerID:)), a disconnect, or a recording starting pauses such a book, ending what Where Am I? holds without resuming it, and a waiting play never starts by itself once ready.
  Over a book that was paused before, with no Play held, the announcement goes on.
  ReaderViewModel.playUnlessUnderWay() plays as Play does unless a play is under way (isPlaybackUnderWay).
  It serves Auto-play on navigate (autoPlayIfEnabled(), after a heading, bookmark, or search result picked from its list) and a sleep timer set to start playback (startSleepTimer(duration:startPlaybackIfNeeded:)).
  ReaderViewModel.showEditedText(_:) restarts a book Where Am I? will play as it restarts a playing one.
  ReaderViewModel.pauseAudioForPackageMove() leaves a chapter held for Where Am I? held, and resumeAudioAfterPackageMove() leaves it to the announcement while it is held.
  An announcement that ends during the move lets the chapter go in startPlayHeldByWhereAmI(), leaving it to the move's end (audioPausedForMove), which plays it from the package's new place.
  The summaries, briefWhereAmISummary and fullWhereAmISummary, and Copy Reading Position's readingPositionSummary say "Finished" in place of the percent and the times left while the cursor rests at its end (isFinished, from cursorRestsAtEnd, P07); the full summary still gives the book's whole time.

## Speech refusal report
<!-- id: speech-refusal-report; keys: speech engine refusal, skipped text, AVSpeechSynthesizer error, report sheet, refused passage, diagnostics log; src: TextMouth/Models/SpeechRefusalReport.swift, TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Services/SpeechService.swift, TextMouth/Views/Reader/SpeechRefusalReportSheet.swift, TextMouth/Platform/macOS/Views/LogsInFinder.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouthProductionTests/SpeechRefusalReportTests.swift, TextMouthProductionTests/SpeechRefusalReaderTests.swift, TextMouthProductionTests/SpeechRefusalSheetTests.swift, TextMouth/App/BuildIdentity.swift, TextMouth/Views/Reader/ReaderSnapshot.swift, TextMouth/Platform/iOS/Views/VoiceOverFocus+iOS.swift, TextMouth/Platform/macOS/Views/VoiceOverFocus.swift -->

The report of a speech refusal (B05): what a reader keeps of the speech engine's refusals while its window is open, and the sheet that shows it.

- Owner: ReaderViewModel.speechRefusalAlert, a SpeechRefusalAlert (Models/SpeechRefusalReport.swift): the report its sheet shows, a SpeechRefusalReport, nil while none shows.
  It also counts how many times each place (SpeechRefusalPlace: the chapter, and the character in its text as the book has it) was refused, kept while the window is open.
  A report is a value: the book's title and format.
  The position as the brief Where Am I? says it without the title.
  The chapter, counted from 0 as the logs count it, and its title.
  Where speech stopped in the chapter's text as the book has it, and that text's length.
  What speech handed over (SpeechRefusal, below).
  Two passages (SpeechRefusalPassage: at most 100 UTF-16 units before the stop and 400 from it, clamped to the text and never splitting a character), the chapter as the book has it and the refused text as it was handed to the engine.
  The system's version (ProcessInfo.processInfo.operatingSystemVersionString).
  The build (BuildIdentity.current).
  The time.
  And the count.
  SpeechRefusalReport.lines words every line, and SpeechRefusalWording every word of the sheet and of what VoiceOver hears, so a test pins each without a window.
- Who may write it: ReaderViewModel+SpeechRefusal alone.
  Speech hands over what it refused: SpeechService.transitionLog keeps every line it writes, routine trace lines included, in recentTransitionLines (RecentTransitionLines, the newest 40, offsets and lengths only), so the report never reads a log file on the main thread.
  SpeechService.endDirectSpeechRefused(at:refusing:spanning:) calls onSpeechRefused with a SpeechRefusal.
  A SpeechRefusal holds where speech stopped, the refused utterance's range and its text exactly as handed to the engine, the strictly guarded range, the voice, rate, pitch, and volume it was handed over with, the speed in words per minute, and those lines, ending with DIRECT_RETRY_FAILED.
  ReaderViewModel.showPlaybackStoppedAfterRefusal(_:) ends with showSpeechRefusalReport(_:).
  That first reads where the window stands (speechRefusalWindowStanding, a SpeechRefusalWindowStanding read from AppKit: inFront, the key window of the active app with nothing over it; underASheet, a sheet over it; or behind).
  It builds the report from the cursor's chapter through the offset map's toOriginal, and keeps it with SpeechRefusalAlert.show(_:), which replaces any report shown and counts its place.
  It announces SpeechRefusalWording.announcement unless the window stands inFront.
  It writes SPEECH_REFUSAL_REPORTED to speech's log (the chapter, the offsets, the chunk's range, the count, and whether it announced).
  ReaderViewModel.closeSpeechRefusalReport() lets the report go and keeps the counts.
  Nothing else closes it, Play included.
  A reader without the chapter's text makes no report and announces SpeechService.engineRefusedAnnouncement, and a closed reader makes none.

### The report's sheet
<!-- id: speech-refusal-report-sheet; keys: SpeechRefusalReportSheet, SpeechRefusalReportPresenter, showsReport, Copy Details, Show Logs in Finder; src: TextMouth/Views/Reader/SpeechRefusalReportSheet.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Platform/macOS/Views/LogsInFinder.swift, TextMouth/Views/Reader/ReaderSnapshot.swift -->

- How others observe it: SpeechRefusalReportPresenter, attached in ReaderView, presents SpeechRefusalReportSheet while showsReport(keepingOne:panels:transcriptionDialogShows:errorAlertShows:) holds.
  It holds while:
  - a report is kept;
  - none of the reader's panels shows (ReaderPanels.isShowingAny: Headings, Bookmarks, Sleep Timer, Book Info, Voice, Search, and the Export dialog, ReaderPanels.export, which ReaderBookCommandsSupport opens through a binding);
  - none of its transcription dialogs shows (TranscriptionPresenter.isShowingAny; ReaderView keeps the presenter); and
  - its error alert doesn't show.
  SwiftUI's putting the sheet away changes nothing, so a panel or dialog opened over it only sets it aside.
  The sheet follows a ReaderSnapshot of the report (PERF30), so a playing reader's publishes never redraw it, and decides once, as it is made, whether InitialVoiceOverFocusModifier targets its heading and summary, one element (sheetTakesVoiceOverFocus: anywhere but behind).
  It shows the report's text in ReadOnlyTextArea labelled Details.
  It offers Copy Details (copyDetails(of:to:), the general pasteboard in the app, which announces SpeechRefusalWording.copiedAnnouncement), Show Logs in Finder (LogsInFinder.show(for:)), and Close, the default action, which Escape presses through SilentKeyEquivalent.
