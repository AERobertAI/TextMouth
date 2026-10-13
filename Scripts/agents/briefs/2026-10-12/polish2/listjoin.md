# polish2-listjoin: one list joiner, "a, b, and c", for its four copies

- Team `polish2`; lead `polish2-lead`; your task is number 14 on the team's list.
- Your slug is `polish2-listjoin`. Your branch is `polish2/listjoin`, made with `git checkout -b polish2/listjoin team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-listjoin --role "One list joiner for its four copies" --branch polish2/listjoin --files TextMouth/Models/CountWording.swift TextMouth/Models/LibraryCloudWording.swift TextMouth/Models/AudioFilterChain.swift TextMouth/Models/ReadingStatsTile.swift TextMouth/Parsers/PDFExtractionDiagnostics.swift TextMouth/ViewModels/LibraryViewModel+Cloud.swift TextMouth/ViewModels/LibraryViewModel+BookOperations.swift TextMouth/Models/RemovalWording.swift TextMouthProductionTests/CountWordingTests.swift --team polish2
      bbs task move polish2-listjoin 14 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two TODO items: "three list-joining helpers do one job (`LibraryCloudWording.list`, `AudioFilterChain.list`, `ReadingStatsTile.spokenList`)" (line 3123) and "`PDFExtractionDiagnostics.listed(_:)` and `AudioFilterChain.list(_:)` are two private copies of one list-joiner" (line 3128).

## What is wrong
Four functions join words as a sentence lists them ("A", "A and B", "A, B, and C"), each with the same body:
- `LibraryCloudWording.list(_:)`, internal (`TextMouth/Models/LibraryCloudWording.swift` lines 239 to 247), which other files already borrow;
- `AudioFilterChain.list(_:)`, private (`TextMouth/Models/AudioFilterChain.swift` lines 198 to 206), which alone says "none" for an empty list;
- `ReadingStatsTile.spokenList(_:)`, private (`TextMouth/Models/ReadingStatsTile.swift` lines 105 to 113);
- `PDFExtractionDiagnostics.listed(_:)`, private (`TextMouth/Parsers/PDFExtractionDiagnostics.swift` lines 204 to 212).

## Do
1. **One joiner.** Add `static func list(_ items: [String]) -> String` to `CountWording` (`TextMouth/Models/CountWording.swift`, `enum CountWording` from line 10), in a `// MARK: - Lists` section at the end of the enum. Its body is the shared one. Its doc comment: `items` joined as a sentence lists them, "A", "A and B", "A, B, and C", the same in what TextMouth shows and what VoiceOver speaks; empty for no items, which each caller words for itself.
2. **Its callers.**
   - Delete `LibraryCloudWording.list(_:)`. Its callers call `CountWording.list` instead: `LibraryCloudWording.swift` line 170; `LibraryViewModel+Cloud.swift` lines 580, 597, 767, and 898; `LibraryViewModel+BookOperations.swift` line 1159; and `RemovalWording.swift` lines 389 and 628. Run `grep -rn "LibraryCloudWording.list(" TextMouth TextMouthProductionTests` once afterward: nothing may be left.
   - Delete `ReadingStatsTile.spokenList(_:)`; line 102 calls `CountWording.list(parts)`.
   - Delete `PDFExtractionDiagnostics.listed(_:)`; line 171 calls `CountWording.list(parts)`.
   - `AudioFilterChain.list(_:)` keeps its name and its "none", which is the filter messages' own word, and joins through the one joiner: `items.isEmpty ? "none" : CountWording.list(items)`. Update its doc comment to say so.
3. **No wording changes.** Every message reads exactly as before.
4. **Commits:** one for the joiner with its test and the first caller moved (`LibraryCloudWording`'s callers), one for the other three. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Tests
- In `TextMouthProductionTests/CountWordingTests.swift`, one test of `CountWording.list`: no items gives "", one gives "A", two give "A and B", three give "A, B, and C", and four give "A, B, C, and D".
- The callers' existing tests pin their wording: run the classes below unchanged.

## Build and test
- Run `CountWordingTests`, `AudioFilterChainTests`, `ReadingStatsViewTests`, `BookExportServiceTests`, and `LogContentPolicyTests`.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-listjoin-…`.

      BBS_AGENT=polish2-listjoin .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-listjoin" -only-testing:TextMouthProductionTests/CountWordingTests -only-testing:TextMouthProductionTests/AudioFilterChainTests -only-testing:TextMouthProductionTests/ReadingStatsViewTests -only-testing:TextMouthProductionTests/BookExportServiceTests -only-testing:TextMouthProductionTests/LogContentPolicyTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-listjoin-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `CountWording.listItems(books:episodes:articles:feeds:)` and the other `CountWording` functions: they count, and stay as they are.
- `KeyboardShortcut.swift`'s `.list([String])` case, which is a different thing with the same word.
- `TextMouth/Models/Book.swift` and `TextMouth.xcodeproj/project.pbxproj`, which another team claims; add no new file.
- Any other file, and any `*.md` file.
