# The end of a book, and the times of an audiobook (P07, P08)

A design note for P07 and P08, written before either is built. It draws on the code on main at 9ca9832d and on three scratch programs in the session's scratchpad (`endandjumps/`):

- **A time and jump program** (`endandjumps-times`). A generator copied ten blocks of the app's own code into it, byte for byte, and a checker confirmed all ten against main: `ReadingTimeEstimator`, `TimeFormatting`, `JumpInputValidator`, `AudioSpeed.normalized`, `AudioBookParser`'s placeholder arithmetic, `BookContentIndex.location(forGlobalOffset:)`, `DocumentContent.estimatedReadingTime(wpm:)`, `ReaderViewModel.clampedNavigationPosition`, `CountWording.phrase`, and `audioCharsPerSecond`. The reader's own formulas, which live inside `ReaderViewModel` and its views, are transcribed with the lines they come from. The program runs them on synthetic audiobooks and on today's reading text of the six text fixtures, which T06's measurement program had already extracted with the app's 3.0.7 parsers.
- **An offline speech probe** (`endandjumps-lastword`). It rendered the last passage of each fixture with the Mac's own synthesizer through `AVSpeechSynthesizer.write(_:toBufferCallback:)`, which plays nothing, in Samantha's compact voice, and recorded the last word range the synthesizer reported.
- **A count script** (`endandjumps-counts.py`). It read the user's library.json and reading_stats.json, and three settings from config.json (the end-of-book behavior, the words per minute, 500, and the skip-back units), and printed counts alone: no title, author, path, or note was printed or copied.

The debug logs were searched for tags. No audio was played, nothing in the app or the library was changed, and no app was built.

The items, quoted whole from TODO-2026-09-04.md:

- "P07 — Store a deliberate end-of-book position. P2 · Impact 3 · Difficulty 3 · Design. Completion commonly saves the last reported word/time rather than the exact endpoint. Decide how completed books show 100%, how Replay behaves, and whether loop counts as "finished." Acceptance: text, single-file audio, segmented audio, and resume-after-finish agree across the library and reader."
- "P08 — Define one time-coordinate convention for audiobook jumps. P2 · Impact 3 · Difficulty 3 · Design. Jump code (ReaderViewModel+Jump.swift) uses media time for audio while displayed total/remaining time can be speed-adjusted listening time. Decide which coordinate an entered time means and label it. Acceptance: at 0.5x, 1x, and 2x, a time copied from the display round-trips to the expected position."

## Summary

- **A finished book is not saved as finished.** When a book ends, its place is wherever the last progress report left the cursor:
  - a text book: the start of the last word speech reported, 4 to 9 UTF-16 units before the end in all six fixtures;
  - an audiobook: the last quarter-second tick of its player.

  Nothing in the book's row or record says it finished. The reader's finished state (`hasFinishedBook`) lives in memory only: closing the window, Release Media Controls, or a relaunch forgets it.
- **What the surfaces say.** For a typical book they say "100 percent" and "0 seconds remaining". A short book says "99 percent", and the reader shows "99.3%".

  A book whose last section is skipped stops before that section. With its licence skipped, alice.epub would rest at 90 percent, "6:06 left" at 500 words a minute. Books Finished, the reading list's Skip finished books, and a feed item's "played" mark each count the book's ends instead of reading its place.
- **Play on a finished book plays it to its end again.** A text book speaks its last word again, or nothing at all, and an audiobook plays its last fraction of a second. The book then ends again, says "Finished" again, and Books Finished counts it again.

  A rewind after the end (B02) counts it again too. Go to Percent 100 followed by Play counts a finish after at most a tenth of a second of audio. Nothing starts a finished book over.
- **Measured in your library.**
  - Books Finished holds 67 entries for 28 books. 12 books are counted more than once, 39 extra entries in all, and 20 of the repeats came less than two minutes after the finish before.
  - The Stats tab's Recently Finished shows 10 rows, but they are only 2 books: one of them 9 times, six of those within nine seconds on October 7, the day of the report that became B02.
  - Of the 28 finished books, 18 rows say "100%, 0:00 left", 9 say "100%" with 1 to 96 seconds left, and 1 says "99%, 1:40 left".
- **P08: Go to Time reads media time, but shows and checks listening time.** Go to Time takes a typed time as time in the recording (`jumpToTime(seconds:)`, 10 units a second). Its own starting value, its upper limit, the status row's time left and total, the Headings sheet's "time into book", Where Am I?, Copy Reading Position, and the library row all count listening time at the book's speed. Measured:
  - at 2x, opening Go to Time and pressing Jump moves an audiobook from 2:13:05 back to 1:06:32; at 0.5x, it moves it forward to 4:26:10;
  - a heading's "time into book" from the Headings sheet, typed back at 2x, lands half way to the heading;
  - a time from the recording itself (a chapter list, show notes, the audio editor) is refused past half the book at 2x: "Time exceeds book length";
  - at 2x, the book's total time typed back lands in its middle;
  - a copied "1:02:03" cannot be pasted at all: Go to Time has separate Hours, Minutes, and Seconds fields, each a whole number.

  8 of your 11 audiobooks play at 1.25x to 2x.
- **Recommendation for P07.**
  - The end of a book is a place: the last chapter's end, saved exactly whenever a book plays to its end. A book resting there is finished, which every surface says ("Finished"), including after a relaunch.
  - Play on a finished book starts it again from its beginning ("Starting again: <title>"). A rewind still plays its end again, as B02 made it.
  - Books Finished counts a book again only when it plays to its end anew, not when a rewind replays its end.
  - Loop still never counts.
- **Recommendation for P08.**
  - Every time that names a place in an audiobook counts the recording's own time, whatever the speed: what is typed into Go to Time, its starting value, and the Headings sheet's time into the book.
  - Amounts of time (time left, total time) stay listening time at the book's speed, and name the speed when it is not 1x.
  - Go to Time takes one field that accepts a pasted time, as the audio editor's Go to Time does.
  - Copy Reading Position adds the place's time. Simulated, this round-trips at 0.5x, 1x, and 2x to within the second the fields hold, and lands each heading's time exactly on its heading.
  - Text books keep times at the book's words per minute and say so.
