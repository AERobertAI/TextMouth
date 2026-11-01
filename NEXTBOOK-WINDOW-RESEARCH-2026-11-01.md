# Next book in this window (0.2.5), design note

Branch `feature/nextbook-window`, November 1, 2026. Brief: `Scripts/agents/briefs/2026-11-01/nextbook-window.md`.

## The mechanism

- **The scene** (`TextMouthApp.swift`, the "Book Reader" `WindowGroup(for: UUID.self)`) hands the view a closure that sets its own `$bookID`, and gives the view `.id(bookID)`. A new value gives the view a new identity, so SwiftUI makes a new `@StateObject` `ReaderViewModel` in the same `NSWindow` and tears the old one down.
- **The view** (`BookReaderWindowView`) stores the closure and gives it to its reader (`nextBookWindowSwitcher`) as the reader is made.
- **The reader** has one last step for every move, `showNextBook(_:under:openingANewWindowWith:)` in `ReaderViewModel+NextBookWindow.swift`. It asks the pure `NextBookWindowRule` what to do:
  - `.openANewWindow`: runs today's post (`.continueToNextBook` or `.openBookWindow`), exactly as now.
  - `.switchThisWindow`: marks the reader as switched, then calls the closure.
  - `.bringTheOpenWindowForwardThenClose`: today's post, which brings the book's window forward, then closes this reader's window on the next turn of the main queue.
- **Every request goes first**, as today: the autoplay request in `continueToNextBook`, the reading-list request in `continueThroughReadingList` and `openFromReadingList`. The new reader claims them once loaded (`claimAutoplayRequest`, `claimReadingListRequest`).
- **Who calls it.** The end of a book (`goOnPastThisBook`, through its `start` closure and `waitForNextEpisode`), the reading list's Next and Previous, and the new Next in Folder and Previous in Folder. The window choice is read when the book is asked for, never earlier.
- **Which setting.** A move through the reading list uses the global one. A move through a feed or folder uses that feed's or folder's own choice, when it has one and it goes on (`ListeningOptions.goesOn(under:)`), else the global one.

## Hazards and how each is met

- **Teardown against start.** `NowPlayingService`, the media coordinator, and `SleepTimerService` key everything by the reader's own `ownerID`: the old reader's `close()` clears, pauses, and unregisters only itself. A test checks it leaves a second reader's owner alone.
- **Unregistering the window.** The view's `onDisappear` leaves the window registered when the reader was switched (`hasSwitchedWindow`); the new view registers the same `NSWindow` in `onWindowFound`, and `registerReaderWindow` replaces any earlier entry. An ordinary close unregisters as before.
- **When the switch happens.** Only when the book is asked for: after `NextBookHandOver` asks, after the reading list's announcement, or when an awaited episode arrives. The old reader lives until then.
- **The old book.** Its place is saved and it ends finished, as today; the switch is the last step, and `close()` saves again.
- **VoiceOver.** "Starting" and "Opening" are posted before the half second's wait, as now, from the app's key window; the switch comes after.
- **Failures.** A deleted or unloadable next book shows what a newly opened reader shows; `BookReaderWindowView` already makes an "Unknown" placeholder for a missing ID.
- **Unchanged.** `markBookOpened` runs in the new view's `onAppear`; the open-book registry follows the readers' init and `close()`; reader windows are still not restored.

## Busy states: open a new window, as today, never lose work

The rule gives `.openANewWindow` (and a book already open elsewhere is brought forward as today, with this window left open) when `switchingTheWindowCouldLoseWork`:

