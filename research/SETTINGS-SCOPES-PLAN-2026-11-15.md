# Speech and playback settings for a feed, a folder, or the Reading List: a plan (November 15, 2026)

Branch `research/settings-scopes`, designer `scopeplan`, FR23 in `TODO-2026-09-04.md`.
Brief: `Scripts/agents/briefs/2026-11-15/scopeplan.md`.
Line numbers are those of main at d425dd20f.

The user, November 15: "allow a nother level of scope for speech settings like speed (is pitch supported in the app? that might be another thing) but for feeds to have a global settings for audio or text, a feed setting, and a local setting."
And: "maybe have one for folders and the reading list too when opening a book in it, but you have to open the folder's / feeds settings sheet to set that you want the scope".

## 1. The answer

1. A feed, a folder, and the Reading List may each keep a *scope*: its own voice, speed, and pitch for books read aloud, and its own speed for audio, the two turned on apart.
2. A scope is off until a checkbox in that feed's, folder's, or list's settings sheet turns it on, and turning it on changes nothing by itself: each value starts as "use the global one".
3. Each setting comes from the nearest place that sets it: the book, then the Reading List (when the book was opened from it), then the feed or the folders around the book, then the global settings.
4. While a scope is on, a change of speed, voice, or pitch made in the reader changes the scope, and the reader says so: "1.5 times speed, for this feed".
   A book that should differ is set to "This book only" in its own settings sheet.
5. Pitch is supported today, for text: a global Default Pitch and a book's own.
   Audio has speed only.
6. Audio has no global speed today, though the request assumes one: an audiobook with no speed of its own plays at 1 times speed.
   The plan adds a global audio speed first (question 1).
7. No field is added to a book.
   One key, `playbackScope`, is added to a feed's record, a folder's entry, and the reading list, and one key, `audioSpeed`, to `config.json`.

## 2. What is true today

- **Global, text.**
  `selectedVoiceID`, `wordsPerMinute` (50 to 650, default 200), and `pitchMultiplier` (0.5 to 2.0) in `config.json` (`SettingsPolicy.swift:373-378`), set in Settings, Voice (`VoiceSettingsView`, `SettingsView.swift:156`).
  A change posts `.speechSettingsChanged` (`SettingsViewModel.swift:1251`), and every open reader applies it again (`ReaderViewModel.swift:1493-1502`).
- **Global, audio.**
  None.
  `ReaderViewModel.audioSpeed` starts at `AudioSpeed.normal` (`ReaderViewModel.swift:410`), and Reset sets it back to that (`ReaderViewModel+VoiceAndSpeed.swift:158-161`).
- **A book's own.**
  `localVoiceID`, `localWPM`, and `localPitch` on `Book` (`hasLocalVoiceSettings`, `Book.swift:1472`).
  An audiobook keeps its speed, a multiplier from 0.25 to 4.0, in `localWPM` (`ReaderViewModel+Playback.swift:2850-2861`).
- **Every change in the reader becomes the book's own.**
  A speed step writes `book.localWPM` (`adjustSpeed(delta:)`, `ReaderViewModel+VoiceAndSpeed.swift:33-43`), a pitch change `localPitch` (`:46`), a voice `localVoiceID` (`:57`), and an audio speed `localWPM` (`setAudioSpeed(_:)`).
  So each episode of a podcast starts at 1 times speed and keeps whatever its listener then sets, for that episode alone: the cost FR23 removes.
- **Where a reader takes its settings**, in three places that the plan makes one:
  `applyLocalSpeechOverrides()` (`ReaderViewModel+VoiceAndSpeed.swift:86`), `applyGlobalSpeechSettingsWhereTheBookKeepsNone()` (`:174`), and the audiobook's restore as the reader opens (`ReaderViewModel.swift:922-929`).
  Speech export resolves on its own (`SpeechExportVoiceSettings.of`, `SpeechExportVoice.swift:48`), and so does an audiobook's time remaining (`Book.swift:1751`).
- **The sheets.**
  Feed Info (`FeedInfoSheet.swift:386`, `ownSettings(noun:)`) and Folder Settings (`FolderSettingsSheet.swift:177`) hold the listening options (`ListeningOptions`, FR19), saved as each is chosen.
  The toolbar's Feed Settings or Folder Settings button and the Library menu's command open them (`LibraryFolderSettingsTarget.swift:44`, `LibraryView.swift:1841`).
  The Reading List has no sheet: its options are a bar of controls (`ReadingListOptionsBar.swift:20`), and the settings command does nothing there.
