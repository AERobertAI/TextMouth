# polish4-homes: three helpers moved to neutral homes, with no change of behavior

- Team `polish4`; lead `polish4-lead`; your task is number 38 on the team's list.
- Your slug is `polish4-homes`. Your branch is `polish4/homes`, made with `git checkout -b polish4/homes team/polish4`. Your worktree may start on an old commit, so branch from `team/polish4` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish4-homes --role "Move FeedReadOnlyText, SilentKeyEquivalent, and showLogs to neutral homes" --branch polish4/homes --team polish4 --files TextMouth/Views/Feeds/FeedInfoSheet.swift TextMouth/Views/Reader/SpeechRefusalReportSheet.swift TextMouth/Views/Settings/LogsSettingsSection.swift TextMouthProductionTests/LogsSettingsSectionTests.swift TextMouth/Views/ReadOnlyTextArea.swift TextMouth/Views/SilentKeyEquivalent.swift TextMouth/Views/LogsInFinder.swift TextMouth.xcodeproj/project.pbxproj
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish4-homes 38 working

- This brief gives you what you need. Read only the line ranges it names, once each.

## Why
The second polish team's verifier found three helpers living in the wrong file (`Scripts/agents/briefs/2026-10-12/polish2/candidates.md`, entry L3113). `FeedReadOnlyText` and `SilentKeyEquivalent` live in `FeedInfoSheet.swift`, but the reader's speech refusal report and the feed item's Book Info sheet use them too. `showLogs(for:opening:)` is a static of a Settings view, `LogsSettingsSection`, but the reader's refusal sheet calls it. The fix: move the two views to neutral files, the first under a neutral name, and put `showLogs` where both its callers can reach it without naming a Settings view.

