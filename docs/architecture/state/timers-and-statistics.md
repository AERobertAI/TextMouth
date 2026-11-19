# Timers and statistics
<!-- id: timers-statistics; keys: sleep timer, reading stats, listening statistics, timer tolerance, Stats tab; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The sleep timer
<!-- id: sleep-timer; keys: per-window sleep timer, End of heading, End of book, Restart Sleep Timer, Show Sleep Timer, fade out, countdown, textmouth_timer.log; src: TextMouth/Services/SleepTimerService.swift, TextMouth/Services/SleepTimerRegistry.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Views/Reader/SleepTimerView.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/SleepTimerStatusLabel.swift, TextMouth/Views/Reader/PlaybackControlsView.swift, TextMouth/Platform/macOS/App/TextMouthApp.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderShownState.swift, TextMouth/Services/AudioPlaybackService.swift, TextMouth/Views/Library/LibraryView.swift, TextMouthProductionTests/WindowSleepTimerTests.swift, TextMouthProductionTests/SleepTimerServiceTests.swift -->

The sleep timer.

- Owner: each reader window's own SleepTimerService, not one timer for the whole app.
  On the Mac ReaderWindowContent (Views/Reader/BookReaderWindowView.swift), the view the reader window's scene (Platform/macOS/App/TextMouthApp.swift) shows,
  - makes the timer once for the window, in a WindowSleepTimerHolder kept as a @StateObject,
  - and gives it to each BookReaderWindowView below it, whose reader takes it (ReaderViewModel.init(sleepTimer:), the reader's sleepTimerService).

  The holder is an ObservableObject that publishes nothing.
  So a tick of the timer does not run the window content's body and, with it, BookReaderWindowView.init (a look-up of the book among the library's) once a second (WindowSleepTimerTests.testATickOfTheWindowsTimerDoesNotDrawTheWindowContent counts the body's runs while the timer publishes).
  The countdown the reader's window shows, "4:59" with a moon and "Sleep timer: 4:59 remaining" to VoiceOver, is drawn while the timer runs and nowhere else.
  It is drawn by SleepTimerStatusLabel (Views/Reader/SleepTimerStatusLabel.swift) in BookInfoBar, the status row, and PlaybackControlsView, the playback bar.
  The label observes the window's own SleepTimerService (viewModel.sleepTimerService), so a tick, a start, and a stop draw that small label and nothing else.
  The countdown moves every second whether the book plays or is paused, though the reader publishes only when what its window shows changes (ReaderShownState, in [Reader state](reader.md)).
  The reader's views never read the timer from the reader.
  The sheet observes the timer itself, and the reader's status shows it as the reader publishes.
  The book is the content's .id(bookID), so a book changing in place ([A reader window's book changes in place](windows.md)) makes a new view and reader and the window keeps its timer.
  A reader made with no window's timer, as a test's, makes one of its own.
  The iPhone, which shows one reader at a time, keeps SleepTimerService.shared, which exists only there (#if os(iOS)) and which its readers share.
  SleepTimerRegistry.shared (Services/SleepTimerRegistry.swift, on the main actor) lists every timer of the app weakly, as each is made (register(_:)), so a timer goes with its window, and answers what no single timer can, which timer is on its way to a book from whichever window.
  It also keeps the copy of the last duration started, below.
  The timer's owner is the readerID of the reader that started it, an identity of each reader's own (ReaderViewModel.readerID), which also owns the reader's Now Playing session, so two windows of the same book are told apart.
  What the timer waits for is a SleepTimerDuration:
  - a number of minutes,
  - the end of the heading (endOfHeading, the one place-based timer for any document, into which End of chapter folded: where the next heading of any level begins or the book ends; an audiobook's chapters, tracks, and marker segments each begin with a heading, so its heading ends with its chapter),
  - or the end of the book (endOfBook).

### Who may write the sleep timer
<!-- id: sleep-timer-writers; keys: start, cancel, restart, End of heading, Restart Sleep Timer, lastUsedDuration, expireAtHeadingEnd; src: TextMouth/Services/SleepTimerService.swift, TextMouth/Services/SleepTimerRegistry.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

- Who may write it: a reader starts, cancels, or restarts its window's timer, passing its readerID.
  Starting a timer replaces its window's timer, whoever owned it.
  That is the reader before it after a switch in place, and a timer on its way to the reader's book from another window (ReaderViewModel.sleepTimerComingHere, stopped by stopSleepTimerComingHere(because:), as cancelSleepTimer() does too).
  Another window's own timer is never touched.
  Pausing and resuming the countdown, and the end of the heading an End of heading timer waits for, count only when they come from the owning reader, so another window's playback, even of the same book, never affects the timer.
  That timer waits for the heading after the place where playback reads when it was set: the cursor while the book plays, and, while it does not, the first word Play says (ReaderViewModel.headingAfterPlaybackStart).
  It works through playbackStartPlace(), which asks searchForSpeechStart, the one rule for where Play begins, with LongChapterPreparation.never.
  A long chapter whose speech is not kept ends the search and nothing is prepared on the main actor, which Play's own wait for a preparation under way never does.
  So a timer set where nothing is read, as on an image-only cover, at a chapter's tail, in a skipped section, or in white space before a heading, waits for the end of the heading Play starts in and not for the one Play begins at.
  Both startSleepTimer and refreshSleepTimerHeading, which every hand-over, restart, edit, and load path calls, ask it.
  A book whose Play waits for its chapter's speech counts as playing (isPlaybackUnderWay, isWaitingForChapterSpeech), and a long chapter not ready yet leaves the place unknown, so both take the cursor's heading as a provisional choice.
  Play settles it where it starts reading, in startSpeakingAsNowPlaying, which play() and continueWaitingPlay() both use (retargetSleepTimerHeading(toPlayStartingAt:)).
  A heading that has begun at the place speech starts is replaced by the one after that place, and one still ahead of it is kept (ReaderViewModel.sleepTimerNextHeading, found once a loading book has its headings; nil after the last heading, which ends with the book).
  The reader's refresh, at most every 0.12 s, asks whether playback reached it (stopForSleepTimerIfPlaybackReachedHeadingEnd, through waitsForHeadingEnd(ownedBy:)) and, if so, stops playback, puts the cursor at that heading, and ends the timer (expireAtHeadingEnd(by:)).
  A move forward to or past it ends the timer the same way, after the move's own announcement (endSleepTimerIfMoveReachedHeadingEnd).
  A move back leaves it waiting.
  Where a chapter's speech or audio ends, the reader asks whether its own timer stops playback there and, if so, ends it (expireAtChapterEnd(endingTheHeading:endingTheBook:by:), deciding through stopsPlaybackAtChapterEnd(endingTheHeading:endingTheBook:ownedBy:)).
  End of heading stops there when the next chapter opens with the next heading (ReaderViewModel.chapterEnding(beforeChapter:), through headingHasBegun(_:atStartOfChapter:text:)).
  That is where End of chapter and End of heading differed, since a next chapter with text before its first heading, or none, plays on under the heading.
  End of heading and End of book both stop at the last chapter's end, the book's.
  A timer ended so stops as stop() stops it, with no fade left to run and no expiry callback.
  The duration last started, in any window, is one preference for the app, saved as sleepTimer.lastUsedDuration at every start (rememberLastUsedDuration(_:)) for Restart Sleep Timer.
  It is kept in the registry too (SleepTimerRegistry.noteStarted(_:savedIn:)), which every timer's lastUsedDuration reads once a timer of that registry has started (lastStartedDuration(savedIn:), only for a timer saving in the same store), the preference only until then.
  So a restart in another window repeats the duration the first one started at once, whatever the store answers.
  A saved endOfChapter or endOfDocument restores as End of heading.
  A reader that closes stops the window's timer if it owns it, unless the timer is held for the next book from that reader (the next entry): closing a window stops only its own timer, and a window that went on to another book in place has a new owner, so the closing old reader leaves it alone.
  Restart Sleep Timer is a reader's own:
  - a key carries the window it was pressed in (sourceWindow),
  - a menu command follows the key window (WindowCommandRouting.shouldAccept(sourceWindow:hostWindow:keyWindow:), a sheet counting as its window),
  - and the media gesture, which belongs to no window, names the reader that owns Now Playing, the playing one or, while none plays, the focused one (NowPlayingService.restartGestureOwnerKey in the notification's userInfo, from the coordinator's activeOwnerID as the gesture ends).

  Only that reader acts (acceptsSleepTimerRestart(_:), which writes RESTART_ROUTE_RECEIVED, ACCEPTED, or REJECTED to the timer's log, a gesture with no owner going to the focused reader, or to one with no window).
  The reader then resets its running timer, "Timer reset.", or starts its own with the duration last started, "Timer restarted: DURATION."
  (restartOrStartLastSleepTimer()).
  Show Sleep Timer takes the same route to the key window's reader (ReaderPanelCommands.shouldAcceptPanelCommand).

### How the sleep timer is observed
<!-- id: sleep-timer-observers; keys: sleep timer sheet, spokenLabel, fade out, handleEndOfBook, m4b chapter marker, textmouth_timer.log; src: TextMouth/Services/SleepTimerService.swift, TextMouth/Views/Reader/SleepTimerView.swift, TextMouthProductionTests/WindowSleepTimerTests.swift -->

- How others observe it: each window's sleep timer sheet shows its own window's timer (SleepTimerView.sheet(for:onClose:), the one way a reader's sheet is made: the timer the reader owns, a start that plays the book unless it plays already, and the Close that clears the reader's panel).
  So two windows' sheets show two timers and stay open together.
  A sheet shows End of heading and End of book in its Stop At section, after the minute presets and the custom minutes (SleepTimerView.endOfHeadingTitle, endOfHeadingLabel, and endOfHeadingHint, and the End of book constants).
  VoiceOver reads the timer's status, in the sheet and in the reader, as spokenLabel, such as "Sleep timer: 4:59 remaining" or "Sleep timer: stops at the end of this heading".
  The owning reader's callbacks fade out and pause its playback when a timer counting minutes runs out (sleepTimerExpiredAnnouncement):
  - an audiobook through its volume,
  - and speech through setSleepTimerFadeVolume(_:duration:), which never switches direct speech to rendered audio ([Speech for text books](media-playback.md)).

  A stop at the heading's end, within a chapter or with one, announces sleepTimerStoppedAtHeadingEndAnnouncement, "Sleep timer expired at the end of the heading.
  Playback paused."; at a chapter's end the reader stops before the next chapter starts (stopForSleepTimerAtChapterEnd(of:nextChapterIndex:)): its cursor waits, saved, at the next chapter's start, and a text book discards the chapter rendered ahead unplayed.
  At the book's end, handleEndOfBook starts the book again only when no timer of the reader's stops there, and continues to the next book unless a timer of the reader's ends listening there.
  One fading out, or one set for the end of a heading or of the book, which this end reaches (sleepTimerEndsListeningHere, decided before a timer that stops playback here ends).
  A timer counting minutes goes on with the next book (the next entry).
  VoiceOver hears why nothing follows.
  An audiobook fades out toward a stop at a chapter's end over the timer's fade-out time, its volume following the time left in the chapter at the playback speed (fadeOutBeforeSleepTimerStop(), from AudioPlaybackService.timeLeftToPlay).
  So a pause holds the volume where it is and cancelling or replacing the timer restores it.
  Speech is not faded toward such a stop.
  An m4b's chapter marker inside one file stops the timer through the heading path, a moment past the marker, at the next refresh after an audio position update, without a fade.
  Since AudioPlaybackService.timeLeftToPlay measures the file, not the chapter. textmouth_timer.log records each timer from start to expiry.
- Tests:
  - WindowSleepTimerTests:
    - two windows each counting, pausing, and running out their own timer,
    - a book opened beside a paused timer,
    - the timer going on in place between text and audio books four ways,
    - the new window taking it,
    - closing a window,
    - the routing of the menu command, the key, and the gesture,
    - two sheets open together,
  - SleepTimerRegistryTests,
  - and the hand-over tests listed in the next entry.

## The sleep timer held for the next book
<!-- id: sleep-timer-held-next-book; keys: sleep timer hand over, next book, held timer, timer follows book, timer log, Next in Folder; src: TextMouth/Services/SleepTimerService.swift, TextMouth/Services/SleepTimerRegistry.swift, TextMouth/Models/SleepTimerHandOverWording.swift, TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift, TextMouth/ViewModels/ReaderViewModel+BookMoves.swift, TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Services/ReaderRequestStore.swift, TextMouth/Views/Reader/BookReaderWindowView.swift -->

The sleep timer held for the next book (0.2.5): a running timer goes on with listening to another book, in the same window or another.

- Owner:
  - the window's SleepTimerService (the previous entry), which holds its timer for one book at a time (heldForBookID, from heldFromOwnerID, with askedBookID, holdGeneration, and heldBookIsOpen), not a request store, whose requests live 30 seconds,
  - and SleepTimerRegistry.shared, which finds the timer held for a book in whichever window (timer(heldForBook:), isHeld(forBook:)) and passes each call about a book to that timer:
    - markAsked(forBook:),
    - dropHold(forBook:),
    - releaseHeld(forBook:reason:announcingAfter:),
    - and cancelHeld(forBook:).

  The registry keeps a timer alive while it is held for a book (setRetained(_:_:), isRetaining(_:)), as the one shared timer always outlived every window, and stops any other timer held for the same book when a timer is held for it (noteHold(of:forBook:)).
  Two windows moving to one book is the only way two could, and the later hold wins.
  The retention rule is the timer's own (updateRetention(), at every end of a hold, clearHold()).
  The registry keeps a timer while it is held, and, once its hold has ended, while a fade it was in runs on.
  It lets the timer go when the timer stops (stop() ends the fade first) or its fade ends and it runs out (noteExpiry()), and a timer whose hold ends while it is only running or paused is its window's again.
  The mark that a held timer ran out for a book before the book's reader took it is the registry's too, by book (noteExpiredWhileHeld(forBook:bySerial:), expiredWhileHeld, asked through consumeExpiredWhileHeld(forBook:); the timer's expiredWhileHeldBookID reads it).
  So it outlives a timer whose window has closed and been let go.
  Each timer has a serial number from the registry (nextSerial()), which names its marks without keeping it alive, and a start, a take, or a new hold forgets only that timer's own mark (forgetExpiredMarks(ofSerial:)), while releaseHeld and cancelHeld forget the book's, whichever timer made it.
  The registry counts every start, hold, and take in any window (timerChanges, noted by noteTimerChange()), which the sentence owed after a stop reads (below).
  Its asksMade subject tells, with the book's ID, each time a timer held for a book is asked for, so a reader already open for the book in any window takes the timer.
  The timer stays the old reader's from the moment a move is announced, the one owner it has, until the reader that opens the next book takes it; the countdown, the duration, and a countdown halted by the old reader's pause are never changed by the move.
  The last-resort deadline is heldTimerDeadline, 20 minutes, armed with each hold (armHoldDeadline(forBook:generation:after:)).
  It acts only when no reader is open for the book, which the service asks the library's registry of open readers through the check the hold was given (isBookOpen:, the reader's bookIsOpenCheck, kept as heldBookIsOpen and cleared with the hold).
  Otherwise it looks again a deadline later, as a download keeps its autoplay request.
  The registry of open readers is LibraryViewModel.openBookIDs, counted per book by registerOpenBook(_:) and unregisterOpenBook(_:) over openReaderCounts, in [A reader window's book changes in place](windows.md).
  The check asks isBookOpenNow, the registry's synchronous truth, since the published set follows a turn late ([why](windows.md#the-registry-of-open-readers-and-when-it-publishes)).
  The service does not know the library. expiryCount counts the times a timer has run out and only goes up; lastExpiredOwnerID and lastExpiryNumber say who it ran out for, and when.

### Who may write the held timer
<!-- id: held-timer-writers; keys: hold, hold deadline, passOnHold, releaseHeld, take, restartHeld, expiredWhileHeld; src: TextMouth/Services/SleepTimerService.swift, TextMouth/Services/SleepTimerRegistry.swift, TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift -->

- Who may write it: the timers alone write the fields, each its own, through these calls, which the readers reach through the registry when the timer is not their window's.
  A reader that announces a move (noteMoveAnnounced(to:) and holdSleepTimer(forBook:) in ReaderViewModel+SleepTimerHandOver) does one of two things:
  - it holds its window's timer (hold(forBook:from:deadline:isBookOpen:), when isCarriable(by:): it owns a running timer that is counting minutes or waiting for a place and is not fading out),
  - or it passes on a hold made for its own book, whose reader has not taken it, by whichever window's timer holds it, to the book it moves to (passOnHold(fromBook:toBook:deadline:isBookOpen:returning:)).

  The returning flag of passOnHold puts a hold back where it was for a cancelled move, even while the timer fades.
  The same code also notes moveCarriesSleepTimer and moveExpiryMark, the expiry count as the move began, and, for the move that cancels it, undoes (undoPendingMoveHold(), cancelAskedMoveUnderWay()).
  The ask, half a second later, calls markAsked(forBook:), through the registry, which lets a reader take the timer and tells a reader that is open already, in any window, through asksMade.
  A reader open for the book takes it as its load ends, before the autoplay claim (claimSleepTimerHandOver(), from the load, or from asksMade), into its own window's timer with take(heldForBook:from:as:onExpire:onFadeStep:onFadeCancelled:), where the source is the timer held for the book.
  From the window's own timer, which a switch in place leaves held, the owner and callbacks change and the hold ends (adoptHeld(forBook:as:onExpire:onFadeStep:onFadeCancelled:), transferOwnership).
  From another window's timer, as when the book opened in a new window, or in its own window brought forward, this timer takes the source's running state in place of any timer of its own.
  The duration, the seconds left (secondsLeftNow), the fade-out time, and a countdown, counting or halted by the previous owner's pause until the new owner plays (resumeCountdown(by:)), never reset or restarted.
  The source stops without a word, its hold ended, so its window shows none, and a timer fading out is never taken (isCarriable(by:)).
  Then refreshSleepTimerHeading() makes a timer for the end of a heading wait in the new book.
  The method restartHeld() resets a minutes countdown to its full duration, keeps the hold and the owner, resumes no reader, and ends a fade the held timer is in, restoring the owner's volume.
  It is called by restartSleepTimer(startPlaybackIfNeeded:) for the reader's own window's timer, and for the one on its way to the reader's book from another window, sleepTimerComingHere.
  A held fade is otherwise left to run out, whether a Pause reaches the old reader or it closes, so the expiry is said once, even if the reader has gone, and the book is not started.
  The method releaseHeld(forBook:reason:announcingAfter:) stops a timer held for a book that truly cannot open and says SleepTimerHandOverWording.noBook after the delay, only if no timer in any window has started, been held, or taken one since (SleepTimerRegistry.timerChanges).
  So a Restart in another window meanwhile is not contradicted.
  The method releaseHeld is called:
  - from a load failure (showLoadFailure) and a cloud opening that stopped or failed (stopOpening(at:announcing:)), both with afterTheReason, 3 seconds, so the reason is read first;
  - BookReaderWindowView.makeReader for a book deleted since the window was asked for, the same;
  - ReaderOpenRefusal.dropRequests(for:), at once, when the Library refuses the open;
  - and the deadline.

  The method cancelHeld(forBook:), from close(), stops it without a word when the reader's window closes while its book loads and no other reader of the book is left.
  The method dropHold(forBook:) ends a hold without stopping the timer, for a timer that fades out as its book would take it, and for a cancelled move's own hold.
  Starting, stopping, and replacing a timer, and its running out (noteExpiry()), each end the hold.
  A timer that runs out while held leaves the registry's mark for the book (the registry's expiredWhileHeld, above), which the book's reader asks once (consumeExpiredWhileHeld(forBook:)).
  And the move's own check, didExpire(whileOwnedBy:sinceExpiry:) against moveExpiryMark, tells showNextBook that the timer ran out before the ask, and the book is then not started.
  A reader that finds the timer already fading out as it would take it drops the hold and does not start its book either (claimSleepTimerHandOver()).
  A move cancelled before it asks leaves no trace: the hold it made is undone, and the run-out mark of its target forgotten.

### How the held timer is observed
<!-- id: held-timer-observers; keys: isHolding, isHeld, SleepTimerHandOverWording, timer(heldForBook:); src: TextMouth/Services/SleepTimerService.swift, TextMouth/Services/SleepTimerRegistry.swift, TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift -->

- How others observe it: isHolding, isHeld(forBook:), isHeld(from:), isAsked(forBook:), and heldForBookID, and, for any window's timer, SleepTimerRegistry.timer(heldForBook:) and isHeld(forBook:), which ReaderViewModel.sleepTimers (its window's timer's registry) reaches.
  Until the new window's book has loaded the held timer is the old window's own, which its sheet shows and its Cancel stops, and the new reader's window shows none.
  ReaderViewModel.close() leaves a timer held from its reader running (isHeld(from:)).
  A closing reader stops the timer it owns otherwise, so closing the old window during an episode's download, when no hold is made yet, stops it, and only that window's: every other window's timer runs on.
  What still ends listening at a book's end is sleepTimerEndsListeningHere (a timer fading out, or one set for the end of a heading or of the book, which this end reaches), asked before the end's own timer ends.
  One set after the book has ended, such as during an episode's wait, is not spent by that end and goes on.
  The sentences are SleepTimerHandOverWording (noBook, afterTheReason, fadeEndedByTheMove) and "Timer reset." for a restart.
  A move ends a fade of any timer it carries (beginMoveToAnotherBook(), in [The reader](reader-navigation.md)), and the log textmouth_timer.log records HELD, RESTART_HELD, FADE_CANCELLED_BY_RESTART, TRANSFERRED, and the stops with their reasons.

## Listening checkpoints
<!-- id: listening-checkpoints; keys: reading_stats.json, Stats tab, Books Finished, listening session, streak, Recently Finished, sleep and wake, FinishedBookKind; src: TextMouth/Services/ReadingStatsService.swift, TextMouth/Models/ReadingStatsTile.swift, TextMouth/Views/Settings/ReadingStatsView.swift, TextMouth/Services/Feeds/FeedLifecycle.swift -->

Listening checkpoints.

- Owner: ReadingStatsService.shared: the statistics, saved as reading_stats.json, and the open listening session.
- Who may write it: a reader starts a session when it plays and ends it when it pauses or stops.
  Every 60 seconds a timer checkpoints the open session, crediting the time since the previous checkpoint and saving, so a crash loses at most a minute.
  The method markBookFinished(bookID:title:) counts each book once (P07): it writes an entry only for a book Books Finished counts for the first time, returns whether it did, and posts bookDidFinish at every end it is told of, so a feed item marked unplayed and heard again is played again.
  A rewind's replay of a finished end tells it nothing (finishAtTheEnd(replayingAFinishedEnd:), [The end of a chapter and of the book](../reading-a-book.md)).
  The entry records the book with its kind (FinishedBookEntry.kind, a FinishedBookKind: a text book, which an article a feed downloaded is too, an audiobook, or a podcast episode, an audiobook a feed downloaded).
  It is told while the library still holds the book, since a played episode's download is soon deleted.
  The feed engine installs the resolver on the statistics service (ReadingStatsService.finishedBookKind, answered by FeedCenter.finishedBookKind(of:)).
  It knows its episodes, an audiobook Move to Library… made of an episode among them, even once its feed's record is gone, by its package record's feed link, read once without downloading (cameFromAFeed(_:)), and reads any other book's format from the library.
  A kind a later version writes reads as none.
  No save is written while reading_stats.json is only in the cloud ([Files several Macs write](data-directory.md)).
  A save made while a data-directory move copies the library is provisional, and is made again once the move has ended ([Holding storage work](data-directory.md)).
  ReadingStatsService hears NSWorkspace's will-sleep and did-wake notices.
  Going to sleep checkpoints the open session and keeps a SleepNote, the moment with the awake clock (ProcessInfo.systemUptime, which stops while the Mac sleeps).
  Every credit after it, from the checkpoint timer, a session's end, or the wake's notice, begins no earlier than the wake the awake clock finds.
  So the night is left out of Today, This Week, All Time, the streak, and the book's total in whatever order the wake's events come, and even should the wake's notice never come.
- How others observe it: the Books Finished figures count ReadingStats.countedFinishes, each book once, by the first entry naming it.
  So the repeats an earlier version wrote at each end of a book stay in the file and count once (booksFinishedAllTime, booksFinishedThisYear(at:), in the year of that first finish).
  And Recently Finished lists recentlyFinished(limit:), the last ten of them, newest first, its rows keyed by entry (FinishedBookEntry is Identifiable by its book and date).
  The Stats tab reads every figure at one instant on each tick (ReadingStatsFigures), including the open session's time since its last checkpoint, and the books finished by kind (booksFinishedThisYearByKind(at:) and booksFinishedAllTimeByKind, as FinishedBookCounts).
  A book finished before kinds were recorded counts by the library's answer while the library holds it, and in no kind after.
  The two Books Finished tiles show the kinds under the count and speak them with it (ReadingStatsTileWording.books(_:byKind:finished:)).

## Day keys
<!-- id: day-keys; keys: day key, Gregorian calendar, time zone, reading_stats.json, dayKeyVersion, Today, This Week; src: TextMouth/Services/ListeningDays.swift, TextMouth/Services/ListeningDayKeyMigration.swift, TextMouth/Services/ReadingStatsService.swift -->

Day keys.

- Owner: ListeningDays.
  A day key such as "YYYY-MM-DD" names one local day, written in the Gregorian calendar, the POSIX locale, and ASCII digits whatever the user's settings, in the time zone current when the time is credited.
  Time already credited never moves.
- Who may write it: ReadingStatsService credits time under these keys, and ListeningDayKeyMigration converts, once, keys saved under the system's own calendar (ReadingStats.dayKeyVersion).

## How the app's timers wake the Mac
<!-- id: how-app-timers-wake-mac; keys: timer tolerance, energy, wake-ups, power use, coalescing, watchdog, audit C16; src: TextMouth/Services/TimerCoalescing.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/LibrarySessionLease.swift, TextMouth/Services/SpeechService.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Views/Settings/ReadingStatsView.swift, TextMouthProductionTests/TimerCoalescingTests.swift -->

How the app's timers wake the Mac (the audit's C16).

- Owner: TimerCoalescing (Services/TimerCoalescing.swift): tolerance(forInterval:), a tenth of a timer's interval, and loosen(_:), which sets a timer's tolerance to that and returns the timer, so one expression makes and loosens it.
- Who may write it: the timers nobody hears or sees to the second:
  - ReadingStatsService's checkpoint timer (checkpointTimer),
  - LibrarySessionLease's timer,
  - the two speech watchdogs' RunLoopWatchdogTimer (SpeechService),
  - and the Stats tab's refresh (ReadingStatsView, through Timer.publish(every:tolerance:on:in:)).

  The speech position timer has its own tolerance, 20 ms of its 100 ms (SpeechService.positionTimerTolerance), so a word's highlight moves by no more than a frame.
  The sleep timer's countdown keeps no tolerance, since its announcements and its expiry are heard.
  Its one-second Timer is on the main run loop, and its tick acts in its own turn through MainActor.assumeIsolated, with no hop to the main queue and no second wake-up, which traps should the timer ever run elsewhere.
  The timer's generation is checked first, so a tick of a countdown that was replaced does nothing, and a countdown whose service is gone invalidates its timer.
- How others observe it: nobody does; a timer fires up to a tenth of its interval late, which macOS can fold into other work.
  TimerCoalescingTests read each timer's tolerance, and read that the countdown's is zero (SleepTimerService._fireCountdownTimerForTesting()).
