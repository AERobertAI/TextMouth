# Changelog

Part of [TextMouth's documentation](../../README.md).

Every version of TextMouth, newest first, and what changed for you in each.

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
