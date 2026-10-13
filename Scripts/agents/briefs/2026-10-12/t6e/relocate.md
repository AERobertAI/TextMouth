# t6e-relocate: places found at load, and a cursor carried into edited text (pure)

- **Slug** `t6e-relocate`; **branch** `t6e/relocate`, from `team/t6e`; **board task** given in your prompt.
- Read `worker-common.md` beside this file first, then "The worker's part" of `../teams-common.md`.
- Line numbers are `team/t6e`'s at 056e8a90 (main).

Two pure functions in `TextMouth/Models/PlaceRelocator.swift`, in the extension "Moving a Book's Places" (lines 1059-1372), placed after `relocate(_:from:to:movedAt:)` (1224-1252), with their tests. No app wiring: later tasks call them.

## Read first (by range)
- `PlaceRelocator.swift`:
  - 128-215: `Finding`, `DiffEvidence`, `Guess`, `Result`, `HeadingResult`.
  - 1015-1049: `standingHeading(of:among:in:requiringWords:)`, `holdsNoWords`, `finding(_:)`, which maps a `TextAnchorFinder.Finding`.
  - 1059-1372: `Places`, `Outcome`, `Counts`, `isAtTheStart`, both `relocate` functions, `stays`, `outcome(of:position:bookmarks:skips:in:headings:movedAt:)`, `moved`.
- `TextAnchorFinder.swift` 1-300: the rules, `find(_:savedAt:savedChapterLength:)`, `findHeading(level:label:anchor:savedAt:)`.
- `FineWords.swift` 224-330: `TextPlace.opening(...)` and `BookWords` (`endPlace`, `isEnd`).
- `TextAnchorCapture.swift` 1-30: `DocumentContent.anchor(at:measuredIn:)`, and `chapterStartOffset`/`totalCharacterCount`, which it uses.
- `ReaderViewModel+SavedPlaces.swift` 177-190: how the reader holds a saved place within the text (`openingPlace`).

## Function 1: places checked at every load, with no old text
`static func relocate(_ places: Places, within content: DocumentContent, movedAt date: Date) -> Outcome?`

At every load, each place is checked directly. One whose saved words are not at its numbers is found by them, and anything left goes to a silent best guess. There is no old text to diff.

1. **Nil when every place stands.** This runs at every open of a book, so the shortcut makes only direct checks on the chapters' texts (`content.chapters.map(\.text)`), with `content`'s own offsets for the end of the book (`chapterStartOffset`, `totalCharacterCount`). It builds no `BookWords` and no `TextAnchorFinder`. A reading position or bookmark stands when:
   - a. it has no saved words (`anchor == nil`): nothing finds it without the old text, and the reader's clamp and its capture of missing words take it, as they do today;
   - b. its anchor holds no fine word (`holdsNoWords`): words that stand anywhere prove nothing;
   - c. its anchor marks the end of the book and it is exactly the end of `content`, by `BookWords.isEnd`'s rule. Reproduce that rule from `content`'s offsets in one helper. Do not copy it: if `isEnd` can share the helper, make it.
   - d. its anchor stands exactly at its numbers (`anchor.stands(at:in:)`);
   - e. it is the reading position at chapter 0, offset 0: a book never begun, or begun over, stays at its start, as the diff's start-of-book rule keeps it (REV15, finding 14).
   - A named skip stands when `standingHeading(of:among:in:)` finds its heading.
   - The shortcut also needs no waiting skip whose heading now stands exactly as it was skipped (`standingHeading(…, requiringWords: true)`): such a skip must name its heading again, so it is no shortcut.
