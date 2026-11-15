# Settings
<!-- id: settings; keys: ; src: -->

Part of [TextMouth's documentation](../../README.md).

## The tabs
<!-- id: tabs; keys: ; src: -->

Settings has these tabs.

Voice, Playback, Shortcuts, Text (substitution rules and repeated symbols), Braille (the language, the braille code, and its contraction), Sounds, Stats (listening time, streak, and books finished), Library (the Library window's views), Feeds (podcast and article feeds), Storage, and Miscellaneous.
Every tab but Text and Library scrolls when it is taller than the window, its groups in boxes, and Tab, and VoiceOver as it moves, bring each control into view; the Text tab's rule list and the Library tab's list of views scroll by themselves.
A slider is labelled by its setting alone, as "Speed" or "Bluetooth disconnect delay", since VoiceOver names the kind of control itself, and the value shown beside a slider is read once, as the slider's value, with its unit.

## Open the next book in
<!-- id: open-next-book; keys: ; src: -->

The Playback tab's End of Book group has, just below the When book ends pop-up and the captions under it, a pop-up button, "Open the next book in", with the choices "This Window", the default, and "A New Window".
Its hint, which a caption under the pop-up shows and VoiceOver reads once, as the pop-up's hint, is "Where the next book opens when listening goes on from one book to another: in this window in place of the book here, or in a new window.
A book already open in another window is brought forward, and with This Window this window closes."
It decides where the next book opens at the end of a book, with Next in Reading List and Previous in Reading List, and with Next in Folder and Previous in Folder, unless a feed or a folder has a choice of its own (see [Reader windows](reader-windows.md), [Podcasts and article feeds](feeds.md), and [The Library window](library-window.md)). config.json holds it as nextBookWindow, the choice's name (see [Editing settings in config.json](config-json.md)).

## Show Export in the reader toolbar
<!-- id: show-export-reader-toolbar; keys: ; src: -->

The Playback tab's Reader Toolbar section has Show Export in the reader toolbar, off by default, which puts an Export button in every reader's toolbar.
File menu, Export… is there either way.

## Speed with time left
<!-- id: speed-time-left; keys: ; src: -->

The Playback tab's Times group has Include the speed with time left and total time, off by default, which names the speed those times count at beside them: on the reader's status row, as in "3:44:01 left at 2.0x", which VoiceOver reads as "at 2.0 times speed", or "at 500 words a minute" for a text book; in Where Am I?'s time left, and its full summary's total; in Copy Reading Position's time left; and in the Headings sheet's durations.
An audiobook at 1x names nothing, and Where Am I?'s time left in the heading never names the speed.

## Pages in the reader and Where Am I?
<!-- id: pages-reader-where-am-i; keys: ; src: -->

The Playback tab's Pages group has two checkboxes, both on by default.
"Show the page on the reader screen" puts the page being read beside the percent on a reader's status row, for a book of more than one page; its hint is "Shows the page being read, such as Page 12 of 300, beside the percent, for books of more than one page."
"Say the page in Where Am I?" adds the page to Where Am I?'s brief and full summaries; its hint is "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books of more than one page."
Each hint is shown as a caption under its checkbox, and VoiceOver says it once, as the checkbox's hint.
The Page navigation unit and Go to Page… work whichever way the checkboxes are set (see [Reader windows](reader-windows.md)). config.json holds them as showsPageInReader and saysPageInWhereAmI (see [Editing settings in config.json](config-json.md)).

## Transcription
<!-- id: settings-transcription; keys: ; src: -->

The Playback tab's Transcription group chooses the language audiobooks are transcribed in, and whether TextMouth offers to transcribe each audiobook it imports (see [Transcribing an audiobook](transcribing.md)).

## Repeated Symbols
<!-- id: repeated-symbols; keys: ; src: -->

The Text tab's Repeated Symbols group sets how the voice reads one symbol written several times in a row, directly or with single spaces between, such as a separator line of asterisks.
Say how many, the default, reads a run of 4 or more as a count, such as "7 asterisks"; Leave out skips the run with a pause; Repeat each symbol reads every one.
"Collapse runs of at least" sets the shortest run that is counted or left out (2 to 99), and "Never collapse: read every symbol" reads every symbol whatever the style.
The Symbols field lists the characters that can form runs; Reset to Default restores the standard list of ASCII symbols, bullets, dashes, the ellipsis, and box-drawing lines.
Only speech changes: the text on screen and on a braille display keeps every symbol.
A change applies from the next chapter spoken.

## Reset the text rules
<!-- id: reset-text-rules; keys: ; src: -->

The Text tab's Reset to Defaults asks first, naming how many rules it replaces, as in "The 15 rules in the list will be replaced by TextMouth's 16 default rules.
Rules you added or changed will be lost."
In a regular expression rule's replacement, $1, $2, and so on put back what each group of the pattern matched, as the replacement field's hint says, naming the dollar sign in words.

## Reset sound effects
<!-- id: reset-sound-effects; keys: ; src: -->

The Sounds tab's Reset to Defaults gives the sound assignments, the volume, and sounds on their defaults again at once, and VoiceOver says "The sound effects are reset to the defaults."

## Books Finished and listening time
<!-- id: books-finished-listening-time; keys: ; src: -->

The Stats tab's Books Finished This Year and Books Finished All Time count text books, audiobooks, and podcast episodes apart as well as together, under each count and spoken with it as one sentence, as in "7 books finished this year: 4 text books, 2 audiobooks, and 1 podcast episode".
An article from a feed counts as a text book.
A book finished before TextMouth counted kinds counts by its kind while it is in the library, and among other books once it has left.
Books Finished counts each book once, however often it is finished, in the year it was first finished, and a rewind that replays a finished book's end counts nothing.
Recently Finished lists the last ten books counted, newest first, each once, by the first time it was finished.
The repeats an earlier version wrote, at each end of a book, stay in reading_stats.json and are counted once.
Once on each Mac, after a launch's maintenance that has read reading_stats.json, TextMouth puts each book Books Finished counts whose row reads 100 percent exactly at its end, so it says Finished, keeping the date it was last opened, so Recently Opened, the Last Opened sort, and Speak Info stay as they were; while the statistics file is missing or cannot be read, nothing is moved, and the first launch that reads it makes the move; a book whose record is only in the cloud, or that is open in a window, waits for a later launch, and one whose content index disagrees with its row is left where it is.
The time the Mac sleeps with a book playing is never counted as listening: not in Today, This Week, All Time, the streak, or the book's total.

## Restart timer gesture note
<!-- id: restart-timer-gesture-note; keys: ; src: -->

The Miscellaneous tab's note under the restart timer gesture names the action that does the same from the keyboard as the Shortcuts tab names it: "The keyboard shortcut for the same action is Restart Sleep Timer in the Shortcuts tab; its default is Shift + Command + R."
