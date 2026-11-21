# Settings
<!-- id: settings; keys: Preferences, Settings window, Command-Comma, config.json; src: TextMouth/Views/Settings/SettingsView.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

Part of [TextMouth's documentation](../../README.md).

## The tabs
<!-- id: tabs; keys: Preferences, tab bar, Voice tab, Feeds tab, slider value, scrolling tab, VoiceOver slider; src: TextMouth/Views/Settings/SettingsView.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

Settings has these tabs.

Voice, Playback, Shortcuts, Text (substitution rules and repeated symbols), Braille (the language, the braille code, and its contraction), Sounds, Stats (listening time, streak, and books finished), Library (the Library window's views), Feeds (podcast and article feeds), Storage, and Miscellaneous.
Every tab but Text and Library scrolls when it is taller than the window, its groups in boxes, and Tab, and VoiceOver as it moves, bring each control into view; the Text tab's rule list and the Library tab's list of views scroll by themselves.
A slider is labelled by its setting alone, as "Speed" or "Bluetooth disconnect delay", since VoiceOver names the kind of control itself, and the value shown beside a slider is read once, as the slider's value, with its unit.

Four tabs have pages of their own, and this page holds the rest:

- [Settings: the Shortcuts tab](settings-shortcuts.md), with the keys a text field keeps.
- [Settings: the Braille tab](settings-braille.md), with this Mac's braille tables.
- [Settings: the Library tab](settings-library.md), with its views, titles, and the view editor.
- [Settings: the Storage tab](settings-storage.md), with the library folder, imports, duplicates, and maintenance.

## The language of the interface
<!-- id: interface-language; keys: language, Spanish, Japanese, Korean, Language & Region, localization, translated interface, String Catalog; src: TextMouth/Localization/Localizable.xcstrings; status: incomplete; issues: FR34 -->

TextMouth's own words, its menus, buttons, hints, and messages, are in eleven languages: English, Spanish, Italian, French, Brazilian Portuguese, German, Russian, Ukrainian, Simplified Chinese, Japanese, and Korean.
All but English are machine translations, which a native speaker will review.
TextMouth follows the language order of the Mac or iPhone and shows the first of those languages it has.
To set TextMouth's language alone, on the Mac choose it in System Settings, General, Language & Region, Applications; on the iPhone, in Settings, TextMouth, Language.
A language TextMouth does not have shows English.
This is separate from the voice, which speaks a book in the voice's own language, from the transcription language (see [Transcribing an audiobook](transcribing.md)), and from the braille language (see the Braille tab).

## Open the next book in
<!-- id: open-next-book; keys: nextBookWindow, End of Book, When book ends, This Window, A New Window, next book; src: TextMouth/Models/NextBookWindow.swift, TextMouth/Views/NextBookWindowPicker.swift, TextMouth/Views/Settings/SettingsView.swift -->

The Playback tab's End of Book group has, just below the When book ends pop-up and the captions under it, a pop-up button, "Open the next book in", with the choices "This Window", the default, and "A New Window".
Its hint, which a caption under the pop-up shows and VoiceOver reads once, as the pop-up's hint, is "Chooses where the next book opens: in this window or a new one.
A book open in another window comes forward, and with This Window chosen, this window closes."
It decides where the next book opens at the end of a book, with Next in Reading List and Previous in Reading List, and with Next in Folder and Previous in Folder.
A feed or a folder with a choice of its own overrides it (see [Reader windows](reader-windows.md), [Podcasts and article feeds](feed-listening-and-settings.md), and [The Library window](library-window.md)).
The file config.json holds it as nextBookWindow, the choice's name (see [Editing settings in config.json](config-json.md)).

## Show Export in the reader toolbar
<!-- id: show-export-reader-toolbar; keys: showExportInReaderToolbar, Export button, reader toolbar; src: TextMouth/Models/BookExportWording.swift, TextMouth/Views/Settings/SettingsView.swift -->

The Playback tab's Reader Toolbar section has Show Export in the reader toolbar, off by default, which puts an Export button in every reader's toolbar.
File menu, Export… is there either way.

## Speed with time left
<!-- id: speed-time-left; keys: includeSpeedWithTimes, time left, total time, status row, words a minute, playback speed; src: TextMouth/Models/ReaderTimeWording.swift, TextMouth/Views/Settings/SettingsView.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift -->

The Playback tab's Times group has Include the speed with time left and total time, off by default.
It names the speed those times count at beside them: on the reader's status row, as in "3:44:01 left at 2.0x", which VoiceOver reads as "at 2.0 times speed", or "at 500 words a minute" for a text book.
It does so in Where Am I?'s time left, and its full summary's total, in Copy Reading Position's time left, and in the Headings sheet's durations.
An audiobook at 1x names nothing, and Where Am I?'s time left in the heading never names the speed.

## Pages in the reader and Where Am I?
<!-- id: pages-reader-where-am-i; keys: showsPageInReader, saysPageInWhereAmI, page number, Go to Page, page navigation unit; src: TextMouth/Models/ReaderPageWording.swift, TextMouth/Views/Settings/SettingsView.swift -->

The Playback tab's Pages group has two checkboxes, both on by default.
"Show the page on the reader screen" puts the page being read beside the percent on a reader's status row, for a book of more than one page; its hint is "Shows the page being read, such as Page 12 of 300, beside the percent, for books of more than one page."
"Say the page in Where Am I?" adds the page to Where Am I?'s brief and full summaries; its hint is "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books of more than one page."
Each hint is shown as a caption under its checkbox, and VoiceOver says it once, as the checkbox's hint.
The Page navigation unit and Go to Page… work whichever way the checkboxes are set (see [Reader windows](reader-pages.md)). config.json holds them as showsPageInReader and saysPageInWhereAmI (see [Editing settings in config.json](config-json.md)).

## Transcription
<!-- id: settings-transcription; keys: transcriptionLocale, offerTranscriptionAfterImport, speech recognition, language, Transcribe Audio; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/Views/Transcription/TranscriptionSettingsSection.swift -->

The Playback tab's Transcription group chooses the language audiobooks are transcribed in, and whether TextMouth offers to transcribe each audiobook it imports (see [Transcribing an audiobook](transcribing.md)).

## Repeated Symbols
<!-- id: repeated-symbols; keys: repeatedSymbolStyle, repeatedSymbolThreshold, repeatedSymbolSet, asterisks, separator line, run of symbols; src: TextMouth/Views/Settings/RepeatedSymbolsSettingsView.swift, TextMouth/Services/RepeatedSymbolRule.swift -->

The Text tab's Repeated Symbols group sets how the voice reads one symbol written several times in a row, directly or with single spaces between, such as a separator line of asterisks.
Say how many, the default, reads a run of 4 or more as a count, such as "7 asterisks"; Leave out skips the run with a pause; Repeat each symbol reads every one.
"Collapse runs of at least" sets the shortest run that is counted or left out (2 to 99), and "Never collapse: read every symbol" reads every symbol whatever the style.
The Symbols field lists the characters that can form runs; Reset to Default restores the standard list of ASCII symbols, bullets, dashes, the ellipsis, and box-drawing lines.
Only speech changes: the text on screen and on a braille display keeps every symbol.
A change applies from the next chapter spoken.

## Import and export rules as a pronunciation lexicon
<!-- id: lexicon-import-export; keys: Import Rules, Export Rules, pronunciation lexicon, PLS, W3C, grapheme, alias, phoneme; src: TextMouth/Views/Settings/SubstitutionsSettingsView.swift, TextMouth/Parsers/PronunciationLexicon.swift, TextMouth/Services/TextSubstitutionService+Lexicon.swift, TextMouth/Models/PronunciationLexiconWording.swift; status: incomplete; issues: DR32 -->

The Text tab's Import Rules… reads a W3C pronunciation lexicon (a .pls file) and adds its spelling-to-words entries after your rules, as plain text rules that match a whole word and ignore case.
Its hint says the entries go after your rules, and that entries giving only phonetic spellings are set aside.
An alert titled "Rules Imported" then says what happened, as in "Added 3 rules from “names.pls”.
It goes on, as needed, with "1 rule was already in your rules." and "2 entries give only a phonetic spelling, so they were set aside."
A rule already among yours is skipped, and a lexicon adds at most 5000 rules at a time, saying how many entries it did not read.
A file that is not a lexicon, or is larger than 8 MB, ends in an alert titled "Import Failed".
Export Rules… saves your plain text rules that are on as a lexicon, named "Substitution Rules.pls" at first.
Rules that use regular expressions, and rules that are off, are left out.
Its alert, "Rules Exported", counts the rules written and the ones left out.
When none can be written, it says "There are no rules to export.
Only plain text rules that are on can be written in a lexicon."
The iPhone app has no Text tab, so a .pls lexicon is refused there as "not a playlist" without the advice to import it.

## Reset the text rules
<!-- id: reset-text-rules; keys: substitutions, substitutions.json, regular expression, $1, Reset to Defaults, pronunciation rules; src: TextMouth/Views/Settings/SubstitutionsSettingsView.swift, TextMouth/Services/TextSubstitutionService.swift -->

The Text tab's Reset to Defaults asks first, naming how many rules it replaces, as in "The 15 rules in the list will be replaced by TextMouth's 16 default rules.
Rules you added or changed will be lost."
In a regular expression rule's replacement, $1, $2, and so on put back what each group of the pattern matched, as the replacement field's hint says, naming the dollar sign in words.

## Reset sound effects
<!-- id: reset-sound-effects; keys: soundEffectsEnabled, soundEffectsVolume, soundEffectAssignments, sound assignments, Reset to Defaults; src: TextMouth/Views/Settings/SoundEffectsSettingsView.swift -->

The Sounds tab's Reset to Defaults gives the sound assignments, the volume, and sounds on their defaults again at once, and VoiceOver says "Sound effects reset to defaults"

## Books Finished and listening time
<!-- id: books-finished-listening-time; keys: reading_stats.json, streak, Recently Finished, Today, This Week, All Time, sleep; src: TextMouth/Views/Settings/ReadingStatsView.swift, TextMouth/Models/ReadingStatsTile.swift, TextMouth/Services/ReadingStatsService.swift -->

The Stats tab's Books Finished This Year and Books Finished All Time count text books, audiobooks, and podcast episodes apart as well as together, under each count and spoken with it as one sentence, as in "7 books finished this year: 4 text books, 2 audiobooks, and 1 podcast episode".
An article from a feed counts as a text book.
A book finished before TextMouth counted kinds counts by its kind while it is in the library, and among other books once it has left.
Books Finished counts each book once, however often it is finished, in the year it was first finished, and a rewind that replays a finished book's end counts nothing.
Recently Finished lists the last ten books counted, newest first, each once, by the first time it was finished.
The repeats an earlier version wrote, at each end of a book, stay in reading_stats.json and are counted once.
Once on each Mac, after a launch's maintenance that has read reading_stats.json, TextMouth puts each book Books Finished counts whose row reads 100 percent exactly at its end, so it says Finished.
It keeps the date the book was last opened, so Recently Opened, the Last Opened sort, and Speak Info stay as they were.
While the statistics file is missing or cannot be read, nothing is moved, and the first launch that reads it makes the move.
A book whose record is only in the cloud, or that is open in a window, waits for a later launch, and one whose content index disagrees with its row is left where it is.
The time the Mac sleeps with a book playing is never counted as listening: not in Today, This Week, All Time, the streak, or the book's total.

## Restart timer gesture note
<!-- id: restart-timer-gesture-note; keys: restartTimerGestureEnabled, restartTimerGesturePattern, Restart Sleep Timer, bluetooth, media gesture, Miscellaneous tab; src: TextMouth/Views/Settings/MiscellaneousSettingsView.swift -->

The Miscellaneous tab's note under the restart timer gesture names the action that does the same from the keyboard as the Shortcuts tab names it: "The keyboard shortcut for the same action is Restart Sleep Timer in the Shortcuts tab; its default is Shift + Command + R."
