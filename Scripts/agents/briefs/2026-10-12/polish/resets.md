# polish-resets: Reset to Defaults says what it did (Shortcuts and Sound Effects)

- Team polish; lead `polish-lead`. Your slug is `polish-resets`, and your branch is `polish/resets`, made with `git checkout -b polish/resets team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes this TODO item from "Still open after FR12's branch A": the Reset to Defaults alert "announces nothing after resetting". The item's other half, plainer alert wording, is not part of this task.

## What is wrong
The two Reset to Defaults buttons in the Settings window say nothing after resetting, so a VoiceOver user cannot tell whether they worked.
- **The Shortcuts tab** (`TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift`, about lines 43 to 58). The button opens the "Reset Keyboard Shortcuts?" alert. The alert's Reset calls `shortcutManager.resetToDefaults()` and does nothing more.
- **The Sound Effects tab** (`TextMouth/Views/Settings/SoundEffectsSettingsView.swift`, about lines 38 to 43). The button calls `soundEffectService.resetToDefaults()` and does nothing more. That call resets the sound assignments, the volume, and "sounds on" (`TextMouth/Services/SoundEffectService.swift`, about lines 204 to 208).

The audio filter presets' reset already speaks: "The filter presets are reset to the defaults." (`AudioFilterPresetsWording.resetAll` in `TextMouth/Views/Settings/AudioFilterPresetsView.swift`, about line 59). Follow its wording.

## Do
1. In `ShortcutsSettingsWording` (in the same file, from about line 400), add `static let resetDone = "The keyboard shortcuts are reset to the defaults."`, with a comment.
2. On `KeyboardShortcutsSettingsView`, add a static function that resets and then announces `resetDone`, and have the alert's Reset call it: `static func resetEveryShortcut(_ manager: KeyboardShortcutManager, announce: (String) -> Void = { VoiceOverAnnouncer.announceAfterSheetCloses($0, from: nil) })`.
   - It announces once the alert has closed (`VoiceOverAnnouncer.announceAfterSheetCloses`, in `TextMouth/Services/VoiceOverAnnouncer.swift`, about lines 77 to 97, from REV11 F6): VoiceOver hearing the alert close would cut the words off.
   - The `announce` parameter lets a test capture the words without waiting out the 0.6-second delay.
3. For the Sound Effects tab, add a small `enum SoundEffectsSettingsWording` to `SoundEffectsSettingsView.swift`. It holds:
   - the button's title, "Reset to Defaults", as today;
   - its VoiceOver label, "Reset all sound effects to defaults", as today;
   - `resetDone = "The sound effects are reset to the defaults."`.

   Add a static `resetEverySound(_ service: SoundEffectService, announce: (String) -> Void = { VoiceOverAnnouncer.announce($0) })`, and have the button call it. No alert closes here, so it announces at once.
4. Comment every function and constant: what VoiceOver hears, and why.

## Tests
- **The shortcuts.** Use `ShortcutManagerTests` (`TextMouthProductionTests/ShortcutManagerTests.swift`). Its `makeManager(_:)`, at about line 20, gives a manager on a sandboxed store, and `testResetToDefaultsGivesEveryActionBack`, at about lines 117 to 129, shows the shape.
  - Test that `resetEveryShortcut` resets the edits.
  - Test that it gives `announce` exactly `[ShortcutsSettingsWording.resetDone]`.
  - Pin the sentence's words.
- **The sound effects.** Build a `SoundEffectService` on a sandboxed store, the way `PreferenceStoreTests` or `HostedTestIsolationTests` (about lines 320 to 330) builds one.
  - Change an assignment and the volume, then call `resetEverySound` with a capturing `announce`.
  - Check that the defaults are back and that the words were given.
  - Pin the title and label constants too.
  - Put the test in whichever of those two classes already builds the service. Never use the user's real store, and no sound may play.

## Build and test
- Run only `ShortcutManagerTests`, `ShortcutsSettingsTabTests`, and the class that holds your sound test.
- Start each build in the background and check on it no more often than every 4 minutes.
- `-jobs 4` is required (the orchestrator's #2107).
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-resets-…`.

    BBS_AGENT=polish-resets .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-resets" -only-testing:TextMouthProductionTests/ShortcutManagerTests -only-testing:TextMouthProductionTests/ShortcutsSettingsTabTests -only-testing:TextMouthProductionTests/<SoundTestClass> > <scratchpad>/polish-resets-build-1.log 2>&1

## Do not touch
- `KeyboardShortcutManager` and `SoundEffectService`.
- The alert's title and message.
- Any `*.md` file.
