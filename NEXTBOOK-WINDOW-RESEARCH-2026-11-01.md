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
- **The guarantee.** A switch leaves a claim (`WindowSwitchRequests`, a `ReaderRequestStore`, made with the other requests before the switch). The reader that takes the window over claims it in `attach(to:)`, once its window is found, and `SwitchedWindowFocus.place(in:)` looks 1.6 seconds later: if the window is key and VoiceOver is not on the marked element, it posts the same notifications. A reader opened for a new window finds no claim, and does nothing more than before.

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
  - Gone: "Opening: <title>. Not started because of the sleep timer." A running timer goes on with the book. New: "Sleep timer cancelled, because the next book could not be opened." The end of a book's own sentences are unchanged.

## The sleep timer goes on with the book (the user, November 1: "yes for all 3, the sleeping timer in particular I would like to move still running to the new book without a new window opening")

- **Rule.** When listening goes on from a book (its end, Next and Previous in the reading list and in the folder), a running timer its reader owns goes on, in this window or another. `showNextBook` asks as it shows the book (`handOverSleepTimer(to:)`: `SleepTimerHandOverRequests`, a reader request store, made before the switch or the notification); the reader of the next book adopts it (`SleepTimerService.transferOwnership`) as its load ends, before the autoplay claim, or as the request is made when it is open already. Owner and callbacks change; the countdown, duration, and a countdown halted by a pause do not (the new reader's play resumes it). A timer waiting for a heading's end then waits in the new book.
- **What still ends listening.** A timer fading out, or set for the end of a heading or of the book that this book's end spends (`sleepTimerEndsListeningHere`): "Finished: <title>. Next book not started because of the sleep timer." is unchanged. A minutes timer no longer keeps the next book from starting.
- **A fade at a move.** A command's pause during a fade does what the listener's own Pause does today (`pause()`: it stops the timer, ends the fade, restores volume), so a fading timer is not handed over, and the book moved to starts without a timer. At a book's end a fading timer ends listening.
- **Runs out before the new book takes it.** Noted as the move is announced (`moveCarriesSleepTimer`); at the ask, an expired or fading timer drops the requests and starts nothing (the expiry has said so). A load that ends after the expiry (`didExpire(whileOwnedBy:)`) drops the autoplay request. An episode wait does the same (`timerWasRunning`). A timer started during the wait goes with the episode. One the listener cancelled leaves nothing to take, and the book starts.
- **Hazards.** Exactly one owner: the old reader keeps it until the new reader adopts. Its `close()` leaves a handed-over timer running while the request waits (`isWaitingForTheSleepTimerToBeTaken`), and the old callbacks are replaced, so it never pauses a book it no longer holds. No taker (load failure, window closed first): the timer is stopped and said so. Restart Sleep Timer's last owner follows the new reader.

## Order of work

1. The rule, the global setting, and `ListeningOptions`' new key, with tests.
2. The switch in the scene, view, and reader.
3. The local controls in Feed Info and Folder Settings.
4. Next in Folder and Previous in Folder.

## Decided

- The folder commands, run in a book read from the reading list, go through the book's folder.
- A feed that stops at an item's end dims its choice, and the choice stops applying everywhere (the commands then follow the global setting).
