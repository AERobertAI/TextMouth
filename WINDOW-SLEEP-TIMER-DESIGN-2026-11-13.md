# The sleep timer, one for each reader window: design (November 13, 2026)

Branch `feature/window-sleep-timer`, lead `wintimer`. Brief: `Scripts/agents/briefs/2026-11-13/wintimer.md`.

The user, November 13: "I noticed that the sleep timer still appeared when going from book to book but playing had it stuck... maybe this is from moving from a text book to a audio book when I saw it? Anyway I want each sleep timer to be refactored to be per book view window not global if you understand..." And on November 1: "the sleeping timer in particular I would like to move still running to the new book without a new window opening." Both stand.

## 1. The stuck timer: what happened

The timer log (installed app 0.4.2) shows reader A5084DDE's 15-minute timer paused at 2:40 from 00:25 to 03:19, a pause from reader 98722863 ignored as "owner-mismatch" at 01:00, and no `HELD` or `TRANSFERRED` line. So no move went from A to the other book: the other reader, B, was opened on its own while A stayed open, from the Library (a book, a reading list row, a feed episode) or as a second window. Every window showed the one shared timer (`SleepTimerService.shared`, read by `SleepTimerView`, `ReaderView`'s status line, and `PlaybackControlsView`'s label), so B's window showed A's timer, which B's Play and Pause could neither run nor stop, since they pass B's own `readerID` and the service ignores any but the owner's.