- **The reader has closed, or its window is gone or off screen** (`NextBookWindowStanding.isOnScreen`: visible, minimized, or TextMouth hidden with Command-H, which orders every window out).
- **A sheet or an alert is open** on the window (`attachedSheet`): Edit Book Information, Search in Book, headings, bookmarks, sleep timer, voice, export.
- **A field is being typed in** (the window's first responder is a field editor): Go to Percent, Time, and Page are panels inside the window, not sheets, and the typing would reach the next book's single-key shortcuts.
- **Edit Text is in use** for this book (`BookTextEditSessions.isEditing`).
- **The library is moving or unavailable** (`dataDirectoryMove`, `dataDirectoryUnavailability`): `ContentView` refuses the open and drops the requests, which a silent switch would get around.
- **No switcher** is set (a reader made in a test).

## Focus after a switch

- **How a new reader gets its first focus.** No `FocusState` and no key view loop. The views mark one element with `voiceOverFocusID` (the play button, with `.background(StandardVoiceOverFocus())`; the progress bar and the message of the loading and error states, with `InitialVoiceOverFocusModifier`). The trigger view fires once, 0.8 or 1.2 seconds after it reaches its window: it finds the element, makes it first responder, and posts `.focusedWindowChanged` and `ScreenChanged`, twice, 0.3 seconds apart. The system announces a window that opens.
- **A switched window.** It is the same window: nothing announces it, and the old focused view has gone. The new views make the same trigger, which should place the focus; this is unverified.
- **The guarantee.** A switch leaves a claim (`WindowSwitchRequests`, a `ReaderRequestStore`, made with the other requests before the switch). The reader that takes the window over claims it in `attach(to:)` once its window is found, and sees to the focus once the book has loaded, when the play button's own trigger is due: `SwitchedWindowFocus.place(in:)` acts once, 1.6 seconds later, only in the key window and only when no trigger posted in that window since the load (`focusPostCount(of:)`); it shares its attempt with the trigger's own (`placeFocus`). A reader opened for a new window finds no claim, and does nothing more than before.

## What is new, word for word

- **Settings, Playback, below "When book ends":** a pop-up button.
  - Label: "Open the next book in". Choices: "This Window" (default), "A New Window".
  - Hint: "Where the next book opens when listening goes on from one book to another: in this window in place of the book here, or in a new window. A book already open in another window is brought forward, and with This Window this window closes."
  - config.json key `nextBookWindow`, the choice's name as its value, like `endOfBookBehavior`.
- **Feed Info and Folder Settings, beside "When an episode ends" and "When a book ends":** a pop-up button.
  - Label: "Open the next episode in", "Open the next article in", "Open the next item in", "Open the next book in".
  - Choices: "Use the global setting (This Window)", "This Window", "A New Window".
  - Hint: "Where the next episode opens when listening goes on from one of this feed's episodes: in this window, in a new window, or as the global setting says".
  - Hint while dimmed: "Available only while this feed's episodes go on to another episode when one ends".
  - A dimmed choice is not in effect, as the pre-download switch's is not.
- **Navigate menu, Shortcuts tab (no default keys):** "Next in Folder", "Previous in Folder".
  - Offered in a reader window.
  - Next goes the way the end of the book would go on: up in a feed or folder that plays the one above, down otherwise (Stop included); Previous goes the other way. The words "next" and "previous" follow the command; what lies that way ("before it", "after it") follows the way looked.
  - Spoken: "Starting: <title>" or "Opening: <title>" (the reading list's sentences).
  - With no item that way: the succession's own note and a full stop: "No more books in folder.", "Every book after it in the folder is finished.", "Every book before it in the folder is finished."
  - For an episode not downloaded: "Downloading the next episode: <title>", "Downloading the previous episode: <title>".
  - A failed download: "The previous episode could not be downloaded. <reason>", or ", so playback stopped" before the full stop when the book was playing. A cancelled one: "Download of the previous episode cancelled." (", so playback stopped" when it was playing). "Article" for an article.
  - Gone: "Opening: <title>. Not started because of the sleep timer." A running timer goes on with the book. New: "Sleep timer cancelled, because the next book could not be opened." and "Sleep timer cancelled, because you moved to another book while it faded out." The end of a book's own sentences are unchanged.

## The sleep timer goes on with the book (the user, November 1: "yes for all 3, the sleeping timer in particular I would like to move still running to the new book without a new window opening")

- **Rule.** When listening goes on from a book (its end, Next and Previous in the reading list and in the folder), a running timer its reader owns goes on, in this window or another. A timer counting minutes, or set for the end of a heading or of the book after this book ended, has not run out and goes on.
- **Where the held timer lives, and why.** In the shared `SleepTimerService` (`hold(forBook:from:)`), not in a request store, whose requests live 30 seconds. The hold is made as the move is announced (`noteMoveAnnounced(to:)`): the timer stays the old reader's, the one owner it has. The old reader's `close()` never stops it. The ask, half a second later, marks the book asked (`markAsked`), and only then may a reader take it.
- **Who is responsible.** A reader open for the book is opening it and is responsible for the timer, which it takes at its load or releases on every way it can fail. "Open" is the library's registry (`LibraryViewModel.openBookIDs`, counted per book by `registerOpenBook` and `unregisterOpenBook`, so a book stays registered until its last reader closes), the one registry there is (W6). The reader gives the service a check that asks it when it holds or passes on a hold (`isBookOpen`, kept with the hold and cleared with it); the service does not know the library. The twenty-minute deadline (`heldTimerDeadline`) acts only when no reader is open for the book, and looks again a deadline later while one is, as a download keeps its autoplay request (V1). A reader's close stops a timer held for its own book, without a word, only when no reader of that book is left.
- **The take.** The reader takes the timer (`adoptHeld`) as its load ends, before the autoplay claim, or at once through `asksMade` when it is open already. Owner and callbacks change; the countdown, duration, and a halted countdown do not. A timer waiting for a heading's end waits in the new book (`refreshSleepTimerHeading()`, also when a finished book starts over).
- **One move at a time (V2, V4).** `beginMoveToAnotherBook()` (and `handOverToNextBook` for a book's end) is the one start: it cancels an earlier move that has not asked (a command's ask, a hand-over), counts the book as playing when that move, an episode wait, or a pending autoplay was to play, ends any episode wait, and says the fade sentence. The hold made at the ask never replaces one made for another book (`isHolding`).
- **A move cancelled before it asks leaves no trace (W1).** The hold a move makes is noted (`pendingMoveHold`: its own timer held for the target, or a hold passed on from a still-loading target, with whether it was asked). A move that cancels it first undoes it (`cancelPendingMoves()`): its own timer is the reader's again, not held, or a passed-on hold is held again for the reader's own book, asked as before; the move's carry and run-out notes are forgotten. The cancelling move then holds as any move does. The folder commands' download branch holds nothing, and the wait's own move carries the timer when the episode arrives. The undo also consumes the run-out mark of the cancelled target, so a timer that ran out between the announcement and the cancel leaves nothing for a later move to that book (X2), and it returns a hold even while the timer fades out, since a return is no new carry (X3).
- **The last move wins until its book has started (X1; the user's question 17).** A move stays its reader's asked move (`askedMove`) until its book's reader claims the request to play it, the span of the hand-over's `isUnderWay`. A later move from the same reader, in that span, discards that request (the book opens in its window without playing), undoes the move's hold asked or not unless the book has taken the timer, counts the book as playing, and goes on as any move: "Starting: <title>", and the timer goes with it. Once the book has claimed its request and plays and owns the timer, a later move from the old window is an ordinary move from a book that is not playing: it only opens its book.
- **A move ends a fade of any timer it carries (question 13, X3).** Its own or one held for its book, as a target still loading carries one: the fade and the timer end, the book moved to starts, and "Sleep timer cancelled, because you moved to another book while it faded out." follows. `BookMoveStart.timerFadeEnded` is true exactly when the move ended a fade.
- **Restart while held (V3, W3).** `restartHeld()` resets a minutes countdown to its full duration, leaves a place timer, keeps the hold and the owner, and resumes no reader. During a held fade it is the listener saying they are awake: the fade is cancelled (the old reader's volume restored), the countdown restarts at its full duration, halted until the book that takes the timer plays, and "Timer reset." is said.
- **A fade before the take (V5, W2).** The old reader's close, or a Pause reaching it, leaves a held fade to run out: the timer's expiry is said once, and the book does not start. Its callbacks touch only the old reader's own audio and speech. The expiry's own pause stops the timer (`noteExpiry` clears the hold first), and a move's own pause ends a fade because the move undoes its hold first (W1). The expiry sentence is said even when the reader whose handler it is has gone (W5): the handler calls one static function with its reader weakly, which pauses the reader if there is one and says the sentence once.
- **Released.** On every way the book truly cannot open (load failure, cloud stop or failure, the Library's refusal, a deleted book's placeholder) the timer is stopped and "Sleep timer cancelled, because the next book could not be opened." is said after current speech, three seconds after a failure so the reason is read first (V7). Closing the target's window while it loads stops the timer without a word. A release or cancel clears the run-out mark for its book (V6). The delayed sentence is said only if no timer has been started or held since the release (W4). Release and cancel share one stop in the service.
- **What ends listening.** A timer that ran out, counted by the service (`expiryCount`, a counter that only goes up, V8) since a move that carried it, or an episode's wait, began; and one fading out. At a book's end the timer that this end spends ends listening: "Finished: <title>. Next book not started because of the sleep timer." is unchanged.
- **A fade at a command.** The command's pause does what the listener's own Pause does (it ends the fade and stops the timer), and the book moved to starts; "Sleep timer cancelled, because you moved to another book while it faded out." follows, after current speech.

## Order of work

1. The rule, the global setting, and `ListeningOptions`' new key, with tests.
2. The switch in the scene, view, and reader.
3. The local controls in Feed Info and Folder Settings.
4. Next in Folder and Previous in Folder.

## Decided

- The folder commands, run in a book read from the reading list, go through the book's folder.
- A feed that stops at an item's end dims its choice, and the choice stops applying everywhere (the commands then follow the global setting).
