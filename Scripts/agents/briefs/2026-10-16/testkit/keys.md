# testkit/keys: keyboard reachability, checked by machine

Slug `testkit-keys`. Branch `testkit/keys`, made from `team/testkit`. You build; at most two builders run at once. Read `teams-common.md`'s worker's part first.

## Why

The acceptance matrix's "Keyboard only" row (TODO-2026-09-04.md line 3639) says: "every primary action, context action, slider, reorder operation, and sheet is reachable; text entry does not trigger unintended playback shortcuts." The user is blind and works by keyboard alone: a command with no key and no menu item is a command he cannot reach. A person has to try each by hand today. The part a machine can check is which actions have a way in, and that no two defaults collide. This task adds that, only where the existing tests do not already.

## Ground truth

- `TextMouth/Models/KeyboardShortcut.swift` (1691 lines; read by range): `ShortcutAction` (:4-165, about 100 cases, each raw value is its name; `title`), `ShortcutScope` (:360-480: app, library, reader, audioEditor, recording), `defaultScopesOfTheirOwn` (:232), `keyEquivalentActions` (:516, the actions that are menu key equivalents), `KeyBinding.systemCommands`/`editMenuCommands`/`dialogKeys` (:609-710), `ShortcutAction.defaultBindings` (:1453, `[ShortcutAction: [KeyBinding]]`).
- `TextMouth/Models/ShortcutEdits.swift`: how conflicts between bindings are detected today (reuse its logic for the collision test; do not write a second rule).
- `TextMouth/App/MenuCommands.swift` (863 lines): the menu. Most commands are `Button(ShortcutAction.xxx.title)` or `Button("Play / Pause")` (a raw value spelled out); a few take their title from `FeedWording`. Read it in four chunks (`:90-290`, `:286-440`, `:441-560`, `:552-863`).
- Existing tests that already say much: `ShortcutListingTests`, `MenuKeyShortcutTests`, `ShortcutManagerTests`, `ShortcutsSettingsTabTests`, `ShortcutEditsTests`, `WindowScopeShortcutTests`, `TextFieldEditingKeysTests` (text entry does not trigger shortcuts), `DoublePressBindingTests`, `AudioEditorShortcutTests`, `RecordingWindowTests`. **Read their `func test` names first** (`grep -n "func test" ...`), and write only what is missing. List in your report what each existing class already covers, in one line each.
- `SourceScanTestSupport.swift`: `AppSourceFile.all()` reads the app's Swift sources from a test (used by `LogContentPolicyTests`); use it to read `MenuCommands.swift`.

## What to add (a new file `TextMouthProductionTests/KeyboardReachabilityTests.swift`; run `xcodegen`)

1. **Every action has a way in.** For every `ShortcutAction`, either it has at least one default binding, or it is a key-equivalent/menu action with a menu item, or it is on an explicit list `unboundActions: [ShortcutAction: String]` (the String is the reason, a full sentence: `"Reached from the library toolbar's Folder or Feed Settings button; a key would shadow Edit > Select All."`). The list is a plain static dictionary at the top of the test class, with a comment saying how to extend it: **team `feedopts` will add one unbound action ("Folder or Feed Settings") tonight, and any later action must either get a default binding or be added to the list with a reason**. The failure message for an action that is none of these says exactly that, naming the action. A listed action that now HAS a binding fails (the list must not rot): `"X is listed as unbound but now has a binding; remove it from the list."`
2. **No two defaults collide where both apply.** Use `ShortcutScope` and the existing conflict logic: two actions may share a key only when their scopes can never both be active in one window (e.g. library and audioEditor). The failure names both actions, the key in words (`KeyBinding.accessibleDisplayString`), and their scopes.
3. **Every menu command maps to an action, or is listed.** Scan `MenuCommands.swift` with `AppSourceFile` for `Button(` titles. Each is either `ShortcutAction.<case>.title`, a string literal equal to some action's raw value, or on an explicit list `standaloneMenuCommands: [String: String]` (title to reason, e.g. a FeedWording command). Spell out the extraction rules in a comment, and add a sanity check that the scan finds more than 30 buttons (so a reformatted file never lets it pass having checked nothing).
4. **Every binding can be spoken.** For every default binding of every action, `KeyBinding.accessibleDisplayString` is non-empty, contains no raw private-use or control character (`KeyBinding.isUnnamedPrivateUseCharacter`), and no two different bindings of one action read the same. (Skip this if `ShortcutListingTests` already pins exactly that: say so.)
5. **No default is refused by the shortcut rules it is subject to**: `ShortcutRefusal` (:567-): no default binding of an action in `keyEquivalentActions` is a `systemCommands` key, and none is a bare printable key with no Command or Control unless the scope allows it (read `ShortcutRefusal` and the listing tests to see what is already pinned; add only the gap).

If a check finds a real problem (an action nobody can reach), do not fix the app: add it to the unbound list ONLY if it is deliberate; otherwise post a finding (`bbs post testkit-keys --tag finding --file TextMouth/Models/KeyboardShortcut.swift --topic "..."`) and write the test with the action on the list under the reason `"UNDER QUESTION: ..."` so the suite stays green and the finding is not lost.

## Tests to run

`KeyboardReachabilityTests`, plus `ShortcutListingTests`, `MenuKeyShortcutTests`, and `ShortcutsSettingsTabTests` once at the end.

## Do not

Edit the app or any existing test. Bind a new key. Press keys in a window or post key events (no UI): these are model and source checks only. Let a test trap: build the scan with `XCTUnwrap` and guards, no `[0]` on an unchecked array.

## Commits

1. Checks 1, 2, and 5 (the actions).
2. Checks 3 and 4 (the menu and the speech of keys).

## Report (at most 15 lines)

Branch; commits; exact result lines; what each existing shortcut test class already covered; the final unbound list with its reasons; the findings posted; the sentence for the docs ("how to add an action").
