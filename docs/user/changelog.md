# Changelog

Part of [TextMouth's documentation](../../README.md).

Every version of TextMouth, newest first, and what changed for you in each.

## 0.2.2 (October 24, 2026)
### Reading
- Go to Page… says the page that the status row then shows, which is the last of the pages that begin at the place it goes to, where it said the page typed.
- Return in Go to Page's field, on a label that another page carries too, goes to that label's next page, and round to the first after the last, where it closed the panel and did nothing.
- A page break's number inside an EPUB or HTML heading is no longer part of the heading: "Part 9Two" is now "Part Two".
- Next Page, Previous Page, and Go to Page… do nothing while a book is still loading, where they said "This book has no pages."
- The playback bar's navigation unit pickers leave Page out for a book without pages.
- A PDF's own page label that looks like a number with a thousands separator, such as 1.100, stays as the PDF gives it, and a PDF already in your library keeps its old labels until Redo Text Extraction reads it again.
- Plain text books have pages: each form feed between words begins one.
- The first time this version opens, every braille, plain text, EPUB, and HTML book is read again once, and a braille book whose new reading differs from its text keeps a copy of its old text beside it (see [Where TextMouth keeps your library](where-your-library-lives.md)).

### Braille
- BRF and PEF books have pages, the braille pages an embosser or a braille display counts, named by their braille page number read as print, such as 12 or p1, and Next Page, Previous Page, and Go to Page… move by them.
- English Braille, American Edition is read with its italic and bold, and no longer reads stray signs in place of its emphasis signs, such as the period of ".cat" for an italic "cat".
- Contracted Unified English Braille reads a whole word before an emphasis end sign as the word, so "people" is no longer "p".

### Export
- Export to BRF or PEF writes italic and bold in English Braille, American Edition, as it does in Unified English Braille.

### Library
- Replace Existing puts the new copy in the place of the old one, keeping its reading position, bookmarks, settings, folder, and place on the reading list, and an audiobook's transcript when its audio is the same, where it threw them away.
- The duplicate question says what Replace Existing keeps and where the old copy's files go, in place of what it threw away, and for a text book that an edit of its text is kept beside the new text as a copy.
- Replace Existing waits, and says why, while the old copy is open in a reader, being transcribed, being exported, or having its audio edited, or while some of its files are only in the cloud.
- Edit Text says it has stopped for a book that Replace Existing replaced.

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
