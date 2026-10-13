# polish3-testhelpers: #2037, two test helpers each kept once

- Team `polish3`; lead `polish3-lead`; your task is number 23 on the team's list.
- Your slug is `polish3-testhelpers`. Your branch is `polish3/testhelpers`, made with `git checkout -b polish3/testhelpers team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-testhelpers --role "#2037: two test helpers kept once" --branch polish3/testhelpers --team polish3 --files TextMouthProductionTests/AccessibilityTestSupport.swift TextMouthProductionTests/SpeechDirectChunkingTests.swift TextMouthProductionTests/CompletionGenerationTests.swift TextMouthProductionTests/SpeechRefusalReaderTests.swift TextMouthProductionTests/WhereAmIAnnouncementEndTests.swift TextMouthProductionTests/FullSummaryReaderTests.swift TextMouthProductionTests/MediaCommandPlaybackTests.swift TextMouthProductionTests/AudioEditorWindowTests.swift TextMouthProductionTests/RepeatedSymbolSettingsViewTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-testhelpers 23 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two TODO items: #2037 (`handleQueuedCallbacks` in six files) and "`control(labelled:in:)` twice".

## 1. #2037: `handleQueuedCallbacks` (one commit)
Six test classes keep a private copy of one helper, which returns once the main queue has run every block queued on it so far:
- `SpeechDirectChunkingTests.swift` lines 1610 to 1616 (message "The callbacks were never handled");
- `CompletionGenerationTests.swift` lines 908 to 914 (it waits with `eventually { handled }`);
- `SpeechRefusalReaderTests.swift` 282 to 288, `WhereAmIAnnouncementEndTests.swift` 244 to 250, `FullSummaryReaderTests.swift` 345 to 351, and `MediaCommandPlaybackTests.swift` 3230 to 3236 (all four with `waitUntil(timeout: 5)` and "The main queue never ran").

Confirm it is still open first: `grep -rln "private func handleQueuedCallbacks" TextMouthProductionTests` lists the six files.

1. Add one `handleQueuedCallbacks(file:line:)` to `TextMouthProductionTests/AccessibilityTestSupport.swift`, in its `extension XCTestCase` (from line 19), right after `waitUntil(timeout:_:)` (line 111), with the same signature, `waitUntil(timeout: 5) { handled }`, and the message "The main queue never ran", failing at the caller's `file` and `line`. Its doc comment says what it waits for and why: the services under test handle the synthesizer's and the player's callbacks on the main queue. Keep the isolation `waitUntil` has (read its lines 105 to 122 first).
2. Delete the six private copies, with their doc comments. The calls stay as they are.
3. Run each class: one changed its wait helper (`eventually`), so look at its result with care.

**Completion check:** `grep -rn "func handleQueuedCallbacks" TextMouthProductionTests` finds one line, in `AccessibilityTestSupport.swift`.

## 2. `control(labelled:in:)` (one commit)
Two classes keep a private copy of one lookup, the control labelled `label` among `[AccessibleControl]`, failing with every label found when there is none: `AudioEditorWindowTests.swift` lines 577 to 579 ("no control is labelled …") and `RepeatedSymbolSettingsViewTests.swift` lines 229 to 233 ("no control labelled …").

Confirm it is still open first: `grep -rn "private func control(labelled" TextMouthProductionTests` finds both.

1. Add one `control(labelled:in:)`, `throws`, to `AccessibilityTestSupport.swift`'s `extension XCTestCase`, beside `accessibleControls(in:)` (line 257), with a doc comment and the message "no control is labelled \(label): \(controls.map(\.label))".
2. Delete both private copies; their calls stay as they are.

**Completion check:** `grep -rn "func control(labelled" TextMouthProductionTests` finds one line, in `AccessibilityTestSupport.swift`.

## Commits
Two commits, one per part. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run the eight classes: `SpeechDirectChunkingTests`, `CompletionGenerationTests`, `SpeechRefusalReaderTests`, `WhereAmIAnnouncementEndTests`, `FullSummaryReaderTests`, `MediaCommandPlaybackTests`, `AudioEditorWindowTests`, and `RepeatedSymbolSettingsViewTests`, and nothing else. `MediaCommandPlaybackTests` is long: let it run.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-testhelpers-…`.

      BBS_AGENT=polish3-testhelpers .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-testhelpers -only-testing:TextMouthProductionTests/SpeechDirectChunkingTests -only-testing:TextMouthProductionTests/CompletionGenerationTests -only-testing:TextMouthProductionTests/SpeechRefusalReaderTests -only-testing:TextMouthProductionTests/WhereAmIAnnouncementEndTests -only-testing:TextMouthProductionTests/FullSummaryReaderTests -only-testing:TextMouthProductionTests/MediaCommandPlaybackTests -only-testing:TextMouthProductionTests/AudioEditorWindowTests -only-testing:TextMouthProductionTests/RepeatedSymbolSettingsViewTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-testhelpers-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- App code, and every test file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is. Change no test's assertions.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/testhelpers` to `polish3-lead`, move task 23 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.
