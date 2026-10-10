# Task brief: importandsheets — the import progress follow-ups and the folder sheets' keyboard

Slug `importandsheets`; branch `fix/import-and-sheet-followups`. Read `common.md` beside this file first; its usage override ended at the 8:00 a.m. reset on October 10, so the normal rule applies: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count as your baseline.

## Why
Two groups of open items in TODO-2026-09-04.md: "Still open after the import-progress merge (October 7 evening)" and the October 6 sheet sweep's leftovers in "Still open after October 6". Read those lines, the importprogress agent's notes and the October 6 sheet agents' notes (librarysheets, feedpicker) in `AGENT-NOTES-2026-10-04.md`, and FR10's two merge entries, first. Since FR12's branch D (2c3b3eac), Return, Enter, Escape, and Command-Period always reach a sheet's or an alert's own buttons; check what each item below does on main before changing it.

## Items, one commit each, each with its tests
1. **A quick ZIP import that finds no new book ends in silence:** say what it found ("No new books: all 24 were already in your library"), through `VoiceOverAnnouncer`, however short the import.
2. **Imports queued behind the one shown are not mentioned:** the overlay and Speak Import Progress say how many more imports wait ("2 more imports waiting").
3. **A one-book audio or DAISY ZIP shows its step and time but not the bytes extracted** (`importAudioZipWithReport` passes no progress to the extractor): pass it.
4. **A `.tmb` package and New from Text show no book or step:** show them as other imports do.
5. **Each book of a ZIP batch is read twice for its checksum** (the duplicate check, then `importFileWithReport`): compute it once and pass it along; test that a batch reads each book's bytes once.
6. **The estimate counts books, not sizes**, so it runs short until a mixed archive's big books come: weight it by size where sizes are known, as FR10's feed half does (`FeedDownloadTimeEstimate`); share what the two estimates can share.
7. **DRY (#1461):** the text cache's observer view duplicates `ImportProgressObserver`; one view or helper serves both. (Leave #1460, the 5-second elapsed-time rule in `ReaderViewModel+CloudDownload.swift`, to the agent editing that file now.)
8. **The New Folder fields do not take keyboard focus when they open** (the Move sheet's and the feed sheets' folder pickers, `LibraryFolderPicker`): focus the name field, so a VoiceOver user lands where they type.
9. **Escape closes the whole Move sheet while the New Folder fields are shown:** Escape closes the New Folder fields first, saying so, and a second Escape closes the sheet.
10. **In Add Feed, Search keeps Return while its field is focused even with the New Folder fields shown**, so Create also draws as the default: one default button at a time.
11. **DRY (#1241):** the Return-key test helpers exist twice, privately in `LibraryFolderPickerTests` and as an XCTestCase extension in `FeedUIAddFeedTests`; one copy in `AccessibilityTestSupport.swift` serves both.

## Files you own
The import path's progress and batch code (`FileImportService`'s ZIP batch, `ArchiveExtractor`'s progress, `ImportProgress`, `ImportProgressWording`, `ImportProgressObserver`, the text cache's observer view), `LibraryFolderPicker` and the Move sheet in `LibrarySheetViews.swift`, the Add Feed sheet, and their tests. `movetolibrary` (FR11's branch D) opens the same folder picker for Move to Library…: post on the board before you change the picker, and keep its interface. `whereamikeys` owns the reader's playback, Where Am I?, cloud download, and keyboard files.

## Verify or report as unverified
Live VoiceOver and a real hundred-book archive are unverified; pin every wording and focus rule with tests that need no window where hosted tests cannot see buttons. Report the README and ARCHITECTURE wording and the TODO sentence.
