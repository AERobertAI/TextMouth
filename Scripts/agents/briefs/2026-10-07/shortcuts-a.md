# Task brief: shortcutsA — FR12's branch A, a record of the shortcuts the user edited

Slug `shortcutsA`; branch `feature/shortcut-edit-record`. Read `common-evening.md` beside this file first, but use main as it is now: main is at 52ce9dd8 or later, and its suite counts **4857 tests, 54 skipped, 0 failures**, with no Swift warnings.

## The design and the user's answers
The design is `KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md` in the repository root: read sections 1, 4, 5, 6, and 8 whole, and build exactly its "Branch A: `feature/shortcut-edit-record`". The user answered its ten questions yes on October 7 evening (`humanQuestions/2026-10-07-evening.md` in the main checkout, which your worktree does not have; FR12's entry in TODO-2026-09-04.md quotes the answers). The ones that bind this branch:
- (5) An edited action set back to its default keys stays the user's until Reset to Default.
- (6) At the migration, an action whose keys equal its default, today's or an earlier one (`ShortcutAction.formerDefaultBindings`), counts as never edited. For this user that leaves Release Media Controls (Shift-R) as the only edit, and gives Next Bookmark its current default, which ends B04's Shift-Command-B clash; the user chose to wait for this branch rather than change config.json by hand.
- (10) In config.json an unedited action reads `"default: w"` (text naming the default it follows) and an edited one a list such as `["shift+r"]`; writing a list makes an action the user's, writing "default" gives it back.
- Coming later, not in this branch: double presses (branch B), the full-summary actions (C), the fixed menu keys made editable (D), and shortcuts scoped to a kind of window (E, the user's request: "new from text should only work in Library view and sleep timer only in reader view, maybe view specific shortcuts with a field should be made possible"). Keep the record's per-action entry and the config.json forms easy to extend with a scope field later, and say how E would add one.

## This user's data comes first
This is the one branch of FR12 that could lose the user's shortcuts. The old preference (`customKeyboardBindings`) is read once for the migration and never written again; the migration is tested on maps shaped like this user's (72 actions, two of which differ from today's defaults: Release Media Controls on Shift-R, the user's own; Next Bookmark on Shift-Command-B, a default until March 24). Never read or write the live `~/.TextMouth/config.json` or the real preferences from a test; build fixtures shaped like them.

## Files you own
TextMouth/Models/KeyboardShortcut.swift, a new TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/KeyboardShortcutManager.swift (the bindings, their storage, and the conflict rule; leave `shouldHandle` and `TextEditingKeys` as B03 left them), TextMouth/Services/ConfigService.swift and TextMouth/ViewModels/SettingsViewModel.swift (only the `keyboardShortcuts` field, its policy, and its mirror), TextMouth/Models/SettingsPolicy.swift (only `keyboardShortcuts`), TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, and the tests the design names. No other agent edits these files now.

## Items, one commit each, each with its tests
Follow the design's branch A list: `ShortcutEdits` (the record, lenient decoding, a fixed order, `effectiveBindings(defaults:)`); the manager's bindings derived from the record, every change through it, `resetToDefault(_:)` and `resetToDefaults()`, one conflict rule; the migration (section 4.2) with `formerDefaultBindings`; config.json's two forms with the conflict rule of section 5.2 and its log line, names matched ignoring letter case, `Portability.mirrored` pairing the new key with the field; and the Shortcuts tab: each row's label in words (finding: symbols reach a braille display as signs), "Edited" on an edited row, Reset to Default on each edited row (a button and a VoiceOver action), and the recording announcement naming a key "Taken from …" another action. The design lists the tests; add the existing tests it names that change.

## Verify or report as unverified
- Live VoiceOver and braille in the Shortcuts tab are unverified; say so.
- Say exactly what this user's shortcuts become after the migration, action by action for the two that differ, and that every other action follows today's defaults.
