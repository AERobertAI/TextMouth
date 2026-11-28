# Menu items that show their keyboard shortcuts: research and plan (November 15, 2026)

Branch `research/shortcut-labels`, researcher `shortcutlabels`, FR22 in `TODO-2026-09-04.md`.
Brief: `Scripts/agents/briefs/2026-11-15/shortcutlabels.md`.

The user, November 15: "if a command in the context menu or menu bars have a keyboard shortcut add them to the item like "Move Up (cmd+shift+up) with proper formatting for verius shortcuts", then "have agents try researching / planning that nicity".
And then: "I was just saying put it as part of the name as saying what other apps do, if they show up on the right visually thats fine VO reads them."
And: "I mostly notice the missing shortcuts in the the apps menus like Library and Book in the menu bar and the context menu, actually some seem to have one attached like add feed but the move book up/down and others do not and I haven't seen any in the context menu".
So each item shows the key in force at its right, where AppKit draws a key equivalent and VoiceOver reads it, and never in its title.

## 1. The answer

- **Showing.** Every menu bar item and context menu item whose command has a key in force gets that key as its SwiftUI `.keyboardShortcut`, as Go to View's items have today.
  AppKit draws it at the item's right, and reports it to VoiceOver in the item's accessibility attributes, the same for an item SwiftUI made as for one AppKit made (probes B3, C2).
- **Never acting, in the menu bar.** The delegate method the brief named cannot do it: AppKit asks `menuHasKeyEquivalent(_:for:target:action:)`, but still matches the items in the menu when it answers no (probes A2, B8).
  An item without a key equivalent matches no press, so each time the shortcut manager passes a press on to AppKit it lifts that key from the items of TextMouth's five menus that show it, and puts it back on the main queue's next turn (probe D).
  A key equivalent's key, Add Feed…'s among them, is never lifted, and acts as today.
- **Never acting, in context menus:** nothing is needed, since a closed context menu never acts on its keys (probe C2).
- **Following an edit:** SwiftUI keeps the keys it shows through a rebuild and updates an edited one at once (probe B4), and the `Commands` that show keys observe the shortcut manager (three more will, section 8), so a key edited in Settings shows at once, as Open Book…'s does today.
- **What no menu shows:** a double press, a command's second key, Fn and Globe, and a few keys AppKit has no symbol for (section 5).
- **Nothing else changes** while the menus are closed (question 4 is the open one): a press the manager takes never reaches a menu, as today, and a press it passes on finds no shown key to match, as today, so it reaches the field, the sheet's buttons, or the list.

## 2. What is true today

Each of the brief's statements was checked against main at 922fbf12f.

- A menu bar item shows a key only when its key is its key equivalent: the actions in `ShortcutAction.keyEquivalentActions` (`Models/KeyboardShortcut.swift`), through `View.menuCommandKey(_:shortcuts:frontKind:)` (`App/MenuCommands.swift`).
  They are Open Book…, New from Text…, New Recording…, Search Library…, Import Folder…, Add Feed…, Copy Reading Position, and Search in Book; the Record window's three buttons are key equivalents of buttons.
- Every other action's keys are taken by `KeyboardShortcutManager`'s local event monitor (`Services/KeyboardShortcutManager.swift`), and its menu item has no key equivalent: `MenuCommands.swift` says "Cmd+Shift+Up handled by KeyboardShortcutManager" under Move Book Up.
- The one exception is the Library menu's Go to View submenu: `View.goToViewKey(number:shortcuts:frontKind:)` gives each of its first nine items `KeyboardShortcutManager.menuShownKey(for:frontKind:)` (an extension in `MenuCommands.swift`), a real SwiftUI `.keyboardShortcut`.
  It never acts on its key because the manager takes Command-1 to Command-9 first in every Library window.
- A focused field keeps the keys it edits with (`KeyboardShortcutManager.shouldHandle(binding:whenTextInputIsFocused:)`, `Models/TextEditingKeys.swift`).
  A sheet keeps Return, Enter, Escape, and Command-Period (`KeyBinding.dialogKeys`), and a Library window keeps a letter alone for its letter navigation (`ShortcutWindowKind.navigatesByLetter`).
  The manager returns such a press to AppKit untouched.
