# Task brief: anchorcapture — T06's branch B, capturing every saved place's words

Slug `anchorcapture`; branch `feature/text-anchors-capture`, from main (branch A merged as 2597e5c8). Read `common.md` beside this file first; the normal usage rule applies: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count as your baseline.

## The design
- `TEXT-ANCHORS-RESEARCH-2026-10-10.md`: section 5 ("What a place keeps", and when places are captured) and section 8's "Branch B".
- `TEXT-ANCHORS-ADDENDUM-2026-10-10.md`: section 9 ("What a place keeps", "The end of a book") and section 10's "Branch B". The addendum overrides the first note where they differ.
- T06's entry in TODO-2026-09-04.md: the user's answers, yes to (6) the backfill, (7) a place past its chapter's end going to the chapter's end (in the last chapter, to the book's end), and (9) an anchor build with no extraction change.
- The anchorengine agent's notes in `AGENT-NOTES-2026-10-04.md` (branch A's engine, its rules, and what it left for you) and the TODO's "Still open after T06's branch A merge".

## What this branch adds
1. **Capture at every save,** from the text the reader shows: `makeCurrentReadingPosition()` (ReaderViewModel.swift), `toggleBookmarkAtCurrentPosition` and `addBookmarkAtCurrentPosition` at the offset each saves (the toggle's nudged one), with `LibraryViewModel.addBookmark` and `Library.addBookmark` taking the anchor, and `toggleHeadingSkip` (ReaderViewModel+VoiceAndSpeed.swift) with `updateSkippedHeadings` taking `SkippedHeading`s. **Switch which side leads:** `skippedHeadings` becomes what is saved, and `skippedHeadingIDs` is written from it for older builds and the reader's filter. Audiobooks keep their places in time (P08) and need no anchor; say what you did for DAISY text.
2. **The backfill** (question 6): each existing place captured from its book's text as it reads now, at load when it is in range, and in a launch pass before the text cache batch, for books on this Mac (a book only in the cloud waits; a book held by an Edit Text session waits). Decide and say what `measuredIn` records for a place captured from a text read before its cache was rebuilt.
3. **The end-of-chapter rule** (question 7): a place past its chapter's end goes to the chapter's end, and in the last chapter to the book's end, in place of today's clamp to the chapter's start in `showLoadedContent` (ReaderViewModel.swift about 1328; board #2028: a book `Book.restsAtEnd` calls Finished can reopen at its last chapter's start).

**No extraction change in this build** (question 9): the text the anchors are captured from must be the text the places were saved in. Nothing is spoken or shown.

## Tests (hosted where the brief says, every subscript guarded)
Capture on save, in the row and the record, for the position, a bookmark (both adds), and a skipped heading; the launch pass over a library with and without places, a book in the cloud, and a book held by an edit; the checkpoint journal's adoption keeping the anchor; `LiveReadingPositions` publishing nothing for an unmoved cursor; a feed item's index keeping anchors; a record written before this branch loading; the end-of-chapter rule, a past-the-end place in the last chapter reopening Finished.

## Files you own
The place-saving paths named above, the launch pass (beside the text cache batch), `showLoadedContent`'s clamp, the bookmark and skipped-heading saves in `LibraryViewModel` and `Library`, and their tests. `placediff` (T06's branch C) is building `PlaceRelocator`, a new pure type; `whereamimoves` is editing `ReaderViewModel+Playback.swift`, `+WhereAmI.swift`, `+LibraryUpdates.swift`, and `+CloudDownload.swift`: keep out of them, and post a notice if you must touch one.

## Report
What you built, what `measuredIn` records and why, how the backfill behaves on a library like the user's (746 books, 52 with places; counts only from `~/.TextMouth`, never content), the README and ARCHITECTURE wording, and the TODO sentence.
