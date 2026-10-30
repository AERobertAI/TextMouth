# bughunt-folderedits: a folder edit keeps changes made meanwhile, and no book or folder goes into a folder that is gone

Worker slug `bughunt-folderedits`, branch `bughunt/folderedits` (from `team/bughunt`). Read `README.md` beside this file first. Two fixes, one commit each, each with its tests. Both were verified by the lead by reading. `LibraryViewModel.swift` and `LibraryViewModel+FolderManagement.swift` are claimed by team `views` tonight: change neither.

## 1. A reading-list change made while a folder edit moves its packages is undone when the edit finishes
`LibraryViewModel.library(after:current:)` (`TextMouth/ViewModels/LibraryViewModel+BookOperations.swift:528-556`) returns the edit's proposed library whenever the books, the folders, and the folder sort settings are unchanged since the plan was made (`:530-533`). The proposed library carries everything else as it was when the edit began: so a book added to the Reading List in another window while a folder of 300 books is renamed (the packages move for a second or more) is dropped again when the rename publishes, and saved that way. The feed shelf and the rows kept from a newer TextMouth go back the same way. `library(afterMoving:from:current:)` (`TextMouth/ViewModels/LibraryViewModel+Migration.swift:1806-1810`, the data-directory move) has the same shortcut.

Fix: in both, take the shortcut only when the whole library is unchanged (`current == plan.original`, and `current == snapshot`; check that `Library` is `Equatable` and compares every stored field, and say so in a comment); any other change goes through the existing merge, which starts from the current library and so keeps it. Do not change the merge itself. Only `library(afterMoving:from:current:)` in `LibraryViewModel+Migration.swift`: the tests team is changing `withStorageWorkHeld` in that file tonight.

Tests: in `LibraryTransitionOffMainTests`, beside `testThePublishedLibraryKeepsChangesMadeMeanwhile`: a plan made, then a book added to `current.readingList` (and, in a second assertion, a change to the feed shelf if the class can make one simply), and `library(after:current:)` keeps it. For the move's function, a test in the class that already tests it (grep `afterMoving`); if it is `private`, make it internal for the test with a comment saying so.

## 2. Move to Folder, New Folder, and a ZIP batch's folder accept a folder that no longer exists
- `moveBooksReturningOutcome(_:toFolder:)` (`LibraryViewModel+BookOperations.swift:284-300`) sets each book's `folderPath` to `path` without checking that the library still has a folder there; Move to Library checks (`LibraryViewModel+MoveToLibrary.swift:117`). Window A's Move sheet with "Essays" chosen, while window B renames "Essays": pressing Return makes `Library/Essays` again on disk and moves the books into it, and they vanish from the Folders view (a folder with no row).
- `Library.createFolderThrowing(name:parentPath:equivalence:)` (`TextMouth/Models/Library.swift:546-563`) never checks that the parent exists, so New Folder in a folder renamed meanwhile, or a ZIP batch's "Put in a folder of their own" answered after its folder was renamed (`LibraryViewModel+Duplicates.swift:550` keeps the path it captured), makes a folder row whose parent has no row.

Fix:
1. `createFolderThrowing` refuses a non-empty `parentPath` that names no folder (under the same equivalence it already uses for `storedSpelling`) with the existing `FolderOperationConflict.destinationNotFound(parentPath)` ("The destination folder “X” is no longer in the library."). **First grep every caller of `createFolderThrowing` and `createFolder(`**: any that makes nested folders (a repair adopting folder rows, an import making a folder path) must make each parent first; if one makes a child before its parent, stop and ask the lead rather than change that caller.
2. `moveBooksReturningOutcome` refuses a non-empty `path` that names no folder, before anything moves, with that same conflict's sentence, as its other failures are returned (`.failure(...)`: read how the Move sheet shows a failure and keep that).
3. One shared check for "the library has a folder at this path" (a `Library` method, if none exists; grep for one first), used by both.

Tests: in `FolderOperationOutcomeTests`, moving books to a folder path the library does not have fails with that sentence and changes nothing (no book's folder, no directory made); in `FolderSafetyTests`, `createFolderThrowing` under a missing parent throws `.destinationNotFound` and adds no folder, and under an existing parent works as today. Run the classes of every caller you found.

## Run
`LibraryTransitionOffMainTests FolderOperationOutcomeTests FolderSafetyTests ReadingListTests DataDirectoryMoveTests LibraryFolderTests` (grep each; drop any that does not exist and say so) plus the callers' classes. `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies` is load-sensitive: rerun a failure there alone and report both results.

## What a listener hears
Nothing new: the refusals use the existing sentence "The destination folder “X” is no longer in the library."