- The kinds of book play no part: text then audiobook (the user's guess) does it, and so does any pair.
- A did not outlive its window. A closing reader stops the timer it owns, and A's was still running at 03:19 when a new one replaced it; nothing in the log says A's `close()` was skipped.
- A owned the 03:19 timer, so A started it: from its own window, or from the Restart Sleep Timer media gesture, which goes to the last timer's owner (A) and not to the book being heard (B), so it restarted A's timer and played A. Both causes are removed: each window has its own timer, and the gesture goes to the reader that owns Now Playing (section 5).

Pinned by `WindowSleepTimerTests`: a book opened beside a reader holding a paused timer shows no timer, its Play and Pause leave the other timer alone, and it sets a timer of its own without replacing the other (all four pairs of text and audiobook; fails on main, where the second reader shows and shares the first's timer); and the restart gesture reaches the book being heard (fails on main, where it reaches the last owner).

## 2. Where each window's timer lives

- **One `SleepTimerService` per reader window.** The "Book Reader" `WindowGroup(for: UUID.self)` gives its content a root view of its own, `ReaderWindowContent` (in `BookReaderWindowView.swift`), which keeps the window's timer as a `@StateObject` and shows `BookReaderWindowView(...).id(bookID)` below it. The identity `.id(bookID)` gives each book is below the timer's, so a book changing in place makes a new reader and keeps the window's timer.
- **How a reader finds it.** It is given it as it is made: `BookReaderWindowView` passes its window's timer to `makeReader`, and `ReaderViewModel.init(sleepTimer:)` keeps it, for the reader's life, as `sleepTimerService`. A reader made with none, as a test makes one, has a timer of its own on the Mac (a window of its own would), and `SleepTimerService.shared` on the iPhone.
- **The iPhone.** It shows one reader at a time and keeps its one timer: `SleepTimerService.shared` exists on iOS only, and every reader `PhoneSession` makes shares it, so its hand-over stays within one timer, exactly as now.
- **The last timer used** (`sleepTimer.lastUsedDuration`) stays one preference for the app: `lastUsedDuration` is read from the preferences each time it is asked, so a timer started in any window is the one every window's Restart Sleep Timer repeats.

## 3. The registry: `SleepTimerRegistry.shared` (new)

What a window's timer cannot say about itself: which timer is on its way to a book from another window.

- Every `SleepTimerService` registers itself as it is made, weakly. A timer held for a book is also retained by the registry until its hold ends, so a timer carried from a window that has closed lives until the next book takes it, as the shared timer always lived.
- `timer(heldForBook:)`, `isHeld(forBook:)`, `markAsked(forBook:)`, `dropHold(forBook:)`, `consumeExpiredWhileHeld(forBook:)`, `releaseHeld(forBook:reason:announcingAfter:)`, and `cancelHeld(forBook:)` find the timer held for the book (or marked as having run out for it) and call that timer's own method, which is today's, unchanged.
- `asksMade` tells the asks of every timer, so a reader open for a book in another window hears that a timer is asked for its book (it was each timer's own subject).
- **One hold per book.** A hold for a book stops any other timer held for that book: two windows moving to one book within the same moment is the only way, and stopping rather than releasing leaves no timer running for a reader that closed or moved on.

## 4. The hold machinery: what stays, what goes

- **Stays, unchanged in meaning: the hold.** Every move holds its reader's running timer for the next book as it is announced (`noteMoveAnnounced(to:)`), because the window choice is made only at the ask, half a second later (the window may close, a sheet may open), so at the announcement a move cannot know whether its timer will stay in this window. `hold`, `passOnHold`, `markAsked`, the 20-minute `heldTimerDeadline` with its `isBookOpen` check, the run-out mark, `restartHeld`, `releaseHeld`, `cancelHeld`, `dropHold`, `pendingMoveHold`, `askedMove`, and the expiry count all live in the timer that is held, and the registry finds it. A per-window timer would make the hold unnecessary only after an in-place switch, which the hold already covers; the new-window case needs all of it.
- **Changes: the take.** `take(heldForBook:from:as:onExpire:onFadeStep:onFadeCancelled:)` replaces `adoptHeld`:
  - the same timer (an in-place switch: the window's own timer, held from the reader before): owner and callbacks change, exactly as `adoptHeld` did;
  - another window's timer (A New Window, a busy window, the book's window brought forward): this window's timer takes the running state (the duration, the time left, a countdown halted or counting, the fade length), replacing any timer of its own, and the other stops without a word (`STOP reason=taken into another window`). The countdown is neither reset nor restarted, and a timer fading out is never taken (unchanged).
- **Changes: the reach.** Wherever the hand-over asked the shared timer about a book (`isHeld(forBook:)`, `isAsked`, `consumeExpiredWhileHeld`, `markAsked`, `dropHold`, `passOnHold` for a book still loading, the fade a move ends, the release on every way a book cannot open, `ReaderOpenRefusal.dropRequests`, `PhoneSession.refuse`), it asks the registry. Wherever it asked about the reader's own timer (`isCarriable(by:)`, `isHeld(from:)`, the pause, the close, `sleepTimerEndsListeningHere`, the episode wait's expiry mark, `didExpire(whileOwnedBy:)`), it asks the reader's window's timer.
- **New: the timer coming here.** `sleepTimerComingHere` is a timer held for this reader's book in another window. Restart Sleep Timer restarts it where it is (`restartHeld`), as a restart reached the one timer; starting or cancelling a timer in this window stops it, as starting a timer replaced the one timer.
- **Gone.** `lastOwnerID` and `forgetLastOwner` (the gesture goes to the Now Playing owner); the sheet's `.sleepTimerSheetOpened` broadcast, which closed every other window's sleep timer sheet because they all showed one timer; `SleepTimerService.shared` on the Mac.

## 5. Commands and gestures, exactly

- **Show Sleep Timer** (the menu item, or its key): the key reader window's sheet, or the reader whose sheet is key (`WindowCommandRouting.shouldAccept`, unchanged), and that sheet shows its own window's timer.
- **Restart Sleep Timer, its key:** the post carries the window it was pressed in; that window's reader restarts its timer (or the timer coming to it).
- **Restart Sleep Timer, the media gesture:** `NowPlayingService` puts its active owner in the post (`restartGestureOwnerKey`: the playing reader, else the one last focused or played, which keeps its book shown paused); only that reader acts, on its own window's timer. With no owner, the focused reader acts: the key or main window's, or a reader with no window, today's fallback.
- **Remote commands** (Play, Pause, skips from the AirPods and media keys): the active owner, as before; its own timer's countdown resumes and halts with its playback.
- **The sheet's Reset Timer and Cancel Timer:** that window's timer.
- **Closing a window:** its reader stops its own window's timer unless the timer is held for the next book, and stops a timer carried to its own book only when no reader of that book is left (both unchanged).

## 6. Today's behaviors, mapped

Every case the six rounds of November 1 fixed (the letters of the next-book design note) and the tests that pin them:

| Behavior | Per window |
| --- | --- |
| A running timer goes on with a switched window | The window's own timer, held and taken in place |
| A running timer goes on with a new window | Held in the old window's timer, taken into the new window's as its book loads |
| A timer fading out is not held; a move ends a fade it carries (Q13, X3, Y1) | The fading timer is the reader's own or the one held for its book, in any window |
| Command-W before the ask: the book opens in a new window and takes the timer | The registry keeps the held timer alive until the new window takes it |
| A second move before the first book loaded passes the timer on (V2, V4) | `passOnHold` on the timer held for the loading book, wherever it is |
| Next then Previous asks once; the ask never replaces a later hold | Unchanged (the reader's own timer's `isHolding`) |
| A held timer is kept while its book's reader is opening it (V1); a slow load | Unchanged, in the held timer |
| Restart during a hold, during a held fade (V3, W3) | The old reader (its own timer is held) and the book's reader (the timer coming to it) restart it; a third window's reader restarts its own timer |
| A close or a Pause during a held fade leaves it to run out (V5, W2) | Unchanged: the old reader's own timer |
| The delayed "could not be opened" sentence (W4); the expiry said with the reader gone (W5) | Unchanged, per timer |
| Two readers of one book (W6); the deadline and the registry of open readers | Unchanged |
| The last move wins (X1, question 17); the request's date (Y2); the run-out mark (X2) | Undone, marked, and consumed in whichever timer holds the book |
| Refused opens, deleted books, failed loads and downloads release the timer (V6, V7) | Through the registry |
| An episode's wait, End of heading and End of book at a book's end | The waiting or finishing reader's own timer |
| The heading timer waits for the heading in the next book | Unchanged (`refreshSleepTimerHeading()` after the take) |
| A timer belongs to the reader that set it, not to its book | Each window's own timer; the owner check stays, for the old reader of a switched window |

## 7. Assertions the per-window rule changes

- A timer started, restarted, cancelled, or run out in B's window is B's own and leaves A's alone (`WindowsMatrixTests` column 7, which pinned the shared timer "under question").
- The restart gesture goes to the reader that owns Now Playing, not to the last timer's owner (`IntegrationSleepTimerTests`); `lastOwnerID` is gone from every test.
- A restart from a third window starts that window's own timer and leaves the one held for another book (`NextBookWindowReaderTests`).
- After a hand-over to a new window, the new window's timer has the state and the old window's has stopped (it was one timer whose owner changed).

## 8. The commits

1. This design.
2. The registry and the cross-window take, beside the shared timer, with their unit tests.
3. Readers take their window's timer (the scene's `ReaderWindowContent`, `makeReader`, the reader's `sleepTimer:`); the hand-over reaches held timers through the registry, and takes across windows; the shared timer stays the default of a reader made with none, so every older test still passes. `WindowSleepTimerTests` drives readers in windows of their own.
4. The gesture goes to the Now Playing owner; `lastOwnerID` goes.
5. The sheet: each window's own, the broadcast gone.
6. The tests moved off the shared timer, file by file.
7. The Mac's shared timer removed: a reader made with none has its own; `SleepTimerService.shared` on iOS only.

## 9. Decisions, each with the question for the user

1. A timer carried to a window that already has its own running replaces it: listening goes on under the timer the listener had while listening. The other choice: keep the window's own and stop the carried one.
2. Two windows may each show their sleep timer sheet at once. The other choice: opening one still closes the others.
3. During a hand-over to a new window, the timer shows in the old window until the next book has loaded, then in the new one. The other choice: the new window shows it from the moment it opens.
4. With nothing playing, the restart gesture goes to the reader whose book Now Playing shows, the one played or focused last.
