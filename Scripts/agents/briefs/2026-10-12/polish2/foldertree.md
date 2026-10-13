# polish2-foldertree: one rule for a folder's tree of books

- Team `polish2`; lead `polish2-lead`; your task is number 13 on the team's list.
- Your slug is `polish2-foldertree`. Your branch is `polish2/foldertree`, made with `git checkout -b polish2/foldertree team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-foldertree --role "One rule for a folder's tree of books" --branch polish2/foldertree --files TextMouth/Models/Library.swift TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift TextMouthProductionTests/UnopenedCategoryTests.swift --team polish2
      bbs task move polish2-foldertree 13 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two items of "Still open after the polish-team merge" (TODO line 3152): "`Library.folderHasContents` builds a list where a short-circuiting check would do" and "the Delete Folder path spells the folder-tree filter a fourth time (`LibraryViewModel+FolderManagement.swift`, about line 146)".

## What is wrong
`Library.booksInFolderTree(_:)` (`TextMouth/Models/Library.swift` lines 803 to 812) is meant to be "the one place that says what "in a folder's tree" means": the library's own books, never a feed's items, in the folder at a path or below it. Yet:
1. `folderHasContents(_:)` (lines 786 to 792) builds that whole list only to ask whether it is empty.
2. `removeFolderAndContents(id:)` (lines 448 to 478) spells the path rule four times (`x == folderPath || x.hasPrefix(folderPath + "/")`): for the books it returns, the books it removes, the folders it removes, and the sort settings it drops. Its book rule has no feed-item guard.
3. Delete Folder…, `removeFolderAndEverything(_:)` in `TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift`, gathers the packages to delete with its own filter (lines 146 to 148), also without the guard, and then calls `library.removeFolderAndContents(id:)` (about line 163).

A feed's item names no folder (FR11), and new ones are stored with an empty folder path, but an older record can still name one: `UnopenedCategoryTests.testBooksInFolderTreeCountsNestedBooksAndNoFeedItems` (lines 181 to 210) builds exactly that, and `booksInFolderTree` rightly leaves it out. Today Delete Folder would delete such an item's package; with only one of the two filters changed, it would drop the item's record and leave its package on disk. So both must take the one rule. A feed's downloads must survive Delete Folder… (`LibraryFeedFolderDeleteTests`, about lines 120 to 133, already checks "Delete Everything took a download").

## Do
1. **The path rule, once.** In `Library`, a `static func isPath(_ path: String, inTreeAt root: String) -> Bool`: `path == root || path.hasPrefix(root + "/")`, with a doc comment (a folder named "Essays Old" is not in "Essays"'s tree).
2. **The book rule, once.** A `private func isInFolderTree(_ book: Book, at path: String) -> Bool`: `!book.isFeedItem && Self.isPath(book.folderPath, inTreeAt: path)`, documented as the rule `booksInFolderTree(_:)` states. `booksInFolderTree(_:)` filters with it; its doc comment stays true.
3. **A check that stops early.** `func hasBooks(inFolderTree path: String) -> Bool`, `books.contains { isInFolderTree($0, at: path) }`, documented; `folderHasContents(_:)` uses it.
4. **`removeFolderAndContents(id:)`:** the books it returns and removes are `booksInFolderTree(folderPath)` (remove them by their IDs, so the two can never disagree); the folders and sort keys it drops use `isPath(_:inTreeAt:)`. Update its doc comment to say a feed's items are never taken, being in no folder.
5. **Delete Folder…** (line 146 to 148): `let booksToRemove = library.booksInFolderTree(path)`, with a short comment that it is the same rule `removeFolderAndContents` applies afterward.
6. Change nothing else: no other caller, no wording.
7. **Commits:** one for steps 1 to 3 (the rule and the early check), one for steps 4 and 5 (the removals), each with its tests. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Tests
Beside `testBooksInFolderTreeCountsNestedBooksAndNoFeedItems` in `TextMouthProductionTests/UnopenedCategoryTests.swift` (lines 181 to 210; reuse its `Self.book(…)` helper and its fixture's shape):
- `hasBooks(inFolderTree:)` is true for "Essays" (a book in "Essays/Travel/Rail" is enough), false for a folder holding only a feed's item that names it, and false for "Essay", a name that only starts the same.
- `removeFolderAndContents(id:)` on "Essays" returns and removes the books in "Essays" and below, keeps the book in "Essays Old" and the feed's item that names "Essays", removes the folders "Essays" and "Essays/Travel", and drops their sort settings but not "Essays Old"'s. (Look at how `folderSortSettings` is set in one existing test with `grep -n "folderSortSettings" TextMouthProductionTests/*.swift | head -3`.)

`UnopenedCategoryTests` runs on the main actor, one test at a time; keep the new tests in that form.

## Build and test
- Run `UnopenedCategoryTests`, `LegacyLibraryModelTests`, `ReadingListTests`, `FolderSafetyTests`, `RemovalOutcomeTests`, and `LibraryFeedFolderDeleteTests`.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-foldertree-…`.

      BBS_AGENT=polish2-foldertree .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-foldertree" -only-testing:TextMouthProductionTests/UnopenedCategoryTests -only-testing:TextMouthProductionTests/LegacyLibraryModelTests -only-testing:TextMouthProductionTests/ReadingListTests -only-testing:TextMouthProductionTests/FolderSafetyTests -only-testing:TextMouthProductionTests/RemovalOutcomeTests -only-testing:TextMouthProductionTests/LibraryFeedFolderDeleteTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-foldertree-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- Any other function in `Library.swift`, above all the reading positions, bookmarks, and skipped headings (another team's work is near them).
- The other `hasPrefix(… + "/")` checks in the app: they compare file paths or other things.
- Any other file, and any `*.md` file.
