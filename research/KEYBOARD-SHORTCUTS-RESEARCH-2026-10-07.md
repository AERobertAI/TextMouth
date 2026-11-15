# Double-press shortcuts, every shortcut in config.json, and a record of your edits (FR12)

A design note for FR12, written before it is built. It draws on the code on main at 05092db8, which includes the reading list (01197eb1) with its two new actions, and the October 7 follow-ups (cb134bb1); on the history of Models/KeyboardShortcut.swift; on Apple's VoiceOver and AppKit documentation; and on this user's config.json. That file was read once, strictly read-only, by a script in the session's scratchpad, which compared its `keyboardShortcuts` with today's defaults and printed only the differences. Nothing was copied, and nothing in the app, the library, or the preferences was changed. Nothing was built.

The request, quoted whole in FR12 in TODO-2026-09-04.md (October 7, evening), answering whether a second quick press of Speak Info (I) or Where Am I? (W) while the brief summary speaks should switch to the full one: "2. Yes that sounds liek a good idea, I would want this to go with a general expansion of the keyboard short customization to allow users to set double press keys and a time out at the same time I think all built in shortucts should just be editable in the same json as the user settings, maybe using the same edited records used for the meta data fields to no override user settings with new or changed shortcuts". Added the same evening: "also fhre the shortcuts to have customizable items for full info and wear am i summaryies in shortcut section". The first part of that answer, "1. Yes if its not in the continue to next book mode anyway", is about REV07 (4), the rewind after a finished book, and is not part of FR12.

## Summary

- **Today, the first change saves every action.** `KeyboardShortcutManager` keeps one map of every action's keys under `customKeyboardBindings`. Once the user changes one shortcut, the whole map is saved, and from then on no changed default reaches an action already in it. config.json mirrors that map, every action written as a list of keys. Nothing records which actions the user actually chose.
- **This user's shortcuts show the cost.** config.json lists 72 actions, written by the installed build, which predates Speak Info. Two differ from today's defaults:
  - Release Media Controls has Shift-R. It has no default, so this is the user's own choice.
  - Next Bookmark has Shift-Command-B. That was its default until March 24, and the saved map kept it.

  Shift-Command-B has also been Show Bookmarks' default since that day, so one key belongs to two actions. Which one acts depends on the order of a Swift dictionary, which can change at every launch.
- **Recommendation for the record:** keep only the actions the user edited, under a new store key, `keyboardShortcutEdits`, as `Book.HandEdits` keeps edited metadata fields. Every other action takes the defaults of the build that runs, less any key an edited action of its scope holds. For this user the record holds one action, Release Media Controls. Next Bookmark goes back to Option-Shift-Command-B, and the clash ends.
- **Recommendation for config.json:** every action stays listed, in one of two forms:
  - An action you edited is a list of its keys, as today: `"Release Media Controls": ["shift+r"]`.
  - Every other action is text beginning with "default", followed by its keys: `"Where Am I?": "default: w"`.

  Writing a list makes an action yours, and writing "default" gives it back to TextMouth's defaults. A newer build's defaults then reach every action written "default", whatever build wrote the file.
- **Recommendation for double presses:** a binding can be a double press, written "w twice". One double-press time serves every shortcut: 0.5 seconds by default, from 0.2 to 2 seconds, set in the Shortcuts tab and in config.json. When a key has both a single and a double action:
  - If the double action escalates the single one (a brief summary, then the full one), the first press acts at once.
  - Otherwise the single action waits out the double-press time.

  A held key's repeats never count as presses, and neither do keys typed in a text field.
- **Recommendation for the full summaries:** two new actions, Speak Full Info (I twice) and Where Am I? Full Summary (W twice), listed under Information and in the Library and Playback menus. The first I starts the brief summary at once. A second I within the double-press time switches to the full summary, which is the user's yes. A single press after that time still stops a summary.
- Section 7 asks ten yes-or-no questions, each with a recommended answer. Section 8 plans three branches: the record, then double presses, then the full-summary actions, with a fourth after question 7.

## 1. How shortcuts work today

### 1.1 The actions and their keys (Models/KeyboardShortcut.swift)

- **`ShortcutAction`** (line 4) is a `String` enum whose raw values are the names Settings shows and config.json uses. Main has 75 cases:
  - 34 work in every window except the audio editor's.
  - 41 work only in the audio editor's windows, each named "Audio Editor: …".

  `title` drops that prefix for Settings. `category` groups the actions under headings: Playback, Navigation, Bookmarks, Panels, Information, Library, and Audio Editor. `notificationName` names the notification each action posts; the editor's actions share `audioEditorShortcut`, which carries the action.
- **`ShortcutScope`** (line 201) has two cases, `.app` and `.audioEditor`. A key may mean one thing in an editor window and another elsewhere, but never two things in one scope.
- **`KeyBinding`** (line 218) is one key press:
  - `key` holds a lower-case character or a named key: "space", "tab", "return", "delete", "escape", or one of the four arrows. Four flags hold the modifiers.
  - Three string forms: `displayString` uses symbols ("⌘I"), `accessibleDisplayString` uses words ("Command + I"), and `configText` is config.json's form ("command+i").
  - `init?(configText:)` reads that text generously: any letter case, spaces ignored, and cmd, ctrl, opt, and alt accepted.
  - `matches(_:)` (line 266) requires the event's Shift, Control, Option, and Command to equal the binding's exactly.
  - `from(event:)` (line 305) makes a binding from a key press, for the recorder.
- **The defaults** are `ShortcutAction.defaultBindings` (line 455) and `audioEditorDefaultBindings` (line 580):
  - Each action has at most two keys. Release Media Controls and the two reading-list actions have none.
  - In the app's scope, Where Am I? is W, Speak Info is I (since October 7), and Book Info is Command-I.
  - In the editor's scope, Where Am I? is W and Mark In is I.

  Two tests pin that no key is the default of two actions in one scope: `SpeakInfoShortcutTests.testThePlainIIsNoOtherAppShortcutAndBookInfoKeepsCommandI` and `AudioEditorShortcutTests.testTheEditorsDefaultsClashWithNothingInTheirGroup`.
- **Defaults that changed.** Only two existing actions have ever changed their defaults; every other change added an action.
  - Move Book Up and Move Book Down went from Control-Option-Up and Control-Option-Down to Shift-Command-Up and Shift-Command-Down (1ec35f02, March 22).
  - Next Bookmark went from Shift-Command-B to Option-Shift-Command-B (ffb538b1, March 24), when Shift-Command-B went to the new Show Bookmarks.

