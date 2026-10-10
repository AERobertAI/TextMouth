# Task brief: textanchors — a design note for T06, reading places that survive re-extraction

Slug `textanchors`; branch `docs/text-anchors-research`. A design note only: no change to the app, and no app build or suite. Read `common.md` beside this file first (the user's rules; its usage override ended at the 8:00 a.m. reset, so read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with what you have below 10% left). You may write and run standalone measurement programs in the session's scratchpad (prefix them `textanchors-`), as the FR11 design agents did (`FEED-ITEMS-ADDENDUM-2026-10-07.md`, "How it was measured"), against copies of the repository's own test fixtures, never `~/.TextMouth`.

## The item
T06 in TODO-2026-09-04.md: "Relocate reading positions, bookmarks, and skipped headings after re-extraction. P1 · Impact 4 · Difficulty 5 · Design / Risk. Numeric offsets and heading IDs can change when text/chapter extraction improves. Add versioned text anchors or an explicit migration/reporting policy. Acceptance: re-extract a book with inserted code, removed duplicate links, and corrected chapter boundaries; saved locations either follow the same content or are clearly reported as needing review."

Why it matters now: the extraction keeps improving (the EPUB headings fix, DOCX structure, PDF embedded text, the metadata reader versions, the reading-text cache keyed by `ReadingTextKey`), and the user has 640-odd books with places, bookmarks, and skipped headings saved as numeric offsets and heading IDs. The user is a VoiceOver and braille user who reads for hours; a place that silently moves to the wrong paragraph is the failure to prevent.

## What to find and measure
1. **Every place a location is saved** (`ReadingPosition`, bookmarks, skipped headings, the reading list, the checkpoint journal, transcripts' offsets, the refusal report's offsets, Stats if it keys anything by offset) and in what coordinates (chapter index, UTF-16 offset into the extracted or the spoken text, time for audio, heading IDs).
2. **Every way a book's text can be re-extracted** today, and what each does to saved locations now: a newer extraction version, the text cache's invalidation, Edit Text, a transcript's cleanup, Replace on a duplicate import, the metadata refresh, a cloud book re-downloaded.
3. **What actually shifts:** run the current extraction (or a faithful copy of the code paths in a scratch program) on test fixtures with the acceptance cases: inserted code, removed duplicate links, corrected chapter boundaries; report how far offsets move and how often a heading ID changes.
4. **Options**, each with its cost and its failure modes, measured where you can: (a) text anchors (a short quote around the place, with the chapter and offset as hints, re-found by search after re-extraction); (b) an extraction version stamped on each saved location and a migration that maps old to new offsets by diffing the two texts; (c) a report of locations that could not be placed, shown to the user ("needs review"), with the old text around them; and combinations. Say what each does for VoiceOver users when it cannot place a location.
5. **The user's data:** read `~/.TextMouth` only for counts (how many books have places, bookmarks, skipped headings), never content; say how many could be affected by the next extraction change.

## The note
Write `TEXT-ANCHORS-RESEARCH-2026-10-10.md` in the repository root, in the style of `FEED-ITEMS-RESEARCH-2026-10-07.md` and `KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md`: a summary first, the facts with file and function names, the measurements and how they were taken, a recommendation, a build plan in small branches with their tests, what you could not verify, and questions for the user, each a yes-or-no with a recommended answer (the user prefers concrete yes-or-no questions). Commit it on your branch with `git add -f`, one commit, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Register on the board as `textanchors` with `--files TEXT-ANCHORS-RESEARCH-2026-10-10.md`.

## Report
The note's summary, its questions, the measurements, and what you could not verify.