- Section 7 asks eleven yes-or-no questions, each with a recommended answer. Section 8 plans three branches: the end place, its words, and the audiobook clock.

## 1. How a book ends today (P07)

### The paths to the end

- **A chapter's end.** `speechDidFinish(_:)` and `audioDidFinish(_:)` (ViewModels/ReaderViewModel+Playback.swift) save the position (`savePosition()`), then call `handleEndOfBook()` when no chapter follows (a text book passes over chapters with nothing speakable, `nextSpeakableChapterSpeech(from:)`).
- **Play with nothing left to say.** `play()` finds nothing speakable from the cursor and calls `endBookWithNothingLeftToSpeak()`, which calls `handleEndOfBook()` without saving. Speech started again by a skip or a jump while playing ends the book the same way (`speakCurrentChapter()`).
- **`handleEndOfBook()`** ends the listening session, sets `hasFinishedBook = true`, and then follows the reading list's options for a book read from it (`finishBookReadFromReadingList(sleepTimerEndsListening:sleepTimerStoppedHere:)`, ViewModels/ReaderViewModel+ReadingList.swift), or else the book's end-of-book behavior (`effectiveEndOfBookBehavior`).
- **Counting.** `ReadingStatsService.markBookFinished(bookID:title:)` appends an entry to `ReadingStats.finishedBooks`, with no check for one already there. It posts `.bookDidFinish`, on which `FeedCenter.bookDidFinish(_:)` marks a feed item played now, which restarts its delete-after-played clock.

| How the book ends | Place saved | Books Finished | Rests finished | VoiceOver hears |
| --- | --- | --- | --- | --- |
| Stop | the last progress report, saved before the end; nothing more | +1 | yes | "Finished: Dune" |
| Stop, with an End of book or End of heading timer | the same | +1 | yes | "Finished: Dune. Sleep timer expired." |
| Continue to Next Book, a next book in the folder | the same, saved again | +1 | no: the hand-over takes it back | "Starting: Emma" |
| Continue to Next Book, no next book | the same, saved again | +1 | yes | "Finished: Dune. No more books in folder." |
| Continue to Next Book, this reader's sleep timer in effect | the same, saved again | +1 | yes | "Finished: Dune. Next book not started because of the sleep timer." |
| Loop to Start | the beginning (chapter 0, offset 0) | no | no | "Restarting: Dune", and it plays |
| Loop to Start, with an End of book timer | the beginning | no | no | "Finished: Dune. Not restarted because of the sleep timer." |
| The reading list, a next book | the same as Stop, saved again | +1 | no | "Starting: Emma" |
| The reading list, Stop, the list's end, or only finished books beyond | the same, saved again | +1 | yes | "Finished: Dune. End of the reading list." (or the reason) |

The one place where loop and the timer disagree: a looping book stopped at its end by an End of book timer says "Finished", but it is neither counted nor at its end. It waits at its beginning.

### Where the place is when the book ends

- **A text book (EPUB, HTML, plain text, Markdown, Word, PDF, and a DAISY text book, which is read the same way).** The cursor follows speech's progress reports:
  - **Direct speech** reports each word's range as the synthesizer reaches it (`SpeechService.onWordSpoken`, mapped back through the offset map).
  - **Rendered audio** reports every tenth of a second the place its frames have reached (`SpeechService.startPositionTracking()`). That place comes from a map that spreads the text's characters evenly over the speech's frames (`AudioEngineService.frameMap(utf16Length:speechFrameCount:)`), and it is published only when it falls on a word.

  Either way the cursor ends inside the last word or on the punctuation after it. Measured with the offline probe, the last word reported starts 7 units before the end in the four Project Gutenberg fixtures ("eBooks."), 9 in sample.md, and 4 in test_book.docx.
- **A book whose last part says nothing.** The place lies before chapters with nothing speakable, a skipped last section, or text substitutions removed. Measured with each fixture's licence skipped (the last word before the heading):

  | Fixture | Skipped heading | Rests at | Short by | Row at 500 words a minute | At 200 |
  | --- | --- | --- | --- | --- | --- |
  | alice.epub | THE FULL PROJECT GUTENBERG™ LICENSE | 146,556 of 163,421 | 16,865 units | 90%, 6:06 left | 90%, 15:15 left |
  | frankenstein.html | THE FULL PROJECT GUTENBERG™ LICENSE | 421,394 of 438,259 | 16,865 units | 96%, 6:00 left | 96%, 15:01 left |

- **An audiobook.** The cursor follows the player's periodic time observer, every quarter second of the recording (`AudioPlaybackService.setupTimeObserver()`, through `onPositionUpdate`). `finishPlayback()` reports the end with no final position, so the place saved at the end is the last tick: up to 0.25 s of the recording (2 units) before the end.

  What happens after that depends on how the book's chapters lie in its files:
  - **One file, or a file per chapter.** No clip end is set. The setup's own comment says the observer also fires "whenever its time jumps or it starts or stops", so the pause that ends playback can deliver one more tick. `AudioPositionObserverPolicy.action(seconds:isSeeking:isPlaying:clipEndTime:)` publishes it, because without a clip end it publishes any time. That would move the cursor to the file's end after the end was saved, and `close()` would then save that place. A file whose measured length is shorter than its played end would put the place past its chapter's end, and the book would then reopen at that chapter's start (`showLoadedContent`), which for one file is the beginning.
  - **One file with chapter marks (an m4b), and a DAISY audiobook's clips.** A clip end is set, and ticks at or past it are ignored once playback has finished, so the place stays at the last tick.

  Which of the two comes first is AVFoundation's order. The hosted tests pin only "at or past the last half second" (`MediaCommandPlaybackTests.finishSilentAudioBook`). Your library shows both: 1 audiobook exactly at its end and 6 within its last second.
