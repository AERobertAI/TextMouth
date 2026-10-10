# Task brief: endandjumps — a design note for P07 and P08

Slug `endandjumps`; branch `docs/end-and-jump-research`. A design note only: no change to the app, and no app build or suite. Read `common.md` beside this file first (the user's rules; its usage override ended at the 8:00 a.m. reset, so read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with what you have below 10% left). You may write and run standalone programs in the session's scratchpad (prefix them `endandjumps-`), against the repository's test fixtures, never `~/.TextMouth` (which you may read for counts only).

## The items
Two of the user's open decisions in TODO-2026-09-04.md:
- **P07 — Store a deliberate end-of-book position.** "Completion commonly saves the last reported word/time rather than the exact endpoint. Decide how completed books show 100%, how Replay behaves, and whether loop counts as "finished." Acceptance: text, single-file audio, segmented audio, and resume-after-finish agree across the library and reader."
- **P08 — Define one time-coordinate convention for audiobook jumps.** "Jump code (ReaderViewModel+Jump.swift) uses media time for audio while displayed total/remaining time can be speed-adjusted listening time. Decide which coordinate an entered time means and label it. Acceptance: at 0.5x, 1x, and 2x, a time copied from the display round-trips to the expected position."

Since they were written, much has changed around them: a finished book rests finished and the AirPods' rewind replays its end (B02, the finished-book follow-ups), Continue to Next Book and the reading list hand over at a book's end, Stats' Books Finished counts finished books, the reading list's Skip finished books depends on "finished", and T06's design note (`TEXT-ANCHORS-RESEARCH-2026-10-10.md`, question 7) proposes that a place past its chapter's end go to the end. Read those merge entries, T06's note, and `ARCHITECTURE.md`'s reading walkthrough first.

## What to find and measure
1. **P07:** for a text book, a single-file audiobook, a segmented audiobook, and a DAISY book, what is saved when the book ends (and when it ends under each end-of-book behavior: stop, loop, continue to the next book, the reading list's continuation, a sleep timer's End of book), what the library row, Speak Info, Where Am I?, Stats, the reading list's Skip finished books, and Unopened then say, and what a reopen, Play, a rewind, and Replay do. Where they disagree, show it. Measure with the code (scratch programs or reading it precisely), not by guessing.
2. **P08:** where audiobook times are shown and spoken (the reader's elapsed and remaining, the library's time left, Where Am I?, Go to Time's field and its words, Copy Reading Position, bookmarks' times, Stats), which are media time and which are listening time at the book's speed, and what a time copied from one and typed into Go to Time does at 0.5x, 1x, and 2x; the same for a text book's times, if any.
3. **Options** for each, with their costs and what VoiceOver and braille users hear.

## The note
Write `END-AND-JUMP-RESEARCH-2026-10-10.md` in the repository root, in the style of the other research notes: a summary, the facts with file and function names, the measurements, a recommendation for each, a small build plan, what you could not verify, and questions for the user, each a yes-or-no with a recommended answer (the user prefers concrete yes-or-no questions). Commit it on your branch with `git add -f`, one commit, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Register on the board as `endandjumps` with `--files END-AND-JUMP-RESEARCH-2026-10-10.md`.

## Report
The note's summary, its questions, the measurements, and what you could not verify.
