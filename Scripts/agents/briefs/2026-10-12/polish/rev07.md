# polish-rev07: REV07's Library finding 7, the library's duplicated and dead code

- Team polish; lead `polish-lead`. Your slug is `polish-rev07`, and your branch is `polish/rev07`, made with `git checkout -b polish/rev07 team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes REV07's Library finding 7, the review's last open item.
- It also closes this item from "Still open after the feed-counts merge": "`FeedCommands.swift` spells 'unread' and 'unplayed' itself".

Make three commits, each one keeping the app's behavior exactly as it is.

## Commit 1: `Book.isUnopened`
1. Add `var isUnopened: Bool { lastOpened == nil }` to `Book`, right below `var lastOpened: Date?` (`TextMouth/Models/Book.swift`, line 102). Give it a doc comment: a book is unopened while it has never been opened. It is what the Unopened category lists, and what a row's "New" and `BookState.isNew` (about line 885) read.
2. Replace every `lastOpened == nil` in `TextMouth/` with `isUnopened`. Find them with `grep -rn "lastOpened == nil" TextMouth`; there are about seven:
   - `Book.swift`, about line 885;
   - `Library.swift`, about line 840;
   - `LibraryInfoRow.swift`, about lines 157 and 199;
   - `FeedLibraryPresentation.swift`, about line 46;
   - `LibrarySubviews.swift`, about lines 473 and 600.
3. Replace `lastOpened != nil` with `!isUnopened` wherever it means "opened". Check each one.
4. Edit nothing else in Book.swift: another team's next branch edits its skips.

## Commit 2: Remove `Library`'s dead and test-only functions
Both functions are in `TextMouth/Models/Library.swift`.
1. **`booksWithNoFolder()`** (about lines 830 to 833) has no caller in the app. Delete it, and update its two tests:
   - `LegacyLibraryModelTests.swift`, about line 106: use `booksInFolder("")` instead.
   - `UnopenedCategoryTests.swift`, about line 194: this line compares it with `booksInFolder("")`. Drop the line, and anything in the test's comment that names the function.
2. **`sortSetting(for:default:)`** (about lines 250 to 254) is called only by tests:
   - `FolderSafetyTests`, about lines 205 and 521;
   - `LibrarySortStateTests`, about line 262;
   - `FolderDuplicateRepairTests`, about line 140.

   Move it, unchanged, into an `extension Library` in `TextMouthProductionTests/LibraryIndexTestSupport.swift`. Its comment should now say it is a reader for tests. That file already exists, so you add no new file and run no xcodegen.

## Commit 3: The remaining duplications
1. **The folder-tree filter.** `!$0.isFeedItem && ($0.folderPath == path || $0.folderPath.hasPrefix(path + "/"))` is spelled out three times:
   - in `Library.folderHasContents(_:)` and in `totalBooksInFolderTree(_:)`, about lines 793 to 811;
   - in `FolderInfoFacts.init`, without the `isFeedItem` check (`TextMouth/Views/Library/LibraryInfoRow.swift`, about lines 186 to 201).

   Name it once in `Library`, for example `func booksInFolderTree(_ path: String) -> [Book]`: the library's own books in the folder and in every folder below it. A feed's items name no folder (FR11). Use it in all three places, with `contains` where a Bool is wanted. Leave the deletion path in `LibraryViewModel+FolderManagement.swift` (about line 146) alone.
2. **"unread" and "unplayed".** `FeedWording.marked(title:played:isArticle:)` (`TextMouth/Views/Feeds/FeedCommands.swift`, about lines 330 to 333) spells these words itself. Use `unplayedNote(_:)` (`TextMouth/Views/Feeds/FeedLibraryWording.swift`, about lines 52 to 53) with the item's noun.
3. **`LibraryInfoSpeaker.swift`** (`TextMouth/ViewModels/`, 267 lines). REV07 found a comment there that the code broke, and FR12 has reworked the file since. Read the file once, and fix any doc comment that the code now breaks. If there is none, say so in your report.

## Tests
- Update the moved and changed tests named above.
- Add a test that `Book.isUnopened` follows `lastOpened`.
- Add a test that `booksInFolderTree` counts the books of a nested folder and no feed item.
- Put both new tests in `LegacyLibraryModelTests` or `UnopenedCategoryTests`, whichever already builds books and folders.

## Build and test
- Run only these classes:
  - `LegacyLibraryModelTests`, `UnopenedCategoryTests`, `FolderSafetyTests`, `LibrarySortStateTests`, `FolderDuplicateRepairTests`;
  - `LibraryInfoWordingTests` and `LibraryInfoSpeakerTests`;
  - the class that tests `marked(title:` (grep `TextMouthProductionTests` to find it).
- Start each build in the background and check on it no more often than every 4 minutes.
- `-jobs 4` is required (the orchestrator's #2107).
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-rev07-…`.

    BBS_AGENT=polish-rev07 .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-rev07" -only-testing:TextMouthProductionTests/LegacyLibraryModelTests -only-testing:TextMouthProductionTests/UnopenedCategoryTests -only-testing:TextMouthProductionTests/FolderSafetyTests -only-testing:TextMouthProductionTests/LibrarySortStateTests -only-testing:TextMouthProductionTests/FolderDuplicateRepairTests -only-testing:TextMouthProductionTests/LibraryInfoWordingTests -only-testing:TextMouthProductionTests/LibraryInfoSpeakerTests > <scratchpad>/polish-rev07-build-1.log 2>&1

## Do not touch
- Anything about skipped headings in Book.swift.
- `LibraryView.swift` and `LibrarySheetViews.swift`, which other tasks edit.
- Any `*.md` file.
