# polish3-fixturepaths: test data found through one function; `CountWording.list` tested once

- Team `polish3`; lead `polish3-lead`; your task is number 24 on the team's list.
- Your slug is `polish3-fixturepaths`. Your branch is `polish3/fixturepaths`, made with `git checkout -b polish3/fixturepaths team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-fixturepaths --role "Test data through requireFile; CountWording.list tested once" --branch polish3/fixturepaths --team polish3 --files TextMouthProductionTests/LegacyScenarioHarness.swift TextMouthProductionTests/EPUBMetadataTests.swift TextMouthProductionTests/EPUBMetadataWritebackTests.swift TextMouthProductionTests/ReaderEPUBMetadataTests.swift TextMouthProductionTests/MetadataReaderVersionTests.swift TextMouthProductionTests/LegacyPDFParserTests.swift TextMouthProductionTests/LibraryCloudCommandTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-fixturepaths 24 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two TODO items: "the Alice fixture path written twice" and "`CountWording.list` is tested in both `CountWordingTests` and `LibraryCloudCommandTests`".

## 1. One way to the test data (one commit)
`TextMouthProductionTests/LegacyScenarioHarness.swift` has `requireFile(_:)` (lines 82 to 92: the URL of a file in the repository's `TestData`, throwing when it is missing) and `testFilePath(_:)` (lines 94 to 103: the same path, not checked, for optional fixtures), and both build the path from `#filePath`. Five test files build it by hand once more:
- `EPUBMetadataTests.swift` lines 223 to 228, `repositoryFixture()`, used at lines 7, 17, and 216;
- `EPUBMetadataWritebackTests.swift` lines 249 to 253, `static let aliceFixture`, used at line 269;
- `ReaderEPUBMetadataTests.swift` lines 238 to 242, `static let aliceFixture`, used at line 248;
- `MetadataReaderVersionTests.swift` lines 50 to 52, in `testAnImportStampsTheRowWithTheReaderThatReadItsFile`;
- `LegacyPDFParserTests.swift` lines 259 to 266, `fixture(_:)`, which skips the test (`XCTSkip`) when an optional fixture is missing.

Confirm it is still open first: `grep -rn '"TestData' TextMouthProductionTests` finds seven lines.

1. In `LegacyScenarioHarness.swift`, `requireFile(_:)` builds its URL from `testFilePath(_:)` (or both from one small function of their own), so the path is built once. Keep both functions' names, signatures, and behavior, and give each a doc comment.
2. The four Alice users call `try requireFile("alice.epub")` and their own helpers go. Make a test `throws` where it needs the `try`.
3. `LegacyPDFParserTests.fixture(_:)` takes its path from `testFilePath(_:)` and keeps its `XCTSkip` for a missing file.

**Completion check:** `grep -rn '"TestData' TextMouthProductionTests` finds only `LegacyScenarioHarness.swift`, and at most two lines there.

## 2. `CountWording.list` tested once (one commit)
`CountWordingTests.testListJoinsItemsAsASentenceListsThem` (`CountWordingTests.swift` lines 104 to 112) pins `CountWording.list` for none to four items. `LibraryCloudCommandTests.testListsJoinTitlesInASentence` (`LibraryCloudCommandTests.swift` from about line 545, its doc comment and lines 548 to 553) pins the same for none to three.

Confirm it is still open first: `grep -n "CountWording.list" TextMouthProductionTests/LibraryCloudCommandTests.swift` finds its lines.

1. Delete `testListsJoinTitlesInASentence` and its doc comment, and a `// MARK:` left with nothing under it.
2. Leave `CountWordingTests.swift` as it is.

## Commits
Two commits, one per part. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run `EPUBMetadataTests`, `EPUBMetadataWritebackTests`, `ReaderEPUBMetadataTests`, `MetadataReaderVersionTests`, `LegacyPDFParserTests`, `LibraryCloudCommandTests`, and `LegacyEPUBParserScenarioTests` (a user of `requireFile`), and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-fixturepaths-…`.

      BBS_AGENT=polish3-fixturepaths .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-fixturepaths -only-testing:TextMouthProductionTests/EPUBMetadataTests -only-testing:TextMouthProductionTests/EPUBMetadataWritebackTests -only-testing:TextMouthProductionTests/ReaderEPUBMetadataTests -only-testing:TextMouthProductionTests/MetadataReaderVersionTests -only-testing:TextMouthProductionTests/LegacyPDFParserTests -only-testing:TextMouthProductionTests/LibraryCloudCommandTests -only-testing:TextMouthProductionTests/LegacyEPUBParserScenarioTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-fixturepaths-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- App code, `TestData`, `CountWordingTests.swift`, the legacy scenario files in `TextMouthTests/` (another task's), and every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is. Change no test's assertions.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/fixturepaths` to `polish3-lead`, move task 24 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.