- **The one rule that already has these layers** is `EndOfBookRule.resolve` (`EndOfBookRule.swift:44`): the Reading List, the book, the feed or folder, the global setting.
  The resolver below follows its shape.
- **The iPhone app** has no Feed Info or Folder Settings sheet (nothing under `TextMouth/Phone/` reads `listeningOptions`), and shares the reader's code.

## 3. The scopes and their order

Text speech and audio playback are two kinds, resolved apart: a feed may set an audio speed and leave speech alone.
Within a kind each setting is resolved by itself, so a book may keep its own speed and take its voice from its folder.

For a book that is an item of a feed, nearest first:

1. the book's own value;
2. the Reading List's scope, when the reader reads the book from the list (`isOpenedFromReadingList`, `ReaderViewModel+ReadingList.swift:21`);
3. the feed's scope;
4. the scope of each folder above the feed's folder (`Feed.folderID`), innermost first;
5. the global setting.

For any other book, step 3 is the folder that holds it and step 4 the folders above that one.
A scope that is off, or on with that value left at "use the global one", is passed over.

The cases the brief names:

- **A book in a folder, opened from the Reading List.**
  The list's scope wins over the folder's, as the list's "When a book ends" already wins.
  The same book opened from its folder takes the folder's.
  With the list's scope off, which is how it starts, the list changes nothing (question 3).
- **A feed's episode moved to the library.**
  Move to Library clears the book's feed link (`LibraryViewModel+MoveToLibrary.swift:241`), so the book takes the settings of the folder it now lives in, then the global ones.
  Nothing is copied onto it: a book follows where it is, as a book moved between two folders does (question 5).
  Its own values, if it had any, go with it.
- **A folder inside a folder.**
  The inner folder's scope wins, and a book in a folder with no scope takes the nearest scope above it.
  This differs from the listening options, which reach only the books directly in a folder (`LibraryViewModel+ListeningOptions.swift:27-38`); a voice for a folder of French books should reach its authors' folders (question 4).
  Folders are at most four deep (`BookFolder.maxDepth`), so the walk is short.
- **A setting changed while a book plays.**
  Every open reader resolves again at once and applies the result as it applies a global change today: speed and pitch as the audio plays, a voice with a fresh look-ahead.
  Only the window where the change was made speaks; a reader in another window changes without a word.
  A book moved to another folder, taken off the Reading List, or moved to the library while open resolves again the same way.

## 4. Turning a scope on

In Feed Info, in Folder Settings, and in a new Reading List Settings sheet, one shared group of controls, under the heading "Voice and Speed".

- A checkbox turns the speech scope on, and a second the audio scope.
  While one is off, its controls are not in the sheet at all, so a sheet nobody uses this in gains two checkboxes and nothing else.
- Turned on, every value starts at "use the global one".
  Nothing sounds different until a value is set in the sheet or changed in a reader.
- Turned off, the scope and its values are deleted, and its books go back to what lies further out.
- Feed Info shows the speech group for a feed of articles, the audio group for a feed of episodes, and both for a mixed feed, by the noun the sheet already has (`FeedWording.ItemNoun`, `FeedWording.swift:139`).
  A feed with no items yet counts as episodes there; for these controls it shows both groups.
  Folder Settings and Reading List Settings show both.

**The Reading List's sheet.**
The settings command is the one the user named, so it gains a third target: at the Reading List, the toolbar button reads "Reading List Settings" and opens the new sheet (`LibraryFolderSettingsTarget` gains `.readingList`).
The options bar is left as it is: nine more controls in it would stand between the listener and the list (question 6).

**Books that already keep their own.**
Because every change in a reader has been saved on its book, many episodes of a feed will hold a speed of their own, and a book's own value wins.
While a scope is on, the sheet counts them, "12 episodes keep their own speed.", and offers "Remove Their Own Speed…", which asks once and then clears those values (`clearLocalVoiceSettings()`), so the whole feed follows the scope (question 7).

## 5. Changing a setting in the reader

A speed step, a pitch change, or a voice choice made in the reader goes to one *owner*, decided for each kind:

1. the book, when it keeps a value of its own of that kind (`hasLocalVoiceSettings` for speech; `localWPM` for audio);
2. otherwise the nearest scope of that kind that is on, in the order of section 3;
3. otherwise the book, as today.

So with no scope on, nothing changes.
With a scope on, the speed keys do what the user asked the scope for: set the feed's speed while listening to it.
The reader never asks: a question in the middle of a book, at each press of a speed key, is worse than either answer.
The announcement ends by naming the owner, so the listener always hears where the change went (section 6).

