# Task brief: keysinfields — a focused text field keeps the keys it edits with (B03)

Slug `keysinfields`; branch `fix/text-field-editing-keys`. Read `common-evening.md` beside this file first.

## Why
B03 in TODO-2026-09-04.md (section "Feature requests and bugs (October 7)"), found by the FR12 study (`KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md`) from the code, no key pressed: `KeyboardShortcutManager.shouldHandle` (Services/KeyboardShortcutManager.swift) leaves only plain keys to a focused text field, so a shortcut with a modifier acts even while the user types. Command-Delete in the Library's search field, which a Mac user presses to delete to the start of the line, removes the selected books instead (asking first only when `confirmBeforeDelete` is on), and Command-A selects every book rather than the field's text. The user is a VoiceOver and braille user who edits text by keyboard all day; a key that edits text must never act on the library.

## Files you own
TextMouth/Services/KeyboardShortcutManager.swift (`shouldHandle` and whatever small helper it needs), a new TextMouth/Models/TextEditingKeys.swift (or a name like it) if the rule is a table, and the tests (KeyboardShortcut tests in TextMouthProductionTests; a new TextFieldEditingKeysTests.swift). `readinglistreader` and `importprogress` add actions to Models/KeyboardShortcut.swift and App/MenuCommands.swift now; leave those files alone. FR12 will later rework the manager; keep this change small and self-contained so it rebases easily.

## Items, one commit each, each with its tests
1. **Measure first.** Write tests, through the manager's own decision function with a stand-in for the first responder (no real key presses needed), that show today's behavior: Command-Delete and Command-A acted on while a text field edits. Say which actions are bound to which modified keys by default (`ShortcutAction.defaultBindings`) and which of them a text field also uses.
2. **The rule.** While a text field or text view is the first responder and editing (a search field included, and the field editor of an `NSTextField`), every key the text system edits with goes to the field: Delete and Forward Delete with any modifier, the arrow keys, Home, End, Page Up and Page Down with any modifier, Command-A, Command-C, Command-V, Command-X, Command-Z and Shift-Command-Z, and the Control-letter editing keys (Control-A, E, K, D, H, F, B, N, P, T, O, Y). Other Command shortcuts (Command-I's Book Info, say) still act, since a field has no use for them; say in a comment how you drew the line, and list every default binding the rule now leaves to a field. The menu bar's own key equivalents are not the manager's and stay as they are.
3. **Spoken outcome.** No new wording is needed when the field takes the key; check that nothing the manager announces fires for a key the field took.

## Verify or report as unverified
- Live VoiceOver typing in the search field and in the reader's search is unverified; say so. Name every text field and text view you found in the app's windows and whether the rule covers it.
