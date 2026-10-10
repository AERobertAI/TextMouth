# Task brief: placediff — T06's branch C, the diff relocator

Slug `placediff`; branch `feature/place-diff`, from main (branch A merged as 2597e5c8). Read `common.md` beside this file first; the normal usage rule applies: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count as your baseline.

## The design
- `TEXT-ANCHORS-ADDENDUM-2026-10-10.md` is your design: section 1 (the hybrid's rules as measured: the patience diff over fine words, solid matches, a place keeping the words that follow it, slides, removed text, the end of the book), section 3 (what defeats it), section 9, and section 10's "Branch C".
- `TEXT-ANCHORS-RESEARCH-2026-10-10.md` gives the background.
- The anchorengine agent's notes in `AGENT-NOTES-2026-10-04.md`: branch A's `FineWords`, `BookWords`, `TextAnchor`, and `TextAnchorFinder` are on main, and you share their words.

## The reference and the truth
- `~/programming/ai/claude/investigate/text-anchors-2026-10-10/addendum/src/hybrid.swift` is the measured program: the diff, its rules, and the fallbacks.
- `addendum/truth/`, `addendum/results/`, and the addendum's scripts hold the exact answers for the 26 real version steps and the synthetic cases.
- `engine-harness/` is branch A's standalone harness. It compiles the app's own engine files and ran the real steps through them.
Port the relocator's rules faithfully into app code that reads like the app's (comments, naming, DRY); say why wherever you change a rule. Extend the harness to run your `PlaceRelocator` over the real steps (the addendum's result: 0 on wrong words, 0 a few words off) and the synthetic cases with the whole old text (146 on wrong words, 130 of them in moved paragraphs). Report what you get. Read `~/.TextMouth` for counts only, never content.

## What this branch adds (pure; branch D wires it into the rebuild)
**`PlaceRelocator`**, pure and `Sendable`, moves positions, bookmarks, and skipped headings from an old text to a new one:
- it lines the texts up with the patience diff over fine words (common words at both ends first, then words found once in each as fixed points, chained in their longest common order, recursively, with an exact longest common subsequence for small gaps);
- it carries each place across by the addendum's rules;
- where the diff cannot decide, it falls back to `TextAnchorFinder` and then the best guess;
- a skipped heading lands on the heading of its level where it lands; failing that, it is found by level, label, and words; failing that, the skip waits;
- it returns where each place went, how it was found (unchanged, by the diff, by the saved words, guessed), and the counts for the `PLACES_RELOCATED` line;
- it finds a place in the old text at its numbers when its saved words are there, or else by its words first (the snapshot may read differently from the text the place was saved in; addendum section 1, "What a snapshot can hold").
Say what you measured for its speed and memory on the user's largest text (3.54 MB of content.md; a synthetic text that size is fine).

## Tests (pure, no window, every subscript guarded)
- Each synthetic case in miniature: restored code with a span inside the next words; link text written twice; a chapter restored, moved, merged, or removed; dense edits; rewritten sentences; a passage printed twice; paragraphs moved (followed into the text the diff found put in, never to a second copy it kept).
- The slides: "CHAPTER" before "CHAPTER XIX."; a removal ending as the text before it ends.
- A place in removed text goes where the text after it begins.
- The end of the book.
- A place whose snapshot reading differs from the text it was saved in.
- An unchanged book moves nothing.

## Files you own
New files for the relocator and its tests; `FineWords` and `TextAnchorFinder` only where the relocator must share a rule, with a notice on the board first. `anchorcapture` (T06's branch B) edits the place-saving paths and `showLoadedContent`; `whereamimoves` edits the reader's playback files; you need neither.

## Report
What you built, the rules changed from the reference and why, the harness results for the real steps and the synthetic cases, speed and memory, the ARCHITECTURE wording (nothing is visible yet), and the TODO sentence.