- The menus are SwiftUI `Commands`: `FileCommands`, `EditCommands`, `PlaybackCommands`, `NavigationCommands`, `BookmarkCommands`, `LibraryCommands`, and `BookCommands`.
  `MenuVisibilityManager` (`Platform/macOS/Services/MenuVisibilityManager.swift`) already reaches the `NSMenu`s SwiftUI builds, to hide the Library menu in a reader and the reader's menus in a Library window.
- The context menus are SwiftUI `.contextMenu`s.
  Only the Library's rows hold commands with keys (section 7).
- `App/MenuCommands.swift` is compiled for the iPhone too; only `Platform/macOS/` is the Mac's alone (`project.yml`).

## 3. Why Go to View's way does not carry over

- `KeyBinding.keyboardShortcut` (`App/MenuCommands.swift`) gives a SwiftUI key only for a binding that `canBeKeyEquivalent`: one press, with Command or Control, and none of the `TextEditingKeys`; nor does its key table hold an arrow, Delete, Home, End, Page Up, or Page Down.
  So `menuShownKey` would show nothing for Move Book Up's Shift-Command-Up Arrow, nor for W or Space: exactly the keys the user misses.
- Those are the keys the manager returns to AppKit while a field has the keyboard, and AppKit offers a key-down to the key window's views and then to the menu bar before the first responder's `keyDown:` ("The Path of Key Events", Cocoa Event Handling Guide).
  So the brief's open question has its answer: yes, a menu item whose key equivalent is Shift-Command-Up Arrow would act on it in a focused field, and the field would never select (probes A1 and A7).
- The same goes for the other presses the manager returns where a menu showing them is visible: Return or Escape in a sheet, and a letter alone in a Library window, which a Library menu item given that letter would take from letter navigation.
- Go to View is safe only because Command with a number key is never one of those, wherever the Library menu shows.

## 4. What the prototypes showed

### How they were run

- Four command-line probes, built with `swiftc` (Swift 5 mode, the macOS 26.0 SDK) under `run_locked.py`, and run on macOS 26.3.1: AppKit menus (A), SwiftUI menu content made into an `NSMenu` by `NSHostingMenu` (B), a SwiftUI `.contextMenu` (C), and the lifted key (D).
  Their sources and transcripts are in the worktree's `build/orchestrator/nov15/shortcutlabels/`, which git ignores.
- Each set its activation policy to `.prohibited` first, showed no window, opened no menu, and posted no event.
  A press was an `NSEvent` made in memory and handed to `performKeyEquivalent(with:)`; accessibility was read from the process's own objects, never through an accessibility client.
- A made-up Shift-Command-F holding a capital F matched no item, while one holding a lower-case f did (A1); so the Shift-Command-F rows that rest on AppKit's own matching (A3, A4, A5, A12, B2) say nothing, and probe D used the lower-case form.

### AppKit menus (probe A)

- With no delegate, each item acted on the key it shows: Shift-Command-Up Arrow, W alone, Space alone, and Command-1 in a submenu (A1).
- A delegate answering no for every key but Add Feed…'s was asked nine and six times, and Move Book Up, Where Am I?, and Play / Pause acted all the same; its yes with Add Feed…'s target and action ran Add Feed… (A2).
  A submenu's own delegate answering no stopped nothing either (A4b).
- AppKit asks whether a delegate answers that method once, when it is set: a delegate that began to answer afterwards was never asked (A12).
- With the Library menu's own item hidden, as `MenuVisibilityManager` hides it, Move Book Up still acted when its menu bar was asked (A5).
  That menu bar was not `NSApp.mainMenu`, and `NSMenuItem.h` says an item with a hidden superitem takes no key, so the real menu bar may differ; the design lifts a hidden menu's keys too.
- A view holding a context menu did not act on that menu's keys (A6).
- Neither an `NSTextView` nor an `NSTextField` claimed Shift-Command-Up Arrow as a key equivalent (A7): a field gets it only through `keyDown:`, after the menus.
- An App Shortcut registered in memory (`NSUserKeyEquivalents`) changed no item, so App Shortcuts went untried (A11).