### 1.2 KeyboardShortcutManager (Services/KeyboardShortcutManager.swift)

- **One for the app.** TextMouthApp creates it as a `@StateObject` and hands it to Settings as an environment object.
- **Matching.** A local key-down monitor (line 184) calls `handleKeyEvent` (line 197), which:
  1. Finds the key window's scope with `scope(ofKeyWindow:)`: the editor's scope in an editor window, no scope in a sheet over one, and the app's scope anywhere else.
  2. Walks `bindings`, a dictionary, through the actions of that scope.
  3. On the first binding that matches, posts the action's notification and consumes the key press. The notification carries the action and the key window as `sourceWindow`, so that only that window acts (`WindowCommandRouting`). It can also carry `shiftHeld`, which section 9 finds is never set.

  Nothing looks at `NSEvent.isARepeat`, so a held key acts once per repeat.
- **Text fields.** `shouldHandle(binding:whenTextInputIsFocused:)` (line 270) leaves a key to a focused text field unless the binding holds Command or Control. A binding with only Shift or Option counts as a plain key. `isTextInputFocused()` (line 284) checks whether the first responder is an `NSTextView` or an `NSTextField`. The reader draws its text without an `NSTextView`, so plain keys reach the manager there.
- **Saving.** `bindingsPreference` (line 47) keeps the map under `customKeyboardBindings`, as JSON keyed by raw value.
  - Reading decodes the whole map. If any part cannot be decoded, every action gets its defaults.
  - `bindings(addingDefaultsTo:)` (line 66) then gives each action the map leaves out its defaults, less any key another action of its scope already holds. That rule arrived on August 7 (3aa3fa2b).
  - Writing saves the whole `bindings` map, which holds every action once it is loaded. So the user's first change saves every action, and after that no changed default reaches an action already saved. Only actions added later get their defaults.
- **Changes.**
  - `addBinding(_:to:)` (line 137) takes the key away from every other action of its scope.
  - `updateBindings(for:to:)` (line 132) replaces an action's list without that check.
  - `removeBinding(_:from:)` removes one key, and `resetToDefaults()` resets every action.

  A `PreferenceObserver` picks up changes others write to the store, such as config.json being applied.

### 1.3 config.json

- **The field** is `keyboardShortcuts` in `ConfigService.AppConfig` (line 351), of type `[String: [String]]`. It names each action by its raw value with a list of `configText` strings; an empty list means no key.
  - `SettingsPolicy.keyboardShortcuts` (line 434) is the `KeyedSettingRule` that reads and writes the field.
  - `LenientFields.entries` (line 186) logs and skips a name it does not know ("names nothing TextMouth knows; ignoring it") and an entry it cannot read, in which case the action keeps its keys.
  - `Portability.mirrored` pairs the store key `customKeyboardBindings` with the field.
- **Writing.** `SettingsViewModel.writeServicePreferences` (line 916) writes every action. README says so, and `ConfigSyncTests.testShortcutsReachTheShortcutManagerAndAreSaved` pins it.
- **Applying.** `adoptServicePreferences` (line 984) puts the file's entries in place through `KeyboardShortcutManager.bindings(_:adopting:)` (line 98). Each named action takes exactly the keys listed for it, and any other action loses a key a named action takes. But the file names every action. So if a key is added by hand to a second action and not removed from the first, both keep it.
- **At launch,** `ConfigService.loadFromDisk` (line 869) reads the file, and `SettingsViewModel.startConfigSync` (line 514) applies it before anything else, then saves.
  - `lastSyncedConfig` (line 140) is the merge base that tells TextMouth's own changes from an edit's, used by `merging(ours:theirs:base:)` (line 1007).
  - It is kept only in memory, so after a relaunch the file's listing is taken as it stands.

### 1.4 This user's shortcuts

From config.json, read once and read-only:

- **What it lists.** The file was last saved at 11:05 on October 7, by a build without Speak Info. That matches the installed build of October 5 that AGENTS.md records. It lists 72 actions, every action that build has. Speak Info and the two reading-list actions are newer. They get their defaults (I, none, and none) when a newer build first loads the store.
- **70 actions are exactly at today's defaults.** Two differ:
  - Release Media Controls has Shift-R. That action was added on May 9 without a default, so Shift-R is the user's own choice.
  - Next Bookmark has Shift-Command-B. That was its default until March 24, when the default became Option-Shift-Command-B. The saved map, written when the user first changed something, kept the old key.
- **One key on two actions.** Shift-Command-B is also Show Bookmarks' key. It became that action's default on March 24, before the August 7 rule that keeps a new default off a key already in use. Here is what follows:
  - `handleKeyEvent` takes the first match in a Swift dictionary.
  - A dictionary's order can change from one launch to the next.
  - So Shift-Command-B can open the bookmark list at one launch and move to the next bookmark at another.

  Until the record lands, either of these leaves Shift-Command-B to Show Bookmarks alone:
  - In config.json, change Next Bookmark's entry to `["option+shift+command+b"]`.
  - In the Shortcuts tab, remove Shift-Command-B from Next Bookmark, then add Option-Shift-Command-B.
- **What was not read.** The preferences store was not read. TextMouth writes it and config.json together, so the store is taken to hold the same.

### 1.5 The Shortcuts tab (Views/Settings/KeyboardShortcutsSettingsView.swift)

- **Layout.** The tab is a form with a section per category, headed by the category's name, and a row per action (`ShortcutBindingRow`). A row holds:
  - the action's title;
  - a button for each key (`ShortcutRecorderButton`), labelled in words, such as "Command + I";
  - after each key, a remove button, such as "Remove shortcut Command + I from Book Info";
  - "Add shortcut", while the action has fewer than three keys.

  Each row is a container whose VoiceOver label is "<name>: <keys>". The keys come from `allDisplayStrings(for:)` (line 175) in symbols: ⌘I, ⇧⌘B, and arrows. A braille display shows them as those symbol characters.