- **The finished state.** `hasFinishedBook` is set by `handleEndOfBook()` and taken back by:
  - Loop;
  - the hand-over;
  - `play()`;
  - `navigateTo(chapterIndex:characterOffset:)`;
  - `stop()`, which Release Media Controls and closing the window call;
  - a backward skip while another reader is the active owner.

  It is never saved, so a relaunch forgets it (the B02 merge entry: "P07 untouched: the finished state is not saved across a relaunch").

### What a finished book shows

| Surface | What it reads | A finished text book (fixtures, 500 words a minute) | A finished audiobook |
| --- | --- | --- | --- |
| Library row (`BookRow.progressText`, `remainingText`) | the saved place's share, rounded (`%.0f`), and `Book.estimatedTimeRemaining(wpm:)` | "100%, 0:00 left", spoken "100 percent, 0 seconds remaining"; sample.md "99%" | "100%, 0:00 left" |
| Speak Info (`LibraryInfoWording.briefParts(of:)`) | the row's words | "… EPUB. In Classics. 100 percent. 0 seconds remaining." | the same |
| Reader status row (ReaderView `statusRow`) | `%.1f%%`, time left, total | "100.0%, 0:00 left"; test_book.docx "99.9%", sample.md "99.3%" | "100.0%, 0:00 left" |
| Where Am I? (`briefWhereAmISummary`) | `%.0f percent`, time left | "100 percent. 0 seconds remaining." | the same |
| Copy Reading Position (`readingPositionSummary`) | `%.1f%% through`, time left | "100.0% through \| 0:00 remaining" | the same |
| Stats: Books Finished, Recently Finished | the count of entries, and the last 10 entries | one more entry for each end | the same |
| Reading list's Skip finished books (`LibraryViewModel.finishedBookIDs`) | every book ever in Books Finished | skipped from the first finish on, even when read again | the same |
| Unopened (`lastOpened == nil`) | never opened | never Unopened | the same |
| A feed item | `playedDate`, set by each counted finish | played; the delete-after-played clock restarts at each finish | the same |

No surface says "finished". "100 percent, 0 seconds remaining" is the closest a listener hears, and a short book or a book with a skipped last section never reaches it.

### What happens next

- **Reopen.** The reader opens at the saved place, kept by `showLoadedContent` while it lies within its chapter, and is not finished.
- **Play, any time after the end.** A text book speaks from its last word. When nothing speakable follows the cursor, it ends at once instead. An audiobook plays from its last tick, a fraction of a second.

  Either way the book ends again: "Finished: Dune", one more entry in Books Finished, and a feed item marked played again. Gaps of one to three seconds between your repeated entries fit this path. A rewind cannot finish again that fast: your skip back is 15 seconds (30 with Shift), and the nine books with a skip of their own use 15 or 30 seconds.
- **A rewind (backward skip) while the book rests finished and its reader is the active owner.** It plays from where the skip lands (`performSkip(unit:forward:)`, B02). At the end the book is finished again and counted again.

  After a relaunch, Release Media Controls, or another book playing, a backward skip moves the cursor only.
- **A forward skip at the end** stays there (an audiobook's cursor goes to one unit, a tenth of a second, before the end, as `MediaCommandPlaybackTests` pins), and the book stays finished.
- **Go to Percent 100** lands on the last unit of the last chapter, because `clampedNavigationPosition` keeps every jump one unit inside its chapter. That is 0.1 s before an audiobook's end, and a text book's last character. Play then plays it, and Books Finished counts a finish.
- **Replay.** There is no Replay command, and Play does not start over. Starting a finished book over takes Go to Percent 0, or the first heading in the Headings sheet.

### This user's library

- **Rows:** 745: 730 EPUB, 11 audiobooks, 2 plain text, 1 HTML, 1 DAISY.
- **End-of-book behavior:** Stop, globally, with no book of its own. The reading list is empty, its Skip finished books on (the default).
- **Books Finished:** 67 entries, all of 2026, for 28 books. 13 entries name their kind (text); the others predate kinds.
  - 12 books are counted more than once: 39 extra entries.
  - The gaps between a book's repeated entries: 20 under two minutes (14 of them under ten seconds), 4 under an hour, 11 under a day, and 4 longer.
  - The last 10 entries, which Recently Finished lists, are 2 books: one of them 9 times. The gaps between consecutive entries are 1, 2, 3, 2, 1, 25,656, 233, 43, and 247,199 seconds; the first six, one book, all fell on October 7. Recently Finished keys its rows by book ID, so those rows repeat an ID (an open follow-up of October 3).
  - Which path made them cannot be read from the logs: the end-of-book trace lines are not written to the debug log.
- **Where the finished books rest:**
  - 18 rows say "100%, 0:00 left", 9 say "100%" with 0:01 to 1:36 left, and 1 says "99%, 1:40 left";
  - 6 of the 21 finished text books, all saved before October 3, hold a global offset past their book's present total, since their text was extracted again on October 3; their rows clamp to 100 percent (T06 found 3 books whose place lies past the end of their last chapter, which reopen at that chapter's start);
  - 7 rows at or above 99.5 percent are not counted finished.
- **Audiobooks:** 7 of the 11 rows say "100%, 0:00 left": 1 exactly at its end, 6 within its last second.

## 2. How times are counted today (P08)

### Two clocks

- **The recording's clock (media time).** An audiobook's place is 10 units for each second of the recording (`ReaderViewModel.audioCharsPerSecond`). These count it:
  - the player, its position observer, and every seek;
  - a skip by time: 15 seconds back is 15 seconds of the recording, 7.5 seconds of listening at 2x (`performSkip` → `skipCharacters(count:)`);
  - Go to Time's jump (`jumpToTime(seconds:)`);
  - the audio editor ("12:04.3 of 48:00", `AudioEditorWording.clock(_:)`);
  - a transcript's sentence times.
