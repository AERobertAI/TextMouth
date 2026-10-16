# fixes-smallwords: one dead function, "1 seconds", and a blank manifest title

- Team `fixes`; lead `fixes-lead`; your task is number 50 on the team's list.
- Your slug is `fixes-smallwords`. Your branch is `fixes/smallwords`, made with `git checkout -b fixes/smallwords team/fixes`. Your worktree may start on an old commit, so branch from `team/fixes` exactly so.
- First read `Scripts/agents/briefs/2026-10-16/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds". **Tonight the usage rule is overridden:** the user said to "max it out" before the weekly reset, so keep working until the API refuses you, whatever the usage reading says. The "Weekly (Fable)" window caps another model and does not apply. Commit each green step at once.
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Use `git -C <path>` rather than `cd … &&`. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register fixes-smallwords --role "Dead timeToHeading removed; 1 second in a kill reason; blank manifest title falls back" --branch fixes/smallwords --team fixes --files TextMouth/ViewModels/ReaderViewModel.swift TextMouth/Services/WatchedProcess.swift TextMouth/Services/FileImportService.swift TextMouth/Parsers/AudioManifest.swift TextMouth/Parsers/AudioBookParser.swift TextMouthProductionTests/OggAfconvertTests.swift TextMouthProductionTests/AudioManifestTests.swift TextMouthProductionTests/AudioMediaImportTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move fixes-smallwords 50 working

- This brief gives you what you need. Read only the line ranges it names, once each, and what its tests lead you to.
- Three small independent changes, one commit each, in this order.

## 1. Remove the dead `ReaderViewModel.timeToHeading(_:)` (TODO #2005)
`TextMouth/ViewModels/ReaderViewModel.swift` about 827 to 841 ("Time from start of book to when a heading begins"): no caller in the app or any test. The lead checked the whole repository: only the declaration matches. Remove the function and its doc comment, nothing else (its neighbour `timeEstimateForHeading(_:)` is used by Where Am I? and by `AudioClipChainReaderTests`; `percentAtHeading` stays).
- **Completion check, run before you commit:** `grep -rn "timeToHeading" TextMouth TextMouthProductionTests TextMouthTests` must find nothing.
- `TextAnchorFinder.findHeading` is NOT dead any more (`PlaceRelocator.headingResultAtLoad` calls it): leave it. The statistics pass's `movedPlaces` plumbing in `LibraryViewModel+Migration.swift` is passed along by live code: leave it.

## 2. "1 seconds" in a kill reason (TODO line 3408, `WatchedProcess.swift`)
`WatchedProcess.KillReason.words` (about lines 36 to 48) says `"it ran longer than \(Int(seconds.rounded(.up))) seconds"` and `"its output did not grow for \(Int(seconds.rounded(.up))) seconds"`, so a one-second limit reads "1 seconds" (the debug log only). Use the app's counting helper, `CountWording.seconds(_:)` (`TextMouth/Models/CountWording.swift` about 59: "1 second", "5 seconds"), in both. Keep the rounding up. The memory phrase is unchanged.
- Test: add a method to `OggAfconvertTests`, right after `testKillReasonsReadAsWords` (about line 195), pinning "it ran longer than 1 second", "its output did not grow for 1 second", and, so the plural cannot slip, "it ran longer than 2 seconds" and the existing 63 and 20 cases. Do not change the existing method.

## 3. A blank manifest title or author falls back as a missing one does (TODO lines 3402, 3406)
`FileImportService.publishTracks` (about 1889 to 1920) takes the manifest's `title` and `author` as they come: `if let manifestTitle = manifest.title { title = manifestTitle }` and the same for the author (1905 to 1906). A manifest with `"title": ""` or `"title": "   "` therefore names the book with nothing, where a manifest with no title leaves the book the archive's or folder's name (`title`), and with no author leaves `Book.unknownAuthor`. The reading side repeats it: `AudioBookParser.swift` about 175 to 176 (`manifest?.title ?? url.lastPathComponent`, `manifest?.author ?? Book.unknownAuthor`). `String.nonBlank` (`Models/DocumentContent.swift` about 185: nil for whitespace only) is what `BookManifestEditing` already uses for the same job (`manifest.title?.nonBlank`, lines 687 and 822).
- Add two documented computed properties to `AudioManifest` (`TextMouth/Parsers/AudioManifest.swift`, the struct at the top; `title` is at line 16, `author` at 18), `bookTitle` and `bookAuthor`, the title or author with a blank one read as nil, and use them in `publishTracks` and in `AudioBookParser` (one place for the rule, not three). Do not change what the manifest decodes or encodes: a hand-edited manifest keeps every byte.
- Tests: in `AudioManifestTests` (the accessors: nil for nothing, empty, and spaces and newlines; the text itself otherwise); in `AudioMediaImportTests`, model `testAudioArchiveWhoseSectionStartsPastItsFileFailsNamingIt` (about line 96: `makeAudioArchive(named:)`, `AudioTestFixtures.writeSilence`) and import with `FileImportService.importAudioZipWithReport(from:toFolder:observer:)`: a manifest with a blank title and author gives the book the archive's name and `Book.unknownAuthor`, and one with a real title and author gives the book those. Read how the neighbouring tests make the library folder and read the imported book.
- Prove the import test fails without the change: after your commit, `git checkout HEAD~1 -- TextMouth/Services/FileImportService.swift` (adjust to your history), run the new import test alone (`-only-testing:TextMouthProductionTests/AudioMediaImportTests/<testName>`; if the property is still defined it compiles), see it fail, then `git checkout HEAD -- TextMouth/Services/FileImportService.swift`. Report both results.

## Commits
Three commits, in the order above. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Comment every function and non-obvious block.

## Build and test
Run once after the three commits, in one build: `OggAfconvertTests`, `AudioManifestTests`, `AudioMediaImportTests`, `AudioManifestCheckTests`, `AudioDirectoryImportTests`, `AudioClipChainReaderTests`, `BookManifestEditTests`. Then the revert run. Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/`, each named `fixes-smallwords-…`. Start each build in the background and check no more often than every 4 minutes with one short command.

    BBS_AGENT=fixes-smallwords .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-fixes-smallwords -only-testing:TextMouthProductionTests/OggAfconvertTests -only-testing:TextMouthProductionTests/AudioManifestTests -only-testing:TextMouthProductionTests/AudioMediaImportTests -only-testing:TextMouthProductionTests/AudioManifestCheckTests -only-testing:TextMouthProductionTests/AudioDirectoryImportTests -only-testing:TextMouthProductionTests/AudioClipChainReaderTests -only-testing:TextMouthProductionTests/BookManifestEditTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/fixes-smallwords-build-1.log 2>&1

Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. Your change must add no Swift warning. **Never touch the user's live library at `~/.TextMouth`**: tests use the sandboxed folders their neighbours use. A failing existing test means stop and ask (`bbs post fixes-smallwords --to fixes-lead --tag question --topic "…"`), with its name and why: never edit, weaken, or work around it. `OggAfconvertTests` may skip tests that need `afconvert`; say which skipped.

## Do not touch
- Any existing test, any `*.md` file, any other test file, and `project.pbxproj` (add no new file).
- `ReaderViewModel.swift` beyond the one function removed (team fixes' `fixes-endsound` adds a property near line 365 on another branch).

## Finish
As "The worker's part" says: post `done: fixes/smallwords` to `fixes-lead`; move task 50 to `review`; remove your build folder, unregistering its app first; release your claims; reply with your report of at most 15 lines.