- **Recording, as VoiceOver meets it.**
  - VO-Space on "Add shortcut", or on a key's button, starts recording. The button's label becomes "Recording shortcut. Press a key.", with the hint "Press any key to set, or click to cancel".
  - `ShortcutRecorderEventHandler` installs its own key-down monitor, and the next key pressed is recorded.
  - Escape cancels the recording. So Escape cannot be recorded here, although the editor's Clear Selection has it by default.
  - Nothing is announced. The button's label becomes the key in words, which VoiceOver says the next time it reads the button.
- **Where the recorded key goes.**
  - A key recorded on "Add shortcut" is silently taken from any other action of its scope (`addBinding`).
  - A key recorded on an existing key's button replaces that key through `updateBindings`, which never takes it from another action. That path can leave one key on two actions.
- **Resetting.** "Reset to Defaults" resets every action, after asking. A single action cannot be reset.

### 1.6 The menus

- **Customizable actions show no keys in the menus.** Their menu items (Play / Pause, Where Am I?, Speak Info, Book Info, and the rest) carry no key equivalent. The manager handles their keys and says which window they were pressed in. A SwiftUI `keyboardShortcut` on the item would post a second notification without the window, as comments in MenuCommands.swift say. So a VoiceOver user learns these keys from the Shortcuts tab, not from the menus.
- **Some commands have fixed keys,** outside `ShortcutAction` and config.json:
  - File menu: Open Book… (Command-O), New from Text… (Shift-Command-T), and New Recording… (Option-Command-N, `RecordingShortcuts.newRecording`).
  - Library menu: Import DAISY Folder… (Shift-Command-O) and Add Feed… (Shift-Command-F, `FeedShortcuts.addFeed`).
  - Playback menu: Copy Reading Position (Shift-Command-P) and Search in Book (Command-F).
  - Recording window: Record (Command-R), Pause or Resume (Command-P), and Stop (Command-period), all in `RecordingShortcuts`.
  - The sheets' Return and Escape buttons, and AppKit's own menu items: Quit, Close, Settings, and the Edit menu.
- **A menu key equivalent is a single key press.** No menu can show or take a double press.

### 1.7 MediaGestureDetector (Services/MediaGestureDetector.swift)

- **What it does.** It times a pattern of up to 8 media commands, by default Previous Track three times, within a window: 2 seconds by default, 0.5 to 10, set in Miscellaneous settings (`restartTimerGestureWindow`). The window is measured from the pattern's latest event back over the whole pattern.
  - `recordEvent(_:at:)` takes the time as a parameter, so tests can supply it.
  - A lock guards its state, because MediaPlayer can call it from any queue.
- **It acts at once, and the last press takes over.** Every press before the last does what it always does. `NowPlayingService.consumeForGesture` consumes only the pattern's last press and posts Restart Sleep Timer. A brief-then-full pair needs this same policy.
- **Why the keyboard should not share its type.** It never waits, and its patterns are made of different commands, not of one key pressed twice. The keyboard needs a pending single press and a timer, and runs on the main thread. So the double-press code should share its approach, with the time passed in and the state cleared after a match, but not the type.

### 1.8 The summaries: Where Am I? and Speak Info

- **Where Am I?** is `ReaderViewModel.whereAmI()` in ReaderViewModel+WhereAmI.swift.
  - A press while an announcement speaks stops it and resumes the book.
  - Otherwise the book pauses and the brief summary speaks. The full summary speaks instead when `shouldUseFullWhereAmI(last:now:)` finds the press within `whereAmIEscalationInterval` (3 seconds) of the press that started the last announcement.
- **Speak Info** is `LibraryInfoSpeaker.press(voice:wordsPerMinute:now:subject:)`, in the Library window. It follows the same rule with the same interval (`escalationInterval`).
- **In practice, the full summary takes three presses.** A brief summary usually lasts longer than 3 seconds, so a second quick press stops it, and the full summary needs a third press within 3 seconds of the first. README says so ("three quick presses"), and REV07 (6) recorded it.
- **Recent and queued work on these files:**
  - `fix/october-7-followups`, merged as cb134bb1, changed ReaderViewModel+WhereAmI.swift so that a cancelled announcement is heard and its synthesizer replaced (c2fa4d94). The three-second rule above is unchanged.
  - Two of REV07's Library items are queued for LibraryInfoSpeaker.swift and LibraryView.swift. Item (2): a press on another row while a summary speaks says nothing, and the full summary is not tied to the row. Item (4): Speak Info's speaking flag stays set after a cancel it did not cause (board #1378).

## 2. Double presses

### 2.1 How a binding says "pressed twice"

- **In the model,** `KeyBinding` gains `isDoublePress: Bool`, false by default, so every `KeyBinding(key: …)` written today stays valid.
  - The flag is saved only when it is true, so a single key is saved as it is today.
  - It is read with `decodeIfPresent` in a hand-written `init(from:)`. This is required: Swift's synthesized decoding needs the key of every stored property that is not optional, even one with a default value. And when the map fails to decode, `bindingsPreference` gives every action its defaults. A synthesized `isDoublePress` would therefore make the first launch of the new build read this user's shortcuts as all defaults. Only config.json, applied at launch, would bring them back. A test must decode a map saved in today's form.
- **Matching.** A double W and a single W are different bindings, since `Hashable` includes the flag. A key press is matched against `stroke`, the same binding as a single press. `matches(_:)` keeps matching the stroke, and the dispatcher (2.4) decides whether a press is a single or the second of a double.
- **In config.json,** the word "twice" goes after the shortcut: "w twice", "command+i twice". It is read as generously as the rest: "twice" in any letter case, with or without the space before it, and "double w" too. TextMouth writes "w twice".
- **In words,** `accessibleDisplayString` adds " twice" ("W twice", "Command + I twice"), and so does `displayString` ("⌘I twice"). The screen, VoiceOver, braille, and config.json all use the same word.
- **In the Shortcuts tab:** see 6.1.

### 2.2 The double-press time

- **One time for every double press.** The setting is `shortcutDoublePressSeconds`, a `NumericSettingRule` in `SettingsPolicy`:
  - 0.5 seconds by default, from 0.2 to 2 seconds in tenths;
  - set at the top of the Shortcuts tab ("Double press time") and in config.json, where an out-of-range value is moved to the nearest allowed one, as every number there is.
- **How it is measured:** from the first key-down to the second, by the events' own timestamps (`NSEvent.timestamp`, which only moves forward). A second press counts as a double only if the gap is shorter than the time. A press at exactly the limit is a single, as `shouldUseFullWhereAmI` treats its own boundary.
- **Why one setting, not one per binding:** the user asked for "a time out". One value behaves the same on every key. A time per binding would add a control to every key's button and a number to every config.json entry.
- **Why not the Mac's double-click speed** (`NSEvent.doubleClickInterval`, the user's own setting in System Settings): it is tuned for a mouse button, and a value of TextMouth's own travels with config.json.
- **What it costs:** nothing on a key whose single action acts at once (2.3). It delays only a single press that waits, and no default key waits; a test pins that. So the time can be generous at no cost. Half a second leaves room for an unhurried second press.

