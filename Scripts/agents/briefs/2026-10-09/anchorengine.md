# Task brief: anchorengine — T06's branch A, the text anchor engine

Slug `anchorengine`; branch `feature/text-anchors`, from main. Read `common.md` beside this file first; its usage override ended at the 8:00 a.m. reset on October 10, so the normal rule applies: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count as your baseline.

## The design
Two notes, read in this order:
- `TEXT-ANCHORS-RESEARCH-2026-10-10.md` (the first note): section 5's "What a place keeps" and "Finding a place again", and section 8's "Branch A".
- `TEXT-ANCHORS-ADDENDUM-2026-10-10.md` (the addendum, which overrides the first note where they differ): sections 1 (the rules as measured), 9 (the revised design), and 10's "Branch A".
T06's entry in TODO-2026-09-04.md quotes the user's answers. What changed since the first note: **no Places to Review list and no announcement**. Where the first note "reports" a place (a tie, the locality rule), the finder now returns its best guess and says it was a guess, so the caller can count it for the `PLACES_RELOCATED` log line. Other changes: **fine words** (a word also splits at punctuation, between letters and digits, and where a small letter meets a capital), the end-of-book rule (a place at a book's end stays at its end: P07), and the addendum's tolerant second search.

## The reference
The measured rules exist as a standalone program: `~/programming/ai/claude/investigate/text-anchors-2026-10-10/addendum/src/hybrid.swift`. The same folder holds the addendum's scripts, `results/`, and `truth/` (the exact answers made with marker words), and `first-note/` holds the first note's drivers and fixtures. Port the anchor and finder rules from it faithfully into app code that reads like the app's (comments, naming, DRY). Where you change a rule, say why. If it is cheap, run the real version steps' truth through your `TextAnchorFinder` in a standalone harness, to confirm the addendum's row "saved words alone, words split finely: 2 wrong, 0 a few words off"; report what you got either way. Never copy the user's library or read more than counts from `~/.TextMouth`.

## What this branch adds (the diff relocator is branch C, not yours)
1. **`TextAnchor`** (Models): `before` and `after` (up to 64 UTF-16 units of the chapter's reading text, cut on composed-character boundaries), `fraction`, `measuredIn`, and `version`, decoded with `decodeIfPresent`. Its capture from a chapter's text.
2. **Fine words:** the word keys every later branch shares (the diff in branch C splits words the same way), in one place.
3. **`TextAnchorFinder`:** the direct check, candidates, scores, ties and locality as best guesses, headings by level, label, and anchor, the end-of-book rule, and the tolerant second search. It returns where each place goes and how it was found (unchanged, found, best guess), pure and `Sendable`, fast enough to run off the main thread over a large book (say what you measured).
4. **The model fields,** last: `ReadingPosition.anchor`, `Bookmark.anchor`, and `SkippedHeading` with `Book.skippedHeadings` (`skippedHeadingIDs` read once to make them and kept in step for older builds), each decoded with `decodeIfPresent`, and the pins in `ContentAnalysisMergeTests` (`bookWithEveryFieldSet`, `testBookRebuiltFromItsRecordHasEveryField`). `bookends` (P07) is changing `Book.swift` and `LibraryViewModel+Migration.swift`: do items 1 to 3 first, and this one after rebasing onto main once `fix/book-ends-finished` has merged (the orchestrator's `merged:` post on the board says when). If it has not merged when you get here, post on the board and wait with heartbeats.

Nothing captures or moves a place yet (branches B to E): this branch changes no behavior, and nothing is spoken or shown.

## Tests (pure, no window)
The first note's list for branch A and the addendum's additions: the direct check; restored code before, inside, and at a place; duplicate link text removed; rewrapped lines; a restored chapter, merged chapters, a moved boundary; a passage printed twice with one copy edited (the near copy, never the far); places at a chapter's start and end and a cover chapter's heading; emoji, combining marks, and CR LF at a cut; fine words (digits and letters, a capital after a small letter); text run together (alice.docx's contents list and test_book.docx's table, kept as strings from their 3.0.4 and 3.0.7 readings); the refrain (the nearer verse); the end of the book; a record without anchors decoding; the anchor's size pinned for Latin text. Every subscript guarded (AGENTS.md: an unguarded subscript can trap the test host).

## Files you own
New files for the engine and its tests; `ReadingPosition`, `Bookmark`, and the skipped headings in `Book.swift` (after P07 merges); `ContentAnalysisMergeTests`' pins. `recordingtime` (P08) edits the reader's jumps, the Headings sheet's times, and a new setting; `bookends` the end of a book. New test files need `xcodegen` (AGENTS.md).

## Report
What you built, the rules you changed from the reference and why, the harness result if you ran it, the timings, the README and ARCHITECTURE wording (ARCHITECTURE only, since nothing is visible yet), and the TODO sentence.