- **Listening time at the book's speed.** The recording's length over the book's speed (`ReaderViewModel.totalEstimatedTime`: `baseAudioDuration / audioSpeed`), shared out by the place (`ReadingTimeEstimator.remaining`).
- **A text book has no recording.** Its times are its words at its words per minute (`DocumentContent.estimatedReadingTime(wpm:)`), shared out by the place.

| Where | What it shows or speaks | Clock (audiobook) |
| --- | --- | --- |
| Reader status row, percent button | "22.9%", "22.9% through the book" | — |
| Reader status row, time button | "3:44:01 left", spoken "3 hours, 44 minutes, 1 second remaining at current speed" | listening |
| Reader status row, total | "Total: 4:50:33", spoken "Total time: …" | listening |
| Reader, elapsed | not shown, except as Go to Time's starting value | — |
| Go to Time's starting value (`JumpToTimePanel.onAppear`) | the total less the time left, whole seconds, in three fields | listening |
| Go to Time's limit (`JumpInputValidator.time(…bookLength:)`) | "Time exceeds book length. Maximum is 4 hours, 4 minutes, 9 seconds." at 2x | listening |
| Go to Time's jump and its words | the typed seconds × 10 units; "Jumped to 2 hours, 13 minutes, 5 seconds." | recording |
| Go to Time's fields | "Jump to:", then Hours, Minutes, Seconds, each a whole number, with "h", "m", "s" beside them | — |
| Headings sheet, time estimate | each heading's length | listening |
| Headings sheet, time into book (`HeadingNavigatorView.makeHeadingItems()`) | where each heading starts: units over 10 over the speed | listening |
| Where Am I?, brief and full | "… 3 hours, 44 minutes, 1 second remaining"; full adds the heading's time left and "Total book time" | listening |
| Copy Reading Position | "… \| 22.9% through \| 3:44:01 remaining" (no place time) | listening |
| Library row, Speak Info, summary bar | "3:44:01 left" at the book's own speed (`Book.estimatedTimeRemaining(wpm:)`) | listening |
| Bookmarks | "Bookmark 3, <heading>, Note: …": no time | — |
| Stats | listening time measured by the wall clock | wall clock |
| Sleep timer | minutes by the wall clock | wall clock |
| System Now Playing | title and artist, rate 1 or 0: no times (`NowPlayingService`) | — |

The comment on `jumpToTime(seconds:)` contradicts itself: "time from the start of the book at the current playback rate — so a 1-hour audio book takes a 30-minute jump to its midpoint, regardless of speed setting". The code does neither: it reads the recording's clock.

### Measured round trips

**Go to Time's own round trip** (audiobook A: one file, 9:41:07.4; the cursor at 2:13:05.0 on the recording): open Go to Time and press Jump without changing its starting value.

| Speed | Status row | Starting value | Lands at (recording) | Miss |
| --- | --- | --- | --- | --- |
| 0.5x | 22.9%, 14:56:04 left, Total: 19:22:14 | 4 h 26 m 10 s | 4:26:10.0 | +2:13:05.0 |
| 1x | 22.9%, 7:28:02 left, Total: 9:41:07 | 2 h 13 m 5 s | 2:13:05.0 | none |
| 1.25x | 22.9%, 5:58:25 left, Total: 7:44:53 | 1 h 46 m 28 s | 1:46:28.0 | −26:37.0 |
| 1.5x | 22.9%, 4:58:41 left, Total: 6:27:24 | 1 h 28 m 43 s | 1:28:43.0 | −44:22.0 |
| 1.75x | 22.9%, 4:16:01 left, Total: 5:32:04 | 1 h 16 m 2 s | 1:16:02.0 | −57:03.0 |
| 2x | 22.9%, 3:44:01 left, Total: 4:50:33 | 1 h 6 m 32 s | 1:06:32.0 | −1:06:33.0 |

**The Headings sheet's time into book, typed into Go to Time** (audiobook B: 30 files, 8:08:19.1; heading 20 starts at 5:00:39.3 on the recording):

| Speed | Sheet shows | Lands at (recording) | Lands in | Miss |
| --- | --- | --- | --- | --- |
| 0.5x | 10:01:16 | 8:08:19.0, the end | chapter 30 | +3:07:39.7 |
| 1x | 5:00:38 | 5:00:38.9 | chapter 19 | −0.4 s |
| 1.25x | 4:00:30 | 4:00:30.7 | chapter 15 | −1:00:08.7 |
| 1.5x | 3:20:25 | 3:20:25.5 | chapter 12 | −1:40:13.8 |
| 1.75x | 2:51:47 | 2:51:47.5 | chapter 11 | −2:08:51.8 |
| 2x | 2:30:19 | 2:30:19.4 | chapter 10 | −2:30:19.9 |

**A time on the recording's own clock** (each of B's 30 headings, as a chapter list or show notes give it, in whole seconds):

| Speed | Accepted | Refused | Of those accepted, in the heading's chapter / a moment before it | Largest miss |
| --- | --- | --- | --- | --- |
| 0.5x | 30 | 0 | 20 / 10 | 1.2 s |
| 1x | 30 | 0 | 20 / 10 | 1.2 s |
| 1.25x | 25 | 5 | 15 / 10 | 0.8 s |
| 1.5x | 21 | 9 | 11 / 10 | 0.8 s |
| 1.75x | 18 | 12 | 8 / 10 | 0.8 s |
| 2x | 15 | 15 | 5 / 10 | 0.8 s |

At 2x the refusal reads "Time exceeds book length. Maximum is 4 hours, 4 minutes, 9 seconds." What Go to Time accepts lands within about a second of the recording's time, which is right. The limit is listening time, which refuses the second half of the book.

**The status row's total, typed back** (audiobook A): at 0.5x "Total: 19:22:14" is accepted and lands at the end; at 1x "9:41:07" lands at the end; at 2x "4:50:33" lands at 4:50:33, the middle of the book.