## The rules of a move
- **The code moves as it is.** Keep every line of each declaration: its body, its doc comments, `@MainActor`, the parameters and their defaults. Change only:
  - the names this brief names;
  - a doc comment's sentence this brief names;
  - a missing one-line doc comment on a function, which you add (the user's rule: every function has one).
- **No behavior changes:** no wording anyone hears, no accessibility label, no key, no timing.
- **One commit per move**, in the order below. Each commit leaves the app building: its completion check finds nothing before you commit.
- **A new file** needs `/opt/homebrew/bin/xcodegen generate` (`project.yml` takes every file under `TextMouth/`), and the regenerated `TextMouth.xcodeproj/project.pbxproj` goes in the same commit. Check `git diff --stat TextMouth.xcodeproj/project.pbxproj` first: it should add only a few lines for the one new file. If it changes much more, stop and tell your lead.
- **A new file starts with the imports it needs.** Its types take no access modifiers: the app has one module, and the moved types have none today.

## The three moves

### 1. `FeedReadOnlyText` becomes `ReadOnlyTextArea`, in `TextMouth/Views/ReadOnlyTextArea.swift`
- **Today:** `TextMouth/Views/Feeds/FeedInfoSheet.swift` lines 425-474. That is the line `// MARK: - Text Read With VoiceOver's Text Navigation`, its doc comment (lines 427-431), the struct (lines 432-473), and the blank line after it.
- **The new file:** `import AppKit` and `import SwiftUI`, then the doc comment and the struct, renamed `ReadOnlyTextArea`. Leave out the `MARK` line, since the file holds one type. Add one sentence to the doc comment naming who uses it: Feed Info's description, Show Description…, and the reader's speech refusal report.
- **Callers to rename:**
  - `FeedInfoSheet.swift` lines 312 and 582;
  - `TextMouth/Views/Reader/SpeechRefusalReportSheet.swift` line 53.
- **Completion check:** `grep -rn 'FeedReadOnlyText' TextMouth TextMouthProductionTests TextMouthTests` finds nothing.

### 2. `SilentKeyEquivalent` and `SilentKeyEquivalentView`, in `TextMouth/Views/SilentKeyEquivalent.swift`
- **Today:** `FeedInfoSheet.swift` lines 475-527 on the branch's starting commit; after move 1 they sit 50 lines higher. That is the line `// MARK: - A Key Equivalent Without a Button`, the struct with its doc comment (lines 477-506), the view class with its doc comment (lines 508-526), and the blank line after it.
- **The new file:** `import AppKit` and `import SwiftUI`, then both types, with their names unchanged and no `MARK` line.
- **The struct's doc comment:** it names one user, "so Show Description's Close, whose shortcut is Return, answers Escape through this". Widen that sentence to name the sheets whose Close answers Escape through it:
  - Show Description…;
  - the feed item's Book Info sheet (`TextMouth/Views/Library/FeedItemBookInfoSheet.swift` line 89);
  - the speech refusal report (`SpeechRefusalReportSheet.swift` line 85).
- **Callers keep their code:**
  - `FeedInfoSheet.swift`'s Show Description… (line 602 today);
  - `FeedItemBookInfoSheet.swift` line 89;
  - `SpeechRefusalReportSheet.swift` line 85;
  - the tests `SpeechRefusalSheetTests.swift` line 60 and `FeedUICommandsTests.swift` line 658, which find `SilentKeyEquivalentView` by its type.
- **Completion check:** `grep -n -E 'struct SilentKeyEquivalent|class SilentKeyEquivalentView|struct ReadOnlyTextArea' TextMouth/Views/Feeds/FeedInfoSheet.swift` finds nothing, and `grep -rn -E 'struct SilentKeyEquivalent\b|class SilentKeyEquivalentView' TextMouth` finds only the new file.

### 3. `LogsSettingsSection.showLogs(for:opening:)` becomes `LogsInFinder.show(for:opening:)`, in `TextMouth/Views/LogsInFinder.swift`
- **Today:** `TextMouth/Views/Settings/LogsSettingsSection.swift` lines 130-146: the blank line before it, its doc comment (lines 131-135), `@MainActor`, and the function (lines 137-146).
- **The new file:** `import AppKit`, then `enum LogsInFinder`, with a doc comment such as "Show Logs in Finder, for each place that offers it: Storage settings' Logs group and the reader's speech refusal report." The function inside keeps its doc comment, `@MainActor`, `static`, parameters, default, and body; only its name changes, from `showLogs` to `show`.
- **The wording stays:** the function still says its failure with `LogsSettingsWording.showFailure(folder:)`, so the words stay defined once, in `LogsSettingsSection.swift`.
- **Callers to change:**
  - `LogsSettingsSection.swift` line 108: `Self.showLogs(for:)` becomes `LogsInFinder.show(for:)`.
  - `SpeechRefusalReportSheet.swift` line 128. Reword its comment on lines 126-127 from "Storage settings' own Show Logs in Finder, which makes this Mac's folder first when it is missing." to "The same Show Logs in Finder as Storage settings', which makes this Mac's folder first when it is missing."
  - `TextMouthProductionTests/LogsSettingsSectionTests.swift` lines 151, 152 and 169. Change the call only, `LogsSettingsSection.showLogs(for:` to `LogsInFinder.show(for:`, keeping its trailing closure. The tests' names, assertions, messages, and MARK stay. These are the only existing-test edits this task allows.
- **Completion check:** `grep -rn -E 'showLogs|LogsSettingsSection\.show' TextMouth TextMouthProductionTests TextMouthTests` finds nothing.

## Build and test
- Build and test twice:
  - after move 1, to prove the procedure (new file, `xcodegen`, rename);
  - after move 3.

  If a build fails, fix it before you go on, in the commit where the cause lies. Amend it if it is your last commit; otherwise post the problem to your lead and wait.
- Each time, run `LogsSettingsSectionTests`, `SpeechRefusalSheetTests`, `FeedUICommandsTests`, and `FeedItemUIBookInfoTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish4-homes-…`. Number the logs `-build-1.log`, `-build-2.log`, and so on.

      BBS_AGENT=polish4-homes .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish4-homes -only-testing:TextMouthProductionTests/LogsSettingsSectionTests -only-testing:TextMouthProductionTests/SpeechRefusalSheetTests -only-testing:TextMouthProductionTests/FeedUICommandsTests -only-testing:TextMouthProductionTests/FeedItemUIBookInfoTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish4-homes-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. Your change must add no Swift warning.
- A failing existing test means stop and ask, as "The worker's part" says.

## Do not touch
- `FeedItemBookInfoSheet.swift`: its code keeps working unchanged.
- Every other app file and test file, and `project.yml`.
- The t6e team's files: `ReaderViewModel*.swift`, `PlaceRelocator`, `PlaceSnapshots`, `TextAnchor*`, `Book.swift`, `MarkdownCacheService`, `LibraryPersistenceService`, and the Edit Text session files.
- Any `*.md` file.

## Finish
As "The worker's part" says:
- post `done: polish4/homes` to `polish4-lead`;
- move task 38 to `review`;
- remove your build folder, unregistering its app first;
- release your claims;
- reply with your report of at most 15 lines.
