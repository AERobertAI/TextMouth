# polish-smallfixes: Two one-line fixes (#1551, and pitch in the voice reset's announcement)

- Team polish; lead `polish-lead`. Your slug is `polish-smallfixes`, and your branch is `polish/smallfixes`, made with `git checkout -b polish/smallfixes team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- Make one commit for each fix.

## A. #1551: `TextEditingKeys` compares the stroke
This closes #1551, from "Still open after the double-press merge".

### What is wrong
`TextEditingKeys.contains(_:)` is in `TextMouth/Models/TextEditingKeys.swift`, about lines 84 to 89. It asks `editMenuKeys.contains(binding)`, which compares the whole binding. So a double press of Command-A (`isDoublePress`), or a key spelled in upper case, would not count as one of the Edit menu's keys. The other two checks in the same function go by `binding.key` alone.

### Do
1. Compare `binding.stroke` instead. `KeyBinding.stroke` (`TextMouth/Models/KeyboardShortcut.swift`, about lines 716 to 730) is the binding as one press, with a one-character key in lower case.
2. Update the function's doc comment: a double press belongs to a field when its stroke does.

Today's callers pass one press, so nothing changes for them; the rule is just stated once.
- `keyEquivalentRefusal` (about lines 547 to 551) refuses a double press first.
- `KeyboardShortcutManager.shouldHandle(binding:whenTextInputIsFocused:)` (about lines 680 to 685) is asked with the stroke.

### Test
Use `TextFieldEditingKeysTests`; its Edit-menu test is at about lines 89 to 107. `KeyBinding` has an `isDoublePress` field. Test that:
- a double Command-A counts as a field's key;
- a double Shift-Command-Z counts as a field's key;
- Command with "A" in upper case counts too;
- a double Command-B does not.

## B. The voice reset's announcement names pitch (an A10 follow-up)
This closes the item from "Still open after the A10 fixes merge": "'Using global voice and speed settings' leaves out pitch".

### What is wrong
The voice sheet's Reset to Global Settings clears the book's voice, speed, and pitch (`ReaderViewModel.resetToGlobalSettings()`, in `TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift`, about lines 146 to 170). Its button names all three (`BookVoiceSettingsWording.resetToDefaultsLabel`, in `TextMouth/Views/Reader/PlaybackControlsView.swift`, about lines 222 to 240). But for a text book, the announcement says "Using global voice and speed settings" (about line 169), leaving out pitch.

### Do
1. Add `static let resetDone = "Using global voice, speed, and pitch settings"` to `BookVoiceSettingsWording`, with a comment.
2. Announce it in `resetToGlobalSettings()`.
3. Leave the audiobook's "Audio speed reset to …" as it is.

### Test
- Pin the constant beside the existing tests of `BookVoiceSettingsWording`. Grep `TextMouthProductionTests` for it; `A10AccessibilityTests` uses it.
- If a test class already builds a text-book reader and captures its announcements, test that the reset says the sentence. To find one, grep `TextMouthProductionTests` for `resetToGlobalSettings` and for announcement captures.
- Do not build a new reader fixture for this.

## Build and test
- Run only `TextFieldEditingKeysTests`, `ShortcutManagerTests`, `MenuKeyShortcutTests`, and `A10AccessibilityTests`, plus the class you test B in, if it is another.
- Start each build in the background and check on it no more often than every 4 minutes.
- `-jobs 4` is required (the orchestrator's #2107).
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-smallfixes-…`.

    BBS_AGENT=polish-smallfixes .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-smallfixes" -only-testing:TextMouthProductionTests/TextFieldEditingKeysTests -only-testing:TextMouthProductionTests/ShortcutManagerTests -only-testing:TextMouthProductionTests/MenuKeyShortcutTests -only-testing:TextMouthProductionTests/A10AccessibilityTests > <scratchpad>/polish-smallfixes-build-1.log 2>&1

## Do not touch
- `KeyboardShortcut.swift` and `KeyboardShortcutManager.swift`. Read them only.
- The audiobook branch of `resetToGlobalSettings()`.
- Any `*.md` file.
