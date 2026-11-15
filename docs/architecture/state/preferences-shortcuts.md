# Preferences: keyboard shortcuts
<!-- id: preferences-shortcuts; keys: hotkey, key binding, shortcut editor, double press; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/KeyboardShortcutManager.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Keyboard shortcuts
<!-- id: keyboard-shortcuts; keys: hotkey, key binding, key equivalent, double press, shortcut editor; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/ShortcutPressDispatcher.swift -->

Keyboard shortcuts (FR12): the record of the shortcuts the user edited, every action's keys in force, and the double-press time.

### Shortcut record and its owner
<!-- id: shortcut-record-owner; keys: hotkey, key binding, clash, scope, default keys, ShortcutAction, KeyBinding; src: TextMouth/Models/ShortcutEdits.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Models/SettingsPolicy.swift, TextMouth/Models/TextEditingKeys.swift, TextMouth/Views/Recording/RecordingWording.swift -->

- Owner: KeyboardShortcutManager (Services/KeyboardShortcutManager.swift), the one the app makes and every window shares.
  Its edits, a ShortcutEdits (Models/ShortcutEdits.swift), hold each action the user edited, with its keys, and nothing else: an action is edited exactly while the record holds it, even with its default keys, and an edited action without a key holds an empty list.
  The preferences store keeps the record under keyboardShortcutEdits (editsPreference) as JSON keyed by the actions' names, the form the whole map had, an action working in a scope the user chose holding an object, {"keys": [...], "worksIn": "`<the ShortcutScope's raw value>`"}.
  It is written with sorted keys so one record is always the same bytes (storedData), and read entry by entry (ShortcutEdits.reading(_:)).
  So an entry naming no action this build knows, or whose keys can't be read, is left out with a STORED_VALUE_REPAIRED line while the rest load.
  An entry naming a scope this build doesn't know, or one its action can't be given, keeps its keys at its default scope with such a line.
  Each action works in a scope (ShortcutScope: .app, every window but an audio editor's; .library; .reader; .audioEditor; .recording, the Record window).
  Its defaultScope is its group's or one of its own (ShortcutAction.defaultScopesOfTheirOwn: New from Text… and the Library menu's Import Folder… and Add Feed… in Library windows, Show Sleep Timer and the Playback menu's Copy Reading Position and Search in Book in reader windows).
  The user may change it among availableScopes, which offer .app, .library, and .reader to the app's actions and the File menu's commands and fix every other's.
  The record keeps a chosen scope beside the action's keys only when it is not the default (scopesByEditedAction, setScope(_:for:keys:), cleared by Reset to Default).
  The Record window's buttons are the group ShortcutAction.recordingWindowCategory, "New Recording", the window's own title (RecordingWording.windowTitle), which begins their names, as in "New Recording: Stop".
  The menu commands' keys, and the Record window's buttons', are actions too (ShortcutAction.keyEquivalentActions).
  Each is one press with Command or Control that no text field edits with (KeyBinding.canBeKeyEquivalent, TextEditingKeys), and claims its double press as well (KeyClaims.forms(of:for:)).
  ShortcutAction.refusal(ofKeys:holding:), the one refusal rule since REV11, refuses, among the keys a change adds to those the action holds, any other key for one of them and a key past the one its item may have, or past as many as it holds.
  For any action it also refuses a key in KeyBinding.systemCommands that is not the action's own default.
  It gives a ShortcutRefusal naming the first key at fault, and never a key the action holds already.
  The manager passes the action's keys in force (change(_:to:)), and config.json none (ShortcutListing.refusal(for:)), asking it only of the entries the record doesn't hold (ShortcutEdits.entriesLeftOut(of:)).
  Its bindings, every action's keys in force, are ShortcutEdits.effectiveBindings(defaults:) over this build's ShortcutAction.defaultBindings, a static let built once, as audioEditorDefaultBindings is.
  The edited actions claim their keys first, then every other action takes its defaults less any key that clashes with one already claimed in a kind of window where its keys act (KeyClaims, by ShortcutWindowKind).
  Each group goes in ShortcutAction.allCases order, which since FR12's branch B is the order the Shortcuts tab lists the actions in, each group whole (#1528, pinned by ShortcutsSettingsTabTests).
  So no key is in force for two actions in one kind of window, and a default a later build adds or changes reaches every action the user never edited and none the user did.
  ShortcutScope.windowKinds(of:) gives the kinds of window where an action's keys act: its scope's, and, for a key equivalent, every kind its menu item acts in (admitsMenuCommand(in:)), an audio editor's included for a File menu command working in every window.
  So no editor action holds a key such a command answers there (REV11).
  ShortcutAction.sharesAWindow(in:with:in:) is the clash rule's overlap (ShortcutEdits.key(_:of:clashesWith:of:), and the move from the saved map).
  KeyClaims, ShortcutPressDispatcher.Index, and the tests' ShortcutKeyOwners (keysOnTwoActions(in:scopes:) and actions(holding:in:sharingAWindowWith:scopes:)) follow it too.
  A KeyBinding can be a double press (isDoublePress, FR12's branch B): its stroke, the key with its modifiers, pressed twice within the double-press time.
  A key's single press and its double press are two keys, which two actions may hold, unless one of them is a key equivalent's, whose key claims both.
  KeyBinding's Codable is written by hand, so a binding saved without the flag, as every binding before it was, reads as a single press, and a single press is saved exactly as before, with no flag.
  The double-press time is SettingsPolicy.shortcutDoublePressSeconds (0.2 to 2 seconds, 0.5 by default), one time for every shortcut.
  The manager reads and writes it in tenths of a second (doublePressTimePreference, through SettingsPolicy.validatedDoublePressSeconds(_:)), correcting a stored value out of range or between tenths silently, with no log line, and publishes it as doublePressTime.

### Who may write the shortcuts
<!-- id: who-may-write-shortcuts; keys: Reset to Defaults, migration, customKeyboardBindings, shortcut config text, stepper; src: TextMouth/Models/ShortcutEdits.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/Views/Settings/SoundEffectsSettingsView.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Services/ConfigService.swift, TextMouth/Models/SettingsPolicy.swift -->

- Who may write it: the manager, every change going through the record and saved at once.
  KeyboardShortcutManager.updateBindings(for:to:), addBinding(_:to:), and removeBinding(_:from:) make an action the user's through ShortcutEdits.setKeys(_:for:).
  It takes each of its keys from every other edited action that shares a kind of window with it (sharesAWindow(in:with:in:)), those keeping their other keys and staying edited.
  Keys that leave an unedited action as it is change nothing, and a key the action can't take changes nothing and comes back as a ShortcutRefusal (ShortcutAction.refusal(ofKeys:holding:)).
  KeyboardShortcutManager.setScope(_:for:), from the tab's Works in, makes the action edited at its keys in force in the scope chosen, taking them from the actions whose scopes now overlap.
  KeyboardShortcutManager.resetToDefault(_:) takes one action out of the record (Reset to Default), and resetToDefaults() empties it (Reset to Defaults).
  The tab's Reset to Defaults asks first, then KeyboardShortcutsSettingsView.resetEveryShortcut(_:announce:) resets and announces ShortcutsSettingsWording.resetDone once the alert has closed (VoiceOverAnnouncer.announceAfterSheetCloses).
  The Sound Effects tab's, which asks nothing, runs SoundEffectsSettingsView.resetEverySound(_:announce:), which announces SoundEffectsSettingsWording.resetDone at once.

### Moving the saved map, and applying config.json
<!-- id: shortcuts-move-and-config-file; keys: customKeyboardBindings, SHORTCUT_EDITS_MOVED, ShortcutListing, applyConfigChanges, old form, formerNames, double-press time; src: TextMouth/Models/ShortcutEdits.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/SettingsPolicy.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

At the first launch whose store holds no record, SettingsViewModel's applyFileAtLaunch calls moveSavedShortcutsIfNeeded(in:fileListings:) before it applies config.json.
It reads, once, the whole map every earlier release saved under customKeyboardBindings, with config.json's lists in the old form, and makes the record (ShortcutEdits.migrating).
An action takes the file's keys where they differ from the map's, an edit made while TextMouth was closed.
An action whose keys are its default, today's or a former one (ShortcutAction.formerDefaultBindings: Move Book Up's and Move Book Down's Control-Option arrows, and Next Bookmark's Shift-Command-B), whole or less the keys other actions whose default scopes overlap its own hold, counts as unedited.
A key two edited actions then hold goes to the one the file edited, or, where the file edited both or neither, to the first in allCases order.
It logs SHORTCUT_EDITS_MOVED with the actions edited, writes the record, and returns true, so applyFileAtLaunch leaves the file's shortcuts out of what that launch applies and the launch's own save writes config.json in the new form.
Nothing writes customKeyboardBindings again, so it stays as a copy to go back to.
A config.json already in the new form, holding an entry that follows the defaults, moves nothing: an empty record is written and the file is applied over it.
The file's entries (SettingsPolicy.keyboardShortcuts, whose KeyedSettingRule reads an action's name in any letter case through ShortcutAction.named(_:)) are ShortcutListing values (Models/KeyboardShortcut.swift).
The exact spelling wins over another, and a name ending in an ellipsis is read with three periods or none.
A list is an edited action's keys.
An object (.object(keys:worksIn:)) is an edited action's keys and the scope it works in, written with ShortcutScope.title and read by ShortcutScope.named(_:), its field names in any letter case (ShortcutJSONKey), and "keys" also as one shortcut written as text.
Text beginning with "default" is an action following the defaults, whose other words are never read, naming a Library or reader default after it ("default in reader windows: …", ShortcutScope.isSaidAsADefault).
Any other text is one shortcut.
A former name, as the Record window's buttons' "Recording Window: …" or the bookmark command's "Add Bookmark" (its case is still addBookmark, its name Toggle Bookmark), is read as its action's.
It is read so here and in the stored record (ShortcutAction.formerNames, through named(_:) and exactlyNamed(_:), which ShortcutEdits.reading(_:) uses).
Only the names in force are written.
Each shortcut is written as KeyBinding.configText and read back by KeyBinding(configText:), which takes "twice" after a shortcut, or "double" before it, in any letter case and with or without spaces, as a double press.
It also takes a key by its name in KeyBinding.keyNames, such as pageDown or f5, or by its own character.
SettingsViewModel.applyConfigChanges puts them in place through KeyboardShortcutManager.adopt(_:in:) (ShortcutEdits.adopting(_:)).
A list makes its action the user's in its default scope, an object in the scope it names, and "default" takes it out of the record, keys and scope.
A file in the old form, which holds no entry in the record's form (no object and no text beginning with "default": ShortcutListing.isInTheRecordsForm), as a hand-written file of only lists does not, is read as the move reads it (listingsLeavingOutDefaults(of:skipping:)).
A list whose keys are a default of its action by the move's own rule (ShortcutEdits.keysAreADefault, which steps 2 and 3 of migrating share, so the two cannot differ) is left out and edits nothing.
Such a default is today's default or a former one, whole or less the keys other actions' lists in the file hold, compared as sets.
So an action edited in the app keeps its edit, an unedited one keeps following the defaults, and only a list that differs from every default makes its action the user's.
In a file with any entry in the record's form, a list equal to its action's default still makes the action the user's, so an edited action set back to its default keys stays the user's.
An entry ShortcutEdits.entriesLeftOut(of:) names (a scope its action can't have, or keys it refuses) is left out with a STORED_VALUE_REPAIRED line and adopt(_:in:) returns true, as it does when it left an old-form file's list out as a default (one trace line counts them, naming no key).
So the file is saved again in the new form, which a second reading changes nothing in.
A key two edited actions then hold goes to the one whose entry changed the record, or, where both or neither did, to the first in allCases order (resolvingSharedKeys(favoring:)), with a STORED_VALUE_REPAIRED line naming the key and both actions.
After either, applyConfigChanges saves config.json again (syncToConfig), so the file shows the keys in force.
The double-press time is set by the Shortcuts tab's stepper (setDoublePressTime(_:)) and by config.json's shortcutDoublePressSeconds, which ConfigService reads moved into range and to the nearest tenth, logging the repair.
SettingsViewModel.applyConfigChanges adopts it through doublePressTimePreference, a file without it leaving the time alone.
A change of either in the store reaches the manager through its PreferenceObserver.

### How shortcuts are observed
<!-- id: how-shortcuts-are-observed; keys: Shortcuts tab, record a key, Works in picker, Try a Double Press, menu hints; src: TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/ShortcutPressDispatcher.swift, TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift, TextMouth/App/MenuCommands.swift, TextMouth/Views/Recording/RecordingWindowView.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/AudioEditorModel.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift, TextMouth/Models/CountWording.swift, TextMouth/Models/StoredPreference.swift -->

- How others observe it: the manager publishes once for each change of the record (take(_:)), a change another writer makes in the store included, such as applying config.json (PreferenceObserver), and once for each change of the double-press time.
  Key presses go by both at once ([Windows](windows.md), Key presses).
  SettingsViewModel.syncToConfig lists every action in config.json (ShortcutEdits.listings(defaults:)).
  It lists an edited action as the list of its keys in force, or, when it works in a scope the user chose, an object of them and the scope's ShortcutScope.title.
  It lists every other as "default: " and its keys in force, or "default: none", with "default in Library windows: " or "default in reader windows: " where ShortcutScope.isSaidAsADefault.
  It writes shortcutDoublePressSeconds beside them.
  The Shortcuts tab (KeyboardShortcutsSettingsView and ShortcutBindingRow, in Views/Settings/KeyboardShortcutsSettingsView.swift) shows "Edited" and Reset to Default on the row of an action isEdited(_:) names, Reset to Default as a button and as an accessibility action of the row.
  Its words are ShortcutsSettingsWording's, pinned by ShortcutsSettingsTabTests.
  The row's VoiceOver label is rowLabel(for:keys:isEdited:defaultsHeldElsewhere:worksIn:), which says where the action works when that is Library or reader windows or other than its default.
  For an unedited action that goes without a default key, it also says which action has it (ShortcutsSettingsWording.defaultsHeldElsewhere(_:), from the manager's defaultKeysHeldElsewhere(for:), as the row shows it too).
  Its keys go in words through KeyBinding.accessibleDisplayString, from the one table of named keys, KeyBinding.keyNames (KeyName: the key as a binding holds it, its words, what the screen shows, config.json's name, and the key code of a key matched by its code).
  It holds the nine keys matched by their codes (Space, Tab, Return, Delete, Escape, and the arrows).
  It holds every AppKit function key, held as its private-use character but named in words (Forward Delete, Home, End, Page Up, Page Down, the F keys, and the rest), the keypad's Enter, and the punctuation marks, named in words and shown as themselves.
  Any other key is its character, a letter in capitals, and a double press ends in " twice".
  ShortcutsSettingsWording's words also include the announcement of a key recorded, with every action that lost a key to it (actions(thatLostKeysSince:besides:)).
  They include that of a reset, with the keys the action has then and, when the reset changed it, where it works (resetAnnouncement(for:keys:worksIn:)).
  ShortcutBindingRow adds a Works in Picker on each row whose action has more than one scope available, bound to the manager's scope(of:) and setScope(_:for:) and announced by scopeChanged(_:to:takenFrom:).
  A key from the private-use area that no name says can no longer be recorded or read (KeyBinding.isUnnamedPrivateUseCharacter(_:)).
  The tab opens with DoublePressTimeStepper (setDoublePressTime(_:), its value spoken through CountWording.secondsToTheTenth(_:), as the Miscellaneous tab's gesture time window is) and Try a Double Press (tryDoublePress(report:), over a DoublePressTrial, in Services/ShortcutPressDispatcher.swift).
  The trial takes the next two presses for five seconds as no shortcuts and reports a DoublePressTrial.Outcome.
  A key's button records through ShortcutRecorderEventHandler, whose local key monitor hands each press to a ShortcutRecording.
  ShortcutRecording records a single press once the double-press time passes, a second press of the same key within it as a double press, another key ending the wait with the first recorded as a single press, a held key's repeats ignored, and Escape cancelling.
  For a key equivalent's row it takes the first press at once (takesDoublePresses false).
  DoublePressTrial and ShortcutRecording measure two presses through one TwoPresses.
  Try a Double Press keeps its last outcome as text under the button (trialStatus, from the manager's lastDoublePressTrialOutcome, kept until TextMouth quits).
  One more line of text under it says why a letter shortcut does nothing in a Library window (ShortcutsSettingsWording.letterNavigationNote, pinned by ShortcutsSettingsTabTests; the rule is under Key presses in [Windows](windows.md)).
  A recorder calls recordingStarted(by:) and recordingStopped(by:) to tell the manager, which holds the recorders weakly and acts on no key while one records.
  Make Double Press and Make Single Press (ShortcutsSettingsWording.pressChange(for:)) are each key button's accessibility action and context menu item, but a key equivalent's, whose row holds one key.
  A key recorded is announced through ShortcutsSettingsWording.recorded(_:for:takenFrom:nowWaitsBefore:), which adds nowWaits(_:before:) when the manager's waitingAction(for:in:) newly names an action the key's single press waits before.
  An audio editor window's model reads the keys in force for its buttons' hints through bindingsPreference, a read-only StoredShortcutBindings over the record's key, says them in the same words (AudioEditorWording.shortcutSentence(_:)), and redraws as the record changes.
  The Record window does the same for its buttons (RecordingWindowView, through StoredKeyEquivalents).
  Each hint ends with the button's key in force, in those words (RecordingWording.recordHint(device:key:), pauseHint(key:), resumeHint(key:), and stopHint(key:)), or with nothing while the button has no key.
  The Bookmarks menu (App/MenuCommands.swift) titles each of its items from its ShortcutAction raw value, so the menu, the Shortcuts tab, and config.json cannot name a command differently.
