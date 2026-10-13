# polish2-rename: a filtered render puts its result in place in one step (#1988, #1989)

- Team `polish2`; lead `polish2-lead`; your task is number 12 on the team's list.
- Your slug is `polish2-rename`. Your branch is `polish2/rename`, made with `git checkout -b polish2/rename team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-rename --role "#1988: render result in place in one step; one rename(2) helper" --branch polish2/rename --files TextMouth/Services/SavedFile.swift TextMouth/Services/LogWriter.swift TextMouth/Services/ReadingTextCache.swift TextMouth/Services/AudioEditing/AudioFilterProcessor.swift --team polish2
      bbs task move polish2-rename 12 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes #1988 and #1989 (TODO line 3139): "`AudioFilterProcessor.process(_:chain:)` has each of two renders of one stretch remove the result before moving its own partial there, a real race whichever call threw".

## What is wrong
`AudioFilterProcessor.process(_:chain:)` (`TextMouth/Services/AudioEditing/AudioFilterProcessor.swift` lines 18 to 74) renders a stretch through a filter chain into a hidden partial file, then puts it at the result's name, which is made from everything that decides its sound. Lines 61 to 69 do that in two steps:

    try? FileManager.default.removeItem(at: result)
    do {
        try FileManager.default.moveItem(at: partial, to: result)
    } catch where FileManager.default.fileExists(atPath: result.path) { … }

When two renders of one stretch run at once (a preview and a level measurement can ask at once), one can remove the result the other just moved there, and the other's `Self.frames(of: result, …)` (line 73) then finds no file. `AudioEditCachesTests.testTwoRendersOfOneStretchAtOnceBothGetIt` failed so once under load.

rename(2) puts a file in place of another in one step, so a reader finds the old file or the new one, never none. The app has two private copies of that already:
- `LogWriter.renameReplacing(_:_:)` (`TextMouth/Services/LogWriter.swift` lines 430 to 445), internal, which captures `errno` inside the closure, as it must;
- `ReadingTextCache.rename(_:to:)` (`TextMouth/Services/ReadingTextCache.swift` lines 394 to 404), private, called at line 343, which reads `errno` after the closure returns, where it may have changed.

## Do
1. **One helper.** Move `LogWriter.renameReplacing(_:_:)`, with its doc comment and unchanged, to `SavedFile` (`TextMouth/Services/SavedFile.swift`, `enum SavedFile` from line 17), whose purpose is files TextMouth replaces whole. Put it in its own `// MARK:` section at the end of the enum. Its doc comment gains one sentence: the source and destination must be on one volume, as a partial file beside its destination is.
2. **Its callers.**
   - `LogWriter.swift`: delete its copy; the `rename:` default (line 146) becomes `{ try SavedFile.renameReplacing($0, $1) }`.
   - `ReadingTextCache.swift`: delete the private `rename(_:to:)` (lines 394 to 404); line 343 becomes `try SavedFile.renameReplacing(partial, url(for: bookID))`.
   - The tests that call `LogWriter.renameReplacing`: `LogWriteSafetyTests.swift` lines 153 and 239, and `LogTestSupport.swift` line 15. Change only the name.
3. **The render.** Replace lines 61 to 69 of `AudioFilterProcessor.swift` with one `try SavedFile.renameReplacing(partial, result)`, under a comment saying why: the result's name is made from everything that decides its sound, so another render of this very stretch makes the same file; each puts its own in place in one step, so neither ever finds the result missing (#1988). The `defer` that removes the partial stays: after the rename there is nothing to remove, and `try?` ignores that.
4. **Commits:** first the helper's move with steps 1 and 2 and the helper's test; then the render's fix with its test. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Tests
- **The helper**, in `LogWriteSafetyTests.swift` (it already uses it): one test that `SavedFile.renameReplacing` puts the source's content in place of an existing destination and leaves no source; and that it throws a `POSIXError` with code `.ENOENT` for a source that is missing. Use a temporary folder of the test's own (look at how the file's other tests make theirs), never the user's library.
- **The render**, in `TextMouthProductionTests/AudioEditCachesTests.swift`, beside `testTwoRendersOfOneStretchAtOnceBothGetIt` (lines 127 to 145, read them for the setup): a render that finds a damaged result at its name replaces it. Render once; overwrite the one processed stretch (`processedStretches(in:)`, line 160) with a few bytes that are not audio; render again; the segment has the same length (16,000), the file reads as audio again, there is still one processed stretch, and no partial (a name starting with ".") is left.
- **The race, repeated.** Once the three classes pass, run the race's test alone ten times in one build, by replacing the `-only-testing` arguments of the command below with `-only-testing:TextMouthProductionTests/AudioEditCachesTests/testTwoRendersOfOneStretchAtOnceBothGetIt -test-iterations 10`, and report its result line.

## Build and test
- Run `AudioEditCachesTests`, `LogWriteSafetyTests`, and `ReadingTextCacheTests`.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-rename-…`.

      BBS_AGENT=polish2-rename .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-rename" -only-testing:TextMouthProductionTests/AudioEditCachesTests -only-testing:TextMouthProductionTests/LogWriteSafetyTests -only-testing:TextMouthProductionTests/ReadingTextCacheTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-rename-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.
- No test may play sound aloud; these render to files only.

## Do not touch
- `FeedItemPackage.swift`'s `renamex_np` swap: it exchanges two folders, a different operation.
- `EPUBParser.swift` and `AudioEditBookRender.swift`, which use `FileManager.replaceItemAt` on a book's own file.
- Any other file, and any `*.md` file.