**Pasting.** Typed or pasted into the Hours field:

- "1:02:03" and "62:03" are refused with "Hours must be a whole number.";
- "3723" is read as 3,723 hours and refused as longer than the book.

**Smaller effects** (seconds, not hours):

- **Whole seconds.** The fields hold whole seconds, truncated as `TimeFormatting` truncates every time, so a time typed back lands up to a second early. For a heading, that can be a fraction of a second into the chapter before it.
- **Chapter lengths.** Each chapter's placeholder is its measured duration × 10, truncated (`AudioBookParser.placeholderLength(for:)`). B's placeholders total 1.3 s less than its measured length.
- **Chapter marks.** A file with chapter marks places each chapter at the placeholders before it over 10 (`AudioLayout.chapterStartTime`), so chapter 30 of audiobook C (the same 30 durations in one file) starts 1.4 s before its mark.

**Text books** (pride.txt: 744,401 units, 130,415 words; heading 61, "CHAPTER XLVII.", at unit 531,264):

| Words a minute | Go to Time's own round trip | Headings sheet shows | Typed back |
| --- | --- | --- | --- |
| 200 | 7 units early (1.2 words) | 7:45:22 | 7 units early (1.2 words) |
| 500 | 45 units early (7.9 words) | 3:06:08 | 45 units early (7.9 words) |

A text book's times round-trip at the speed they were copied at, a second at most early. Copied at 500 words a minute (3:06:08) and typed after the speed changed to 200, the same time lands at 28.5 percent of the book, for a heading at 71.4 percent.

### This user's audiobooks

11 audiobooks: 3 at 1x, 1 at 1.25x, 1 at 1.5x, 2 at 1.75x, and 4 at 2x. For 8 of them, Go to Time's starting value and its limit, and every time the Headings sheet shows into the book, are off by the book's speed today.

## 3. The options for P07

### Where the end rests

- **(a) Save the exact end, and let the place say "finished" (recommended).** Every end that does not loop saves the last chapter's end: the last chapter, at its full length. A book whose saved place is its end is finished. That needs no new field, and older files and older TextMouth builds read it as an ordinary place.
  - **Cost:** a few lines in `handleEndOfBook()` and `finishBookReadFromReadingList`. The position observer must publish no tick once a play has finished, so the place stays put.
  - **Risk:** a book whose text grows at its end after it finished stops resting there. It still counts in Books Finished.
  - **What a VoiceOver or braille user meets:** "Finished" wherever the book's progress is spoken or shown.
- **(b) Keep today's place, and add a stored finished date** (`Book.finishedDate`).
  - **Cost:** more: a new row and record field (`ContentAnalysisMergeTests.bookWithEveryFieldSet` and `testBookRebuiltFromItsRecordHasEveryField` move with it), and rules for when the date clears.
  - **What a listener meets:** the row says Finished while the place says 99 percent, so the reader and the library disagree unless both read the date.
- **(c) Reset a finished book to its beginning.** Rejected: B02's rewind could no longer replay the end, and a reopened book would read as unstarted.

### What Play does at the end

- **(i) Start the book over, saying so (recommended).** "Starting again: Dune", then the first chapter with anything to say. One press does what the listener most likely means, and the place moves to the beginning; the end is a Go to Percent 100 away. A rewind still replays the end.
- **(ii) Say what Play would do, and start over on a second Play.** "Finished: Dune. Press Play again to start over." This is safe from an accidental AirPods press, but it takes two presses every time.
- **(iii) Today:** replay the last moment, finish again, count again.

### What counts in Books Finished

- **(i) Every end (today).** Your Recently Finished shows one book nine times.
- **(ii) Each time the book plays to its end anew (recommended).** A play that began as a replay of a finished book's end (a rewind from the end) does not count again. With Play starting over, Play at the end never replays the end. A jump to 100 percent followed by Play still counts, as today: the listener asked to hear the end.
- **(iii) Once per book, ever.** That is the reading list's own view ("a book counted once stays counted, even when read again"), but Books Finished would no longer count a book read twice.

### Loop

- **(i) Never counts, and an End of book timer leaves the book waiting at its beginning (today; recommended).** Loop is for listening again and again (a lesson, a story to sleep to). Counting each pass would fill Books Finished. You use Stop for every book.
- **(ii) Counts each pass.**
- **(iii) Counts the first pass.** This needs a record of passes that a loop never shows.

### The books already finished

Under (a), the 28 books Books Finished counts would not say Finished until each ends again. One pass at launch could put a counted book whose row already says 100 percent at its end: 27 of your 28 would move, and the one at 99 percent would stay where it is.

## 4. The options for P08

- **(a) Places on the recording's clock, amounts at the book's speed (recommended).** A time that names a place counts the recording's own time at every speed: the time typed into Go to Time, Go to Time's starting value and its limit, the Headings sheet's time into book, and the place Copy Reading Position adds. Time left and total time stay listening time at the book's speed, which is what a listener plans by, and name the speed when it is not 1x.
  - **Why:** one clock for places, the one the player, the skips, the audio editor, transcripts, chapter lists, and show notes already use. A place's time stays the same when the speed changes.
  - **Cost:** Go to Time's starting value, limit, and words; the Headings sheet's time into book; and a mapping from a recording time to a place through each chapter's start and measured length, which the content index already records (`BookContentAudioChapterIndex.startTime` and `duration`).
  - **What VoiceOver and braille users hear:** "Time in the recording" for Go to Time's field; "3 hours, 44 minutes, 1 second remaining at 2.0 times speed" for the time left.
- **(b) Everything at the book's speed.** Go to Time would multiply what is typed by the speed.
  - **Cost:** one line in `jumpToTime`. Today's displays round-trip at once.
  - **But:** a time from the recording itself (a chapter list, show notes, the audio editor, a transcript) lands wrong at any speed but 1x, and a place's time changes whenever the speed does. Your eight books at 1.25x to 2x would each name every place by a different time than the recording does.
