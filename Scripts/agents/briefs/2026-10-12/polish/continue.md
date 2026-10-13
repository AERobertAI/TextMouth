# polish-continue: The Continue button says no time left for a finished book (a P07 follow-up)

- Team polish; lead `polish-lead`. Your slug is `polish-continue`, and your branch is `polish/continue`, made with `git checkout -b polish/continue team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes this TODO item from "Still open after the P07 merge (October 10)": "the Library's 'Continue: <title>' button still says '0:00 left' ('0 seconds remaining') for a finished book".
- It also ends the button's own spelling of "remaining", part of REV07's Library finding 7.

## What is wrong
The Library's Continue button, `continueListeningButton(for:)`, is in `TextMouth/Views/Library/LibraryView.swift`, about lines 950 to 988. It computes its time left itself, from `lastBook.estimatedTimeRemaining(wpm:)`. It also words that time itself: "\(TimeFormatting.format(remaining)) left", and ", \(TimeFormatting.spoken(remaining)) remaining".

For a finished book (`Book.restsAtEnd`) the estimate is 0. The button then shows "0:00 left", and VoiceOver says "Continue listening to Emma, 0 seconds remaining".

The button shows the last book opened, whatever its state (`LibraryViewModel.lastOpenedBook`). A book's row already follows P07's rule and words, both in `TextMouth/Views/Library/LibrarySubviews.swift`, about lines 661 to 676:
- `BookRow.timeRemaining(for:wpm:)` is nil for a book resting at its end, whose row says "Finished";
- `BookRow.remainingText(_:)` gives the visible "16:00 left" and the spoken "16 minutes remaining".

## Do
1. Beside the button, in `LibraryView`, add two `nonisolated static` functions, each with a comment. Both take their time from `BookRow.timeRemaining(for:wpm:)` and their words from `BookRow.remainingText(_:)`.
   - `continueTimeText(for book: Book, wpm: Double) -> String?`, the visible time: "16:00 left", or nil for a finished book.
   - `continueAccessibilityLabel(for book: Book, wpm: Double) -> String`, the VoiceOver label: "Continue listening to Emma, 16 minutes remaining", or "Continue listening to Emma" for a finished book.
2. Have the button use them. Keep everything else in it as it is: its hint, its identifier, and its focus.
3. In LibraryView.swift, edit only this button's function and the two new functions beside it.

## Tests
Use `FinishedBookWordingTests` (`TextMouthProductionTests/FinishedBookWordingTests.swift`), which already builds books resting at their end. Test that:
- a finished book's label holds no time, and its time text is nil;
- a book partway through gives the same spoken time as its row (`BookRow.remainingText(...).spoken`), and the same visible text.

## Build and test
- Run only `FinishedBookWordingTests`, plus any class that a grep of `TextMouthProductionTests` finds holding "Continue listening to".
- Start each build in the background and check on it no more often than every 4 minutes.
- `-jobs 4` is required (the orchestrator's #2107).
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-continue-…`.

    BBS_AGENT=polish-continue .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-continue" -only-testing:TextMouthProductionTests/FinishedBookWordingTests > <scratchpad>/polish-continue-build-1.log 2>&1

## Do not touch
- `BookRow`, `LibrarySubviews.swift`, and `LibraryViewModel`.
- Any `*.md` file.
