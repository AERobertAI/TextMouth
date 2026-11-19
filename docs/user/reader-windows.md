# Reader windows
<!-- id: reader-windows; keys: reader, book window, playback window, ReaderView, BookReaderWindowView; src: TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

Part of [TextMouth's documentation](../../README.md).

The rest of reading a book has pages of its own:

- [Pages in a reader](reader-pages.md): Go to Page and skipping by page.
- [Media keys and the sleep timer](reader-media-and-sleep-timer.md): headphones, AirPods, the timer.
- [When a book ends, and your saved places](reader-book-end.md): what plays next.
- [When speech or audio goes wrong](reader-speech-problems.md): refusals, stalls, memory limits.

## A window for each book
<!-- id: reader-window-each-book; keys: one window per book, several books open, BookReaderWindowView, open book; src: TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

Each book opens in its own window, and several can be open at once.

## Book content
<!-- id: reader-book-content; keys: text area, scroll area, braille display, maxDisplayChars, 20000 characters; src: TextMouth/Views/Reader/ReaderView.swift, TextMouth/ViewModels/ReaderViewModel.swift; status: incomplete; issues: DR09 -->

Just above the playback controls, the book's text, up to 20,000 characters of the chapter around the reading position, is in a scroll area VoiceOver calls Book content: interact with it to read the text with VoiceOver or on a braille display, whether the book is playing or paused.
The part shown always holds the reading position, keeps whole paragraphs where it can, and never begins or ends inside a word, except in a language written without spaces.
The area doesn't scroll to the reading position, so in a long chapter the text begins up to about 10,000 characters before it.

## Books in a library in the cloud
<!-- id: reader-books-library-cloud; keys: iCloud, download before opening, cloud download, files only in the cloud; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/LibraryCloudWording.swift -->

In a library in the cloud, a book whose files are only in the cloud downloads in its reader window before it opens (see [Keeping your library in the cloud](cloud-library.md)).

## When the library changes an open book
<!-- id: reader-when-library-changes-open-book; keys: metadata edit, rename folder, move book, LibraryBookUpdates, revision, playing during a move; src: TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/ViewModels/LibraryBookUpdates.swift -->

An open book follows what the library does to it elsewhere: a new title or author, a move to another folder, or a renamed folder.
Nothing reloads and speech carries on; an audiobook playing while its files move stops for a moment and plays on from the same place, and one playing from its working copy in a library in the cloud doesn't stop at all.
Meanwhile the book counts as playing.
A Pause or Play/Pause, the sleep timer running out, a recording or another book starting, the AirPods leaving, a stop, or Release Media Controls during the move leaves it paused or stopped when the move is over, and Play then plays it from its place in the moved files.
Play pressed during the move waits in the same way: the book shows Playing, and the move's end plays it from its place in the moved files, unless a Pause or a stop comes first.
A sleep timer set to start playback, or Auto-play on navigate, leaves it to play on as the move ends, and Where Am I? pressed during the move lets it play on once the announcement has ended.
The data directory itself can't move while any book is open.

## The Playback menu
<!-- id: reader-playback-menu; keys: Play/Pause, skip, speed, navigation unit, copy position, menu bar; src: TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Models/KeyboardShortcut.swift -->

The Playback menu holds Play / Pause, Skip Forward and Skip Backward, Cycle Forward Navigation Unit and Cycle Backward Navigation Unit, Increase Speed and Decrease Speed, Where Am I? and Where Am I?
Full Summary, then, while the window's book holds the media controls (see [Release Media Controls](reader-media-and-sleep-timer.md#release-media-controls)), Release Media Controls, and last Copy Reading Position (Shift-Command-P) and Search in Book (Command-F; see below).

## Speak Info
<!-- id: reader-windows-speak-info; keys: summary, Shift-Command-I, SummaryPress, announcement, press twice; src: TextMouth/ViewModels/ReaderViewModel+SpeakInfo.swift, TextMouth/Models/SummaryPress.swift, TextMouth/Models/LibraryInfoWording.swift -->

Speak Info, Shift-Command-I, speaks this window's book's brief summary in the same words the Library's Speak Info says for its row, and Shift-Command-I pressed twice quickly speaks its full summary.
In a reader it is a VoiceOver announcement, made while the book goes on playing, so with VoiceOver off it says nothing; it has no menu item here, since the Library menu is hidden in a reader.

## The Navigate menu
<!-- id: reader-navigate-menu; keys: menu bar, Go Forward, Show Headings, Show Sleep Timer, Book Info, jump history; src: TextMouth/App/MenuCommands.swift, TextMouth/Models/KeyboardShortcut.swift -->

The Navigate menu holds:

- Go to Library,
- Go Back, which in a reader returns to where the last jump began (see below),
- and Go Forward,
- Next Heading and Previous Heading,
- Go to Page… (see [Pages in a reader](reader-pages.md)),
- Next in Reading List and Previous in Reading List (see [The Reading List](reader-book-end.md#the-reading-list)),
- Next in Folder and Previous in Folder (see [Next in Folder and Previous in Folder](reader-book-end.md#next-in-folder-and-previous-in-folder)),
- Show Headings,
- Show Sleep Timer,
- and Book Info.

## Headings that begin at one place
<!-- id: reader-headings-that-begin-at-one; keys: nested headings, subheading, heading chain, outermost heading, Next Heading; src: TextMouth/ViewModels/ReaderViewModel+Navigation.swift -->

Next Heading, Previous Heading, and the subheading jumps say every heading that begins where they land, the outermost first: a season's first episode says "Heading: Season Two, King Nine Will Not Return".
Headings that begin at one place are one stop.
Choosing a heading in Show Headings is unchanged.

## The Bookmarks menu
<!-- id: reader-bookmarks-menu; keys: Add Bookmark, bookmark order, next bookmark, removed book, rotor; src: TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/App/MenuCommands.swift -->

The Bookmarks menu holds Toggle Bookmark, Show Bookmarks, and Next Bookmark and Previous Bookmark.
Next Bookmark and Previous Bookmark go in the order the bookmarks lie in the book, by chapter and then by place in the chapter, not in the order you made them, so with bookmark 1 in chapter 10 and bookmark 2 in chapter 3, Next Bookmark from chapter 1 lands on bookmark 2 first.
Each still says its own number, as in "Bookmark 2", and a press with nothing beyond the cursor neither moves nor speaks.
Add Bookmark and Toggle Bookmark say the number of the bookmark they made, as in "Bookmark 4 added", the number its row in Show Bookmarks has, and not how many bookmarks the book holds.
When the book has left the library, as when it was removed while its reader stayed open, nothing is added or removed.
And VoiceOver says, once focus has settled, "Could not add the bookmark: “Moby-Dick” is no longer in the library." or "Could not remove the bookmark: “Moby-Dick” is no longer in the library."

## The reader's panels
<!-- id: reader-panels; keys: sheets, panels, headings list, bookmarks list, jump panels; src: TextMouth/Views/Reader/HeadingNavigatorView.swift, TextMouth/Views/Reader/BookmarkPanelView.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift -->

### Show Headings
<!-- id: reader-show-headings; keys: heading list, Actions menu, Skip Section, Include Section, Show levels, level filter; src: TextMouth/Views/Reader/HeadingNavigatorView.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift -->

The reader's panels: in Show Headings, each heading's row offers Go To and Skip Section, or Include Section, among its actions in VoiceOver's Actions menu (VO-Command-Space), as its context menu does, and its hint says "Goes to this heading and closes the list."
The level filter, Show levels, offers Level 1, Levels 1 to 2, and so on, and All levels.

### Show Bookmarks
<!-- id: reader-show-bookmarks; keys: bookmark list, rotor, added date, Add Bookmark key, no bookmarks; src: TextMouth/Views/Reader/BookmarkPanelView.swift, TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift -->

In Show Bookmarks, a bookmark's row ends with the day it was added, as in "Bookmark 3, The Battle, Note: Check this, added DATE", which the Bookmarks rotor says too, and its hint says "Goes to this bookmark and closes the list."
With no bookmarks, the panel names the key that adds one, in words, as in "Command + B adds a bookmark at the current position.", or, while that command has no key, says "Add Bookmark adds one at the current position."

### Go to Percent and Go to Time
<!-- id: reader-go-percent-go-time; keys: jump to percent, jump to time, ReaderTimeWording, time left, clock, Time In, Duration; src: TextMouth/Models/ReaderTimeWording.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift, TextMouth/Views/Reader/HeadingNavigatorView.swift -->

The status row's percent and time left are buttons, each opening a panel below it with one labelled field, Return to jump, and Escape to close it.
The percent opens Go to Percent, whose field, "Percent through the book", starts at the place's percent.
The time left opens Go to Time, whose field takes a time typed or pasted as 1:02:03, 62:03, 3723, or 12:04.3, and starts at the place's time, in whole seconds.
For an audiobook the field is "Time in the recording": every time that names a place counts the recording's own time, whatever the speed, so a time from a chapter list, show notes, the audio editor, the Headings sheet, or Copy Reading Position lands where it says.
For a text book it is "Time at 500 words a minute", at the book's own speed.
A time less than a second before a heading lands on the heading.
A time past the end is refused, as in "Time exceeds the recording's length.
The recording lasts 9 hours, 41 minutes, 7 seconds.", shown under the field and spoken.
Return, or Jump, while the field still holds the value it started at closes the panel as Escape does and leaves the place exactly where it is, saying nothing.
The starting time drops the place's fraction of a second and the starting percent is rounded to a tenth, so jumping to either would move the place a little, and a finished book would no longer be finished.
In Show Headings, Time In gives each heading's time on the same clock, for an audiobook the same at every speed, so it can be typed into Go to Time.
And Duration gives each heading's length at the book's speed, to the next heading shown, the last to the very end of the book (a last chapter of exactly 25:03 shows 25:03).
The sheet follows a change of speed, or of the setting that names the speed, made while it is open.

### Copy Reading Position
<!-- id: reader-copy-reading-position; keys: Shift-Command-P, clipboard, position text, Finished; src: TextMouth/Models/ReaderTimeWording.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift -->

Copy Reading Position adds the place's time, as in "at 2:13:05 of 9:41:07 in the recording", or for a text book "at 2:10:24 of 4:20:49 at 500 words a minute", which Go to Time takes back; a finished book copies "Finished" in place of its percent, time, and time left.

### A book's own settings
<!-- id: reader-book-own-settings; keys: per-book voice, per-book speed, toolbar, Voice button, Audio Settings button, global settings; src: TextMouth/Views/Reader/ReaderView.swift, TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift -->

A book's own settings open from the reader's toolbar.
For a text book the button is Voice, which VoiceOver calls Change voice for this book, and its sheet, Voice & Speed for This Book, holds the book's voice, speed, and pitch and what happens when the book ends.
There Save to Global Settings, which the playback bar offers too, makes the book's voice, speed, and pitch the defaults, and Reset to Global Settings removes all three from the book, saying "Using global voice, speed, and pitch settings".
For an audiobook the button is Audio Settings, named the same on screen and by VoiceOver.
Its sheet, Audio Settings for This Book, holds the book's speed, one slider VoiceOver reads as "Audio speed, 1.25 times speed", which moves by 0.05 times; what happens when the book ends; and Reset to Normal Speed while the book has a speed of its own.

## Search in Book
<!-- id: reader-windows-search-book; keys: find in book, BookSearchModel, regular expression, Match Case, Command-F, Search Results rotor; src: TextMouth/Views/Reader/BookSearchView.swift, TextMouth/ViewModels/BookSearchModel.swift, TextMouth/Views/Reader/ReaderView.swift -->

Search in Book, in the Playback menu (Command-F) and as the toolbar's Search button, which VoiceOver calls "Search in book", opens a sheet with a search field, "Search text", a Match Case checkbox, unchecked unless you check it, and a regular-expression switch, and lists the matches as you type.
It lists the first 500, saying so when it finds more, in a list that keeps every row, so VoiceOver's cursor stays put in a long list.
For a text book each result gives its words in context, the heading it is under, and an estimate of where it is, as a percentage or a time as the Display picker chooses, as in "a drowned harbour, The Battle, at 12.5 percent of book".
For an audiobook that has a transcript, Search in Book searches the transcript's text, and every result is timed exactly: the field's hint is "Type to search the book's transcript", the sheet has no Display picker, and a result's row shows when it is heard, as 1:03:45 or, under an hour, 3:45.
VoiceOver reads the row, and the Search Results rotor lists it, as "a drowned harbour, The Battle, at 1 hour, 3 minutes, 45 seconds", the chapter named only when it has a title of its own that is not the book's title.

## Search Library from a reader
<!-- id: reader-search-library-from-reader; keys: Option-Command-F, Find submenu, LibrarySearchWording, match in a book; src: TextMouth/ViewModels/ReaderViewModel+LibrarySearch.swift, TextMouth/Models/LibrarySearchWording.swift, TextMouth/App/MenuCommands.swift -->

Search Library, in the Edit menu's Find submenu (Option-Command-F), searches every book at once and opens a match in its reader, at those words, saying "Moved to the match, Chapter 3." once the window is in front.
Go Back (below) returns to where the reader was before (see [Search Library](search-library.md)).

## Choosing a transcript result
<!-- id: reader-choosing-transcript-result; keys: audio search result, sentence start, Moved to, Auto-play on navigate; src: TextMouth/Views/Reader/BookSearchView.swift, TextMouth/ViewModels/BookSearchModel.swift -->

Choosing a result of a transcript, by Return, Space, a click, or VoiceOver's activation, closes the sheet and moves the audio to the start of the sentence that holds the match, and with Auto-play on navigate on, a paused book plays on from there, as after any jump from a panel.
Once the sheet has closed, VoiceOver says where the audio moved to, as in "Moved to 1 hour, 3 minutes, 45 seconds, The Battle." or, with no chapter to name, "Moved to 1 hour, 3 minutes, 45 seconds."
Return chooses a focused result in a text book's list too.

## Go Back
<!-- id: reader-go-back; keys: Command-[, Return button, last jump, previous position, undo jump; src: TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/BookSearchView.swift -->

Go Back (Command-[), in the Navigate menu, and the toolbar's Return button, which VoiceOver calls "Return to previous reading position" and which is there only while there is a place to return to, take a reader back to where its last jump began.
The jump may have been to a search result, a heading, a bookmark, a page, a percent, or a time.
VoiceOver says "Returned to previous position."
Only the last jump is remembered, and Go Back with no place to return to says "No previous position to return to."

## Search in Book with no text to search
<!-- id: reader-search-book-no-text-search; keys: no transcript, transcript only in iCloud, audio changed, Transcribe Audio, edited text; src: TextMouth/Views/Reader/BookSearchView.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

Search in Book on an audiobook with no text to search says why, in place of opening, and the toolbar shows no Search button:

- With no transcript: "Moby-Dick has no transcript to search.
  Transcribe it first, with Transcribe Audio."
  For a book that is not in a package of its own, which can't be transcribed, it is only "Moby-Dick has no transcript to search."
- With a transcript whose text is not shown: "Moby-Dick has no transcript text to search now", then, by the reason:
  - a full stop alone, when the reason isn't known;
  - the transcript is only in iCloud: ".
    The transcript is only in iCloud, so TextMouth leaves it.
    Download the book, then try again.", or, when its text is: ".
    The book's text is only in iCloud, so TextMouth leaves it.
    Download the book, then try again.";
  - the audio changed since the book was transcribed: ", because the audiobook's audio changed since it was transcribed, so its transcript no longer fits it.
    Transcribe it again, then search the new transcript.";
  - an edit of its text that TextMouth can't take: ", because its edited text can't be used: ", the reason, which ends "and the text shows", and where the edited text was kept (see [Editing a book's text](editing-book-text.md)).

## The Book menu
<!-- id: reader-book-menu; keys: Edit Text With, Retranscribe Audio, Clean Up Transcript, Delete Transcript, Edit Audio, Move to Library, Export; src: TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/App/MenuCommands.swift -->

The Book menu holds:

- Edit Text in Default Editor and Edit Text With…, available for a text book and a transcribed audiobook, a feed's episode included, but not a feed's article,
- then Transcribe Audio…, available for an audiobook and named Retranscribe Audio… once it has a transcript,
- Attach Transcript…, available for the audiobooks Transcribe Audio… is available for (see [Transcribing an audiobook](transcribing.md)),
- Clean Up Transcript (Experimental)… and Delete Transcript…, for a transcribed one,
- then Edit Audio…, for an audiobook other than a feed's episode (see [Editing audio](editing-audio.md)),
- and last Move to Library…, for an episode or article downloaded in its feed (see [Podcasts and article feeds](feed-commands.md)).

File menu, Export… exports the reader's book.

## Edit Manifest
<!-- id: reader-edit-manifest; keys: manifest.json, audiobook of tracks, Edit Manifest With, default editor; src: TextMouth/Models/BookManifestEditWording.swift, TextMouth/Services/BookManifestEditing.swift, TextMouth/ViewModels/ReaderViewModel+ManifestEdit.swift -->

Book menu: Edit Manifest in Default Editor and Edit Manifest With… open an audiobook of tracks' manifest.json in your editor (see [The audiobook manifest](audiobook-manifest.md#editing-an-imported-books-manifest)); they are unavailable for any other book.