- **(c) A choice in Go to Time between the two clocks.** Every jump asks a question it need not ask, and the shown times still need one clock.
- **(d) Both times everywhere ("2:13:05 in the recording, 1:06:32 at 2x").** Twice the speech at every Where Am I? and every row.

**Text books.** A text book has no recording, so its times can only be its words at a speed. Keeping the book's own words per minute (today) round-trips at that speed. Go to Time can say which speed ("Time at 500 words a minute"), and Go to Percent is the speed-proof way to name a place.

**One field.** The audio editor's Go to Time already reads "75.5", "12:04.3", and "1:02:03" from one field (`AudioEditorTimeEntry.reading(_:)`). The reader's three whole-number fields refuse any pasted time. Sharing the editor's reading lets a copied time go in with one paste, and lets a braille user type it in the form it is shown.

## 5. The design

### P07: the end is a place

- **Saving the end.** `handleEndOfBook()` moves the cursor to the book's end, the last chapter at its full length (`ReaderViewModel.restAtEnd()`), and saves it. It does so for Stop, for Continue to Next Book with or without a next book, and through `finishBookReadFromReadingList` for the reading list. Loop still moves the cursor to the beginning.
- **No tick after the finish.** `AudioPositionObserverPolicy` publishes no tick once a play has finished, with or without a clip end, so a late tick cannot move a finished audiobook's place. The cursor of an audio chapter never passes the chapter's length.
- **Finished means "at its end".**
  - `Book.restsAtEnd`: the saved place's global offset is at or past the book's total.
  - `showLoadedContent` sets `hasFinishedBook` when the loaded place is the end, so a finished book reopened after a relaunch behaves as it did before: a rewind replays its end, and Play starts it over. T06's question 7 (a place past its chapter's end goes to the chapter's end, in the last chapter to the book's end) would make the 3 books T06 found past their last chapter's end rest at their end, and so finished, as they were.
- **Replay.** `play()` on a book resting finished moves to the beginning and plays, as Play does from there: passing over silent chapters, with the play sound and a listening session. It first says "Starting again: Dune" (`EndOfBookWording.startingAgain(_:)`). The hand-over to a next book still comes first (`playGoesToTheHandOver()`).
- **Counting.** `performSkip(unit:forward:)` marks a play that replays a finished book's end (`replaysFinishedEnd`). `handleEndOfBook()` then neither counts it nor posts `.bookDidFinish`; everything else about the end stays as it is, the continuation included. A jump (`navigateTo`), Replay, and `stop()` clear the mark.
- **The books already finished.** Once, at launch, each book Books Finished counts whose saved place is at 99.5 percent or more is put at its end: its last chapter, at the length its content index records. The move goes to the row and its record, dated now, with one `FINISHED_BOOKS_AT_END: moved N` line in the debug log. A book whose files are only in the cloud waits for its next open.
- **What does not change:**
  - Books Finished stays a list of finishes.
  - The reading list's Skip finished books still reads it.
  - Loop and its timer rule stay as they are.
  - Unopened stays "never opened".
  - A forward skip at the end stays there.

### P07: what is said

| Surface | Today, at the end | Proposed |
| --- | --- | --- |
| Library row | "Dune, by Frank Herbert, 100 percent, 0 seconds remaining, EPUB" | "Dune, by Frank Herbert, Finished, EPUB"; "Finished" on screen in place of "100%" and "0:00 left" |
| Speak Info | "… EPUB. In Classics. 100 percent. 0 seconds remaining." | "… EPUB. In Classics. Finished." |
| Where Am I? | "Dune. Appendix. Heading 40 of 40. 100 percent. 0 seconds remaining." | "Dune. Appendix. Heading 40 of 40. Finished."; the full summary adds the total time |
| Copy Reading Position | "… \| 100.0% through \| 0:00 remaining" | "… \| Finished" |
| Reader status row | "100.0%", "0:00 left" | "100.0%", "Finished" (the time button, which still opens Go to Time) |
| Play at the end | the last word or moment, then "Finished: Dune" again | "Starting again: Dune", then the book from its beginning |
| Stats, Recently Finished | one row per entry, keyed by book ID | one row per entry, keyed by the entry, so a book read twice is listed twice without repeating an ID |

Every word is a static constant pinned by a test, and "Finished" is a word, never a sign or a colour.

### P08: the recording's clock for places

- **Mapping.** `ReaderViewModel.recordingTime(chapterIndex:characterOffset:)` gives the chapters before the place, summed from the index's measured lengths (`BookContentAudioChapterIndex.duration`), plus the offset over 10. `place(atRecordingTime:)` is its inverse. The recording's length is `book.audioDuration`, the same sum. A file with chapter marks takes each chapter's start from its mark (`BookContentAudioChapterIndex.startTime`), which also mends the 1.4 s drift found above.
- **Go to Time, for an audiobook:**
  - **The field:** one field, labelled "Time in the recording", starting at the cursor's time in the recording ("2:13:05"). It reads "2:13:05", "133:05", "7985", and "2:13:05.4" through the audio editor's reading, moved to a shared `TimeEntry`. Its limit is the recording's length: "Time exceeds the recording's length. The recording lasts 9 hours, 41 minutes, 7 seconds."
  - **The jump:** to `place(atRecordingTime:)`, or to a heading that starts less than a second after the time typed, so that a heading's time, shown in whole seconds, lands exactly on it.
  - **The announcement:** "Jumped to 2 hours, 13 minutes, 5 seconds in the recording."
- **Go to Time, for a text book:** the same one field, labelled "Time at 500 words a minute" (the book's speed), counted as today.
- **The Headings sheet.** An audiobook's "time into book" counts the recording. Its "time estimate" (each heading's length) stays at the book's speed, and its picker says so ("Length at 2.0x").
- **Amounts of time** keep the book's speed and name it when it is not 1x:
  - the status row: "3:44:01 left at 2.0x", spoken "3 hours, 44 minutes, 1 second remaining at 2.0 times speed";
  - the total: "Total: 4:50:33 at 2.0x";
  - Where Am I?: "… remaining at 2.0 times speed";
  - the library row is unchanged: its time left is already the book's own.
