# polish-newfolder: A folder made with Create is announced

- Team polish; lead `polish-lead`. Your slug is `polish-newfolder`, and your branch is `polish/newfolder`, made with `git checkout -b polish/newfolder team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes this TODO item from "Still open after the import-and-sheet merge (October 10)": "a folder made with Create is not announced".

## What is wrong
When a folder is made, VoiceOver hears nothing about it. This happens in two places.

### The folder picker's New Folder fields
`LibraryFolderPicker` is in `TextMouth/Views/Library/LibrarySheetViews.swift`, about lines 300 to 512. The Move dialog, Add Feed, and Feed Info all use it.
- Its `createFolder()` (about lines 501 to 512) makes the folder, chooses it in the pop-up, and closes the fields.
- The Create button the focus was on goes away, and nothing is said.
- Its Cancel New Folder does speak: "New Folder cancelled. Destination folder: Reports." That is `newFolderCancelledAnnouncement(pickerLabel:chosen:)` (about lines 361 to 369), used by `cancelNewFolder()` (about lines 487 to 499).

### The New Folder sheet
`NewFolderSheet` is in LibrarySheetViews.swift, about lines 217 to 270. The Library window owns it, in `TextMouth/Views/Library/LibraryView.swift`, about lines 555 to 575: `.sheet(isPresented: $showNewFolderSheet)`.
- On success, the owner clears the fields and closes the sheet through `closingOnSuccess(_:close:)` (about lines 1491 to 1496).
- Nothing is said.

## Do
1. **The picker.** Beside the cancel's function, add `nonisolated static func newFolderCreatedAnnouncement(name: String, pickerLabel: String, chosen: String) -> String`, which returns, for example, "Folder Q3 created. Destination folder: Reports/Q3."
   - It says the new folder's name, then the pop-up's spoken label and the place now chosen, as the cancel's sentence does.
   - `chosen` is the new folder's label as the pop-up shows it: `LibraryFolderOption` labels a folder by its full path.
   - `createFolder()` announces it once the folder is made and chosen, at once (`VoiceOverAnnouncer.announce`), since the sheet stays open.
2. **The sheet.** On `NewFolderSheet`, add `nonisolated static func createdAnnouncement(name: String, parentPath: String) -> String`, which returns "Folder Q3 created in Reports.", or, at the top level, "Folder Q3 created in Library Root." (`LibraryFolderOption.rootLabel`, about lines 283 to 284).
   - In LibraryView.swift's `onCreate` (about lines 561 to 570), on success, announce it from the window once the sheet has closed: `VoiceOverAnnouncer.announceAfterSheetCloses(_:from: hostWindow)` (`TextMouth/Services/VoiceOverAnnouncer.swift`, about lines 91 to 97).
   - Use the name as it was made, `BookFolder.normalizedName(newFolderName)`. Create is dimmed while that is nil. Read it before the close clears `newFolderName`.
3. A failure says nothing new: the failure notice already says why, and the fields or the sheet stay open.
4. In LibraryView.swift, edit only that `.sheet` block (about lines 555 to 575). Another task edits the file after you.
5. Comment each function: what VoiceOver hears, and why.

## Tests
Add the tests to `LibraryFolderPickerTests` (`TextMouthProductionTests/LibraryFolderPickerTests.swift`). Its `testClosingTheFieldsIsAnnouncedWithTheFolderStillChosen` (about lines 196 to 213) shows the shape, for the cancel.
- Pin both sentences, for a nested folder and for a folder at the top level ("Library Root").
- `testReturnCreatesTheNewFolderWhileItsFieldsAreShownAndMovesOtherwise` (about lines 23 to 84) presses Create in a hosted sheet. Extend it, or add a test like it, that captures the announcements and checks that the created sentence is said once.
  - To capture them, use `announcements(during:)` (`TextMouthProductionTests/LibraryCloudTestSupport.swift`, about lines 288 to 299) or the poster swap it shows.

## Build and test
- Run only `LibraryFolderPickerTests`, plus any test class that a grep of `TextMouthProductionTests` finds using `NewFolderSheet(` or `createFolderReturningOutcome`.
- Start each build in the background and check on it no more often than every 4 minutes.
- `-jobs 4` is required (the orchestrator's #2107).
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-newfolder-…`.

    BBS_AGENT=polish-newfolder .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-newfolder" -only-testing:TextMouthProductionTests/LibraryFolderPickerTests > <scratchpad>/polish-newfolder-build-1.log 2>&1

## Do not touch
- `OperationFailureNotice`.
- The Move dialog's own wording.
- LibraryView.swift outside the New Folder sheet's block.
- Any `*.md` file.
