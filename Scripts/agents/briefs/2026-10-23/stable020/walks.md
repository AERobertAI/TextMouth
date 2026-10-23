# Brief: `stable020-walks` (V03, second half: the walks of the packages, and feed indexes)

- **Slug:** `stable020-walks`. **Branch:** `stable020/walks`, made with `git checkout -b stable020/walks team/stable020` once your lead says `stable020/rows` is integrated there.
- **Read first:** `Scripts/agents/briefs/2026-10-19/teams-common.md`, its sections "The worker's part", "Rules for everyone", "The board", "Builds", and "Lessons every brief applies". Nothing else of it. Then `Scripts/agents/briefs/2026-10-23/stable020/rows.md`, the first half, already on the team branch: `JSONValue`, `UnreadableLibraryRow` (its `json`, `id`, `tmbDirectoryName`, and `folderPath`), `UnreadableLibraryRow.decodeRows(from:)`, `Library.unreadableRows`, and `LibraryViewModel.booksNeedingNewerTextMouth`.
- **Why:** library.json now keeps the rows a later TextMouth wrote, unshown. Their packages are still on disk, and every walk of the packages takes a package no shown row names for an orphan: orphan adoption would add it as a second book, a removal sweep could delete it, Rebuild Library Index could make a row of it beside the kept one. `PLAN-0.2.0-2026-10-23.md`, V03: "Its package is treated as owned by every walk of the packages: orphan adoption, the startup repair, Rebuild Directory, the removal sweeps, and the data-directory move, which copies it."
- **Register with** the files you change (list them once step 1 is done); `TextMouth/Services/Feeds/FeedIndex.swift` and `TextMouthProductionTests/NewerLibraryRowsTests.swift` among them.
- **Disk:** before every build, `df -g /System/Volumes/Data` must show at least 4 GB available; if not, post to `stable020-lead` and wait for an answer (`bbs watch stable020-walks --timeout 240`). Your build folder is `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-stable020-walks`.

## The rule
A package that a kept row names belongs to that row: no walk adopts it, makes a row of it, repairs or moves it, or deletes it, and the data-directory move copies it with the rest. A kept row names its package by its `folderPath` and `tmbDirectoryName` when both read; when only `tmbDirectoryName` reads, by that name in any folder. Give this one home: a value made from the kept rows, e.g. `struct KeptRowPackages { init(_ rows: [UnreadableLibraryRow]); func owns(folderPath: String, tmbDirectoryName: String) -> Bool }` (or a method on `Library`), with doc comments, used by every walk. Never repeat the matching inline.

## Step 1: list every walk (before changing anything)
`grep -rn tmbDirectoryName TextMouth/Services TextMouth/ViewModels`, and read each hit's function. A walk is code that lists packages on disk (folders ending in `.tmb`, or a feed's packages) and acts on those no row names, or that rebuilds rows from packages. Known ones: `FileImportService.adoptOrphanedTMBPackages`; the startup repair (`LibraryViewModel+Migration.swift`, `repairLibrary` and the steps it calls); Rebuild Library Index (`rebuildDirectory`, `runDirectoryRebuild`, `rebuildToDefault`); every sweep that removes packages or folders; the data-directory move (`copyAndPublish` and `TextMouthPaths.moveDataDirectory`): find whether it copies the whole data directory or each row's package. Post the list to your lead (`--tag finding`) with, for each, what it would do to a kept row's package today, and go on without waiting.

## Step 2 (commit 1): every walk leaves a kept row's package alone
Apply the rule at each walk found. A walk that copies (the move) copies a kept row's package too, if it copies per row. Rebuild Library Index makes no row from a package a kept row owns, and keeps the kept rows (the first half already carries them into the rebuilt library; check). For each walk, one test in `NewerLibraryRowsTests` (a `// MARK: - Walks of the packages`), with a library whose library.json holds a kept row (an unknown `format`) whose package exists on disk with a record and a content.md:
- orphan adoption adds no book, and the package is still there, unchanged (compare its files' bytes);
- the startup repair leaves it, and library.json still holds the kept row equal to the original;
- Rebuild Library Index: the rebuilt library holds the readable books, the kept row once, and no row made from its package;
- each removal sweep: the package is still there;
- the move: the package is in the new data directory.
Make the fixtures inside the test sandbox (as other library tests make a data directory of their own); never touch `~/.TextMouth` or `UserDefaults.standard`.

## Step 3 (commit 2): a feed's index keeps the rows it cannot read
`FeedIndex.init(from:)` (`TextMouth/Services/Feeds/FeedIndex.swift:52-61`) decodes `books` in one piece; one row that does not decode makes `FeedIndex.read` (:214-262) preserve the index aside as unusable and rebuild the feed's rows from its packages, dropping the row whose record this TextMouth cannot read either.
1. `FeedIndex` gains `unreadableRows: [UnreadableLibraryRow]`, decoded with `UnreadableLibraryRow.decodeRows(from:)` and written back after `books` in `encode(to:)`, as library.json's are.
2. `FeedIndex.read` returns them in its `Contents`, and `rowsFromPackages(of:in:excluding:)` excludes their packages, as it excludes listed ones.
3. Wherever a feed's index is written again (find it from `Contents`, `FeedShelf`, and `Library.feedIndexRows`), its kept rows are carried and written back unchanged.
4. `LibraryViewModel.booksNeedingNewerTextMouth` adds every feed index's kept rows; its doc comment says so.
5. Tests: a feed index holding a readable row and a row of an unknown format reads the one, keeps the other, is not preserved aside as unusable, and writes the kept row back equal to the original at its next save; the count includes it.

## Test classes to run
`NewerLibraryRowsTests`, the classes of the feeds area that test the feed index (`python3 Scripts/test/run-area.py -h`; at least `FeedItemIndexFileTests`), `ContentAnalysisMergeTests`, the library area, `DataDirectoryMoveTests` (load-sensitive: rerun alone on failure, report both), `StorageGenerationMoveTests` (load-sensitive likewise), and `LogContentPolicyTests`. Run `make lint-tests LINT_BASE=team/stable020` before you report.

## Do not touch
`*.md`, the transcripts team's files, and folder rename, move, and delete (a follow-up: list in your report what each would do to a kept row's package). A failing existing test means stop and ask your lead.

## Report
teams-common's form, the list of walks from step 1 with what each now does, and the folder operations' follow-up.