**One book kept apart.**
While a scope applies to the book, its settings sheet (`BookVoicePickerView`, `ReaderView.swift:816`) shows a pop-up button, "Changes apply to", in place of the Reset button:

- "This feed" (or "The folder Fiction", "The Reading List"): the book keeps nothing of its own.
  Choosing it is today's Reset: it clears the book's own values.
- "This book only": the book keeps its own.
  Choosing it copies the voice, speed, and pitch in force onto the book (the speed alone for an audiobook), so nothing sounds different at that moment.

A book with no scope around it has the sheet it has today.
Save to Global Settings stays, and copies the values in force, whatever their source.

## 6. What VoiceOver says

Every sentence lives in a new `PlaybackScopeWording` enum, with `BookSettingsWording` for the book sheet's additions.
Here "feed" stands for "folder" or "Reading List" in their sheets, "episodes" follows the feed's noun, and a value in parentheses is the global one at that moment.

**In Feed Info, Folder Settings, and Reading List Settings**, in the order VoiceOver meets them:

- Heading: "Voice and Speed".
- Checkbox: "This feed has its own voice, speed, and pitch".
  Hint: "When on, books read aloud here use the choices below unless a book has its own, and a change made while reading one changes it for the whole feed."
- Pop-up button: "Voice", first choice "Use the global voice (Samantha)", then the installed voices, from the picker the book's sheet uses.
- Checkbox: "Use the global speed (200 words per minute)", then the slider "Speed", value "275 words per minute", dimmed while the checkbox is on.
- Checkbox: "Use the global pitch (1.0)", then the slider "Pitch", value "1.2", dimmed likewise.
- Checkbox: "This feed has its own audio speed".
  Hint: "When on, audio here plays at the speed below unless a book has its own, and a change of speed made while listening changes it for the whole feed."
- Checkbox: "Use the global audio speed (1 times speed)", then the slider "Audio speed", value "1.5 times speed".
- Text: "12 episodes keep their own speed.", then the button "Remove Their Own Speed…".
  Its question: "Remove the speed that 12 episodes of Planet Money keep for themselves? They will use this feed's speed."
  Its buttons: "Remove", "Cancel".

The "Use the global …" checkboxes follow the pattern Feed Info already has (`FeedWording.useGlobal`, `FeedInfoSheet.swift:391-415`).

**In the reader**, after a change, the value first, so a second press cuts the rest short:

- to a feed: "1.5 times speed, for this feed"; "275 words per minute, for this feed"; "Pitch 1.2, for this feed"; "Voice changed to Daniel, for this feed";
- to a folder, named because it may be a folder above: "1.5 times speed, for the folder Fiction";
- to the Reading List: "1.5 times speed, for the Reading List";
- to a book inside a scope: "1.5 times speed, for this book only";
- with no scope: "1.5 times speed", as today.

**In the book's settings sheet**, while a scope applies:

- A line of text under the heading, one element: "Voice from the feed Planet Money. Speed from this book. Pitch from the global settings."
  For an audiobook: "Speed from the folder Fiction."
- Pop-up button: "Changes apply to", value "This feed" or "This book only".
  Hint: "Whether a change of voice, speed, or pitch is kept for the whole feed or for this book alone."
- After choosing: "This book now follows the feed Planet Money." or "This book now keeps its own voice, speed, and pitch."

A book opened says nothing new: the speed is heard, and the sheet tells its source.

## 7. Stored form

One optional object, the same in all three places, stored only while a scope is on:

    "playbackScope": {
        "speech": { "voiceID": "com.apple.voice.compact.en-GB.Daniel", "wordsPerMinute": 275, "pitch": 1.2 },
        "audio": { "speed": 1.5 }
    }

- `speech` present means the speech scope is on, and `audio` present the audio scope; `{}` is on with every value global.
- `voiceID` is a string; `wordsPerMinute`, `pitch`, and `speed` are numbers, each optional, each validated as the book's own is (`SettingsPolicy.validatedLocalSpeed`, `validatedLocalPitch`, `SettingsPolicy.swift:604-619`).
- It is read leniently, as `ListeningOptions` is (`ListeningOptions.swift:89-104`): a value that is not an object, or a number out of range, reads as absent, so a scope can never make a feed's record or the library unreadable.
- An object with neither part is never written, so a feed, folder, or list left alone saves byte for byte as before.

Where it lives:

- **A feed:** `Feed.playbackScope`, in the feed's record beside `listeningOptions` (`Feed.swift:101`), written through `FeedCenter` beside `setListeningOptions(_:of:)` (`FeedCenter.swift:1209`).
- **A folder:** `BookFolder.playbackScope`, in the folder's entry of `library.json` (`BookFolder.swift:14`).
  It follows a renamed or moved folder, and a merge of two equivalent folders keeps the survivor's, as it does the listening options (`Library.swift:885`).
