# polish3-deadfunc: #2078's dead `updateReadingPosition` goes; `notInLibrary` moves to the editors' shared wording

- Team `polish3`; lead `polish3-lead`; your task is number 21 on the team's list.
- Your slug is `polish3-deadfunc`. Your branch is `polish3/deadfunc`, made with `git checkout -b polish3/deadfunc team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-deadfunc --role "#2078 dead function; notInLibrary to shared wording" --branch polish3/deadfunc --team polish3 --files "TextMouth/ViewModels/LibraryViewModel+BookOperations.swift" TextMouth/Models/EPUBMetadataSave.swift TextMouth/Views/Reader/MetadataEditorView.swift "TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift" TextMouthProductionTests/MetadataEditorBaselineTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-deadfunc 21 working

- Before you edit `ReaderViewModel+Bookmarks.swift`, run `python3 .claude/skills/agent-bbs/scripts/bbs.py claims`. If anyone else claims it, change nothing there and ask `polish3-lead`.
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two TODO items: #2078 (a dead function in `LibraryViewModel+BookOperations.swift` about line 686) and "`EPUBMetadataSaveWording.notInLibrary` (`EPUBMetadataSave.swift:130`)".

## 1. #2078: the view model's two-argument `updateReadingPosition` goes (one commit)
`LibraryViewModel.updateReadingPosition(bookID:position:)` (`TextMouth/ViewModels/LibraryViewModel+BookOperations.swift` lines 684 to 688, with its doc comment "Compatibility name for navigation and bookmark call sites…") only calls `persistReadingPosition(bookID:position:)` (lines 673 to 682), and nothing calls it. Every two-argument call in the tests is on a `Library` value, whose own `updateReadingPosition(bookID:position:markingOpened:)` (`Library.swift` line 313) stays: `FinishedBooksAtEndMoveTests.swift:198`, `ReadingCheckpointTests.swift:87`, `LibraryListCacheTests.swift:115`, `AudioEditPlacesTests.swift:365`, `LibraryModelBenchmarkTests.swift:159`, and `TextMouthTests/Sources/Tests/IntegrationTests.swift:282`.

Confirm it is still open first: `grep -rn "func updateReadingPosition(bookID: UUID, position: ReadingPosition) {" TextMouth` finds line 686.

1. Delete the function and its doc comment.
2. `grep -rn "updateReadingPosition" TextMouth --include='*.swift'`: any doc comment naming the view model's form now names `persistReadingPosition(bookID:position:markingOpened:)`. Leave `Library`'s and its callers alone.

**Completion check:** the confirm grep finds nothing, and the build compiles every test target, which proves no caller is left.

## 2. `notInLibrary(title:)` moves to the editors' shared wording (one commit)
`EPUBMetadataSaveWording.notInLibrary(title:)` (`TextMouth/Models/EPUBMetadataSave.swift` lines 127 to 132) says "Could not save metadata: “Notes” is no longer in the library. Nothing was changed." The EPUB editor's save uses it (`LibraryViewModel+BookOperations.swift` line 768), and so does the audio editor's (`ReaderViewModel+Bookmarks.swift` lines 326 and 327, whose comment says it borrows "the words the EPUB editor's save uses"). Its home is `MetadataEditorWording` (`TextMouth/Views/Reader/MetadataEditorView.swift` lines 341 to 356): "the words the metadata editors and the library's Book Info sheet share".

Confirm it is still open first: `grep -rn "EPUBMetadataSaveWording.notInLibrary" TextMouth TextMouthProductionTests` finds three lines.

1. Move the function, its doc comment, and its words unchanged into `MetadataEditorWording`, and delete it from `EPUBMetadataSaveWording`.
2. Update the three callers: `LibraryViewModel+BookOperations.swift` line 768, `ReaderViewModel+Bookmarks.swift` line 327, and `TextMouthProductionTests/MetadataEditorBaselineTests.swift` line 215. Reword the comment at `ReaderViewModel+Bookmarks.swift` line 326 to say these are the words every metadata editor's save uses for such a book.
3. Nothing the user hears changes.

**Completion check:** `grep -rn "EPUBMetadataSaveWording.notInLibrary" TextMouth TextMouthProductionTests` finds nothing.

## Commits
Two commits, one per part. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run `MetadataEditorBaselineTests`, `EPUBMetadataWritebackTests`, and each other class that pins the words: `grep -rln "is no longer in the library" TextMouthProductionTests`. Nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-deadfunc-…`.

      BBS_AGENT=polish3-deadfunc .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-deadfunc -only-testing:TextMouthProductionTests/MetadataEditorBaselineTests -only-testing:TextMouthProductionTests/EPUBMetadataWritebackTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-deadfunc-build-1.log 2>&1

  Add an `-only-testing:` for each class the words grep finds.
- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `Library.swift`, `ReaderViewModel.swift`, `ReaderViewModel+SavedPlaces.swift` (another team's), and every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/deadfunc` to `polish3-lead`, move task 21 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.
