# Team libpolish: the Move to Folder sheet that is sometimes empty, and the reading-list words on a book's row

Read `Scripts/agents/briefs/2026-10-17/teams-common.md` first: it is the pattern you follow, and it stands in for AGENTS.md. You are the lead, `libpolish-lead`, on branch `team/libpolish` made from `main`. Your workers' briefs go in `Scripts/agents/briefs/2026-10-17/libpolish/`.

## What the user asked (October 17, 2026, in their words)

"I have noticed that for some reason the "move to folder" dialog sometimes pops up empty according to VO and sometimes properly, check the log to see if those events are recorded and look at the code for it and fix any bugs with new teams."

"Another change I would want is to have the "in reading list" label on book rows somewhere after the title / author to make scrolling through all of them slightly easier with voiceover."

A third item, letter navigation in the Library window, is being clarified with the user; the orchestrator will add it to your charter when it is settled. Leave the keyboard-shortcut files alone until then.

## 1. The Move to Folder sheet that VoiceOver sometimes finds empty (diagnose first, yourself)
- **The logs.** You may read (never write) the user's live logs for a diagnosis: the data directory is `~/.TextMouth` unless the preference `textMouthDataDirectory` names another (`defaults read` the app's domain to see; `TextMouth/Services/TextMouthPaths.swift:40,118`), and the logs live inside it unless the logs location setting moved them (`docs/user/where-your-library-lives.md` names the files and their tags). Find what is recorded when Move to Folder… opens, and around the times it might have opened empty (several presentations close together, a sheet dismissed and shown again, a selection change, a library reload or save). Say in your report what the logs do and do not show.
- **The code.** The sheet is in `TextMouth/Views/Library/LibrarySheetViews.swift` (Move dialog around lines 505-539) and is presented from `LibraryView.swift` (the `moveToFolder` action, its `.sheet`, its state). Find every way it can appear with nothing in it for VoiceOver: an item or binding read before it is set; a selection cleared or replaced as the sheet appears; a folder list built empty, or built once and not refreshed; a sheet shown twice, or over another sheet that is closing; the destination list hidden from accessibility, or the first focus landing on an empty container. Reproduce each candidate in a hosted test (host the view in a fixed frame), confirm the cause, and fix it with tests that fail without the fix.
- **Logging.** If the logs cannot tell an empty presentation from a full one, add one diagnostic line when the sheet appears, naming how many folders it lists and how many items it moves (never a title or a path: `LogContentPolicyTests` pins what logs may hold), so the next report can be checked.

## 2. "In reading list" after the title and author
`TextMouth/Views/Library/LibrarySubviews.swift`: a book row's spoken label is built from parts (around lines 590-622, title and author first), and "In reading list" (`ReadingListWording.inReadingListValue`, `ReadingListWording.swift:13`) is the row's accessibility value (`rowAccessibilityValue`, :627-629), which VoiceOver may speak before the label. Make it a part of the label right after the title and author (before "New", the progress, and the rest), and drop it from the value, so it is said once, in that place, on every row that says it (look for the second row type at :849-889, and feed item rows). Pin the order in the existing wording tests (`grep -ln "In reading list" TextMouthProductionTests/*.swift`), changing those that pin the old place on purpose and saying so in your report.

## Regions
You own `LibraryView.swift`, `LibrarySheetViews.swift`, `LibrarySubviews.swift`, `ContentView.swift`, `ReadingListWording.swift`, and, once item 3 is settled, the keyboard-shortcut files. Team rev18fix owns the reader's playback and episode files, `FeedDownloadManager.swift`, `OggHeaderReader.swift`, `LibraryPersistenceService.swift`, and the storage drill; team todo18 owns `FileImportService.swift`, the parsers, `ImportStaging.swift`, and `EndBehaviorMatrixTests`. A file another team owns is a finding on the board, never an edit.

## Your report
As `teams-common.md` says, with what the logs showed, the cause or causes you confirmed, and the exact new wording of the rows.