### SwiftUI menus (probe B)

- `.keyboardShortcut` made a real key equivalent: Move Book Up's item held U+F700 with Shift and Command, its target a `MenuItemCallback` and its action `menuAction:`, and it acted on its key (B1, B2).
- `.delete` gave Backspace (U+0008), `.deleteForward` U+F728, `.clear` U+F739, `.return`, `.escape`, `.tab`, and `.space` their characters.
- `localization: .custom` turned off both `allowsAutomaticKeyEquivalentLocalization` and `allowsAutomaticKeyEquivalentMirroring`; `.withoutMirroring` only the second.
- A rebuild kept the item objects where it could and updated an edited key at once: Command-2 acted and Option-Command-1 no longer did (B4).
  It also put SwiftUI's own key back over one set by hand (B5), so a shown key must come from `.keyboardShortcut`, never be set by hand.
- A delegate put in front stayed through a rebuild, but its no stopped nothing, as in A2 (B8); SwiftUI's submenu had a delegate of its own, `MenuHoverDelegate`.
- `.help` became the item's tool tip, which the item's accessibility does not report (`AXHelp` nil), so VoiceOver would likely not hear it.

### SwiftUI context menus (probe C)

- In no window, not even a visible button's key acted (C1), so the view was put in a borderless window, never ordered in (C2).
- There, a visible button's Command-K acted, through the window and through the hosting view; none of the context menu's keys did: Shift-Command-Up Arrow, Command-I, Return, and Command-Delete (C2).
- `menu(for:)` gave SwiftUI's context menu (its delegate an `AppKitMenuDelegate`), its items holding the keys `.keyboardShortcut` gave them, with the accessibility attributes of section 6.

### The lifted key (probe D)

- On SwiftUI's items, a key lifted for one press matched nothing: Move Book Up's Shift-Command-Up Arrow, W alone, and Command-1 in the Go to View submenu (D2).
  Each was back a run-loop turn later, its accessibility attributes with it, and acted again when pressed without a lift.
- Add Feed…'s key, spared as a key equivalent's, acted as before (D3).
- With the menu under a hidden item, Move Book Up still acted until its key was lifted, and then did not (D4).
- An edit made while a key was lifted won: the rebuild gave the item its new key, the put-back left it, and only the new key acted (D5); a rebuild that kept the key left it shown (D6).
- Hiding the item for its press, instead of lifting its key, did not stop it acting (D7).
- Neither a subtitle nor a tool tip appears among an item's accessibility attributes (D8), so neither could carry a key for VoiceOver.

## 5. Keys a menu cannot show

- **A double press** (Speak Full Info, Where Am I? Full Summary): a key equivalent is "a Unicode character that can be generated by a single key press" ("Setting a Menu Item's Key Equivalent", Application Menu and Pop-up List Programming Topics), so no item can show "twice".
  Such an item shows no key, as FR12 decided.
  AppKit takes a two-character key such as "ww" and reports it as "WW" (A9), but that is no double press, and the plan never makes one.
