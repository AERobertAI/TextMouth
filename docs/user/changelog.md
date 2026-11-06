# Changelog

Part of [TextMouth's documentation](../../README.md).

Every version of TextMouth, newest first, and what changed for you in each.

## 0.3.2 (November 6, 2026)
### A library in the cloud
- A library in Google Drive, iCloud Drive, or Dropbox now opens by itself when some of its files aren't on this Mac. TextMouth gets them from the sync service, shows Getting Your Library while it does, and opens the library when they arrive. It used to stop on Library Not Available until you chose Try Again (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- If it can't get them, TextMouth says so and says what to check, after trying again for a little while. Books you opened from Finder while waiting open with the library, or are named if they couldn't.
- TextMouth also gets your settings, statistics, substitutions, and feed records in the background when a library in the cloud opens, and never saves over a copy still in the cloud.
- TextMouth can no longer freeze at launch waiting for a folder that is only in the cloud.
### Commands
- The Next Page and Previous Page commands and their keys are gone. To move by page, choose Page as the navigation unit and use Skip Forward and Skip Backward, or use Go to Page… (Option-Command-G) (see [Reader windows](reader-windows.md)). A key you gave either of those commands is dropped the next time TextMouth opens, and your other shortcuts are kept.

## 0.3.1 (November 5, 2026)
### Rich text and Word documents
- TextMouth reads rich text (.rtf), rich text with attachments (.rtfd), and Word 97-2003 documents and templates (.doc, .dot) with code of its own, on the Mac as on iOS. Apple's textutil tool read them on the Mac before, and does not exist on iOS (see [What TextMouth reads](what-textmouth-reads.md)).
- A document's headings are the ones its author set: a paragraph in a heading style, or with an outline level, is a heading at that level, where textutil lost the styles and guessed from font sizes. A document that names no heading still gets the guess from font sizes and bold.
- Pages that textutil lost are found. In rich text, a paragraph set to start a page and a section that starts a page begin pages, as a page break does. In a Word 97-2003 document, a paragraph set to start a page, directly or by its style, and a section that starts a page begin pages, as the author's page breaks do (see [Reader windows](reader-windows.md)).
- A Word field's code, which textutil sometimes read aloud as words such as TITLE and MERGEFORMAT, is never read, only the field's result. A Word document's headers are no longer read at the end of the book. Text a tracked change deleted is left out, and the footnotes and endnotes follow the main text.
- Hidden text in a rich text document is not read, and neither are its headers, footers, and footnotes. The words in a drawing's text box are read.
- A rich text file that textutil refused as damaged, such as one that begins {\rtf with no version number, is read.
- Rich text in a code page of two-byte characters, such as Japanese, Chinese, or Korean, is read whole.
- An .rtfd package is held to the 64 MB limit by its text file, TXT.rtf, alone, and its attachments no longer count.
- Rich text, rich text with attachments, and Word 97-2003 documents read the same on iOS as on the Mac. OpenDocument text, Word 2003 XML, and Word 6 and Word 95 documents are still read by textutil on the Mac, and on iOS are refused (see [Adding books](adding-books.md)).
- The first time this version opens, every rich text, rich text with attachments, and Word 97-2003 book is read again once, for its headings and its pages. Your place follows its words, and a book whose text you changed with Edit Text keeps that text.

## 0.3.0 (November 4, 2026)
### Kindle books
- TextMouth reads Kindle books that are not copy-protected, in the MOBI format: .mobi, .prc, and .azw files in the older MOBI 6 format, and the MOBI 6 part of a .mobi made for both formats, as many Kindle books are. Each becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings (see [What TextMouth reads](what-textmouth-reads.md)).
- A book's chapters come from its own table of contents, the entries under a chapter being its headings, and a book with no table of contents is a chapter for each page break its maker wrote. What a book's head says about it is never read aloud.
- Open Book… offers Kindle books, and Finder offers TextMouth in the Open With menu for them.
- A copy-protected book is refused, never read: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books." A book only in the newer KF8 format, as an .azw3 is, is refused for now, with "This Kindle book is in the newer KF8 format, which TextMouth can't read yet." [Adding books](adding-books.md) gives every sentence.
- Kindle books have no pages yet.

### Older versions
- Caution: TextMouth 0.2.1 to 0.2.6 opens a library that holds a Kindle book without that book. The book stays in the library, so this version shows it again, but it leaves the Reading List the next time the list changes in the older version. TextMouth 0.2.0 and earlier can't open such a library at all.

## 0.2.6 (November 4, 2026)
### Reading
- A book whose EPUB gives its pages no numbers no longer has a page named by its markup: a page list whose one entry was named "pagenum_000000" made the page button say "Page pagenum_000000 of 1". A page list that gives none of its pages a number now counts as none, and a page break named only "Page" is no page. Such a book shows no page button, and Next Page says "This book has no pages."
- The hint of Go to Page…'s field says how many pages the book has, from its first page to its last, as in "This book has 300 pages, from i to 300. Type a page as the book numbers it, such as 12 or xii." A book of one page names it: "This book's only page is 1."
- A page a book names "Page 12" is now page 12, where the page button said "Page Page 12 of 300".
- A book of one page shows no page button, which said "Page 1 of 1" wherever you were.
- In a book of one page, Next Page, Previous Page, Go to Page…, and a skip by Page say "This book has only one page." and do nothing. The Navigate menu dims the three commands, the playback bar's pickers leave Page out, and Where Am I? leaves the page out.
- The first time this version opens, every EPUB and HTML book is read again once, for its pages. In the books these changes mend, a page number printed at a page break now names its page, and is no longer read aloud, as page numbers never are.

## 0.2.5 (November 1, 2026)
### The next book in this window
- When listening goes on from one book to another, at the end of a book or with Next in Reading List and Previous in Reading List, the next book now shows in the window you are in, in place of the book there, instead of opening a new window. The window keeps its place and size on the screen, and the book you leave is saved as closing its window saves it (see [Reader windows](reader-windows.md)).
- A book already open in another window comes forward, and the window you moved from closes, so no two windows show one book. A sheet or an alert open over the window, a field being typed in, Edit Text in use for the book, or a library that is moving or not available still opens a new window.
- The Playback tab of Settings has a pop-up button, "Open the next book in", with "This Window", the default, and "A New Window", which keeps the way earlier versions went. config.json holds it as nextBookWindow (see [Settings](settings.md) and [Editing settings in config.json](config-json.md)).
- Feed Info has a pop-up button of its own, "Open the next episode in", "Open the next article in", or "Open the next item in", and Folder Settings has "Open the next book in", each with "Use the global setting" first, then "This Window" and "A New Window". It is dimmed, with a hint that says when it is available, while the feed's or folder's items do not go on to another item when one ends (see [Podcasts and article feeds](feeds.md) and [The Library window](library-window.md)).

### Next and Previous in a folder
- The Navigate menu has Next in Folder and Previous in Folder, in a reader window, with no keys until you give them some in the Shortcuts tab. They go to the next or the previous item of the book's folder or feed: Next goes the way the end of the book would go on, up in a feed or folder that plays the one above and down in every other case, and Previous goes the other way. A book that was playing plays the item, after "Starting: <title>", and any other only opens it, after "Opening: <title>".
- An episode that is not on this Mac is downloaded first, with "Downloading the next episode: <title>" or "Downloading the previous episode: <title>", and goes on when it arrives. With no item that way, they say why, as in "No more books in folder." A failed or cancelled download says so, as in "The previous episode could not be downloaded. <reason>" and "Download of the previous episode cancelled."

### The sleep timer
- A running sleep timer now goes on with listening to the next book, in this window or a new one, and stops that book when it runs out, where before it kept the next book from starting, as in "Opening: Dune. Not started because of the sleep timer." Going on to another book never starts its countdown again, the timer waits for a book that is still opening, and a timer set for the end of the heading or of the book that runs out at a book's end still ends listening there.
- Restart Sleep Timer, from its shortcut or the AirPods gesture, while the timer is on its way to the next book, starts it again and it still goes on with the book.
- The timer can say two new sentences: "Sleep timer cancelled, because the next book could not be opened." when the book failed to open, and "Sleep timer cancelled, because you moved to another book while it faded out." when Next or Previous ended a fade.

### Older versions
- Caution: an older TextMouth ignores the new setting, opening every next book in a new window, and drops a feed's or folder's own choice the next time it saves that feed or folder.

## 0.2.4 (November 1, 2026)
### Library
- The Library window's View pop-up, which VoiceOver calls "Library view", replaces the row of categories, and offers the views you choose, in the order you choose: Folders, All Items, Unopened, Recently Opened, Reading List, Feeds, and views of your own (see [The Library window](library-window.md)).
- A new Feeds view lists the feeds alone, each by title, and the pop-up offers it only while there is a feed, until you set it to Always.
- The Library tab of Settings, between Stats and Feeds, lists the views in order, and sets each one to Always, When Applicable, or Hidden, with Move Up and Move Down (see [Settings](settings.md)).
- New View…, Edit…, Duplicate, Delete…, and Restore Default… make and change views, with what each lists, All Conditions or Any Condition, nine kinds of condition, one item for each feed, a sort, and a limit, and a count of what the draft lists; the built-in views are changed the same way, and Restore Default… gives one back.
- A view you hide, or that lists nothing, stays in a window that shows it until you choose another, and a view deleted while a window shows it moves that window to the first view offered and says so.
- Go to View 1 to Go to View 9, Command-1 to Command-9, go to the first nine views the pop-up offers, and say the view's name and what it lists; the Library menu has a Go to View submenu.
- The libraryViews key of config.json holds the views, and every view's sort stays in library.json (see [Editing settings in config.json](config-json.md)). A TextMouth older than 0.2.4 drops the key from config.json, but the Mac keeps the views.

### Braille
- A BRF or BRL file is read in the braille file characters it is written in: North American Braille ASCII, Eurobraille, six-dot (German-speaking countries), or Unicode braille patterns, which TextMouth recognizes by the file's bytes (see [What TextMouth reads](what-textmouth-reads.md)).
- The Braille tab has a "Braille file characters" pop-up for the books you add from then on, and the Export dialog has one for a BRF, which starts from it.
- Book Information has a "Braille File Characters" pop-up that reads a BRF or BRL book again in other characters, asking first, and Speak Full Info says "Braille characters: North American Braille ASCII".
- A file in eight-bit computer braille or in UTF-16 is refused by name, with a sentence that says so (see [Adding books](adding-books.md)).
- Replace Existing keeps a braille book's characters.
- Stop in the Export dialog ends a braille export at once, even while its translation runs.
- Caution: a library holding books set to Eurobraille or Unicode braille patterns should not be opened in a TextMouth older than 0.2.4. An older TextMouth reads such a book as North American Braille ASCII when it reads its file again, which gives wrong numbers and punctuation, or refuses a Unicode book and keeps its old text, and it drops the setting at its next save (see [Where TextMouth keeps your library](where-your-library-lives.md)).

### Reading and playing
- Quitting while a book plays keeps its place to the second, not up to 30 seconds back, and a book at rest writes nothing at quit, so a Mac left idle never undoes another Mac's newer places in a shared library.
- The time the Mac sleeps with a book playing no longer counts as listening.
- A one-file audiobook with chapter markers plays its last seconds before it is announced finished.
- Next Bookmark and Previous Bookmark go in the order the bookmarks lie in the book.
- A sleep timer of minutes stops counting while nothing plays after a stop, as after a pause.
- Stop, or Release Media Controls, while a chapter downloads from the cloud no longer leaves Play doing nothing.
- A voice that reports a word past the end of its text no longer ends TextMouth.

### Podcasts and feeds
- Cancel Download chosen while the episode is already being added says "“Ep. 368” is already being added to the library.", and the episode stays as it was asked for.
- Download or Open chosen right after Cancel Download now downloads the episode.
- A feed download or check stopped just as it began no longer stays stuck until TextMouth restarts.
- An episode you deleted stays deleted when its feed briefly lists nothing, or less.
- New episodes a check found are not lost when the library could not be saved before quitting.

### Importing
- Open Book… opens a TextMouth package, a folder ending in .tmb, instead of refusing it, and puts it in the folder the window shows; of several chosen, only the first opens.
- A TextMouth package inside a ZIP imports as one book, with its places and bookmarks.
- Opening a copy of a book's package no longer points the book at the copy.
- A ZIP holding a DAISY book with audio is kept after import, since it can be the only copy of the book's text, and an alert says so.
- Delete After Import never deletes a file inside another book's package or inside the TextMouth library folder.
- A Markdown book whose file is named content.md keeps its own file.
- A duplicate's new copy left by quitting before its question was answered is moved to the Trash at the next launch, with an alert titled "Duplicate Copies Moved to the Trash" that says how to Put Back, unless its question is less than a day old.
- Keep Both and Replace Existing say, naming the book, when the library can't be reached, when the copy's files are gone, or when TextMouth could not keep the copy.
- An import from a disk or network share that drops partway reports the failure instead of ending TextMouth.
- An EPUB can no longer bring the text of a file on your Mac into its title, author, or headings.
- EPUB, DAISY, and PDF books whose contents, page list, or outline nest thousands of levels deep import without crashing.
- An audio file whose header claims an absurd length or sample rate is refused instead of ending the import.
- An Ogg file named .mp3 or .m4a is no longer opened by Apple's audio code during import.

### Your files
- Adding back a book removed with Remove from Library Only keeps your Edit Text changes, and a package of an edited book imports; text that could not be kept is saved beside the new reading as content.md.edited-, and a book that could not be kept stops being added back and says so.
- Reading positions saved while the library index could not be read are kept once it is restored.
- Rebuild Library Index no longer replaces an index that can be read again, and says "The library index was not rebuilt. It can be read again now. Choose Try Again to use it."
- A Reading List change made while a folder is renamed or moved, or the library is moved, is no longer undone.
- A library opened without its index keeps its folders, and a book in a folder with no row gets one at launch.
- A move of the data directory from a folder that is not there says "The current data directory does not exist."

### Audio editing
- The equalizer, and every filter, says which option it needs when it is given none, as in "The equalizer filter needs its frequency: give a number from 0.0001 to 999999.", and a width that makes no usable filter is refused, where it ruined the audio it was applied to.
- An exported MP3 chapter's title is no longer cut short at a Windows line break.

## 0.2.3 (October 25, 2026)
### Reading
- You can choose the encoding a plain text, Markdown, or HTML book's file is read in, which mends a guess that was wrong or missed, and the book is read again in it with its places moving to their words (see [The Library window](library-window.md)).
- Automatic, in the same choice, reads the file as TextMouth reads a file you add, which takes a choice back.
- A file is read in the encoding you choose whatever its bytes say of themselves, and one with a byte that is not valid in it is refused with "“Moby-Dick” can't be read as Shift JIS (Japanese): it holds bytes that are not valid in that encoding. Nothing was changed."
- Characters of JIS X 0212 in EUC-JP, the euro sign in Big5 and EUC-KR, and Big5-HKSCS characters are refused when you choose those encodings, since macOS reads them wrongly or not at all (see [What TextMouth reads](what-textmouth-reads.md)).

### Library
- Book Information's Text Encoding is a pop-up button now, for every plain text, Markdown, or HTML book you added from a file, where it was a row only for a book whose encoding was guessed.
- The pop-up names the encoding the book is read in and what decided it, as in "Windows-1251 (Cyrillic), guessed", "Shift JIS (Japanese), chosen", "UTF-8, from its byte order mark", "ISO 8859-2 (Central European), declared in the file", or "Windows-1252 (Western European), the default".
- Choosing an encoding asks first, and says what happens to your place and bookmarks and to an edit of the book's text, which is kept beside the new reading as a copy.
- VoiceOver says what the book is now read as, as in "“Moby-Dick” is now read as KOI8-R (Russian), chosen.", and where a copy of its earlier text was kept.
- Speak Full Info says "Text encoding: Shift JIS (Japanese), chosen." for a book whose encoding you chose.
- A book is not read again in another encoding, and the sheet says why, while the library's text is being read again, while the book is being exported, or while it is being read again already.
- Edit Text stops for a book you have read again in another encoding, keeps your edit as a copy, and says "Edit Text has stopped for Moby-Dick, since its file was read again. Choose Edit Text again to edit the new text."
- Edit Text, Replace Existing, and Redo Text Extraction wait while a book is read again in another encoding, and say "TextMouth is reading “Moby-Dick” again in another encoding. Try again when that finishes.", where Redo Text Extraction in Storage settings said nothing.
- A TextMouth older than 0.2.3 drops the note that an encoding was chosen: 0.2.2 reads the book in the same encoding as a guess, and 0.1.1 drops the encoding too (see [Where TextMouth keeps your library](where-your-library-lives.md)).

## 0.2.2 (October 24, 2026)
### Reading
- Go to Page… says which page of a shared label it reached, as in "Jumped to page 2, the second page labelled 2."
- Go to Page… says where the cursor is, and why, when it cannot land on the page asked for, as in "Page 7 has no words, so the cursor is on page 8." and "Page 40 is in a skipped section, so the cursor is on page 52.", where it said the page typed.
- Return in Go to Page's field, on a label that another page carries too, goes to that label's next page, and round to the first after the last, where it closed the panel and did nothing.
- A page break's number inside an EPUB or HTML heading is no longer part of the heading: "Part 9Two" is now "Part Two".
- Next Page, Previous Page, and Go to Page… do nothing while a book is still loading, where they said "This book has no pages."
- The playback bar's navigation unit pickers leave Page out for a book without pages.
- A PDF's own page label that looks like a number with a thousands separator, such as 1.100, stays as the PDF gives it, and a PDF already in your library keeps its old labels until Redo Text Extraction reads it again.
- Plain text books have pages: each form feed between words begins one, up to 100,000.
- The first time this version opens, every braille, plain text, EPUB, and HTML book is read again once, and a braille book whose new reading differs from its text keeps a copy of its old text beside it (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- A plain text, Markdown, or HTML file that is neither UTF-8 nor UTF-16 and names no encoding is no longer always read as Windows-1252, since TextMouth now guesses its encoding when you add it, and books already in your library keep their text (see [What TextMouth reads](what-textmouth-reads.md)).

### Braille
- BRF and PEF books have pages, the braille pages an embosser or a braille display counts, named by their braille page number read as print, such as 12 or p1, and Next Page, Previous Page, and Go to Page… move by them.
- A BRF has pages only when it marks them, with form feeds between its braille text or with braille page numbers that end most of its 25-line pieces, and a page with neither words nor a number is not a page.
- English Braille, American Edition is read with its italic and bold where the sign is certain, in words that start with l or n to z, in capitals and numbers, and in most contractions, and no word reads differently from before.
- An emphasized word of English Braille, American Edition that starts with a to j still reads with a stray period, one that starts with k reads with an equals sign, and one that starts with m reads with µ, as before.
- Contracted Unified English Braille reads a whole word before an emphasis end sign as the word, so "people" is no longer "p".

### Library
- Replace Existing puts the new copy in the place of the old one, keeping its reading position, bookmarks, settings, folder, and place on the reading list, and an audiobook's transcript when its audio is proven the same, where it threw them away.
- The duplicate question says what Replace Existing keeps and where the old copy's files go, in place of what it threw away, and for a text book that an edit of its text is kept beside the new text as a copy.
- When one copy is an audiobook and the other is read from its text, Replace Existing keeps only the old copy's folder and place on the reading list, and the question and the button's hint say so.
- With the Trash on, the duplicate question says that putting the old copy's files back won't return that copy to your library, and putting them back does not add it to the library again.
- An audiobook's reading position and bookmarks follow the new copy's chapters when they differ from the old copy's.
- Replace Existing waits, and says why, while the old copy is open in a reader, being transcribed, being exported, or having its audio edited, while some of its files are only in the cloud, or while TextMouth moves books between folders or rebuilds its data directory.
- Replace Existing removes the old copy's files only after the library holds the new copy, and says so if it cannot remove them.
- When Replace Existing keeps an edit of the old copy's text as a copy, VoiceOver says where it was kept.
- Edit Text says it has stopped for a book that Replace Existing replaced.
- Book Information shows a Text Encoding row, and Speak Full Info says the encoding, as in "Text encoding: Windows-1251 (Cyrillic), guessed.", for a text book whose encoding was guessed (see [The Library window](library-window.md)).
- A TextMouth older than 0.2.2 drops a guessed encoding when it saves a book, and that book's text may then read as Windows-1252 again the next time it is rebuilt (see [Where TextMouth keeps your library](where-your-library-lives.md)).

## 0.2.1 (October 23, 2026)
### Reading
- Search in Book also searches an audiobook's transcript, telling you when each match is heard and moving the audio there when you choose one, and Go Back (Command-[) returns to where you were.
- EPUBs that name a file in another letter case than their ZIP spells it now show the chapters they were missing.
- Word 97-2003 files with a table of contents or links now get every page, not only the first.
- The first time this version opens, a book open in a reader gets its new text with its pages, with the cursor on the same words, and words that an EPUB holds inside a page break are kept.
- A heading made of a number, such as "IV" or "1984", in a DAISY or EPUB book is read even where a page begins, and only a page's own number is left unread.
- A line in the text that begins with a page or chapter marker no longer hides the rest of its words.

### Listening
- Retranscribe Audio… takes the place of Transcribe Audio… once a book has a transcript, and its sheet says what it replaces and asks you to download a book that is only in iCloud first.
- A feed episode's transcript can now be edited and cleaned up, and it stays with the episode in its feed, even after its download is deleted, until you delete the episode or the feed.
- Six faults found in a review of transcription are fixed, among them edits to a transcript that were announced as taken and then lost, a damaged transcript file that could crash TextMouth, and a Clean Up that offered Apply and then refused it.
- Resume after a very quick Pause keeps your place instead of restarting the chapter.
- Seeking in a variable-bit-rate MP3 without a Xing header, whose length was only guessed, now lands where you ask and no longer moves a saved place back.
- Play pressed while a book's files are being moved now waits for the move to end, then plays from your place.
- An audio file that never finishes being read no longer leaves its book on Loading: TextMouth stops waiting after a while and says so.
- Such a file is not read again until TextMouth is opened again, so a file that hangs cannot slow TextMouth down by being opened over and over.
- A retranscription or Clean Up that fails partway leaves the transcript and its text as they were.
- The last chapter's length in an MP3 with chapter markers is measured exactly, not estimated.

### Export
- Exported Markdown, for a book's text and for a transcript, has a backslash only where Markdown needs one, and no chapter-marker lines.

### Library
- The duplicate question now says what Replace Existing throws away: the old copy's reading position, bookmarks, settings, and any edit of its text or transcript.
- TextMouth now keeps the books that a later version added in a form it cannot read, as they are but not shown, instead of refusing the whole library, and Storage settings say how many there are.
- Delete Folder leaves such books, and the folders that hold them, where they are, and says so.

## 0.2.0 (October 21, 2026)
### Going back to 0.1.1
- 0.1.1 cannot read the index of a library that holds a book in any of eight kinds that 0.2.0 added: braille, rich text, rich text with attachments, Word 97-2003, OpenDocument, Word 2003 XML, Safari web archives, and SSML. It leaves library.json as it is, keeps a copy of it beside it, and offers Try Again and Rebuild Library Index under Recovery Options…, but it still writes each book's record, and those records lose what 0.2.0 added to them: the record of an edit of the book's text and of the page reader that wrote it. Back in 0.2.0, a book whose text you edited is read from its file again, and your edit is kept beside it as a copy.
- Never choose Rebuild Library Index in 0.1.1. It makes an index without the books in those eight kinds, and without the folders and the manual order that only the index held, which the copy of library.json that it keeps still has.

### Reading
- Next Page, Previous Page, and Go to Page… move by page in EPUB, PDF, Word, DAISY, and other books that have pages, and Where Am I? says the page; books already in your library gain their pages the first time this version opens. If a book's text differs from what TextMouth reads from its file, as after an edit made with Edit Text before this version, its old text is first kept in a copy beside it; an edit you make from now on is kept as it is.
- Rich text, Word 97-2003, OpenDocument, Safari web archive, SSML, and DTBook files can now be added as books.
- Edit Text opens a book's text in your own editor, and your reading position, bookmarks, and skipped headings stay with their words when the text changes.

### Listening
- Audio in more formats, such as AC-3, AMR, and MP2, is converted as it is added and lossless audio stays lossless; M3U playlists and Nero chapter lists are read, and a manifest.json can arrange a ZIP of tracks, which Edit Manifest changes later.
- New Recording records from a microphone, Edit Audio… edits an audiobook's audio from the keyboard, and Transcribe Audio… turns an audiobook into text on macOS 26 and later.

### Braille
- TextMouth reads BRF, BRL, and PEF braille files and writes BRF and PEF from Export, in Unified English Braille or English Braille, American Edition, contracted or not, chosen in a new Braille tab, and it keeps italic and bold where the code can carry them.
- A Language pop-up adds the braille tables of this Mac's VoiceOver, for many languages beyond English.

### Export
- Export copies a book's audio, original file, text, or transcript out of the library, and its Convert to menu makes a text book's text HTML, RTF, Word 97-2003, BRF, or PEF as well as Markdown.

### Library
- Podcasts and article feeds can be subscribed to by address or by searching Apple's podcast directory, each feed lists its episodes and articles in a folder of its own, and the newest are downloaded as you choose.
- A Reading List holds books from any folder in an order you choose and carries on from one to the next, and the Unopened and Recently Opened categories take the place of No Folder and Recent.
- A library can live in iCloud Drive, Dropbox, or Google Drive, and each book can be downloaded when you need it, removed from this Mac to free space, or kept on it.

## 0.1.1
- The first beta version of TextMouth. Its changes are not listed here.