### 2.3 One key with a single and a double action

Here a key means one key with the same modifiers, in one scope:

- **A single action only:** each press acts at once, as today.
- **A double action only:** the first press is taken, and nothing happens. A second press within the time runs the double action. With no second press, nothing happens.
- **A single action, and a double action that escalates it:** the first press runs the single action at once. A second press within the time runs the double action, which takes over.
- **A single action and an unrelated double action:**
  - The first press waits.
  - A second press within the time runs the double action, and the single action never runs.
  - With no second press, the single action runs when the time runs out, or at once if another key is pressed first.

How the cases are told apart:

- **A new property, `ShortcutAction.escalates: ShortcutAction?`,** fixed in code. Speak Full Info escalates Speak Info, and Where Am I? Full Summary escalates Where Am I?.
  - The rule follows the actions, not the keys. Whatever keys the user gives the pair, the single acts at once and the double takes over.
  - Any other pairing waits.
  - An action on both the single and the double press of one key counts as its own escalation: the second press runs it again.
  - There is no setting for this. These two are the only escalations in the app, and a later one would join the table in code.
- **Why not act at once for every pair:** the single action would always run first. With Next Sentence on J and Next Paragraph on J twice, a double J would move a sentence and then a paragraph.
- **Why not wait for every pair:** every press of I and W, the summary keys, would wait half a second before speaking.
- **A key with only a double action** takes its first press and does nothing with it. Passing that press on instead would let the key do whatever it does without the binding: in a list a letter can move the selection, and where nothing takes the key, macOS plays its error sound. The second press would then act on whatever that changed.

Rules for every case:

- A double press is the same key with the same modifiers, pressed twice in the same window.
- A held key's automatic repeats never count as presses. For a key with a double action they are taken and ignored; other keys repeat as they do today.
- A key typed into a text field never counts, and it clears a waiting press. A double binding with Command or Control works from a text field, as single ones do.
- After a double press acts, each further press of the same key that comes within the time of the one before is ignored. So three quick presses, the habit today's three-second rule teaches, give the full summary instead of stopping it.
- A waiting single press keeps its window and whether Shift was held, so it acts in the window where it was pressed, even after the time.

### 2.4 The dispatcher

- **A new type,** `ShortcutPressDispatcher` in Services/ShortcutPressDispatcher.swift, on the main actor, decides what each key press does.
  - It uses an index built from the effective bindings: for each scope, each key leads to its single action and its double action. The index is rebuilt whenever the bindings change.
  - `handleKeyEvent` hands it each press with four facts: whether a text field took the key, the window, the scope, and whether the press is a repeat. It then posts whatever the dispatcher decides.
  - The clock and the timer for a waiting single press are passed in, so tests run without waiting.
- **The index replaces the walk through the dictionary,** so which action a key triggers no longer depends on an order that can change between launches.

## 3. Brief and full summaries as actions of their own

- **Two new actions** in the Information group, in the app's scope:
  - `ShortcutAction.speakFullInfo`, "Speak Full Info", I twice by default. It posts `speakFullInfo`, and the Library window speaks the selected row's full summary through `LibraryInfoSpeaker`.
  - `ShortcutAction.whereAmIFull`, "Where Am I? Full Summary", W twice by default. It posts `whereAmIFull`, and the reader speaks the full announcement (`ReaderViewModel.buildFullWhereAmI`).
- **Unchanged keys.** Speak Info keeps I, Where Am I? keeps W, and Book Info keeps Command-I. The audio editor's actions do not change.
- **Menu items** (question 8): Library > Speak Full Info after Speak Info, and Playback > Where Am I? Full Summary after Where Am I?. Like their neighbors, they carry no key equivalent.
- **What each press does:**
  - Speak Info or Where Am I?: with nothing speaking, it speaks the brief summary. With a summary speaking, it stops it.
  - Speak Full Info or Where Am I? Full Summary: with nothing speaking, it speaks the full summary. With the brief summary speaking, it stops the brief one and speaks the full one. With the full summary speaking, it stops it.
  - Where Am I? pauses and resumes the book as it does today, for the full summary too.