- **Copy Reading Position** adds the place: "… \| 22.9% through \| at 2:13:05 of 9:41:07 in the recording \| 3:44:01 remaining at 2.0x". For a text book: "at 2:10:24 of 4:20:49 at 500 words a minute".
- **Skips by time** stay on the recording's clock, as they are.

Simulated in the scratch program with this design, at 0.5x, 1x, and 2x alike:

| Book | Go to Time's own round trip | Each heading's time typed back |
| --- | --- | --- |
| A: one file, 9:41:07.4 | lands at most 0.9 s before the place | on its heading (1 of 1) |
| B: 30 files | lands at most 1.0 s before the place | on its heading, 30 of 30 |

## 6. Accessibility

- **Every new sentence is spoken and shown alike, and pinned by static constants and tests:** "Finished", "Starting again: Dune", "Time in the recording", "Time at 500 words a minute", "remaining at 2.0 times speed", and Go to Time's errors.
- **Go to Time becomes one text field** with a label of its own, rather than three fields known only by their placeholders beside a separate "Jump to:" text. Return jumps, Escape cancels, and VoiceOver focus lands in the field as now. A pasted time, or one typed as it is shown or spoken, goes in whole.
- **A finished book says so in words** in its row, in Speak Info, in Where Am I?, and in the reader. A braille display shows "Finished" where it showed "100%" and "0:00 left".
- **Play on a finished book is announced** before the book starts again, so the listener knows the place moved. The end is a Go to Percent 100 away.

## 7. Questions for you

Each has a recommended answer.

1. **Should a book that plays to its end be saved exactly at its end, and stay finished after TextMouth quits?** Today it is saved at its last word or quarter second, a short book reads 99 percent, and after a relaunch a rewind no longer replays its end. Recommended: yes.
2. **Should the library row, Speak Info, Where Am I?, Copy Reading Position, and the reader say "Finished" for a book resting at its end, in place of "100 percent, 0 seconds remaining"?** Recommended: yes.
3. **Should Play on a finished book start it again from the beginning, saying "Starting again: <title>"?** Today Play replays its last word or moment and finishes it again at once. Your Books Finished holds six finishes of one book within nine seconds, on October 7. A rewind would still replay the end. Recommended: yes.
4. **Should a rewind after a book's end, played on to the end again, leave Books Finished as it is, rather than count the book again?** Recommended: yes.
5. **Should a book set to loop go on not counting in Books Finished, and go on waiting at its beginning when an End of book sleep timer stops it?** You use Stop for every book today. Recommended: yes.
6. **Should the books Books Finished already counts, whose row says 100 percent, be put at their end once, so they say Finished too?** 27 of your 28 would; the one at 99 percent would stay where it is. Recommended: yes.
7. **Should every time that names a place in an audiobook count the recording's own time, whatever the speed: what you type into Go to Time, its starting value, and the Headings sheet's time into the book?** A time from a chapter list, show notes, or the audio editor would then land where it says, and a time copied from the reader would come back to the same place at 0.5x, 1x, or 2x. At 2x today, Go to Time's own starting value goes back half way, and the second half of the book is refused. A time a fraction of a second before a heading would land on the heading. Recommended: yes.
8. **Should time left and total time stay listening time at the book's speed, and name the speed when it is not 1x ("3:44:01 left at 2.0x"; "remaining at 2.0 times speed")?** The library row stays as it is. Recommended: yes.
9. **Should Go to Time take one field that accepts a time typed or pasted as 1:02:03, 62:03, 3723, or 12:04.3, as the audio editor's Go to Time does, in place of separate Hours, Minutes, and Seconds fields?** Today a pasted "1:02:03" is refused. Recommended: yes.
10. **Should Copy Reading Position add the place's time ("at 2:13:05 of 9:41:07 in the recording"), so a copied place can be typed back?** Today it copies only the time left. Recommended: yes.
11. **For text books, should times go on counting at the book's words per minute, with Go to Time saying so ("Time at 500 words a minute")?** A time copied at 500 words a minute and typed at 200 lands elsewhere (28.5 percent for a heading at 71.4 percent); Go to Percent names a place at any speed. Recommended: yes.

## 8. Build plan

Three branches, each with its tests, and a documentation pass after each merge. `whereamifollowups` is editing ViewModels/ReaderViewModel+Navigation.swift, +Playback.swift, and +WhereAmI.swift now, so branches A and C start after it merges.

### Branch A: `fix/book-rests-at-its-end` (P07, questions 1, 3, 4, 5, and 6)

- **What it changes:**
  - `restAtEnd()`, called from `handleEndOfBook()` and `finishBookReadFromReadingList`.
  - `AudioPositionObserverPolicy`: no tick after a finished play.
  - `Book.restsAtEnd`, and `showLoadedContent` setting `hasFinishedBook`.
  - Replay in `play()`, with `EndOfBookWording.startingAgain(_:)`.
  - `replaysFinishedEnd` in `performSkip`, `handleEndOfBook()`, `navigateTo`, and `stop()`.
  - The one-time move of finished books in LibraryViewModel+Migration.swift, with its log line.
