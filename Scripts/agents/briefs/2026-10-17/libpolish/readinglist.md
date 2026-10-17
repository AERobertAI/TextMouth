# libpolish/readinglist: "In reading list" right after a row's title and author

Worker slug `libpolish-readinglist`, branch `libpolish/readinglist` made from `team/libpolish`. Lead: `libpolish-lead`. Read `Scripts/agents/briefs/2026-10-17/teams-common.md`, "The worker's part", and follow it.

## What the user said (October 17)

"have the "in reading list" label on book rows somewhere after the title / author to make scrolling through all of them slightly easier with voiceover."

## Where things are

- `TextMouth/Views/Library/LibrarySubviews.swift`, `BookRow` (:390-735). The only builder of a book row's spoken words; `LibraryBookListRow` (:800-910) wraps it, and feed items' rows are book rows too.
  - `isInReadingList` (:409-413) and its doc.
  - The row's modifiers (:537-545): `.accessibilityLabel(rowAccessibilityLabel)`, then `.accessibilityValue(rowAccessibilityValue ?? "")` with its 4-line comment (:539-542).
  - `rowAccessibilityLabel` (:592-623), built from parts joined by ", ": "Selected" in edit mode, the title, "by <author>", then "New" or "Now Reading", the cloud note, "Kept on this Mac", the transcription note, the progress, the time left, and the format.
  - `rowAccessibilityValue` (:625-630), "In reading list" or nil.
- `TextMouth/Models/ReadingListWording.swift:9-13`, `inReadingListValue = "In reading list"` and its doc.
- Tests: `TextMouthProductionTests/ReadingListViewTests.swift:399-433`, `testARowSaysInReadingListAsItsValueAndKeepsItsLabel` and `testAHostedRowCarriesTheValue`.

## The change (one commit)

1. "In reading list" becomes a part of the row's label, right after "by <author>" and before "New" or "Now Reading" and every later part, only when `isInReadingList`. A selected row in edit mode still begins with "Selected". So a book in the list reads "Loose Pages, by Ines Okonkwo-Varga, In reading list, New, Plain Text".
2. The row has no accessibility value any more. Remove the `.accessibilityValue` modifier, its comment, and `rowAccessibilityValue`. VoiceOver then says the words once, in that place.
3. Rename `ReadingListWording.inReadingListValue` to `inReadingListNote`, with a doc saying it is spoken in a book's row label, right after its title and author, in every view but the Reading List itself. Update `isInReadingList`'s doc in `BookRow` to say the same.
4. **Tests,** changed on purpose (say so in your report, naming each):
   - Replace `testARowSaysInReadingListAsItsValueAndKeepsItsLabel` with `testARowSaysInReadingListRightAfterItsTitleAndAuthor`. Pin the exact labels:
     - a listed book, and the same book unlisted (no note);
     - a listed book selected in edit mode ("Selected, Loose Pages, by …, In reading list, …");
     - a listed book that has a cloud state, as `LibraryCloudNoteTests` makes one, and progress, so the order against the cloud note and the progress is pinned;
     - a listed book open in a reader ("…, In reading list, Now Reading, …").
   - Replace `testAHostedRowCarriesTheValue` with `testAHostedRowSaysItInItsLabel`: one element, whose label is the row's and contains "In reading list", and whose value is nil or empty. It keeps the existing skip when SwiftUI exposes no elements.
   - Keep the class's other tests as they are.

## Tests to run (only these; `python3 Scripts/test/run-area.py <classes>` with `BBS_AGENT=libpolish-readinglist`)

`ReadingListViewTests ReadingListTests LibraryCloudNoteTests KeepOnThisMacTests TranscriptionProgressTests FinishedBookWordingTests LiveReadingPositionsTests LibraryProgressTextTests ViewsAndWindowsLibraryListTests FeedUILibraryRowsTests` (drop any that `run-area.py` says does not exist).

Log to `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/libpolish-readinglist-<n>.log` (`--log`). Before you report, run `make lint-tests LINT_BASE=team/libpolish` and `make lint-a11y LINT_BASE=team/libpolish`.

## Completion check (must print nothing)

    grep -rn "inReadingListValue\|rowAccessibilityValue" TextMouth TextMouthProductionTests

## Do not touch

`LibraryView.swift`, `LibrarySheetViews.swift`, `LibraryInfoWording.swift` (Speak Info's "In reading list, 3 of 12" stays as it is), the keyboard-shortcut files, any `*.md` file, and every part of `LibrarySubviews.swift` outside `BookRow`.