- **A second key** (Play / Pause's K, Skip Forward's L, Skip Backward's J): an item has one key equivalent, so it shows the first key in force that a menu can draw, in the Shortcuts tab's order.
- **Fn and Globe:** AppKit refuses them for an app's own items: "NSEventModifierFlagFunction specified to -setKeyEquivalentModifierMask: … is only supported for system-provided menu items; will not be used" (its log in A9).
  No binding holds them anyway: `KeyBinding.from(event:)` reads Command, Option, Shift, and Control only, and names a function key by itself (F5).
- **Keys a menu can show**, those for which accessibility reports a glyph or a printable character (A9, D9): letters, digits, and punctuation; Space, Tab, Return, the keypad's Enter, Escape, Delete, and Forward Delete.
  So can the four arrows, Home, End, Page Up, Page Down, Help, Mode Switch, Clear Display, and F1 to F20.
- **Keys a menu cannot show:** Clear, Insert, Print Screen, Pause, Menu, and F21 and above (F21 to F24 and F35 were tried) report no glyph, only AppKit's private-use character (A9, D9).
  So do Begin, Scroll Lock, System Request, Break, Reset, Stop, User, System, Print, Insert Line, Delete Line, Insert Character, Delete Character, Previous, Next, Select, Execute, Undo, Redo, and Find (D9).
  An item whose command has only such keys shows none.
- **Delete and Forward Delete** take characters of their own: Backspace (U+0008) for Delete and DEL (U+007F) for Forward Delete, "not the same characters you get from an NSEvent key-down event when pressing those keys" (`NSMenuItem.keyEquivalent`).
  U+F728 gives Forward Delete's glyph too (A9), and SwiftUI's `.delete` and `.deleteForward` give U+0008 and U+F728 (B1).
- **Letters** are held in lower case with Shift apart; AppKit draws a capital, with Shift only when Shift is held, and `MenuKeyShortcutTests.keyEquivalent(of:)` reads them so.

## 6. What VoiceOver reads: documented and inferred

- Documented: `AXAttributeConstants.h` (HIServices, in the macOS SDK) gives a menu item four attributes for its shortcut: `AXMenuItemCmdChar`, `AXMenuItemCmdVirtualKey`, `AXMenuItemCmdGlyph`, and `AXMenuItemCmdModifiers`.
  Its `AXMenuItemModifiers` bits are Shift (1), Option (2), Control (4), and "no Command" (8), Command being implied; no bit names Fn or Globe.
- Documented: `NSMenuItem` adopts `NSAccessibility` (`NSMenuItem.h`).
- Seen in this process (A8, A9, B3, C2): Move Book Up's item reports the character U+F700, key code 126, glyph 104, and modifiers 1 (Shift and Command); Add Feed…'s the character F and modifiers 1; W alone the character W and modifiers 8; Control-G modifiers 12.
  An item SwiftUI made, in the menu bar or a context menu, reports the same as one AppKit made, and its title (`AXTitle`) is unchanged, so the key never becomes part of its name.
- Documented for VoiceOver's own Help menu only: "If a menu item has a keyboard command, you hear it announced with the name of the item" (VoiceOver User Guide, "Use the VoiceOver Help menu on Mac", its macOS 10.15 edition).
  Apple's pages on the menu bar and on shortcut menus say nothing of how an app's item's key is read.
- The user's account: VoiceOver reads a key shown at the right, and Add Feed… has one today.
- Inferred, not documented: VoiceOver reads these attributes after the title wherever an item has them, in a context menu as in the menu bar; and a braille display shows them in a form this research could not see.
- Not known: how VoiceOver says a key with no printable character, such as an arrow or F13, which only a hand check can tell.

## 7. The items whose command has a key

Keys are the defaults (`ShortcutAction.defaultBindings`); the user may change any of them, and an action with no default key gets one only from the user.
"Shown today" marks a key equivalent that already shows; every other item shows nothing today.

### The menu bar

- File: Open Book… (Command-O), New from Text… (Shift-Command-T, Library windows), and New Recording… (Option-Command-N): shown today.
- Edit > Find: Search Library… (Option-Command-F): shown today.
- Playback, in reader windows:
  - Play / Pause (Space, or K), Skip Forward (Command-Right Arrow, or L), Skip Backward (Command-Left Arrow, or J);
  - Cycle Forward Navigation Unit (F), Cycle Backward Navigation Unit (B), Increase Speed (Command-Plus), Decrease Speed (Command-Minus);
  - Where Am I? (W), and Where Am I? Full Summary (W twice);
  - Release Media Controls (no default), listed only while the reader can release the media controls (`canReleaseMediaControls`);
  - Copy Reading Position (Shift-Command-P) and Search in Book (Command-F): shown today.
- Navigate, in reader windows:
  - Go to Library (Command-L), Go Back (Command-Left Bracket), Go Forward (Command-Right Bracket);
  - Next Heading (Option-Command-Down Arrow), Previous Heading (Option-Command-Up Arrow), Go to Page… (Option-Command-G);
  - Next in Reading List, Previous in Reading List, Next in Folder, and Previous in Folder (no defaults);
  - Show Headings (Shift-Command-H), Show Sleep Timer (Shift-Command-T, reader windows), Book Info (Command-I).
- Bookmarks, in reader windows: Toggle Bookmark (Command-B), Show Bookmarks (Shift-Command-B), Next Bookmark (Option-Shift-Command-B), Previous Bookmark (Option-Command-B).
- Library, in Library windows:
  - Import Folder… (Shift-Command-O) and Add Feed… (Shift-Command-F): shown today;
  - Speak Import Progress and Speak Download Progress (no defaults); New Recording…, whose key File's item carries;
  - Speak Info (Shift-Command-I), Speak Full Info (Shift-Command-I twice), Edit Mode (Command-E);
  - New Folder (Shift-Command-N), Move to Folder... (Shift-Command-M), Move Book Up (Shift-Command-Up Arrow), Move Book Down (Shift-Command-Down Arrow);
  - Add to Reading List, Remove from Reading List, and Folder or Feed Settings (no defaults);
  - Go to View's first nine views (Command-1 to Command-9): shown today, by the manager's keys;
  - the removal item, titled Remove from Library…, Move to Trash, Delete Permanently, or Delete Download (`LibraryRemoveCommandWording.menuBarTitle(preferences:selection:)`), Command-Delete.
- Book, in reader windows: Move to Library… (no default).
- Commands with no shortcut action at all, so no key to show (`KeyboardReachabilityTests.standaloneMenuCommands`, question 7):
  - the Book menu's others: Edit Text in Default Editor, Edit Text With…, the two manifest commands, Transcribe Audio… (or Retranscribe Audio…), Attach Transcript…, Clean Up Transcript (Experimental)…, Delete Transcript…, and Edit Audio…;
  - the Library menu's Refresh All Feeds, Import OPML…, Export OPML…, Keep on This Mac, and Stop Keeping on This Mac, and File > Export….
- Actions with a key and no menu item: Up One Level (Command-Up Arrow), Restart Sleep Timer (Shift-Command-R), Open Selected Book (Return), Select All (Command-A, whose Edit menu item is AppKit's and shows it), and the audio editor's and the Record window's keys.

### Context menus

- A book's row in the Library (`LibrarySubviews.swift`, the row's `menu`):
  - Open (Open Selected Book, Return), Book Info (Command-I), Move to Folder... or Move 3 Books to Folder... (Shift-Command-M);
  - Add to Reading List or Remove from Reading List (no defaults);
  - Move Up and Move Down (`LibraryManualMove`: Move Book Up and Move Book Down, Shift-Command-Up and Shift-Command-Down Arrow);
  - a feed item's Move to Library… (no default);
  - the removal item (Command-Delete), titled as in the menu bar, Delete Download for feed items alone.
  Its other items (Select, Export…, the edit, transcript, audio, and cloud commands) have no action with a key.
- A feed's row (`FeedRows.swift`): Feed Info…, which Book Info's Command-I opens for a selected feed (`LibraryInfoRow.infoCommand(feedInFolder:)`).
- A folder's row (`LibraryView.swift`, `folderMenu`): none; Command-Delete removes selected books only.
- The reader's heading and bookmark lists, the Settings lists, and the Search Library window's results hold no command with a key.
- A context menu's command acts on the row it was opened on, or on the selection when that row is in it; the key acts on the selection.
  With VoiceOver, VO-Shift-M opens the menu of the row under the VoiceOver cursor, which need not be selected (question 2).

## 8. The design

### Showing the key

- One rule says which key an item shows: `KeyboardShortcutManager.menuShownKey(for:frontKind:)`, Go to View's today, widened.
  - For an action whose keys the manager takes: its first key in force that a menu can draw (section 5) and that the press dispatcher runs as this very action in the window in front (`ShortcutPressDispatcher.Index.actions(for:in:)`).
    So no item shows a key that does something else there, or nothing, as a letter alone does in a Library window.
  - For a key equivalent's action: its key equivalent where its item acts (`keyEquivalent(for:)`, `ShortcutScope.admitsMenuCommand(in:)`), so the Library menu's copy of New Recording… shows the key File's item acts on.
  - Nil otherwise, as with no window in front.
- `KeyBinding.menuShortcut` (new, beside `keyboardShortcut` in `App/MenuCommands.swift`) is the binding as SwiftUI's `KeyboardShortcut` for showing, with `localization: .custom`, and nil for a double press or a key no menu draws.
  `.custom` turns off the remapping for other keyboard layouts, which would show Command-Ö for Command-[ on a German layout (SwiftUI's `KeyboardShortcut.Localization`), a key the manager never matches.
  `keyboardShortcut` stays as it is, for the key equivalents that act.
- `View.menuShownKey(_:shortcuts:frontKind:)` (new) is the one modifier every item of section 7 uses whose action is not a key equivalent's; `goToViewKey` becomes one line on it.
- `NavigationCommands`, `BookmarkCommands`, and `BookCommands` take the manager and observe `FrontWindowKind.shared`, as `PlaybackCommands` does.
- The Library rows take their keys from `BookRowContext` (`LibraryView.swift`), made once for all the rows of a drawing of the list (PERF28), so no row observes the manager.
  The value it is made from changes only with the keys in force, so Try a Double Press and the Shortcuts tab's recorders redraw no list.

### Never acting on a shown key: the lifted key

- `MenuKeyLift` (new, `Platform/macOS/Services/MenuKeyLift.swift`) is called by the shortcut manager's event monitor (the macOS `KeyboardShortcutManager.handleKeyEvent(_:)`) each time it returns a press to AppKit.
  That is before AppKit offers the press to any menu, and includes the presses a recorder of the Shortcuts tab or Try a Double Press takes.
- It reads the press's stroke (`KeyBinding.from(event:)`).
  Unless that is a key equivalent's key in force, it clears the key equivalent of every item showing it in TextMouth's five menus (`MenuVisibilityManager.allContextMenuTitles`, found in `NSApp.mainMenu` at each press).
  Their submenus count, and so do hidden menus; an item with an App Shortcut (`userKeyEquivalent`) is left alone.
  It knows those items by the key a menu would show for the stroke (`KeyBinding.menuShortcut`), the one table for showing and lifting alike.
  So it never reads an item's characters back into keys: `TextFieldEditingKeysTests`' own table reads U+007F as Delete, which AppKit reads as Forward Delete (A9).
- On the main queue's next turn, after AppKit has finished with the press, each item gets its key back, unless it was given one meanwhile, so an edit's key is never replaced by the old one.
- So AppKit finds no shown key to match, by whatever path it looks, and the press reaches the field, the sheet's buttons, or the list, as today; a press the manager takes never reaches a menu, as today; and a key equivalent's key acts, as today.
- Its cost: one walk of the five menus' items (under a hundred) for each press passed on, the typing in a field included, and two changes of an item when a typed key is one a menu shows, as W typed in Search in Book's field.
- Why not the alternatives:
  - a delegate answering no does not stop AppKit (A2, B8), nor does hiding the item (D7);
  - keys put on only while a menu is open would have to be set by hand, which SwiftUI undoes (B5), and in `menuNeedsUpdate`, which AppKit also calls before it matches keys (`menuHasKeyEquivalent`'s documentation);
  - menus TextMouth builds itself in AppKit, in place of the five `CommandMenu`s, would work but rewrite most of `MenuCommands.swift`: the fallback if the lift fails on the real menu bar (commit 3).

## 9. The plan, in commits

One branch, `feature/shortcut-labels`, from main.
Each commit builds and passes alone, and no menu bar item shows a new key before the lift is in place.
Every train names `--areas shortcuts,library` and the commit's new classes.

1. **What a menu can show.**
   `KeyBinding.menuShortcut` and the widened `menuShownKey(for:frontKind:)`, with a table test (`MenuShownKeyTests`) over every `KeyBinding.keyNames` entry, letters, digits, a double press, two keys, a letter alone in a Library window, a key another action holds, and a key equivalent's.
   Go to View uses them and still shows Command-1 to Command-9.
2. **The lift, wired in.**
   `MenuKeyLift` and its call from the event monitor, with unit tests (`MenuKeyLiftTests`) on menus a test builds and never shows, pressed with made-up events as probe D was.
   They check that a lifted key matches nothing and is back on the next turn, that an edit made meanwhile wins, that a key equivalent's key and an App Shortcut are never lifted, and that submenus and a hidden menu's items are lifted too.
   Go to View's items are covered from now on, as every item showing a key the manager takes will be.
3. **The Library menu shows its keys, and the real menu bar is pinned.**
   `View.menuShownKey(_:shortcuts:frontKind:)` on each Library item of section 7, with the tests of section 10.
   Its hosted test pins what the design rests on: Move Book Up's item shows Shift-Command-Up Arrow, and the key is back a turn after it is lifted.
   While it is lifted, a Library window's `performKeyEquivalent(with:)` and `NSApp.mainMenu.performKeyEquivalent(with:)` both return false, and no `.moveBookUp` is posted.
   If SwiftUI acts on a lifted key some other way, stop: the fallback is section 8's AppKit menus.
   Three tests change to say what they meant:
   - `TextFieldEditingKeysTests.testOnlyTheEditMenuTakesAFieldsKeyOnItsWay`: no item but the Edit menu's acts on a key a field keeps; an item of the five menus may show one, since its key is lifted when the press is passed on;
   - `FullSummaryActionTests.testTheMenusOfferEachFullSummaryAfterItsBriefOne`: Speak Info shows its key where it works, and Speak Full Info shows none;
   - `RecordingWindowTests.testTheMenusOfferNewRecordingAndNothingClashes`: File's New Recording… still acts on Option-Command-N, and the Library menu's copy shows it.
4. **The reader's menus show theirs:** Playback, Navigate, Bookmarks, and Book.
   `AudioEditorShortcutTests.testTheEditorsCommandShortcutsAreNoMenuCommands` changes to count only the keys a menu acts on.
   Previous Heading now shows Option-Command-Up Arrow, the editor's Previous Chapter Marker key, which is lifted if ever passed on.
   And `FullSummaryActionTests` checks Where Am I?'s key.
5. **The context menus show theirs:** the Library book row's and the feed row's items of section 7, through `BookRowContext`, with tests of the menu SwiftUI builds for a row (as probe C read it, `menu(for:)` in a window never shown) and of the row context's keys after an edit.

After the merge, the documentation pass describes the shown keys and the lift in `docs/architecture/state/windows.md` (Menus, Key presses) and `docs/architecture/state/preferences-shortcuts.md`, and what the menus show in the user's pages.

## 10. The tests

- **Pressing keys safely.**
  The tests press keys only on menus they build themselves, and on the real menu bar only Move Book Up's key with the key lifted (commit 3), since a key that acted by mistake could start a command that speaks.
  Move Book Up's would at most move a book of the test's sandboxed library and record what it says (`VoiceOverAnnouncer` records under hosted tests).
- **Each item's key shown.**
  A table of section 7's items, each with its menu, its title, and the key it shows with the defaults in the window in front, read from the running app's `NSApp.mainMenu` after `menuNeedsUpdate`, as `MenuKeyShortcutTests` reads it; each title unchanged.
- **A key edited in Settings shows at once.**
  In a sandboxed store, Move Book Up given Option-Command-Up Arrow, then put back, each read again within five seconds (`waitUntil`), as `testTheMenusShowTheKeysInForceAndFollowAChange` does; the same for a row's context menu through its row context.
- **Every key still acts exactly as today:**
  - the `shortcuts` area, its scenario tests included (`LegacyKeyboardShortcutScenarioTests`, `LegacyMenuVisibilityScenarioTests`), unchanged but for the four tests the plan names, with `KeyboardReachabilityTests`, `ShortcutPressDispatcherTests`, and `TextFieldEditingKeysTests`;
  - a text field's Shift-Command-Up Arrow: the manager returns the press while a field editor has the keyboard (as `TextFieldEditingKeysTests` checks), and the lift leaves no item showing it during the press, though Move Book Up shows it before and after;
  - a sheet's Return: with Speak Info given Return in a sandboxed store, the Library menu shows Return, the manager returns the press in a sheet the test builds, the lift clears Speak Info's key for it, and the sheet's default button takes it (`performKeyEquivalent(with:)` on the sheet);
  - a letter alone: given to Speak Info, it is shown in no Library window, where letter navigation keeps it, and the lift clears it wherever a hidden menu shows it;
  - the key equivalents: none is ever lifted, so each acts through its item where its action works, as today; nor is an App Shortcut;
  - a recorder of the Shortcuts tab gets every key, a shown one included, since the lift runs for the presses it takes.
- **The break that proves the lift.**
  With the lift turned off, the text field, sheet, and recorder tests fail, since a menu item takes the key; that run is made on a scratch copy through `run_locked.py`, never on a shared train.

## 11. What this research could not verify

- Nothing was drawn on screen and VoiceOver was neither driven nor asked, so how a shown key looks, sounds, and reads in braille rests on the attributes the probes read and on the user's report.
- The real menu bar: the probes made SwiftUI menu content into an `NSMenu` with `NSHostingMenu`, not through `Commands` in a running app, which here would have taken focus.
  SwiftUI's documentation says a shortcut's target is looked for "in the key window first, then the main window, and then the command groups" (`keyboardShortcut(_:modifiers:)`).
  Only the real app can show whether that ever bypasses the item's key equivalent; commit 3 pins it in a hosted test.
- Whether the real menu bar matches a hidden menu's items, as menus asked directly did (A5, D4); the lift covers them either way.
- What an open menu does with a key it shows (question 4).
- App Shortcuts set in System Settings (A11): the lift spares any item that has one, unseen.
- Keyboard layouts other than US English: with the remapping off, a menu shows the key the binding names, which the manager matches by the character typed, as today.

## 12. Questions for the user, each with the answer the plan builds

1. **Keys in the context menus too?**
   Apple's guidelines say "Show keyboard shortcuts in your app's main menus, not in context menus", since a context menu is itself a shortcut to its commands (Human Interface Guidelines, Context menus).
   You asked for both.
   Recommended, and built: show them in the Library rows' context menus too, since VoiceOver users meet commands there (VO-Shift-M), and a context menu item reports its key as a menu bar item does (section 6).
2. **A row's menu acts on that row; the key acts on the selection.**
   With VoiceOver, VO-Shift-M opens the menu of the row under the VoiceOver cursor, which need not be the selected row.
   Recommended, and built: show the key anyway, since it names the same command, and pressing it after selecting the row does what the item does.
3. **Two keys, a double press, a key no menu can draw.**
   A menu item shows one single press, and a help tag or a subtitle would likely go unheard: neither is among an item's accessibility attributes (section 4, probes B and D).
   Recommended, and built: show the first key a menu can draw, and none for a double press, as FR12 decided; the Shortcuts tab keeps naming every key.
4. **A shown key pressed while its menu is open.**
   TextMouth's shortcuts never see a key while a menu is open (menu tracking takes it), so what AppKit does then is AppKit's, and it may choose the item.
   This was not tried, since no menu may open on screen.
   Recommended: accept it, and check once by hand: open the Library menu with VO-M, then press Shift-Command-Up Arrow.
5. **Commands with a key and no menu item** (Up One Level, Restart Sleep Timer, Open Selected Book).
   No menu can show their keys.
   Recommended: leave them for now, and give them menu items later if you want them found there.
6. **VoiceOver actions.**
   A row's VoiceOver actions (VO-Command-Space) have only names, with no place for a key beside them.
   Recommended: leave them as they are; the row's context menu now shows the keys.
7. **The Book menu's commands have no keys to show.**
   You named the Book menu, but of its items only Move to Library… is a command the Shortcuts tab lists, and it has no default key; Edit Text, Transcribe Audio…, Edit Audio…, and the rest cannot be given a key at all (section 7).
   Recommended: a follow-up branch that lists each of them in the Shortcuts tab with no default key, as the reading list's commands are, so you can give them keys, which this plan then shows.
   Not part of this plan's commits.