- **Tests** (hosted, silent audio and offline speech):
  - Each way a book ends (Stop, Continue with and without a next book, with this reader's timer, the reading list continuing and stopping) saves the end, for a text book and for audiobooks of one file, a file per chapter, chapter marks, and DAISY clips.
  - A closed finished audiobook keeps its end.
  - Loop keeps the beginning and counts nothing, with and without an End of book timer.
  - Play at the end says "Starting again" and plays from the first chapter with words (after a cover).
  - A rewind from the end replays it and adds no entry, then a jump and a play to the end adds one.
  - A reopened finished book rests finished: Skip Backward plays, Play starts over.
  - The one-time move, over finished and unfinished books, a book past its end, and a book at 99 percent.
- **Size:** about 250 lines, with 550 lines of tests.

### Branch B: `feature/finished-wording` (P07, question 2)

- **What it changes:** "Finished" in `BookRow`'s label and visible text, `LibraryInfoWording`, the Where Am I? formatters, `readingPositionSummary`, and the reader's status row. Recently Finished is keyed by entry.
- **Tests:**
  - every wording by static constants, without a window;
  - the row label for a finished, an unfinished, and a counted but re-read book;
  - the full Where Am I? for a finished book;
  - Recently Finished with one book listed twice.
- **Size:** about 150 lines, with 250 lines of tests.

### Branch C: `fix/audiobook-recording-time` (P08, questions 7 to 11)

- **What it changes:**
  - `recordingTime(chapterIndex:characterOffset:)` and `place(atRecordingTime:)` from the index's measured lengths, with `chapterStartTime` for chapter marks taking each mark's start from the index.
  - The shared `TimeEntry`, moved from `AudioEditorTimeEntry`, which the editor keeps using.
  - Go to Time's one field, its labels, limit, words, and heading snap.
  - The Headings sheet's time into book and its picker's words.
  - The at-speed labels.
  - Copy Reading Position's place.
- **Tests:**
  - **The acceptance, as pure tests:** a place's time copied from Go to Time, from the Headings sheet, and from Copy Reading Position comes back to within a second of the place at 0.5x, 1x, and 2x, for one file, a file per chapter, chapter marks, and DAISY clips; a text book's at 200 and 500 words a minute.
  - Every heading's time lands on its heading.
  - "1:02:03", "62:03", "7985", and "2:13:05.4" are read.
  - The limit is the recording's length.
  - Every wording.
  - The panel's field, through `withHostedControls`.
- **Size:** about 300 lines, with 450 lines of tests.

### Risks

- **A book whose text grows at its end** after it finished stops resting at its end (Books Finished still counts it). T06's anchors should treat the end of a book as a place of its own (an anchor with nothing after it), so a finished book stays at its end when its text is read anew.
- **After a relaunch, the AirPods** reach TextMouth only once it holds the system's media controls again, by playing. The keyboard's Skip Backward reaches the focused reader at once.
- **An accidental Play** on a finished book starts it over. The announcement says so, and Go to Percent 100 returns to the end.
- **An older TextMouth** on another Mac saves a finished book at its last word, as today. The newer one reads that as not quite finished until the book ends again on it.

## Follow-ups noticed (not part of P07 or P08)

- **The player's asset is made without precise timing** (`AVURLAsset(url:)` in `AudioPlaybackService.makeItem(playing:)`), while the probe asks for it (`AudioMediaProbe`). `seekPlayer(toFileTime:)` clamps a seek to the player's own `duration`. `AudioMediaProbe`'s documentation measured that estimate at 578.6 s for a 600-second VBR MP3 without a Xing header, so a resume or jump in the last part of such a file may land at the estimate. Read from the code, not measured.
- **A file with chapter marks places each chapter** at its placeholders' sum, 0.1 s short a chapter at most: 1.4 s early by chapter 30 in the synthetic book, more in a book of a hundred chapters. Next Heading lands that much before the mark. (ViewModels/ReaderViewModel+Playback.swift, `AudioLayout.chapterStartTime`; branch C mends it.)
- **`jumpToTime(seconds:)`'s comment** describes a convention the code does not follow. (ViewModels/ReaderViewModel+Jump.swift)
- **Recently Finished keys its rows by book ID**, so your list shows one book's ID nine times. (Views/Settings/ReadingStatsView.swift; already noted on October 3)
- **A looping book stopped by an End of book timer** says "Finished" though it is neither counted nor at its end. (ViewModels/ReaderViewModel+Playback.swift, `handleEndOfBook()`)
- **Go to Percent 100 and Play counts a finish** after at most a tenth of a second of audio, or a text book's last character. (ViewModels/ReaderViewModel+Navigation.swift, `clampedNavigationPosition`)
- **A counted finish restarts a feed item's delete-after-played clock** (`playedDate = now`), so each repeated finish keeps the download a day longer. (Services/Feeds/FeedLifecycle.swift, `bookDidFinish(_:)`)
- **The end-of-book trace lines are not written to the debug log**, so a finish cannot be traced afterwards. A `BOOK_FINISHED` event line, with counts only, would let a diagnosis tell Play at the end from a rewind. (ViewModels/ReaderViewModel+Playback.swift)
- **Go to Time's three fields are known to VoiceOver only by their placeholders** ("Hours", "Minutes", "Seconds"), with "Jump to:" and "h", "m", "s" as separate texts. Branch C replaces them. (Views/Reader/ReaderView.swift, `JumpToTimePanel`)

## What I could not verify

- **No app was built, no hosted test was run, and no audio was played.** The audiobook's place at its end comes from the code: the last quarter-second tick, and the possible tick after the finish. AVFoundation's order between that tick and the end notice was not observed. Your library shows both outcomes.
- **Which path made your repeated finishes.** The logs keep no end-of-book lines. The one-to-three-second gaps fit Play at the end, not a rewind of 15 or 30 seconds, your skip back.
- **Direct speech in a live session.** The last word ranges come from an offline render in Samantha's compact voice, which reports through the same delegate callback direct speech uses. Rendered audio's last tick was read from the code.
- **DAISY text fixtures were not extracted.** They are read through the same speech path. No fixture holds DAISY audio; the segmented case was read from the code.
- **Other apps' conventions.** Neither Apple's Books guide for the Mac nor Audible's help says which clock their times count, so the recommendation rests on TextMouth's own clocks.
- **VoiceOver and braille** on the proposed wording and the one-field Go to Time: on paper.