- **The Reading List:** `ReadingList.playbackScope`, in `library.json`'s list (`ReadingList.swift:94-103`).
- **The global audio speed:** `audioSpeed` in `config.json`, a number from 0.25 to 4.0, default 1.0, through a new `SettingsPolicy.audioSpeed` rule and the mirrored names in `ConfigService.swift:674`.

What an older TextMouth does:

- 0.4.11 and earlier ignore all four keys, and drop each from a file they save again.
  The scope is then off, and every book plays by its own and the global values: nothing is damaged, and no book loses a value of its own.
- From V04 (on main, after 0.4.11), an older TextMouth keeps the folder's key, the list's, and `config.json`'s through its saves.
  It still drops a feed's: `Feed` keeps no unknown keys (`FeedRecord`, `Feed.swift:187-190`).
  Giving `Feed` an `UnknownKeys` in the storage branch helps the next key, not this one.

`OnDiskContractTests` gains `playbackScope` in the reading list's keys (`:449`), `audioSpeed` in `config.json`'s (`:242`), and two new tests pinning a folder entry's keys and a feed's keys, which nothing pins today.
The library row and the package record are unchanged, so their tests must pass untouched.

## 8. The code

**New, shared by both platforms:**

- `TextMouth/Models/PlaybackScope.swift`: the stored object of section 7, and `isEmpty`.
- `TextMouth/Models/PlaybackSettingsResolver.swift`: the one place that resolves a setting for a book, data in and data out, like `EndOfBookRule`.
  It takes the book's own values, the layers nearest first (each a `PlaybackSettingSource` and its `PlaybackScope?`), and the global values.
  It returns `ResolvedPlaybackSettings`: the voice, words per minute, pitch, and audio speed, each with the source it came from, and the owner of each kind (section 5).
  `PlaybackSettingSource` is `.book`, `.readingList`, `.feed(id:title:)`, `.folder(id:name:)`, or `.global`.
- `TextMouth/ViewModels/LibraryViewModel+PlaybackScopes.swift`: `playbackLayers(of:readFromReadingList:)`, which gathers a book's layers beside `listeningOptions(of:)`.
  It also holds the folder's and the list's setters, each saving once and saving nothing for no change, the count and the clearing of books that keep their own, and the `.playbackScopesChanged` notification all three setters post.
- `TextMouth/Models/PlaybackScopeWording.swift`: the sentences of section 6.
- `TextMouth/Views/Library/PlaybackScopeControls.swift`: the group of controls, one view for the three sheets, and a voice pop-up shared with `BookVoicePickerView` (its pickers today are `ReaderView.swift:888-900`).
- `TextMouth/Views/Library/ReadingListSettingsSheet.swift`.

**Changed:**

- `ReaderViewModel+VoiceAndSpeed.swift`: one `applyResolvedPlaybackSettings()` replaces `applyLocalSpeechOverrides()` (`:86`), `applyGlobalSpeechSettingsWhereTheBookKeepsNone()` (`:174`), and `applySpeechSettingsOfTheBook()` (`:192`), and keeps the look-ahead check of `:106-112`.
  `adjustSpeed` (`:33`), `adjustPitch` (`:46`), `setLocalVoice` (`:57`), and `resetToGlobalSettings` (`:150`) write through one `writePlaybackSetting` that asks the resolver for the owner and words the announcement.
- `ReaderViewModel+Playback.swift:2850` (`setAudioSpeed`), the same way.
- `ReaderViewModel.swift`: `:909` and `:922-929` become the one call; `:1493-1502` also listens for `.playbackScopesChanged`.
- `ReaderViewModel+LibraryUpdates.swift:33` and `ReaderViewModel+ReadingList.swift`: resolve again after a move, and when the reader starts or stops reading from the list.
- `SpeechExportVoice.swift:48`: takes the resolved values; an export is never read from the list.
- `Book.swift:1751`, and the callers that pass a global speed for a row's time remaining: the resolved speed.
- `Feed.swift:101`, `BookFolder.swift:14`, `ReadingList.swift:94`, `Library.swift:885`, `FeedCenter.swift:1209`: the key and its setters.
- `FeedInfoSheet.swift:417`, `FolderSettingsSheet.swift:153`: the shared group after the listening controls.
- `LibraryFolderSettingsTarget.swift:44`, `LibraryView.swift:1841`: the Reading List target.
- `ReaderView.swift:816-900` and `BookSettingsWording` (`:1131`): the source line and "Changes apply to".
- `SettingsPolicy.swift:373`, `SettingsViewModel.swift:367`, `ConfigService.swift:674`, `SettingsView.swift:227-252`: the global audio speed and its slider.