- **How the user's yes is met:** the first I starts the brief summary at once. A second I within the double-press time is a double press, so Speak Full Info switches to the full summary. "A press while it speaks stops it" still holds for a single press after the double-press time (question 3).
- **The three-second rule is no longer needed.** That is `whereAmIEscalationInterval`, `shouldUseFullWhereAmI`, and `LibraryInfoSpeaker.escalationInterval`. With a key of its own for each summary, the brief action always speaks the brief summary. Retiring the rule (question 4) means a press of I just after a summary ends can no longer speak the full summary unasked.
- **Without the double press.** A user who removes the double press from Speak Full Info can still reach the full summary from the menu. Nothing else changes.
- **The reader** has no Speak Info (FR07 left the reader's I key out), and nothing changes there.

## 4. A record of your edits

### 4.1 The record

- **What it holds.** `ShortcutEdits`, a new type in Models/ShortcutEdits.swift, is kept under a new store key, `keyboardShortcutEdits`. It holds the actions the user edited, each with its keys. It is saved in the same form as today's map, but holds only those actions.
  - An action is edited exactly when it is in the record.
  - An action edited to have no key holds an empty list.
- **How it is like `Book.HandEdits`:**
  - It names what the user changed.
  - It is decoded entry by entry and leniently. An entry a newer build wrote, or one that cannot be read, is left out and logged; the rest of the record still loads.
  - Its entries are written in `ShortcutAction.allCases` order, so the same record is always the same bytes.
  - Nothing removes an entry except the user.
- **How it differs from `Book.HandEdits`:**
  - It holds the keys themselves. An unedited action's keys are stored nowhere; they come from the defaults of the build that runs.
  - It has no `sinceImport` flag, since the move from today's map (4.2) decides every action at once.
- **The bindings in force** come from one pure function of the record and the build's defaults, `ShortcutEdits.effectiveBindings(defaults:)`, applied in Settings order:
  - An edited action has its own keys.
  - An unedited action has its defaults, less any key an edited action of its scope holds.

  The manager's `bindings` come only from this function, and every change goes through the record and the function. The rule that a key belongs to one action of each scope is then enforced in one place, and the replace path of 1.5 can no longer break it.
- **What marks an action edited:** any change the user makes to its keys. That includes recording, replacing, or removing a key in the Shortcuts tab, making a key a double press, and editing the action in config.json (5.1).
- **What does not mark it:** losing a key because the user gave that key to another action. The unedited action then simply lacks that key, and gets it back if the other action is reset. An edited action that loses a key this way keeps its other keys and stays edited.
- **An edited action set back to its default keys stays edited** (question 5), as a metadata field edited back to its earlier value stays the user's own.
- **Leaving the record:**
  - Reset to Default, for one action. This is new: a button on an edited action's row, and a VoiceOver action.
  - Reset to Defaults, for every action.
  - In config.json, writing "default" for the action.
- **New and changed defaults** reach every unedited action at the next launch, and never an edited one. That covers a new action, such as the reading list's or import progress's, and a changed default. If a new default would take a key an edited action holds, the edited action keeps it and the new default goes without it, as `bindings(addingDefaultsTo:)` already does for new actions.
- **In the Shortcuts tab,** an edited action's row says so after its keys: "Release Media Controls: Shift + R. Edited." Book Info's metadata says "edited by hand"; for shortcuts, "Edited" alone reads more plainly. The build pins the word.

### 4.2 From today's saved map to the record

- **When:** once, at the first launch that finds no `keyboardShortcutEdits` in the store, with or without a saved map.
  - If config.json is already in the new form (any entry written "default"), it is read as 5.1 says, and nothing is migrated.
  - Otherwise the steps below take the place of applying config.json's shortcuts at that launch, since step 1 reads them itself. Applying the old file's lists afterwards would mark every action edited.
  - The record is written at that launch, and the launch's save writes config.json in the new form.
  - `customKeyboardBindings`, when there is one, is left as it is and never written again, so it remains as a copy to go back to.
- **The rule,** for each action in Settings order:
  1. Its keys are the ones config.json lists for it when they differ from the saved map's. The old build wrote the two together, so a difference means an edit made in the file while TextMouth was closed. Otherwise its keys are the saved map's. Without a saved map (a user who never changed a shortcut), its keys are the file's, which the old build wrote from its defaults. An action that neither the file nor the map lists is unedited.
  2. It is unedited when those keys are its default, either whole or less keys that other actions of its scope hold in the saved map. A key the user gave to another action leaves this one without it, and does not make this one the user's. The default can be today's or the one the action had before. Former defaults come from a migration-only table, `ShortcutAction.formerDefaultBindings`: Next Bookmark's Shift-Command-B, and the Control-Option arrows of Move Book Up and Move Book Down.
  3. Otherwise it is edited, with those keys.
  4. The bindings in force are then computed (4.1). A key that two edited actions share goes as 5.2 says.
- **An action equal to its default counts as unedited,** so from then on it follows the defaults. Counting it as edited would freeze old defaults, as the saved map did; that is how Next Bookmark came to share Shift-Command-B.
- **What this means for this user:**
  - Edited: Release Media Controls (Shift-R).
  - Next Bookmark holds a former default, so it counts as unedited and takes today's Option-Shift-Command-B. Shift-Command-B stays with Show Bookmarks alone.
  - Every other action is at its default and unedited.
  - Speak Info gets I, and the two reading-list actions have no key. Speak Full Info gets I twice, and Where Am I? Full Summary gets W twice.

  So one key changes for this user: Shift-Command-B no longer moves to the next bookmark at some launches (question 6).
- **Tests** build saved maps of the same shape: an old default, a key lost to another action, a key on two actions, and a hand edit in the file. None of them reads the live file.

## 5. Every shortcut in config.json

### 5.1 The listing

- **Every action, in one of two forms.** `keyboardShortcuts` keeps its name and lists every action by the name Settings shows (the audio editor's with "Audio Editor: " first), in the file's alphabetical order:
  - **An action you edited** is a list of its shortcuts, as today: `"Release Media Controls": ["shift+r"]`. An empty list leaves it with no key.
  - **Every other action** is text beginning with "default", followed by its keys in force: `"Where Am I?": "default: w"`, `"Play / Pause": "default: space, k"`, `"Speak Full Info": "default: i twice"`, or `"Add to Reading List": "default: none"`.
- **How each entry is read:**
  - A list: the action becomes yours, edited, with those keys.
  - Text beginning with "default", in any letter case: the action follows TextMouth's defaults. An edited action goes back to them, as Reset to Default does.
  - Any other text: one shortcut, read as a list of one.
  - An action left out keeps what it has, as today. An entry that cannot be read is logged, and the action keeps what it has, as today.
- **The text after "default" is never read back.** It says what the action has, and changing it changes nothing. To change an action, write a list. This is what lets a newer build's defaults reach every action written "default", however old the file: TextMouth never has to tell an older build's defaults from your edits.
- **Why this form,** rather than every action as a list with a separate list of edited names:
  - One entry says both the keys and whose they are, so the two can never disagree.
  - In a file of lists, telling a hand edit from an older build's defaults would need a hidden copy of what each Mac last wrote, kept in its preferences.
- **Double presses:** "w twice" (2.1). The double-press time is `shortcutDoublePressSeconds`: 0.2 to 2 seconds, 0.5 by default.
- **An excerpt,** as the file would read for this user:

```json
  "keyboardShortcuts" : {
    "Add Bookmark" : "default: command+b",
    "Add to Reading List" : "default: none",
    "Next Bookmark" : "default: option+shift+command+b",
    "Play / Pause" : "default: space, k",
    "Release Media Controls" : [
      "shift+r"
    ],
    "Show Bookmarks" : "default: shift+command+b",
    "Speak Full Info" : "default: i twice",
    "Speak Info" : "default: i",
    "Where Am I?" : "default: w",
    "Where Am I? Full Summary" : "default: w twice"
  },
  "shortcutDoublePressSeconds" : 0.5,
```

### 5.2 A key on two actions of one scope

- **The rule.** After any change, a key, whether a single or a double press, belongs to at most one action of each scope. ARCHITECTURE states this rule today; 1.3 and 1.4 show where it does not hold.
- **An unedited action never gets a key an edited action of its scope holds.**
- **Two edited actions with one key** can come only from a config.json edit, or from the saved map at the migration:
  - The action whose entry changed in that edit keeps the key, as recording a key in Settings takes it for the action recorded.
  - If both entries changed, or neither did (for example, a file edited while TextMouth was closed that lists one key twice), the action Settings lists first keeps it.
  - The other action loses that key and stays edited.
  - A line in the debug log names the key and both actions (`STORED_VALUE_REPAIRED`, as for other repairs), and the next save writes the result, so the file shows the keys in force.
- **A single press and a double press of one key are not a conflict;** 2.3 says how they share the key.
- **The two scopes stay apart,** as today: the audio editor's actions and the rest.

### 5.3 Names the file does not know

- **As today,** a name TextMouth does not know is logged and left out ("names nothing TextMouth knows; ignoring it"), and the next save drops it, since TextMouth writes the file from its record.
- **Names are matched ignoring letter case,** so "where am i?" means Where Am I?.
- **A renamed action keeps its old name readable** through a table of former names, so an edit made under the old name is kept. This plan renames nothing: Speak Info keeps its name.

### 5.4 The fixed menu shortcuts

- **They are not in config.json today.** These are the key equivalents in 1.6.
- **What making them editable takes:** each one becomes a `ShortcutAction` whose menu item reads its key from the manager. `LibraryCommands` already observes an object, `RemovalPreferencesModel`. Such a key must be a single press with Command or Control: a key equivalent has to work in a text field and with no window open, and no menu takes a double press.
- **macOS can already change them.** System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts changes any app's menu items by their titles. It should work for TextMouth's menus as for any app's; this was not tried.
- **AppKit's own commands stay out:** Quit, Close, Settings, and the Edit menu, and so do the sheets' Return and Escape buttons.

## 6. Accessibility

### 6.1 Recording a double press in the Shortcuts tab

- **The recorder.** "Add shortcut" and a key's button record as today, with one change: after the first press, the recorder waits the double-press time. The same key pressed again within that time records a double press; no second press records a single. The recording label says so: "Recording shortcut. Press a key, or press it twice for a double press."
- **Without timing two presses.** Each key's button offers "Make Double Press" or "Make Single Press", as a VoiceOver action (VO-Command-Space) and in its context menu.
- **Every recording is announced** through `VoiceOverAnnouncer`, wherever VoiceOver's cursor is: "W twice, recorded for Where Am I? Full Summary." If the key belonged to another action of the scope, the announcement adds "Taken from Play / Pause." Today a key moves silently.
- **A key that now waits is announced with its cost.** That is a key with an unrelated single and double action: "J now waits before Skip Backward, in case it is pressed twice."
- **The row's label** says the keys in words, not symbols: "Where Am I? Full Summary: W twice". An edited action's label adds "Edited." An edited row has "Reset to Default", which VoiceOver reads as "Reset Where Am I? Full Summary to Default".

### 6.2 Hearing the double-press time

- **A stepper** labelled "Double press time". VoiceOver speaks its value as "0.5 seconds", or "1 second" and "2 seconds", worded through `CountWording` as the Miscellaneous tab words its seconds. Its hint: "How soon a second press must follow the first to make a double press. A key with a different action for each waits this long before its single press acts."
- **Optional, small: "Try a Double Press."** For five seconds, the next two presses of any key are not treated as shortcuts. TextMouth then says "Double press", or "Two presses, 0.7 seconds apart. Set the time above 0.7 seconds to count them as one." This lets a user set the time by ear.

### 6.3 Braille

- **Every key is shown and spoken in words.** "Twice" is a word, and no label is made of symbols alone.
- **config.json reads as it is spoken.** Its forms, such as "default: w twice", read on a braille display the way they are spoken.

### 6.4 VoiceOver's own keys and plain-key shortcuts

- **The VoiceOver modifier.** Key combinations with the VoiceOver modifier (Control-Option, or Caps Lock) go to VoiceOver and never reach TextMouth. A TextMouth key with Control and Option therefore works only with VoiceOver off, or after VO-Tab, which tells VoiceOver to pass the next key combination to the app [2]. VO-Tab passes one combination, so it cannot pass a double press of such a key.
- **Quick Nav.**
  - With arrow-key Quick Nav on (VO-Shift-Q), VoiceOver uses the arrow keys to navigate.
  - With single-key Quick Nav on (VO-Q), single keys navigate [1].

  So while single-key Quick Nav is on, I, W, J, K, L, F, and B, their double presses, and this user's Shift-R may not reach TextMouth. Apple's page is titled for apps and webpages but does not say which apps single keys reach; this was not tried.
- **VoiceOver still speaks over TextMouth's own voice,** as it does with Where Am I? today. A double press does not change that.
- **Text fields.** Plain keys typed in a text field stay text, double presses included.

## 7. Questions for you

Each has a recommended answer.

1. **Should one double-press time serve every shortcut, half a second by default, set in the Shortcuts tab and in config.json?** Recommended: yes. One value behaves the same on every key. A time for each shortcut would add a control to every key.
2. **When one key has a single action and an unrelated double action, should the single action wait out the double-press time before acting?** Recommended: yes. Acting at once would do both: a sentence, then a paragraph. Refusing such pairs would take away what you asked for. No default key waits.
3. **After the double-press time, should a single press of I or W while a summary speaks still stop it?** Recommended: yes. It keeps a one-key way to silence a summary. A second press within the time switches to the full summary instead.
4. **Should the three-second rule be retired?** That rule makes a press within three seconds of the last summary's start speak the full summary. Recommended: yes. I twice and W twice speak the full summary, and I and W then always speak the brief one.
5. **If you set an edited action back to its default keys, should it stay yours until you choose Reset to Default?** Recommended: yes, as an edited metadata field stays yours.
6. **When your saved shortcuts move to the new record, should an action whose keys are its default, today's or an earlier one, count as never edited?** Recommended: yes. One edited action remains, Release Media Controls (Shift-R). Next Bookmark gets today's Option-Shift-Command-B, so Shift-Command-B only opens the bookmark list.
7. **Should the fixed menu shortcuts become editable in Settings and config.json too, in a later branch?** These are Open Book…, New from Text…, New Recording…, Import DAISY Folder…, Add Feed…, Copy Reading Position, Search in Book, and the recording window's three. Each would be a single press with Command or Control. Recommended: yes, after the three branches below. Meanwhile, System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts can change them.
8. **Should the Library menu have Speak Full Info, and the Playback menu Where Am I? Full Summary?** Recommended: yes. A command reached only by a double press would be hard to find.
9. **Should the new actions be named Speak Full Info and Where Am I? Full Summary?** These names become their keys in config.json. Recommended: yes.
10. **In config.json, should an action you have not edited read "default: w", and one you have edited a list such as ["shift+r"]?** You would write a list to make an action yours, and "default" to give it back. Recommended: yes. Each line then says whose keys it holds, and new defaults reach every "default" line.

## 8. Build plan

Three branches in order, each with its tests. A documentation pass writes the README and ARCHITECTURE wording afterwards.

### Wait for, or rebase onto

- **`feature/reading-list-reader`** (`readinglistreader`) adds Next in Reading List and Previous in Reading List to KeyboardShortcut.swift and MenuCommands.swift, and edits ReaderViewModel.swift.
- **`feature/import-progress`** (`importprogress`) may add an action with no key, which speaks the import's progress, to the same two files.
- **`fix/october-7-followups`** (`followups7`) is merged (cb134bb1). Branch C builds on its changes to ReaderViewModel+WhereAmI.swift, which split the end of an announcement into `whereAmISynthesizerFinished(_:)` and `whereAmISynthesizerCancelled(_:)`.
- **REV07's queued Library items (2) and (4)** change the press handling in LibraryInfoSpeaker.swift, which branch C rewrites. Fold them into branch C, or run them first.
- **FR11's branch B** (`feature/feed-item-policy`) adds preferences to the config.json mirror in SettingsViewModel.swift and ConfigService.swift, as branches A and B here do. The lines are adjacent; rebase keeping both sides.

### Branch A: `feature/shortcut-edit-record`

- **What it changes:**
  - `ShortcutEdits`, in the new Models/ShortcutEdits.swift: the record, its lenient decoding, its fixed order, and `effectiveBindings(defaults:)`.
  - `KeyboardShortcutManager`:
    - `editsPreference`, under `keyboardShortcutEdits`, in place of `bindingsPreference`;
    - `bindings` derived from the record;
    - every change going through the record: `addBinding`, `updateBindings`, `removeBinding`, a new `resetToDefault(_:)`, and `resetToDefaults()`;
    - the conflict rule, in one place.
  - The migration (4.2), with `ShortcutAction.formerDefaultBindings`.
  - config.json's two forms:
    - a decodable `ShortcutListing`, a list or text, for `AppConfig.keyboardShortcuts`;
    - `SettingsPolicy.keyboardShortcuts`, and `SettingsViewModel.writeServicePreferences` and `adoptServicePreferences`;
    - the conflict rule of 5.2 with its log line;
    - names matched ignoring letter case;
    - `Portability.mirrored` pairing `keyboardShortcutEdits` with the field, and `customKeyboardBindings` listed as a key read only once.
  - The Shortcuts tab: the row's label in words, "Edited", Reset to Default on each edited row (a button and a VoiceOver action), and the recording announcement with "Taken from …".
- **Tests:**
  - The record: decoding (today's map form, unknown names, unreadable entries) and its bytes.
  - `effectiveBindings`:
    - a changed default reaches an unedited action and never an edited one;
    - a new default's key held by an edited action stays with it;
    - a key lost to another action comes back when that action is reset.
  - The migration: keys equal to the default, a former default, a key lost to another action, a key on two actions, a hand edit made in the file while TextMouth was closed, no saved map, and a file already in the new form.
  - config.json:
    - a list, "default", other text, an action left out, and an unreadable entry;
    - two edited actions with one key: one changed, both changed, and neither changed;
    - a round trip, and the excerpt of 5.1.
  - The replace path no longer leaves a key on two actions.
  - Existing tests updated: the shortcut tests in `ConfigSyncTests`, `ImportAndShortcutPolicyTests`, `SpeakInfoShortcutTests.testAnOlderCustomIKeepsItsActionAndLeavesSpeakInfoUnbound`, `AudioEditorShortcutTests`, the shortcut merge in `ConfigWatcherTests`, `PreferenceStoreTests`, `SettingsPolicyTests`, and the legacy runner's TextMouthTests/Sources/Tests/KeyboardShortcutTests.swift.
- **Size:** about 500 lines, with 650 lines of tests.
- **Risk:** this is the branch that could lose the user's shortcuts. The old key is never written again, and the migration is tested on maps shaped like this user's.

### Branch B: `feature/double-press-shortcuts`

- **What it changes:**
  - `KeyBinding.isDoublePress` with its decoding, `stroke`, the words, and "twice" in config text.
  - `ShortcutPressDispatcher`, in the new Services/ShortcutPressDispatcher.swift, and its index. `handleKeyEvent` hands each press to it, with repeats, text fields, and windows.
  - `SettingsPolicy.shortcutDoublePressSeconds`, with its store key, its config.json field, and its place in the mirror.
  - The Shortcuts tab: the stepper, the recorder's double press, Make Double Press and Make Single Press, the "waits" announcement, and, optionally, Try a Double Press.
  - `ShortcutAction.escalates`, which stays empty until branch C.
  - Recommended, for finding 9: a focused text field keeps its own editing keys (Command with A, Delete, the four arrows, Z, X, C, or V). Every other Command or Control binding still acts from a field, as the sleep timer's field needs.
- **Tests:**
  - decoding a map saved before the flag existed, and the config text both ways;
  - a field's editing keys staying with the field, while another Command binding still acts from it;
  - the dispatcher's four cases;
  - the boundary: a press at exactly the time is a single;
  - another key pressed while a single press waits, a second window, a text field, repeats, and the ignored presses after a double;
  - a waiting single press keeping its window and Shift;
  - the setting's rule and its mirror;
  - no default key waits: no default key has a single and an unrelated double action in one scope;
  - the recorder's wording, pinned by static constants.
- **Size:** about 550 lines, with 700 lines of tests.
- **Risk:** timing. Every test passes the clock in, and none sleeps. These need a check by hand: how the time feels, VoiceOver's speech during a double press, and the recorder with VoiceOver on.

### Branch C: `feature/full-summary-actions`

- **What it changes:**
  - `ShortcutAction.speakFullInfo` and `.whereAmIFull`, with their defaults, notifications, menu items, and `escalates`.
  - `LibraryInfoSpeaker`, with a brief press and a full press, plus REV07 Library (2) and (4) if they are folded in.
  - `ReaderViewModel.whereAmI()`, split into the brief and the full action, with Where Am I?'s pausing unchanged.
  - The three-second rule, removed (question 4).
- **Tests:**
  - the actions, their keys, and their menu items;
  - each press with nothing speaking, with the brief summary speaking, and with the full one speaking;
  - a double I and a double W through the dispatcher;
  - Where Am I? pausing and resuming the book with the full action.
- **Size:** about 250 lines, with 350 lines of tests.
- **Risk:** none to data. README's "three quick presses" paragraph and its description of Speak Info change.

### Branch D, after question 7: `feature/editable-menu-shortcuts`

- **What it changes:** each fixed menu shortcut becomes a `ShortcutAction` whose menu item reads its key from the manager.
  - It is limited to single presses with Command or Control.
  - The conflict rule is extended to these keys.
- **Size:** about 300 lines, with 300 lines of tests.

### Documentation, after each merge

- **README:**
  - the Shortcuts tab (Settings, in tabs);
  - Speak Info and its "three quick presses" paragraph;
  - the Playback menu;
  - the Shortcuts entry of "Editing settings in config.json".
- **ARCHITECTURE:**
  - the KeyboardShortcutManager entry under preferences;
  - the audio editor's Keys item;
  - the Speak Info entry.

## 9. Problems noticed on the way

Each was posted on the board as a finding. None was fixed here.

1. **One key on two actions in this user's data:** Shift-Command-B is both Next Bookmark's and Show Bookmarks', and `handleKeyEvent` takes the first match in a dictionary. File: Services/KeyboardShortcutManager.swift. Branch A's migration ends it; 1.4 gives a workaround until then.
2. **Replacing a key can leave it on two actions.** Recording on an existing key's button goes through `updateBindings(for:to:)`, which never takes the key from another action. Files: Views/Settings/KeyboardShortcutsSettingsView.swift (`ShortcutBindingRow.replaceBinding`) and Services/KeyboardShortcutManager.swift.
3. **config.json cannot move a key.** `bindings(_:adopting:)` takes keys only from actions the file leaves unnamed, and the file names every action. So a key added by hand to a second action stays on both. Two documents overstate this: README's config.json section ("a shortcut given to one action is taken from any other that works in the same windows") and ARCHITECTURE's preferences entry ("a key belonging to at most one action of each scope"). File: Services/KeyboardShortcutManager.swift.
4. **The Shift skip units cannot be reached from the keyboard.** `KeyBinding.matches(_:)` requires Shift to match exactly, so `hasExtraShift` in `handleKeyEvent` is never true and `shiftHeld` is never posted. Yet the Playback tab offers "Shift+Skip Forward" and "Shift+Skip Backward" units ("What happens when you hold Shift and skip forward"). This has been so since the first commit. Files: Models/KeyboardShortcut.swift and Services/KeyboardShortcutManager.swift.
5. **Increase Speed's default key cannot match on a US keyboard.** The default is Command with "+", without Shift, and on a US layout "+" is Shift-equals, so the binding never matches. The keypad's plus key would, and a key recorded in Settings does. File: Models/KeyboardShortcut.swift. This is read from the code; no key was pressed.
6. **A held key repeats its action.** Nothing checks `isARepeat`, so a held I or W starts and stops its summary over and over. File: Services/KeyboardShortcutManager.swift. Branch B covers keys with a double action.
7. **Saved shortcuts are read all or nothing.** If `bindingsPreference` cannot decode one entry, every action reads as its default, and only config.json, applied at launch, brings the user's keys back. File: Services/KeyboardShortcutManager.swift. Branch A's lenient record replaces it.
8. **The Shortcuts row's VoiceOver label uses symbols.** It comes from `allDisplayStrings(for:)`, which uses `displayString`, while each key's button uses words. Files: Services/KeyboardShortcutManager.swift and Views/Settings/KeyboardShortcutsSettingsView.swift. Branch A changes it.
9. **Command keys are taken from text fields, including the fields' own editing keys.** Every Command binding acts from a text field (`shouldHandle`), and the manager consumes the key, so the field's own command never runs:
   - Command-A, Select All's default, selects every book in the Library and enters Edit Mode, instead of selecting the field's text.
   - Command-Delete, which deletes to the start of the line in a field, posts Remove from Library for the selected books. That removal asks first only when `confirmBeforeDelete` is on, a setting kept only in config.json.
   - Command-Left Arrow and Command-Right Arrow, the skip keys, never move a field's cursor to the start or end of the line.

   Files: Services/KeyboardShortcutManager.swift (`shouldHandle`) and Views/Library/LibraryView.swift (the `selectAll` and `removeFromLibrary` handlers). This is read from the code. Branch B is the natural place to let a focused field keep its editing keys.
10. **Recording a key can take a system command.** The Shortcuts tab records any key, Command-Q included, and the manager sees keys before the menus do, so binding Command-Q to an action would stop it from quitting. Escape cannot be recorded at all. File: Views/Settings/KeyboardShortcutsSettingsView.swift. Minor.

## What I could not verify

- **No key was pressed.** Shift-Command-B's dispatch order, the repeats of a held key, Increase Speed's default on a US keyboard, Command-A in the search field, and the recorder with VoiceOver are all read from the code.
- **Only config.json was read.** The preferences store was not; config.json mirrors it.
- **Two VoiceOver behaviors come from Apple's guide,** not from trying them: how far single-key Quick Nav reaches into apps, and VO-Tab passing a key on.
- **App Shortcuts was not tried** on TextMouth's menus.
- **The list of fixed keys in 1.6** comes from a search of the source for `keyboardShortcut(`.

## Sources

1. Apple, "Use VoiceOver Quick Nav in apps and webpages on Mac", VoiceOver User Guide: https://support.apple.com/guide/voiceover/quick-nav-vo27943/mac
2. Apple, "Make VoiceOver ignore the next keypress on Mac", VoiceOver User Guide: https://support.apple.com/guide/voiceover/vo2722/mac
3. Apple, `NSEvent.doubleClickInterval`, AppKit documentation: https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval
