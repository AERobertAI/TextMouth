# polish3-audioeditor: Apply Filter's first preset chosen as the sheet is made; a typed silence length read once

- Team `polish3`; lead `polish3-lead`; your task is number 19 on the team's list.
- Your slug is `polish3-audioeditor`. Your branch is `polish3/audioeditor`, made with `git checkout -b polish3/audioeditor team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-audioeditor --role "Filter sheet's first preset; silence length read once" --branch polish3/audioeditor --team polish3 --files TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift "TextMouth/ViewModels/AudioEditorModel+Commands.swift"
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-audioeditor 19 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two TODO items: "the Filter sheet's first-draw Picker warning (`AudioEditorFilterSheet.swift:23`)" and "`silenceLength` called twice (`AudioEditorModel+Commands.swift` 203 to 204)".

## 1. The Filter sheet's first preset (one commit)
`AudioEditorFilterSheet` (`TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift`) keeps the chosen preset in `@State private var presetID: UUID?` (lines 23 and 24). `init` (lines 28 to 35) leaves it nil, and only `.onAppear` (lines 101 to 105) picks the first preset, so the Filter pop-up draws once with no selection, and SwiftUI logs "Picker: the selection "nil" is invalid and does not have an associated tag".

Confirm it is still open first: `grep -n "presetID = presets.presets.first" TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift` shows the `.onAppear` line.

1. In `init`, after `_presets`, set `_presetID = State(initialValue: presets.presets.first?.id)`, from the `presets` the init was given (the one that becomes the `@StateObject`).
2. Remove the `.onAppear` block (lines 101 to 105). Keep `.onDisappear` exactly as it is.
3. Say in `presetID`'s doc comment that it starts at the first preset listed, so the pop-up has its choice from its first drawing; and in `init`'s doc comment, that the first preset starts chosen. With no presets it stays nil, and the sheet shows `AudioEditorWording.noPresets` and no pop-up, as now.

No new test: `AudioEditorWindowTests` already pins the pop-up's value as the first preset's name when the sheet is drawn (lines 162 to 165), and that VoiceOver starts on the pop-up (line 119). After your run, check the log for the warning: `grep -c "does not have an associated tag" <log>`. Report the count; it should be 0.

## 2. The typed silence length, read once (one commit)
In `AudioEditorModel.answer(_:with:)` (`TextMouth/ViewModels/AudioEditorModel+Commands.swift` lines 194 to 219), the `.insertSilence` case (lines 202 to 206) calls `silenceLength(typed:)` (lines 222 to 233) twice for one answer.

Confirm it is still open first: `grep -c "silenceLength(typed: text)" "TextMouth/ViewModels/AudioEditorModel+Commands.swift"` prints 2.

1. Call it once: `let length = silenceLength(typed: text)`, `problem = length.problem`, and `if let seconds = length.seconds { Task { await insertSilence(seconds) } }`. `silenceLength` gives seconds only when it finds no problem, and a problem only without seconds, so the `problem == nil` test is not needed beside `if let`.
2. Change nothing else in the function.

`AudioEditorEditingTests` covers it (`answer(.insertSilence, with:)` at lines 236 to 245): its too-short, too-long, and taken answers.

## Commits
Two commits, one per part. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run `AudioEditorWindowTests` and `AudioEditorEditingTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-audioeditor-…`.

      BBS_AGENT=polish3-audioeditor .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-audioeditor -only-testing:TextMouthProductionTests/AudioEditorWindowTests -only-testing:TextMouthProductionTests/AudioEditorEditingTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-audioeditor-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- Any test file: another task edits `AudioEditorWindowTests.swift`. Every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/audioeditor` to `polish3-lead`, move task 19 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.
