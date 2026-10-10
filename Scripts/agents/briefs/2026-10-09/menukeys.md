# Task brief: menukeys — FR12's branches D and E, editable menu keys and shortcuts scoped to a kind of window

Slug `menukeys`; branch `feature/menu-and-window-shortcuts`. Read `common.md` beside this file first. Main has moved well past the common brief: FR12's branches A (094dd885), B, double presses (ed23f19c), and C, the full summaries (3cf2c820), are merged, with FR11's branch A1 (de0839c5) and the Now Playing follow-ups (2f74c130). Use the suite count of main as you find it (`git log` and the TODO's latest "After the … merge" sentence) as your baseline.

## The design and the user's answers
`KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md`: sections 1.6 (the menus), 5.2 (a key on two actions of one scope), 5.4 (the fixed menu shortcuts), 6, and 8's "Branch D". Read the shortcutsA, doublepress, and fullsummary agents' notes in `AGENT-NOTES-2026-10-04.md` first; shortcutsA wrote how branch E would add a scope ("a record entry would become an object of keys and a scope, read in both forms; config.json would gain a third form, {list, scope}; one owner per key would hold within each kind of window").

The user's answers (FR12's entry in TODO-2026-09-04.md quotes them):
- Question 7, yes: the fixed menu keys become editable: Open Book… (Command-O), New from Text… (Shift-Command-T), New Recording… (Option-Command-N), Import DAISY Folder… (Shift-Command-O), Add Feed… (Shift-Command-F), Copy Reading Position (Shift-Command-P), Search in Book (Command-F), and the recording window's Record (Command-R), Pause or Resume (Command-P), and Stop (Command-period).
- Branch E, from the Shift-Command-T question (#1451): "I feel like new from text should only work in Library view and sleep timer only in reader view, maybe view specific shortcuts with a field should be made possible".

## Part one, branch D: the fixed menu keys made editable (commits first)
1. Each fixed menu key becomes a `ShortcutAction` in a group named as its menu is, whose menu item reads its key from the manager (a SwiftUI `Commands` observing it, as `LibraryCommands` observes `RemovalPreferencesModel`), so the menus show the key in force and VoiceOver reads it there. Each is a single press with Command or Control: a key equivalent must work in a text field and with no window open, and no menu takes a double press; the recorder and config.json refuse anything else for these actions, with a spoken reason.
2. The manager never consumes these keys itself: the menu item acts on them, as today. Every other action's keys still go through the dispatcher.
3. The conflict rule (section 5.2) covers these actions too. Until part two scopes them, Show Sleep Timer keeps Shift-Command-T as today, and New from Text's menu item shows no key rather than one that does something else; say so in the tab.
4. The recorder refuses keys that would take a system command (Quit, Close, Settings, Hide, Minimize, and the Edit menu's keys) for any action, saying why (design finding 10). Escape stays the recorder's cancel.
5. The user's record and config.json: the new actions appear as "default: command+o" and so on; nothing the user has edited changes. A test on a fixture shaped like the user's record (Release Media Controls on Shift-R, everything else default) pins it.

## Part two, branch E: shortcuts scoped to a kind of window
6. Each action gets a scope: every window (today's reach for the app's actions), Library windows, reader windows, the audio editor (today's editor actions), or the recording window (its three). Defaults keep today's reach for every action except the two the user named: New from Text works in Library windows and Show Sleep Timer in reader windows, so Shift-Command-T is both, each in its own kind of window (ends #1451). A menu item whose action is scoped to another kind of window does nothing there and lets the key reach the window's own action.
7. The Shortcuts tab gets a "Works in" pop-up button on each action's row (VoiceOver: "Works in, Library windows, pop-up button"), changing it makes the action edited, and Reset to Default gives back its default scope too. One key belongs to at most one action wherever their scopes overlap; recording a key takes it only from actions whose scope overlaps, and says so.
8. config.json: an edited action with a scope other than its default is written in a third form, `{"keys": ["shift+command+t"], "worksIn": "library"}` (or names you find clearer; say why), read in all three forms, letter case ignored; a list or "default" keeps reading as today. Tests for every form, round trips, and a file from before this branch.

## Files you own
TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/ShortcutPressDispatcher.swift, TextMouth/App/MenuCommands.swift, TextMouth/App/TextMouthApp.swift (its File menu items), `RecordingShortcuts` and `FeedShortcuts`, TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, the shortcut config.json mirror in ConfigService.swift and SettingsViewModel.swift, and their tests. FR11's later branches will add commands (Move to Library…, Delete Download on Command-Delete) that take your action list as their contract: keep adding an action a one-place change, and say how in your report.

## Verify or report as unverified
- No real key press, menu, VoiceOver, or braille display can be tried by you: list what the user should try by hand (Shift-Command-T in each kind of window, a menu key changed in the tab and shown in the menu, the Works in pop-up with VoiceOver).
- Say exactly what the user's shortcuts are after the first launch of your build.
- If part two cannot be finished within the usage rule, stop after a green part one, say so, and report: part one merges alone.