**Tests** (each new class in `Scripts/test/areas.conf`):

- `PlaybackSettingsResolverTests`: every order of section 3 as a table, each setting apart, each owner of section 5, and a scope that is off or empty passed over.
- `PlaybackScopeTests`: coding, lenient reading, never stored when empty, values clamped.
- `LibraryPlaybackScopesTests`: the layers of a feed item, a nested folder, a book at the top level, and a moved book; setters that save once.
- Reader tests beside `PlaybackSettingsAuditTests` and `ViewsAndWindowsReaderSheetTests`: a step writes to the owner and says the sentence; a scope changed elsewhere reaches a playing reader; with no scope, every existing test passes unchanged.
- `PlaybackScopeWordingTests`, and sheet tests beside `FolderSettingsSheetTests`.
- `OnDiskContractTests`, `UnknownKeysTests`, `ListeningOptionsTests`, and the config fixtures' tests.

## 9. The branches

In build order.
Each leaves every book sounding as it does today until a scope is turned on, and the first three cannot turn one on.

1. **`scopes/resolver`.**
   `PlaybackScope`, `PlaybackSettingsResolver`, and their tests; the reader's three apply paths become `applyResolvedPlaybackSettings()` with no layers.
   A pure refactor, proved by the existing reader tests passing unchanged.
2. **`scopes/global-audio-speed`.**
   The `audioSpeed` setting, its slider "Default Audio Speed" in Settings, Voice, and the audiobook's Reset reworded "Reset to Global Speed".
   At its default of 1 times speed nothing changes.
3. **`scopes/storage`.**
   The key in the three places, the setters, the notification, `playbackLayers(of:readFromReadingList:)`, and the reader, the export, and the estimates resolving with the layers.
   No control sets a scope yet, so tests set them.
4. **`scopes/reader-writes`.**
   The owner rule, the announcements' endings, and the book sheet's source line and "Changes apply to".
5. **`scopes/feed-sheet`.**
   `PlaybackScopeControls`, `PlaybackScopeWording`, Feed Info, and "Remove Their Own Speed…".
   The first branch a listener can use.
6. **`scopes/folder-sheet`.**
   Folder Settings, and the nested-folder cases with VoiceOver's sentences.
7. **`scopes/reading-list-sheet`.**
   The Reading List target of the settings command, and its sheet.

The iPhone app honours a scope from branch 3 and writes to it from branch 4, by the shared reader; turning one on from the iPhone waits for its own sheets.
The user pages a documentation pass must change: `docs/user/reader-windows.md` (A book's own settings), `docs/user/feed-listening-and-settings.md`, `docs/user/data-directory-files.md`, and the Reading List's and the settings' pages.

## 10. What this plan could not verify

- No code was built or run: every line number was read from main, and every sentence is a proposal, unheard in VoiceOver.
- How soon a voice changed from another window is heard in a playing chapter was not measured; the plan gives it the path of a book's own voice change (`setLocalVoice(_:)`).
- The count of books that keep their own values was not timed on a large feed.
- Whether nine controls fit Feed Info's fixed frame was not checked; its body already scrolls.

## 11. Questions for the user, each with the answer the plan builds

1. **Audio has no global speed today. Add one?**
   Recommended: yes, "Default Audio Speed" in Settings, Voice, starting at 1 times speed.
2. **With a scope on, should a speed change in the reader change the feed (or folder, or list), not the book?**
   Recommended: yes, and it says "for this feed"; a book is kept apart by "Changes apply to: This book only" in its own sheet.
   The other answers: always the book, so a scope is set only in its sheet; or ask each time, which interrupts listening.
3. **Opened from the Reading List, should the list's settings beat the feed's or folder's?**
   Recommended: yes, as the list's "When a book ends" does, and only when the list's own scope is on.
   The other answer: the feed or folder first, since a slow speaker stays slow in any queue.
4. **Should a folder's settings reach the folders inside it?**
   Recommended: yes, the nearest folder with a scope wins.
5. **An episode moved to the library: take its new folder's settings, with nothing copied from the feed?**
   Recommended: yes.
6. **The Reading List's settings: a sheet from the toolbar's settings button, "Reading List Settings"?**
   Recommended: yes, and the options bar stays as it is.
7. **Turning a scope on leaves each book's own speed in place and offers "Remove Their Own Speed…". Right?**
   Recommended: yes; the other answer clears them without asking, which loses choices made on purpose.
