# polish3-settingswording: one wording type for a book's own settings

- Team `polish3`; lead `polish3-lead`; your task is number 22 on the team's list.
- Your slug is `polish3-settingswording`. Your branch is `polish3/settingswording`, made with `git checkout -b polish3/settingswording team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-settingswording --role "One wording type for a book's own settings" --branch polish3/settingswording --team polish3 --files TextMouth/Views/Reader/ReaderView.swift TextMouth/Views/Reader/PlaybackControlsView.swift "TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift" TextMouthProductionTests/PlaybackSettingsAuditTests.swift TextMouthProductionTests/A10AccessibilityTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-settingswording 22 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes the TODO's "two per-book settings wording types (`ReaderView.swift:1107`)".

## The problem
A book's own settings have two wording types:
- `BookSettingsSheetWording` (`TextMouth/Views/Reader/ReaderView.swift` lines 1100 to 1141): the sheet's and its toolbar button's names, and the audiobook's speed slider label;
- `BookVoiceSettingsWording` (`TextMouth/Views/Reader/PlaybackControlsView.swift`, its doc comment from about line 220, the enum at lines 231 to 243): the Save and Reset buttons' labels and hints, and what VoiceOver hears after a reset.

And the sheet's audiobook Reset button keeps its words in the view: `"Reset to Normal Speed"`, `"Reset to normal audio speed"`, and its hint, built at `ReaderView.swift` lines 1000 to 1007, beside the literals `"Save to Global Settings"` (line 990) and `"Reset to Global Settings"` (line 1000). Nothing pins those words.

Confirm it is still open first: `grep -rn -E "^enum (BookSettingsSheetWording|BookVoiceSettingsWording)" TextMouth` finds both.

## What to build (one commit)
1. **One type, `BookSettingsWording`,** where `BookSettingsSheetWording` is now in `ReaderView.swift`. It holds every member of both types, with the same names and the same words, and one doc comment that keeps what both say (TODO A10, A11, and the October 10 request that an audiobook's sheet be named "Audio Settings"). Delete `BookVoiceSettingsWording` and its doc comment from `PlaybackControlsView.swift`.
2. **The sheet's buttons' words** join it:
   - `saveButtonTitle`: `"Save to Global Settings"`;
   - `resetButtonTitle(isAudioBook:)`: `"Reset to Normal Speed"`, or `"Reset to Global Settings"`;
   - `resetLabel(isAudioBook:)`: `"Reset to normal audio speed"`, or `resetToDefaultsLabel`;
   - `resetHint(isAudioBook:)`: `"Resets this book to "` and `AudioSpeed.spokenLabel(for: AudioSpeed.normal)`, as line 1006 builds it now, or `resetToDefaultsHint`.

   The Save and Reset buttons at lines 990 to 1008 use them. Each member gets a doc comment.
3. **Every use renamed:** `ReaderView.swift` (lines 144, 146, 854, 995, 996, 1003, 1007, 1018, 1048, 1050), `PlaybackControlsView.swift` (110, 114), `ReaderViewModel+VoiceAndSpeed.swift` (169), `PlaybackSettingsAuditTests.swift` (354, 375 to 387), and `A10AccessibilityTests.swift` (391 to 402).
4. Nothing the user sees or hears changes.

## Tests
In `TextMouthProductionTests/PlaybackSettingsAuditTests.swift`, beside the sheet's wording test (lines 370 to 390), pin the new members: both values of `resetButtonTitle` and `resetLabel`; `saveButtonTitle`; and `resetHint(isAudioBook: true)` as the literal sentence (run it once to read what `AudioSpeed.spokenLabel(for:)` gives for normal speed), and `resetHint(isAudioBook: false) == BookSettingsWording.resetToDefaultsHint`.

**Completion check:** `grep -rn -E "BookSettingsSheetWording|BookVoiceSettingsWording" TextMouth TextMouthProductionTests TextMouthTests` finds nothing, and `grep -n -E '"(Reset to Normal Speed|Reset to normal audio speed|Save to Global Settings|Reset to Global Settings)"' TextMouth/Views/Reader/ReaderView.swift` finds only the wording type's lines.

## Commits
One commit. Its message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run `PlaybackSettingsAuditTests` and `A10AccessibilityTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-settingswording-…`.

      BBS_AGENT=polish3-settingswording .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-settingswording -only-testing:TextMouthProductionTests/PlaybackSettingsAuditTests -only-testing:TextMouthProductionTests/A10AccessibilityTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-settingswording-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `ReaderViewModel.swift` (another team's), any other part of `ReaderView.swift`, and every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/settingswording` to `polish3-lead`, move task 22 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.