2. **Otherwise every place moves at once,** with `BookWords` and one `TextAnchorFinder(content:)` built once:
   - a position or bookmark that stands by 1 stays (`.unchanged`);
   - a place without saved words, whose numbers `content` does not hold, goes where the reader's clamp opens it (`TextPlace.opening`, the position with its `globalCharacterOffset`, as `openingPlace` calls it), counted as `.guessed(.savedWords(.sameShare))`;
   - a place with saved words that does not stand is found by them: `finder.find(anchor, savedAt:)`, with no `savedChapterLength` (there is no old text), mapped with `finding(_:)`;
   - a named skip whose heading stands stays (`.unchanged`); one with saved words is found by `finder.findHeading(level:label:anchor:savedAt:)`, mapped to `HeadingResult` with `finding(_:)`; with none found, or without saved words, it waits (nil), as everywhere else;
   - the outcome is built by the shared `outcome(of:position:bookmarks:skips:in:headings:movedAt:)`. That function captures anchors anew, works out the position's global offset, dates a moved position `date`, takes waiting skips by the waiting rule, and counts. Write no second outcome builder.
3. Pure: no clock (the caller passes `date`), no log line (the caller logs `counts.logLine(title:)`), nothing spoken.

## Function 2: one place carried into an edited text
`static func relocate(_ place: TextPlace, from old: DocumentContent, to new: DocumentContent) -> TextPlace`

A reader's cursor, when Edit Text replaces its text: its own text is the old text. The place moves exactly as a reading position saved at `place` in `old`, with saved words captured there, would move through `relocate(_:from:to:movedAt:)`. So the relocator is built only when those words do not stand in `new`, and the start-of-book and end-of-book rules apply.
- Capture the words with `old.anchor(at:measuredIn: nil)` (or `TextAnchor(capturingAt:in:)` on `BookWords`, whichever `relocate` already reads), after holding `place` within `old` (`TextPlace.opening`).
- A `new` with no chapters gives chapter 0, offset 0.
- Return the moved position's chapter and offset.

## Tests
A new file, `TextMouthProductionTests/PlaceRelocatorAtLoadTests.swift` (`final class PlaceRelocatorAtLoadTests: XCTestCase`). Run `/opt/homebrew/bin/xcodegen generate` and commit the project with it. Small texts written in the test; see `PlaceRelocatorTests.swift` for how it builds `DocumentContent` and places, and reuse its helpers where reachable.

**Function 1:**
- An unchanged book gives nil: a position, a bookmark, a named skip, and a waiting skip whose heading is still gone.
- A paragraph put in before every place: the position and the bookmark are found by their saved words (`.foundBySavedWords`), and the skip's heading by `findHeading`; check the counts and the log line's numbers. The moved position is dated `date`; the bookmark keeps its id, note, and date.
- A place whose words were rewritten is a best guess, at a word start in its chapter.
- A position at the end of the book stays at the new end when text is added after it.
- A position at chapter 0, offset 0 stays there when a title page is put in before the old first words, with a bookmark elsewhere that does move.
- A place without saved words, past its chapter's end, beside a place that moves: it goes to its chapter's end, as the clamp opens it.
- A waiting skip whose heading stands again exactly as it was skipped: a non-nil outcome that names it again.
- A named skip whose heading was removed now waits.

**Function 2:** the cases of `BookTextEditTests.testTheCursorFollowsItsWords` (BookTextEditTests.swift 680-721; `EditedTextCursor` retires in a later task, which deletes that test), each re-expressed:
- an unchanged chapter: the same place;
- text added before the cursor: it follows its words;
- the cursor's own words rewritten;
- a chapter split, with an interlude put in;
- two chapters merged into one;
- unrelated text;
- a cursor in a chapter past the end;
- an empty new text.

Assert what the relocator's rules give. Where that differs from `EditedTextCursor`'s answer in the old test, say in the test's comment which rule decided it, and list each difference in your report.

**Run:** `PlaceRelocatorAtLoadTests`, `PlaceRelocatorTests`, `PlaceRelocatorHeadingTests`.

## Do not touch
Anything outside `PlaceRelocator.swift` (and `FineWords.swift`, only to share the end-of-book rule), the new test file, and the project file.
