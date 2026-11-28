# Settings: the Shortcuts tab
<!-- id: settings-shortcuts-tab; keys: keyboard shortcuts, hotkeys, key bindings, Settings window; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Models/KeyboardShortcut.swift -->

Part of [TextMouth's documentation](../../README.md).

## Shortcuts tab: changing keys
<!-- id: shortcuts-tab-changing-keys; keys: keyboardShortcuts, customKeyboardBindings, hotkeys, reserved keys, macOS menu keys, one press; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/KeyboardShortcutManager.swift -->

The Shortcuts tab changes the shortcuts for reading, navigation, bookmarks, the sleep timer, information (Where Am I?, Where Am I?
Full Summary, Speak Info, Speak Full Info, Speak Import Progress, and Speak Download Progress).
It also changes the shortcuts for the library's actions, the File menu's Open Book…, New from Text…, and New Recording…, the New Recording window's buttons, under New Recording, the window's name.
It changes those of the audio editor too, whose group, Audio Editor, works only in an editor window (see [Editing audio](editing-audio.md)).
A key set there acts before the menus see it, except a menu command's.
Open Book…, New from Text…, and New Recording… (under File), Import Folder…, Add Feed…, and Search Library… (under Library), and Copy Reading Position and Search in Book (under Playback) keep their keys in their menu items, which show the key in force, as VoiceOver reads it.
The New Recording window's Record, Pause or Resume, and Stop (under New Recording) keep theirs in their menu items too, and in that window's buttons, whose hints name the key in force.
Each holds one key, one press of a key with Command or Control that a text field doesn't edit with.
Any other is refused, saying why, as in "W not recorded for Open Book…: a menu command's shortcut is one press of a key with Command or Control." or "Control + A not recorded for Open Book…: a text field edits with it, and a menu command's shortcut would take it from the field."
No shortcut may take a key one of macOS's own commands has in the menus, unless it is that action's own default, as Select All's Command-A is.
Those commands are Quit (Command-Q), Close (Command-W), Close All (Option-Command-W), Settings (Command-Comma), Hide (Command-H), Hide Others (Option-Command-H), Minimize (Command-M), and Minimize All (Option-Command-M).
The Edit menu's commands are Undo (Command-Z), Redo (Shift-Command-Z), Cut (Command-X), Copy (Command-C), Paste (Command-V), Paste and Match Style (Option-Shift-Command-V), and Select All (Command-A).
A refusal says so, as in "Command + Q not recorded for Where Am I?: Quit TextMouth has it in the menus, and no shortcut may take it."
TextMouth keeps a record of the shortcuts you change, and only those, and a shortcut can be one key pressed twice:

### How VoiceOver reads a row
<!-- id: how-voiceover-reads-row; keys: row label, key names, spoken keys, twice, punctuation in words; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Models/KeyboardShortcut.swift -->

Each action's row has a VoiceOver label in words: its name, then its keys, with special keys by name, as in "Skip Forward: Command + Right Arrow or L", where the screen shows symbols.
Punctuation is said in words too, as in "Go Back: Command + Left Bracket", where the screen shows the mark itself, and so are Forward Delete, Home, End, Page Up, Page Down, Help, Clear, the F keys, and the keypad's Enter, which the screen names in words as well, as "Page Down" or "F5".
A key pressed twice is said and shown with "twice" after it, as in "W twice".

### Edited shortcuts and Reset to Default
<!-- id: edited-shortcuts-reset-default; keys: Edited, Reset to Default, Actions menu, VO-Command-Space, changed shortcut; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Models/ShortcutEdits.swift -->

A shortcut you change is marked Edited, after its keys on screen and at the end of its row's label, as in "Release Media Controls: Shift + R. Edited.", and stays yours, even set back to its default keys, until you give it back.
Reset to Default, a button on each edited row and one of the row's actions in VoiceOver's Actions menu (VO-Command-Space), gives the action back TextMouth's default keys, less any that an action you changed holds.
It says the keys it has then, as in "Next Bookmark reset to default: Option + Shift + Command + B."
Reset to Defaults, at the end of the tab, asks first, then gives every action back its default keys and where it works by default.

### Defaults, and taking a key from another action
<!-- id: defaults-taking-key-from-another; keys: Taken from, key conflict, duplicate key, default follows, new default; src: TextMouth/Models/ShortcutEdits.swift, TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift -->

Every shortcut you haven't changed follows TextMouth's defaults, so a default that a later version adds or changes reaches it.
Recording a key that another action working in any of the same windows had takes the key from that action and says so, as in "Command + B, recorded for Show Bookmarks.
Taken from Toggle Bookmark."
A menu command's key counts as pressed once and twice, so recording it as a double press takes it too, as in "Command + O twice, recorded for Book Info.
Taken from Open Book…" An action you changed keeps its other keys.
One you haven't isn't marked Edited for the loss, says on its row, on screen and to VoiceOver, which action has the key, as in "New from Text… has its default, Shift + Command + T.", and has the key again once the action that took it lets it go.

### Reset to Defaults for all shortcuts
<!-- id: reset-defaults-all-shortcuts; keys: Reset Keyboard Shortcuts?, alert, restore all shortcuts; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Models/ShortcutEdits.swift -->

Reset to Defaults, at the foot of the tab, asks first, in an alert, "Reset Keyboard Shortcuts?", and then gives every action its default keys again; once the alert has closed, VoiceOver says "Shortcuts reset to defaults."

### Works in: where a shortcut works
<!-- id: works-where-shortcut-works; keys: worksIn, Every window, Library windows, Reader windows, sheet, audio editor window; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Models/ShortcutEdits.swift -->

Works in, a pop-up button on the row of each action that can work in more than one kind of window, sets where its shortcuts work: Every window, Library windows, or Reader windows.
Its label is "Works in", its value the choice, as in "Library windows" on New from Text…'s row, and its hint "Choosing makes the shortcut yours; Reset to Default restores where it works by default."
By default New from Text… works in Library windows and Show Sleep Timer in reader windows, so Shift-Command-T is each one's in its own kind of window.
Import Folder… and Add Feed… always work in Library windows, and Copy Reading Position and Search in Book in reader windows, where their menus are; the audio editor's actions work in its windows, and the New Recording window's buttons in that window.
Every other action works by default in every window but an audio editor's, though a File menu command that works in every window, as Open Book… and New Recording… do by default, works in an audio editor's window too, as menus do, and any menu command works when no window is open.
So such a command's key is its own in an editor's window too: giving it a key an editor action has takes the key from that action, as in "Command + S, recorded for Open Book… Taken from Audio Editor: Save."
A sheet uses the shortcuts of the window it is over, and a sheet over a sheet those of the window under them both, though no shortcut works in a sheet over an audio editor's window.
A row's VoiceOver label says where its action works when that is Library or reader windows, or other than its default, as in "Show Sleep Timer: Shift + Command + T. Works in reader windows."
Choosing makes the action yours and takes its keys from any other action that works in any of the same windows, as in "New from Text… works in every window.
Taken from Show Sleep Timer."
Reset to Default gives back where it works too, as in "New from Text… reset to default: Shift + Command + T. Works in Library windows."
A menu command set to work elsewhere is dimmed, and shows no key, in other kinds of window, so there its key reaches the window's own shortcut.
In a Library window, whatever Works in says, no shortcut that is a letter pressed alone runs, once or twice: the list takes the letter and moves to the first book or folder whose name starts with it (see [The Library window](library-typing-and-speak-info.md)).
So W, J, K, L, F, and B, the defaults that are a letter alone, work in reader windows only, while a letter with Shift, Option, Command, or Control still runs its shortcut in a Library window.

### How the record of your changes began
<!-- id: how-record-your-changes-began; keys: customKeyboardBindings, upgrade, migration, saved before, old preferences; src: TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/ConfigService.swift -->

The first time TextMouth keeps this record on a Mac, it makes it from every action's keys as saved before, in its preferences and in config.json, taking the file's keys for an action you changed in the file while TextMouth was closed.
It then saves config.json in its new form (see [Editing settings in config.json](config-json.md)).
An action whose saved keys were its default, today's or an earlier one, or that default less a key you gave another action, counts as never changed and follows today's defaults.
A Next Bookmark saved with Shift-Command-B, its earlier default, takes today's Option-Shift-Command-B and leaves Shift-Command-B to Show Bookmarks.
The old copy in the preferences stays as it was, and TextMouth never writes it again.
When config.json is already in the new form, as another Mac sharing the library writes it, the record is made from the file instead.

### Double press time
<!-- id: double-press-time; keys: double press time, half a second, 0.2 to 2 seconds, slider; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Services/ShortcutPressDispatcher.swift -->

Double press time, at the top of the tab, sets how soon a second press of a key must follow the first to make a double press: half a second until you choose another, from 0.2 to 2 seconds in tenths, which VoiceOver speaks as "0.5 seconds" or "1 second".
One time serves every shortcut.

### Recording a double press
<!-- id: recording-double-press; keys: Recording shortcut, Make Double Press, Make Single Press, Escape, record a key; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Services/ShortcutPressDispatcher.swift, TextMouth/Models/KeyboardShortcut.swift -->

A shortcut can be a key pressed twice, a double press.
While a key's button records, its label is "Recording shortcut.
Press a key, or press it twice for a double press.": one press is recorded once the double-press time has passed, a second press of the same key within that time records the double press, and another key pressed before then records the first key once.
Escape cancels, a key held down never records twice, and no shortcut acts while a key is recorded.
Each key's button also offers Make Double Press, or Make Single Press for a double press, in VoiceOver's Actions menu (VO-Command-Space) and in its context menu.
Every key recorded or changed so is announced, as in "W twice, recorded for Go to Library."
A menu command's row, and a New Recording window button's, holds one key and records differently: while its button records, its label is "Recording shortcut.
Press a key with Command or Control.", the first press is recorded at once, and it offers no Make Double Press.

### A key whose single and double press differ
<!-- id: key-whose-single-double-press; keys: waits before, single press waits, J twice, W twice, full summary; src: TextMouth/Services/ShortcutPressDispatcher.swift, TextMouth/Services/KeyboardShortcutManager.swift -->

When one key's single press and double press belong to different actions, the single press waits out the double-press time before it acts, in case a second press follows, and VoiceOver says so as you set it up, as in "J now waits before Skip Backward, in case it is pressed twice."
No default key waits, and a key whose double press runs the same action as its single press acts at once.
So does one whose double press is the full summary of its single press: Where Am I?
Full Summary is W twice and Speak Full Info Shift-Command-I twice, and the first press acts at once as Where Am I? or Speak Info, the second, within the double-press time, switching to the full summary, so neither key waits, whatever keys you give the pair.
A key held down never counts as pressed twice, more quick presses after a double press are ignored, a key a text field keeps never counts as a press, and a double press with Command or Control works from a field, as other shortcuts with Command or Control do.

### Try a Double Press
<!-- id: try-double-press; keys: Try a Double Press, Last try, two presses apart, five seconds; src: TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift -->

Try a Double Press, under the time, says "Press a key twice.", takes your next two key presses as no shortcuts, for five seconds, and says what they made: "Double press."; how far apart they came, as in "Two presses, 0.7 seconds apart.
Set the time above 0.7 seconds to count them as one.", or, 2 seconds apart or more, that the time goes up to 2 seconds; "Two different keys, not a double press."; or, when five seconds pass first, "No key was pressed twice."
The text under the button keeps the last result, as in "Last try: Double press.", for a braille display to read again, until TextMouth quits; while a try waits for its presses, it reads "Press a key twice."
A line of text under the button and its result, which VoiceOver and a braille display read, says why a letter shortcut does nothing in a Library window.
It reads "In Library windows, a letter alone moves to the first book or folder starting with it, so a shortcut that is a letter alone, such as W, works only in other windows."

### Shift with a shortcut's key
<!-- id: shift-shortcut-key; keys: Shift-J, Shift-L, Shift skip units, Increase Speed, Command-Plus; src: TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Models/KeyboardShortcut.swift -->

Shift with the keys of Skip Forward, Skip Backward, and Increase Speed still triggers them, wherever they work, telling them Shift was held.
Shift-J and Shift-L, and Shift with Command-Left Arrow or Command-Right Arrow, skip by the Playback tab's Shift units, and Increase Speed's Command-Plus works as a US keyboard types it, Shift-Command-Equal Sign.
No other shortcut answers its key with Shift added, so outside an audio editor's window Shift-W and Shift-Command-Delete trigger no shortcut unless you give them to an action.
A Shift shortcut of its own, such as a Shift-R you gave Release Media Controls, always wins; Shift never reaches a shortcut this way from a text field; and an audio editor's window matches only its own Shift keys, so there Shift-J and Shift-L are its own ten-second moves.
In a Library window J and L are not shortcuts, so Shift-J and Shift-L fall back to nothing there.
While a sheet or an alert is in front, no shortcut takes Return, the keypad's Enter, Escape, or Command-Period, which press its buttons.

### Go to View 1 to Go to View 9
<!-- id: go-view-1-go-view; keys: Command-1, Go to View submenu, view shortcuts, Library menu; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/ViewModels/LibraryViewModel+Views.swift, TextMouth/App/MenuCommands.swift -->

Go to View 1 to Go to View 9, under Library, go to the first to the ninth view the Library window's View pop-up offers, and have Command-1 to Command-9 until you change them.
Like the other Library actions they work in Library windows, and each is changed, recorded, and reset like any other shortcut.
The Library menu's Go to View submenu shows the key each of its first nine views has in force.
A key with no view says "There is no view 7.
Go to View reaches 6 views."
(see [The Library window](library-window.md)).

### Sync Now
<!-- id: shortcuts-sync-now; keys: Command-Option-S, Option-Command-S, Library menu, Sync Now; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift -->

Sync Now, under Library, has Command-Option-S until you change it, and is changed, recorded, and reset like any other shortcut.
Its menu item exists only while sync is on (see [Syncing your library between your devices](syncing-your-library.md)).

### Next in Folder and Previous in Folder
<!-- id: next-folder-previous-folder; keys: Next in Reading List, Previous in Reading List, Navigate menu, folder navigation; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/FolderNavigationWording.swift -->

Next in Folder and Previous in Folder, under Navigation, go to the next or the previous item of the reader's folder or feed (see [Reader windows](reader-book-end.md)).
Like Next in Reading List and Previous in Reading List, they have no keys until you give them some, and they work in every window but an audio editor's by default, though the Navigate menu offers them in a reader window alone.

## Keys a text field keeps
<!-- id: keys-text-field-keeps; keys: search field, Command-Delete, text editing keys, Control-A, field focus; src: TextMouth/Models/TextEditingKeys.swift, TextMouth/Services/KeyboardShortcutManager.swift -->

While a text field or text area has the keyboard, the Library's search field and every sheet's fields included, the keys that edit text are the field's and never act as shortcuts.
They are Delete and Forward Delete, the arrows, Home, End, Page Up, and Page Down, with any modifiers.
They are also Command-A, Command-C, Command-V, Command-X, Command-Z, and Shift-Command-Z.
And they are Control with A, B, D, E, F, H, K, L, N, O, P, T, V, or Y.
So in the search field Command-Delete deletes to the start of the line rather than removing the selected books.
Command-A selects the field's text rather than every book.
Command-Left Arrow and Command-Right Arrow move to the ends of the line rather than skipping.
Every other shortcut with Command or Control works from a field, such as Command-I for Book Info, and a key with neither types in the field, as it always has.
Leave the field, with Tab, to use those keys as shortcuts.
