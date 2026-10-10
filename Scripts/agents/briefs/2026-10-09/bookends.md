# Task brief: bookends — P07, a book that ends rests at its end and says Finished

Slug `bookends`; branch `fix/book-ends-finished`. Read `common.md` beside this file first; its usage override ended at the 8:00 a.m. reset on October 10, so the normal rule applies: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count as your baseline.

## The design and the user's answers
`END-AND-JUMP-RESEARCH-2026-10-10.md` sections 1 (how a book ends today), 3 and 5 (the P07 options and design), 6, and 8's "Branch A" and "Branch B". Build A and B in that order on this one branch, with the changes the user's answers make (P07's entry in TODO-2026-09-04.md quotes them all; `humanQuestions/2026-10-10.md`, questions 11 to 16):
- (11) yes: a book that plays to its end is saved exactly at its end, and stays finished after TextMouth quits (`Book.restsAtEnd`, no new stored field, as the note proposes).
- (12) "yes except the reader, those controls with the info should still be there": the library row, Speak Info, Where Am I?, and Copy Reading Position say "Finished" for a book resting at its end; the reader's own controls and status row keep their percent and time.
- (13) "I mean maybe this could be a setting but not by default, it should just say "fished" if there not enabled to move to the next book or start over... Maybe this mode should be added to the menu with the modes for what to do at the end of a book?": by default, Play on a finished book says "Finished" (with the book's title, pinned) and does nothing else: no replay of the last word, no new count. A new end-of-book choice, in the same menu as Stop, Loop, and Continue to Next Book (globally and per book, as the others are), makes Play on a finished book start it over from its first chapter with words, saying "Starting again: <title>"; name it plainly (for example "Stop, and Play starts over") and say what you chose. Continue to Next Book and the reading list's continuation behave as today.
- (14) yes: a rewind after the end (B02: the AirPods' or the keyboard's Skip Backward replays the end) played on to the end again does not count again.
- (15) "yes, only one finish per book for now": Books Finished counts each book once, whatever ends it how many times; Loop never counts and keeps waiting at its beginning under an End of book timer.
- (16) yes: the books Books Finished already counts whose row says 100 percent are put at their end once (a one-time move with its log line; 27 of the user's 28; the one at 99 percent stays).
- Recently Finished is keyed by entry, so one book is listed once (the note's follow-up).

## This user's data comes first
The one-time move and the one-finish rule must never lose a place or a Stats entry the user would miss: the move changes only the positions of counted books whose row reads 100 percent, and Books Finished's existing repeats are kept in the file but counted once (say exactly what the user's Stats will show: the note found 67 entries for 28 books). Test on fixtures shaped like the user's; never touch `~/.TextMouth`.

## Files you own
`ReaderViewModel+Playback.swift` (`handleEndOfBook`, `play()`, `performSkip`, `stop()`), `ReaderViewModel+Navigation.swift` (`navigateTo`'s end handling and `clampedNavigationPosition`), the reading list's end (`finishBookReadFromReadingList`), `AudioPositionObserverPolicy`, `Book` (`restsAtEnd`), the end-of-book behavior and its menus and wording (`EndOfBookWording`, the Playback tab's and a book's picker), Books Finished and Recently Finished in the Stats model and view, the row, Speak Info, Where Am I?, and Copy Reading Position wording, the one-time move in `LibraryViewModel+Migration.swift`, and their tests. `a11fixes` owns the reader's speed sheet and toolbar in `ReaderView.swift` and `LibrarySortState`; `feeddelete` owns the feed files (`FeedLifecycle.bookDidFinish` is theirs: post on the board if one finish per book needs a change there); expect adjacent-line conflicts in `ReaderView.swift` and keep both sides.

## Verify or report as unverified
Real AirPods, VoiceOver, and listening are unverified; list what the user should try by hand (finish a book, press Play; rewind with the AirPods; the new end-of-book choice). Report the README and ARCHITECTURE wording and the TODO sentence.
