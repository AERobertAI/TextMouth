# polish3-shortcutkeys: the Edit menu's keys written once; the config fixture writes a shortcut's object form

- Team `polish3`; lead `polish3-lead`; your task is number 20 on the team's list.
- Your slug is `polish3-shortcutkeys`. Your branch is `polish3/shortcutkeys`, made with `git checkout -b polish3/shortcutkeys team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-shortcutkeys --role "Edit menu keys once; config fixture's object form" --branch polish3/shortcutkeys --team polish3 --files TextMouth/Models/KeyboardShortcut.swift TextMouth/Models/TextEditingKeys.swift TextMouthProductionTests/TextFieldEditingKeysTests.swift TextMouthProductionTests/ConfigTestSupport.swift TextMouthProductionTests/ConfigSyncTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-shortcutkeys 20 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two TODO items: "`TextEditingKeys.editMenuKeys`" (it repeats `KeyBinding.systemCommands`' Edit-menu entries) and "`everyFieldCustomized` lacking the object form".

## 1. The Edit menu's keys, written once (one commit)
`TextEditingKeys.editMenuKeys` (`TextMouth/Models/TextEditingKeys.swift` lines 67 to 75) spells out Select All, Copy, Paste, Cut, Undo, and Redo, which `KeyBinding.systemCommands` (`TextMouth/Models/KeyboardShortcut.swift` lines 606 to 630) spells again with their names.

Confirm it is still open first: `grep -c "KeyBinding(key:" TextMouth/Models/TextEditingKeys.swift` prints 6.

1. In `KeyboardShortcut.swift`'s `extension KeyBinding` (from line 606), add `static let editMenuCommands: [KeyBinding: String]` holding exactly those six, each with the name `systemCommands` gives it now: Undo (`z`, Command), Redo (`z`, Shift-Command), Cut, Copy, Paste, and Select All. Doc comment: the Edit menu's commands a text field edits with, each key with its command's name; a field keeps these keys from the shortcut manager (`TextEditingKeys.editMenuKeys`), and no shortcut may take them (`systemCommands`).
2. Build `systemCommands` from the other nine, as a literal of their own, merged with `editMenuCommands` (`.merging(editMenuCommands) { own, _ in own }`; no key is in both). Keep its doc comment, adding that it holds `editMenuCommands`. Paste and Match Style stays among the nine: it is no key a field keeps today, and this change keeps every key's behavior.
3. `TextEditingKeys.editMenuKeys` becomes `Set(KeyBinding.editMenuCommands.keys)`, its doc comment naming where the keys come from.

**Test**, in `TextMouthProductionTests/TextFieldEditingKeysTests.swift`, one test with a doc comment:
- `TextEditingKeys.editMenuKeys` equals the six bindings written out in the test;
- `KeyBinding.systemCommands.count` is 15, and each of `editMenuCommands` is in it with the same name (for example Shift-Command-Z is "Redo");
- Shift-Option-Command-V ("Paste and Match Style") is in `systemCommands` and not in `editMenuKeys`.

**Completion check:** `grep -c "KeyBinding(key:" TextMouth/Models/TextEditingKeys.swift` prints 0.

## 2. The config fixture's object form (one commit)
`ConfigService.AppConfig.everyFieldCustomized` (`TextMouthProductionTests/ConfigTestSupport.swift` lines 11 to 82) is the config every round-trip test of config.json uses. Its shortcuts (lines 69 to 76) are written only as lists and "default: " text, never as the object form TextMouth writes for an action working in a kind of window the user chose (`{"keys": [...], "worksIn": "Library windows"}`; `ShortcutListing`, `KeyboardShortcut.swift` 1176 to 1225). `ShortcutConfigFileTests` (lines 140 to 165) shows Where Am I? may work in Library windows.

Confirm it is still open first: `grep -n "scopes:" TextMouthProductionTests/ConfigTestSupport.swift` finds nothing.

1. Give the fixture's `ShortcutEdits` a scope: `ShortcutEdits([...the three edits as now...], scopes: [.whereAmI: .library])` (`ShortcutEdits.init(_:scopes:)`, `ShortcutEdits.swift` line 48). Reword the comment above it (lines 69 and 70): three actions edited, two written as lists of their keys and Where Am I?, which works in Library windows, as an object with its "worksIn"; every other as "default: " and its keys.
2. **Test** in `TextMouthProductionTests/ConfigSyncTests.swift`, with a doc comment: the fixture writes Where Am I? as `.object(keys: ["option+w"], worksIn: "Library windows")` (`KeyBinding.configText` writes modifiers then the key, joined by "+", `KeyboardShortcut.swift` 1041 to 1044; if the keys text differs, take what `configText` gives, and say so in your report), and the entry survives the file: `try ConfigService.decode(ConfigService.fileData(for: .everyFieldCustomized)).keyboardShortcuts["Where Am I?"]` equals the same object. Those two functions are used so at `ConfigWatcherTests.swift` line 425 and `ShortcutConfigFileTests.swift` line 145.
3. Then every round-trip test that uses the fixture carries the object form too. If one of them fails because Where Am I? now works only in Library windows, do not change that test's expectations: post a question to `polish3-lead` with the test's name and its failure, and wait for the answer.

## Commits
Two commits, one per part. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run `TextFieldEditingKeysTests`, `MenuKeyShortcutTests` (it pins the refusal of a system command's key), `ConfigSyncTests`, `ConfigWatcherTests`, and `ShortcutConfigFileTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-shortcutkeys-…`.

      BBS_AGENT=polish3-shortcutkeys .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-shortcutkeys -only-testing:TextMouthProductionTests/TextFieldEditingKeysTests -only-testing:TextMouthProductionTests/MenuKeyShortcutTests -only-testing:TextMouthProductionTests/ConfigSyncTests -only-testing:TextMouthProductionTests/ConfigWatcherTests -only-testing:TextMouthProductionTests/ShortcutConfigFileTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-shortcutkeys-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `ShortcutEdits.swift`, the other config tests' expectations, and every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/shortcutkeys` to `polish3-lead`, move task 20 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.
